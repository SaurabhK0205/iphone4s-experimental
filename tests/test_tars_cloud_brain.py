"""Unit tests for Multi-Cloud TARS Brain Adapter.

Tests:
1. Brain initialization, environment loading, and status reporting.
2. Multipart form-data encoding for audio uploads.
3. System prompt construction and anti-AI-slop em-dash verification.
4. Action JSON schema parsing, type normalization, and fallback resilience.
5. Strict torch boolean validation (protecting against "false" string bug).
6. Multi-cloud cascade failover on HTTP 429 Too Many Requests.
7. Cloud Whisper STT failover from Groq to Cloudflare.
8. STT fail-closed behavior raising RuntimeError when all tiers fail.
9. Gemini API header-based authentication and history serialization.
10. Strict repository-wide zero em-dash invariant.
"""

import json
import os
import time
import unittest
import urllib.error
from unittest.mock import MagicMock, patch

from tars_cloud_brain import (
    TarsCloudBrain,
    _NoRedirectHandler,
    encode_multipart_formdata,
)


def make_mock_response(json_data):
    mock = MagicMock()
    mock.read.return_value = json.dumps(json_data).encode("utf-8")
    mock.__enter__.return_value = mock
    return mock


class TestTarsCloudBrain(unittest.TestCase):
    def setUp(self):
        # Isolate test fixture from ambient environment overrides
        self._saved_env = {}
        for key in (
            "TARS_HUMOR_PERCENT", "TARS_HONESTY_PERCENT",
            "OPENROUTER_VISION_MODEL", "GEMINI_API_KEY",
            "GROQ_API_KEY", "CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID",
            "OPENROUTER_API_KEY"
        ):
            if key in os.environ:
                self._saved_env[key] = os.environ.pop(key)

        self.brain = TarsCloudBrain(
            groq_api_key="mock_groq_key",
            cf_api_token="mock_cf_token",
            cf_account_id="mock_cf_account",
            openrouter_api_key="mock_or_key",
            gemini_api_key="mock_gemini_key",
            humor_percent=80,
            honesty_percent=95,
            dotenv_path="/dev/null",
        )

    def tearDown(self):
        for key in (
            "TARS_HUMOR_PERCENT", "TARS_HONESTY_PERCENT",
            "OPENROUTER_VISION_MODEL", "GEMINI_API_KEY",
            "GROQ_API_KEY", "CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID",
            "OPENROUTER_API_KEY"
        ):
            if key in os.environ:
                del os.environ[key]
        for key, val in self._saved_env.items():
            os.environ[key] = val

    def test_status_reporting(self):
        status = self.brain.get_status()
        self.assertEqual(status["status"], "ready")
        self.assertEqual(status["active_tiers_count"], 4)
        self.assertEqual(status["tars_settings"]["humor_percent"], 80)
        self.assertEqual(status["tars_settings"]["honesty_percent"], 95)
        self.assertEqual(len(status["tiers"]), 4)

    def test_multipart_formdata_encoding(self):
        fields = {"model": "whisper-large-v3-turbo", "language": "en"}
        files = {"file": ("test.wav", b"RIFFmockwavdata", "audio/wav")}
        body, content_type = encode_multipart_formdata(fields, files)

        self.assertIn("multipart/form-data; boundary=", content_type)
        self.assertIn(b'name="model"', body)
        self.assertIn(b"whisper-large-v3-turbo", body)
        self.assertIn(b'filename="test.wav"', body)
        self.assertIn(b"RIFFmockwavdata", body)

    def test_system_prompt_anti_slop(self):
        prompt = self.brain._build_system_prompt()
        self.assertIn("Humor=80%", prompt)
        self.assertIn("Honesty=95%", prompt)
        # Verify strict zero em-dashes rule
        self.assertNotIn("\u2014", prompt)
        self.assertNotIn("\u2013", prompt)

    def test_parse_action_json_clean(self):
        valid_json = json.dumps({
            "speech": "I have a cue light I can turn on when I'm being sarcastic.",
            "expression": "skeptical",
            "look_at": [0.5, -0.2],
            "torch": False,
            "haptic": "pulse"
        })
        action = self.brain._parse_action_json(valid_json)
        self.assertEqual(action["speech"], "I have a cue light I can turn on when I'm being sarcastic.")
        self.assertEqual(action["expression"], "skeptical")
        self.assertEqual(action["look_at"], [0.5, -0.2])
        self.assertFalse(action["torch"])
        self.assertEqual(action["haptic"], "pulse")

    def test_parse_action_json_torch_validation(self):
        # String 'false' must produce boolean False, not truthy
        action_false_str = self.brain._parse_action_json(json.dumps({"torch": "false"}))
        self.assertFalse(action_false_str["torch"])

        action_true_str = self.brain._parse_action_json(json.dumps({"torch": "true"}))
        self.assertTrue(action_true_str["torch"])

        action_bool_false = self.brain._parse_action_json(json.dumps({"torch": False}))
        self.assertFalse(action_bool_false["torch"])

        action_bool_true = self.brain._parse_action_json(json.dumps({"torch": True}))
        self.assertTrue(action_bool_true["torch"])

        action_invalid = self.brain._parse_action_json(json.dumps({"torch": "invalid"}))
        self.assertFalse(action_invalid["torch"])

    def test_parse_action_json_markdown_block(self):
        raw = "```json\n{\n  \"speech\": \"Absolute honesty isn't always diplomatic.\",\n  \"expression\": \"happy\",\n  \"look_at\": [0.0, 0.0],\n  \"torch\": true,\n  \"haptic\": \"double\"\n}\n```"
        action = self.brain._parse_action_json(raw)
        self.assertEqual(action["speech"], "Absolute honesty isn't always diplomatic.")
        self.assertEqual(action["expression"], "happy")
        self.assertTrue(action["torch"])
        self.assertEqual(action["haptic"], "double")

    def test_parse_action_json_fallback_on_malformed(self):
        malformed = "Just some text without any valid JSON."
        action = self.brain._parse_action_json(malformed)
        self.assertEqual(action["speech"], "Just some text without any valid JSON.")
        self.assertEqual(action["expression"], "neutral")
        self.assertEqual(action["look_at"], [0.0, 0.0])
        self.assertFalse(action["torch"])

    def test_env_personality_fallback(self):
        # When constructor arguments are omitted, env vars should take effect
        with patch.dict(os.environ, {"TARS_HUMOR_PERCENT": "65", "TARS_HONESTY_PERCENT": "85"}):
            brain = TarsCloudBrain()
            self.assertEqual(brain.humor_percent, 65)
            self.assertEqual(brain.honesty_percent, 85)

    def test_parse_action_json_multiple_code_blocks(self):
        # Multiple code blocks (e.g. reasoning block + JSON action block)
        multi_block = (
            "Here is my reasoning:\n"
            "```text\nAnalyzing visual scene. Detection positive.\n```\n"
            "Action plan:\n"
            "```json\n{\n  \"speech\": \"Target identified.\",\n  \"expression\": \"focused\"\n}\n```\n"
        )
        action = self.brain._parse_action_json(multi_block)
        self.assertEqual(action["speech"], "Target identified.")
        self.assertEqual(action["expression"], "focused")

    @patch("urllib.request.OpenerDirector.open")
    def test_groq_429_failover_to_cloudflare(self, mock_urlopen):
        error_429 = urllib.error.HTTPError(
            url="https://api.groq.com/openai/v1/chat/completions",
            code=429,
            msg="Too Many Requests",
            hdrs={},
            fp=None
        )

        cf_response = make_mock_response({
            "result": {
                "response": json.dumps({
                    "speech": "Cloudflare edge fallback online.",
                    "expression": "happy",
                    "look_at": [0.0, 0.0],
                    "torch": False,
                    "haptic": "pulse"
                })
            }
        })

        # Groq retries once on transient 429 before cascading to Cloudflare
        mock_urlopen.side_effect = [error_429, error_429, cf_response]

        action = self.brain.think_and_act("Hello TARS")
        self.assertEqual(action["speech"], "Cloudflare edge fallback online.")
        self.assertEqual(action["expression"], "happy")

    @patch("urllib.request.OpenerDirector.open")
    def test_groq_and_cloudflare_fail_failover_to_openrouter(self, mock_urlopen):
        err1 = urllib.error.HTTPError(url="", code=429, msg="Rate Limited", hdrs={}, fp=None)
        err2 = urllib.error.HTTPError(url="", code=503, msg="Service Unavailable", hdrs={}, fp=None)
        openrouter_response = make_mock_response({
            "choices": [{
                "message": {
                    "content": json.dumps({
                        "speech": "OpenRouter free pool activated.",
                        "expression": "happy",
                        "look_at": [0.0, 0.0],
                        "torch": False,
                        "haptic": None
                    })
                }
            }]
        })

        # Groq retries once, Cloudflare retries once, OpenRouter succeeds
        mock_urlopen.side_effect = [err1, err1, err2, err2, openrouter_response]

        action = self.brain.think_and_act("Status report")
        self.assertEqual(action["speech"], "OpenRouter free pool activated.")
        self.assertEqual(action["expression"], "happy")

    @patch("urllib.request.OpenerDirector.open")
    def test_think_and_act_groq_empty_content_cascades_to_cloudflare(self, mock_urlopen):
        # Groq returns empty content e.g. when reasoning tokens exhaust budget
        groq_empty = make_mock_response({
            "choices": [{
                "message": {"content": ""},
                "finish_reason": "length"
            }]
        })
        cf_response = make_mock_response({
            "result": {
                "response": json.dumps({
                    "speech": "Cloudflare edge fallback active.",
                    "expression": "alert",
                    "look_at": [0.0, 0.0],
                    "torch": False,
                    "haptic": "pulse"
                })
            }
        })
        mock_urlopen.side_effect = [groq_empty, cf_response]

        action = self.brain.think_and_act("Test empty reasoning output")
        self.assertEqual(action["speech"], "Cloudflare edge fallback active.")
        self.assertEqual(action["expression"], "alert")

    @patch("urllib.request.OpenerDirector.open")
    def test_think_and_act_groq_invalid_json_cascades_to_cloudflare(self, mock_urlopen):
        # Groq returns raw conversational prose without JSON format
        groq_prose = make_mock_response({
            "choices": [{
                "message": {"content": "I am unable to format this as a JSON object."},
                "finish_reason": "stop"
            }]
        })
        cf_response = make_mock_response({
            "result": {
                "response": json.dumps({
                    "speech": "Recovered via Cloudflare tier.",
                    "expression": "happy",
                    "look_at": [0.0, 0.0],
                    "torch": False,
                    "haptic": "pulse"
                })
            }
        })
        mock_urlopen.side_effect = [groq_prose, cf_response]

        action = self.brain.think_and_act("Status report")
        self.assertEqual(action["speech"], "Recovered via Cloudflare tier.")
        self.assertEqual(action["expression"], "happy")
        self.assertEqual(mock_urlopen.call_count, 2)

    @patch("urllib.request.OpenerDirector.open")
    def test_stt_whisper_groq_empty_transcript_preservation(self, mock_urlopen):
        # A successful STT call returning empty text must return "" without triggering failover
        groq_empty_response = make_mock_response({"text": ""})
        mock_urlopen.return_value = groq_empty_response

        transcript = self.brain.transcribe_audio(b"RIFFmockwavdata")
        self.assertEqual(transcript, "")
        self.assertEqual(mock_urlopen.call_count, 1)

    @patch("urllib.request.OpenerDirector.open")
    def test_stt_whisper_groq_malformed_response_triggers_failover(self, mock_urlopen):
        # When Groq returns {} without 'text', it must raise ValueError and failover to Cloudflare
        groq_malformed = make_mock_response({})
        cf_response = make_mock_response({"result": {"text": "Failover transcription."}})
        mock_urlopen.side_effect = [groq_malformed, cf_response]

        transcript = self.brain.transcribe_audio(b"RIFFmockwavdata")
        self.assertEqual(transcript, "Failover transcription.")

    @patch("urllib.request.OpenerDirector.open")
    def test_stt_whisper_groq_failover_to_cloudflare(self, mock_urlopen):
        err_groq = urllib.error.HTTPError(url="", code=429, msg="Rate Limited", hdrs={}, fp=None)
        cf_response = make_mock_response({
            "result": {
                "text": "Initiating docking sequence."
            }
        })

        mock_urlopen.side_effect = [err_groq, err_groq, cf_response]

        transcript = self.brain.transcribe_audio(b"RIFFmockwavdata")
        self.assertEqual(transcript, "Initiating docking sequence.")

    @patch("urllib.request.OpenerDirector.open")
    def test_stt_whisper_all_fail_raises_runtime_error(self, mock_urlopen):
        err_groq = urllib.error.HTTPError(url="", code=429, msg="Rate Limited", hdrs={}, fp=None)
        err_cf = urllib.error.HTTPError(url="", code=500, msg="Server Error", hdrs={}, fp=None)

        mock_urlopen.side_effect = [err_groq, err_groq, err_cf, err_cf]

        with self.assertRaises(RuntimeError) as ctx:
            self.brain.transcribe_audio(b"RIFFmockwavdata")
        self.assertIn("All configured speech-to-text tiers failed", str(ctx.exception))

    def test_urlopen_slow_headers_deadline_abort(self):
        # Starts a local server that trickles headers slowly
        import http.server
        import socketserver
        import threading
        import time
        import urllib.request

        # Explicitly bypass ambient proxies for loopback test
        self.brain._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirectHandler)

        class SlowHeaderHandler(http.server.BaseHTTPRequestHandler):
            def handle_one_request(self):
                try:
                    self.wfile.write(b"HTTP/1.1 200 OK\r\nServer: SlowTest\r\n")
                    self.wfile.flush()
                    for i in range(10):
                        time.sleep(0.5)
                        self.wfile.write(f"X-Hdr-{i}: slow\r\n".encode())
                        self.wfile.flush()
                    self.wfile.write(b"\r\nBody")
                    self.wfile.flush()
                except Exception:
                    pass

        server = socketserver.TCPServer(("127.0.0.1", 0), SlowHeaderHandler)
        port = server.server_address[1]
        t = threading.Thread(target=server.handle_request, daemon=True)
        t.start()

        start = time.monotonic()
        req = urllib.request.Request(f"http://127.0.0.1:{port}")
        # Deadline set to 0.7s, well below the 5.0s header trickle
        try:
            with self.assertRaises(TimeoutError):
                self.brain._urlopen_with_backoff(req, timeout=5.0, deadline=start + 0.7)
            elapsed = time.monotonic() - start
            # Must abort close to deadline (under 2.0s) rather than blocking for 5.0s
            self.assertLess(elapsed, 2.0)
        finally:
            server.server_close()

    def test_urlopen_slow_dns_deadline_abort(self):
        # Verifies that a slow DNS getaddrinfo (1.5s) does not block past deadline (0.8s),
        # exercises _fetch_with_deadline, and prevents HTTP transmission after resolution.
        import http.server
        import socket
        import socketserver
        import threading
        import time
        import urllib.request

        # Explicitly bypass ambient proxies for loopback test
        self.brain._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirectHandler)

        received_requests = []
        gai_called = [False]

        class RequestMonitor(http.server.BaseHTTPRequestHandler):
            def handle_one_request(self):
                self.raw_requestline = self.rfile.readline(65537)
                if self.raw_requestline:
                    received_requests.append(self.raw_requestline)

        server = socketserver.TCPServer(("127.0.0.1", 0), RequestMonitor)
        port = server.server_address[1]
        t_srv = threading.Thread(target=server.handle_request, daemon=True)
        t_srv.start()

        orig_getaddrinfo = socket.getaddrinfo
        dns_unblock_event = threading.Event()

        def slow_getaddrinfo(host, p, *args, **kwargs):
            if host == "127.0.0.1":
                gai_called[0] = True
                dns_unblock_event.wait(timeout=2.0)
            return orig_getaddrinfo(host, p, *args, **kwargs)

        socket.getaddrinfo = slow_getaddrinfo
        try:
            start = time.monotonic()
            req = urllib.request.Request(f"http://127.0.0.1:{port}", data=b"payload", method="POST")
            with self.assertRaises(TimeoutError):
                self.brain._urlopen_with_backoff(req, timeout=5.0, deadline=start + 0.8)
            elapsed = time.monotonic() - start
            # Must abort around the 0.8s deadline, well before 2.0s DNS completion
            self.assertLess(elapsed, 1.3)
            self.assertTrue(gai_called[0])

            # Unblock the slow getaddrinfo and allow worker thread to exit
            dns_unblock_event.set()
            time.sleep(0.1)
            # Verify server received zero transmitted requests
            self.assertEqual(len(received_requests), 0)
        finally:
            dns_unblock_event.set()
            socket.getaddrinfo = orig_getaddrinfo
            server.server_close()

    def test_worker_admission_limit_bounds_concurrent_workers(self):
        # Exhaust all available worker slots on the semaphore
        acquired_slots = []
        for _ in range(4):
            acquired = self.brain._worker_semaphore.acquire(blocking=False)
            self.assertTrue(acquired)
            acquired_slots.append(acquired)

        try:
            req = urllib.request.Request("http://127.0.0.1:9")
            with self.assertRaises(TimeoutError) as ctx:
                self.brain._urlopen_with_backoff(req, timeout=5.0, deadline=time.monotonic() + 2.0)
            self.assertIn("admission limit reached", str(ctx.exception))
        finally:
            for _ in acquired_slots:
                self.brain._worker_semaphore.release()

    def test_urlopen_redirect_does_not_drain_body_or_block_worker(self):
        # A 302 redirect with a trickling body must raise HTTPError immediately without draining body
        import http.server
        import socketserver
        import threading

        # Explicitly bypass ambient proxies for loopback test
        self.brain._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirectHandler)

        class Trickling302Handler(http.server.BaseHTTPRequestHandler):
            def handle_one_request(self):
                self.raw_requestline = self.rfile.readline(65537)
                if not self.parse_request():
                    return
                self.send_response(302)
                self.send_header("Location", "/other")
                self.send_header("Content-Length", "100")
                self.end_headers()
                for _ in range(10):
                    time.sleep(0.5)
                    try:
                        self.wfile.write(b"x")
                        self.wfile.flush()
                    except Exception:
                        break

        server = socketserver.TCPServer(("127.0.0.1", 0), Trickling302Handler)
        port = server.server_address[1]
        t = threading.Thread(target=server.handle_request, daemon=True)
        t.start()

        start = time.monotonic()
        req = urllib.request.Request(f"http://127.0.0.1:{port}")
        try:
            with self.assertRaises(urllib.error.HTTPError) as ctx:
                self.brain._urlopen_with_backoff(req, timeout=5.0, deadline=start + 5.0)
            self.assertEqual(ctx.exception.code, 302)
            elapsed = time.monotonic() - start
            # Must abort immediately (under 1.0s) rather than waiting for 5.0s body trickle
            self.assertLess(elapsed, 1.0)
        finally:
            server.server_close()

    def test_instance_opener_captures_proxy_from_dotenv(self):
        # Verify that instance-local opener created after load_dotenv captures proxy settings from .env file
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as f:
            f.write("HTTPS_PROXY=http://proxy.local:8080\n")
            dotenv_path = f.name

        try:
            with patch.dict(os.environ, {}, clear=False):
                os.environ.pop("HTTPS_PROXY", None)
                os.environ.pop("https_proxy", None)
                brain = TarsCloudBrain(dotenv_path=dotenv_path)
                proxy_handlers = [h for h in brain._opener.handlers if isinstance(h, urllib.request.ProxyHandler)]
                self.assertTrue(len(proxy_handlers) > 0)
                self.assertEqual(proxy_handlers[0].proxies.get("https"), "http://proxy.local:8080")
        finally:
            if os.path.exists(dotenv_path):
                os.unlink(dotenv_path)

    def test_tls_handshake_stall_abort_and_healthy_failover(self):
        # Verifies that cancellation during a stalled TLS handshake releases worker slots
        # and allows subsequent requests to healthy providers to proceed without blockage.
        import http.server
        import socket
        import socketserver
        import threading

        # Stalling TLS server
        srv_stall = socketserver.TCPServer(("127.0.0.1", 0), socketserver.BaseRequestHandler)
        stall_port = srv_stall.server_address[1]

        def srv_stall_loop():
            while True:
                try:
                    sock, _ = srv_stall.socket.accept()
                    time.sleep(5)
                    sock.close()
                except Exception:
                    break

        t_stall = threading.Thread(target=srv_stall_loop, daemon=True)
        t_stall.start()

        # Healthy local HTTP server
        class HealthyHandler(http.server.BaseHTTPRequestHandler):
            def handle_one_request(self):
                self.raw_requestline = self.rfile.readline(65537)
                if not self.parse_request():
                    return
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"HEALTHY_OK")

        srv_healthy = socketserver.TCPServer(("127.0.0.1", 0), HealthyHandler)
        healthy_port = srv_healthy.server_address[1]
        t_healthy = threading.Thread(target=srv_healthy.handle_request, daemon=True)
        t_healthy.start()

        # Run 4 stalled HTTPS transfers
        try:
            for _ in range(4):
                start = time.monotonic()
                req = urllib.request.Request(f"https://127.0.0.1:{stall_port}")
                try:
                    self.brain._urlopen_with_backoff(req, timeout=5.0, deadline=start + 0.8)
                except Exception:
                    pass

            # Confirm all 4 worker slots recovered
            for _ in range(20):
                if self.brain._worker_semaphore._value == 4:
                    break
                time.sleep(0.05)
            self.assertEqual(self.brain._worker_semaphore._value, 4)

            # Submit 5th request to healthy endpoint
            req_healthy = urllib.request.Request(f"http://127.0.0.1:{healthy_port}")
            resp_bytes = self.brain._urlopen_with_backoff(req_healthy, timeout=5.0, deadline=time.monotonic() + 5.0)
            self.assertEqual(resp_bytes, b"HEALTHY_OK")
        finally:
            srv_stall.server_close()
            srv_healthy.server_close()

    @patch("urllib.request.OpenerDirector.open")
    def test_gemini_header_auth_and_history(self, mock_urlopen):
        gemini_response = make_mock_response({
            "candidates": [{
                "content": {
                    "parts": [{
                        "text": json.dumps({
                            "speech": "Gemini response with history.",
                            "expression": "thinking",
                            "look_at": [0.0, 0.0],
                            "torch": False,
                            "haptic": None
                        })
                    }]
                }
            }]
        })
        mock_urlopen.return_value = gemini_response

        history = [
            {"role": "user", "content": "What is your humor setting?"},
            {"role": "assistant", "content": "Seventy-five percent."}
        ]
        action = self.brain._think_gemini(
            transcript="Can you lower it?",
            system_prompt="System prompt",
            front_b64=None,
            back_b64=None,
            history=history
        )
        self.assertIsNotNone(action)
        self.assertEqual(action["speech"], "Gemini response with history.")

        # Verify request headers and URL
        call_args = mock_urlopen.call_args[0]
        req = call_args[0]
        self.assertEqual(req.headers.get("X-goog-api-key"), "mock_gemini_key")
        self.assertNotIn("key=", req.full_url)

    def test_transcribe_audio_size_limit(self):
        oversized = b"0" * (16 * 1024 * 1024)
        with self.assertRaises(ValueError) as ctx:
            self.brain.transcribe_audio(oversized)
        self.assertIn("exceeds maximum limit", str(ctx.exception))

    def test_parse_action_json_escaped_em_dash(self):
        # Simulates JSON response with unicode-escaped em-dash and en-dash
        raw_json = '{"speech": "Docking sequence complete' + chr(0x2014) + 'initiating spin", "expression": "neutral"}'
        action = self.brain._parse_action_json(raw_json)
        self.assertIsNotNone(action)
        self.assertNotIn(chr(0x2014), action["speech"])
        self.assertIn("complete: initiating spin", action["speech"])

    def test_transcribe_audio_file_bounded_read(self):
        import tempfile
        from tars_cloud_brain import MAX_AUDIO_BYTES
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            f.write(b"0" * (MAX_AUDIO_BYTES + 2048))
            temp_path = f.name
        try:
            with self.assertRaises(ValueError) as ctx:
                self.brain.transcribe_audio(temp_path)
            self.assertIn("exceeds maximum limit", str(ctx.exception))
        finally:
            if os.path.exists(temp_path):
                os.unlink(temp_path)

    def test_cloudflare_dual_camera_skips_to_preserve_views(self):
        # Cloudflare Workers AI only accepts a single image.
        # When both front and back images are supplied, it must return None
        # so execution cascades to OpenRouter/Gemini which support both images.
        action = self.brain._think_cloudflare(
            transcript="Describe both views",
            system_prompt="System prompt",
            front_b64="bW9ja19mcm9udA==",
            back_b64="bW9ja19iYWNr",
            history=[]
        )
        self.assertIsNone(action)

    @patch("urllib.request.OpenerDirector.open")
    def test_openrouter_dual_camera_skips_to_gemini(self, mock_urlopen):
        # OpenRouter free tier models may not reliably support multi-image inputs.
        # When both front and back images are supplied and default openrouter/free is used,
        # it must return None so execution cascades to Gemini which natively supports multiple images.
        with patch.dict(os.environ, {"OPENROUTER_VISION_MODEL": "openrouter/free"}):
            action = self.brain._think_openrouter(
                transcript="Describe both views",
                system_prompt="System prompt",
                front_b64="bW9ja19mcm9udA==",
                back_b64="bW9ja19iYWNr",
                history=[]
            )
            self.assertIsNone(action)
            mock_urlopen.assert_not_called()

    @patch("urllib.request.OpenerDirector.open")
    def test_openrouter_dual_camera_honors_model_override(self, mock_urlopen):
        # When OPENROUTER_VISION_MODEL is explicitly overridden, dual-camera requests
        # must not be skipped and both images should be passed in payload
        openrouter_resp = make_mock_response({
            "choices": [{
                "message": {
                    "content": json.dumps({
                        "speech": "Dual camera analyzed via override model.",
                        "expression": "focused",
                        "look_at": [0.0, 0.0],
                        "torch": False,
                        "haptic": "pulse"
                    })
                }
            }]
        })
        mock_urlopen.return_value = openrouter_resp

        with patch.dict(os.environ, {"OPENROUTER_VISION_MODEL": "qwen/qwen-2.5-vl-72b-instruct:free"}):
            action = self.brain._think_openrouter(
                transcript="Describe both views",
                system_prompt="System prompt",
                front_b64="bW9ja19mcm9udA==",
                back_b64="bW9ja19iYWNr",
                history=[]
            )
            self.assertIsNotNone(action)
            self.assertEqual(action["speech"], "Dual camera analyzed via override model.")

            call_args = mock_urlopen.call_args[0]
            req = call_args[0]
            payload = json.loads(req.data.decode("utf-8"))
            self.assertEqual(payload["model"], "qwen/qwen-2.5-vl-72b-instruct:free")
            images = [item for item in payload["messages"][-1]["content"] if isinstance(item, dict) and item.get("type") == "image_url"]
            self.assertEqual(len(images), 2)

    @patch("urllib.request.OpenerDirector.open")
    def test_openrouter_dual_camera_honored_when_gemini_missing(self, mock_urlopen):
        # When Gemini is unconfigured, OpenRouter should not skip dual-camera requests
        # even on default openrouter/free model
        openrouter_resp = make_mock_response({
            "choices": [{
                "message": {
                    "content": json.dumps({
                        "speech": "Dual camera processed by OpenRouter fallback.",
                        "expression": "focused",
                        "look_at": [0.0, 0.0],
                        "torch": False,
                        "haptic": "pulse"
                    })
                }
            }]
        })
        mock_urlopen.return_value = openrouter_resp

        brain_no_gemini = TarsCloudBrain(
            openrouter_api_key="mock_openrouter_key",
            gemini_api_key="",
            dotenv_path="/dev/null"
        )
        with patch.dict(os.environ, {"GEMINI_API_KEY": "", "OPENROUTER_VISION_MODEL": "openrouter/free"}):
            action = brain_no_gemini._think_openrouter(
                transcript="Describe both views",
                system_prompt="System prompt",
                front_b64="bW9ja19mcm9udA==",
                back_b64="bW9ja19iYWNr",
                history=[]
            )
            self.assertIsNotNone(action)
            self.assertEqual(action["speech"], "Dual camera processed by OpenRouter fallback.")
            self.assertEqual(mock_urlopen.call_count, 1)

    @patch("urllib.request.OpenerDirector.open")
    def test_cloudflare_single_camera_data_uri(self, mock_urlopen):
        cf_response = make_mock_response({
            "result": {
                "response": json.dumps({
                    "speech": "Front camera view analyzed.",
                    "expression": "focused",
                    "look_at": [0.0, 0.0],
                    "torch": False,
                    "haptic": "pulse"
                })
            }
        })
        mock_urlopen.return_value = cf_response

        action = self.brain._think_cloudflare(
            transcript="Describe scene",
            system_prompt="System prompt",
            front_b64="bW9ja19mcm9udA==",
            back_b64=None,
            history=[]
        )
        self.assertIsNotNone(action)
        self.assertEqual(action["speech"], "Front camera view analyzed.")

        call_args = mock_urlopen.call_args[0]
        req = call_args[0]
        payload = json.loads(req.data.decode("utf-8"))
        self.assertEqual(payload["image"], "data:image/jpeg;base64,bW9ja19mcm9udA==")

    def test_think_and_act_aggregate_timeout(self):
        # When aggregate timeout budget is exhausted, cascade immediately returns offline fallback
        action = self.brain.think_and_act("Status report", timeout=0.001)
        self.assertTrue(action.get("_fallback"))
        self.assertIn("autonomous backup reflexes", action["speech"])

    @patch("urllib.request.OpenerDirector.open")
    def test_urlopen_with_backoff_url_error_retry(self, mock_urlopen):
        # Transient network error (URLError) on first try, success on retry
        url_err = urllib.error.URLError("Temporary failure in name resolution")
        success_resp = make_mock_response({"choices": [{"message": {"content": '{"speech": "Recovered from transient error", "expression": "neutral"}'}}]})
        mock_urlopen.side_effect = [url_err, success_resp]

        req = urllib.request.Request("https://api.groq.com/mock")
        res_bytes = self.brain._urlopen_with_backoff(req, timeout=5.0)
        self.assertIn(b"Recovered", res_bytes)

    @patch("urllib.request.OpenerDirector.open")
    def test_gemini_raw_prose_fallback_succeeds(self, mock_urlopen):
        # When Gemini returns conversational text instead of strict JSON,
        # allow_raw_fallback=True extracts the speech text rather than failing
        gemini_prose = make_mock_response({
            "candidates": [{
                "content": {
                    "parts": [{
                        "text": "All desk systems are nominal and ready for commands."
                    }]
                }
            }]
        })
        mock_urlopen.return_value = gemini_prose

        action = self.brain._think_gemini(
            transcript="Check desk systems",
            system_prompt="System prompt",
            front_b64=None,
            back_b64=None,
            history=[]
        )
        self.assertIsNotNone(action)
        self.assertEqual(action["speech"], "All desk systems are nominal and ready for commands.")
        self.assertEqual(action["expression"], "neutral")

    @patch("urllib.request.OpenerDirector.open")
    def test_admission_timeout_tight_deadline_succeeds(self, mock_urlopen):
        # Verifies that when remaining deadline is tight (e.g. 0.3s),
        # HTTP worker admission succeeds without premature TimeoutError
        mock_resp = make_mock_response({"status": "ok"})
        mock_urlopen.return_value = mock_resp

        req = urllib.request.Request("https://api.groq.com/mock")
        deadline = time.monotonic() + 0.3
        res = self.brain._fetch_with_deadline(req, timeout=0.2, deadline=deadline)
        self.assertIn(b"ok", res)

    def test_expression_aliases_and_duration_validation(self):
        from desk_companion import DeskCompanion
        companion = DeskCompanion()
        companion._send_cmd = MagicMock(return_value={"status": "ok"})

        # Test alias mapping
        companion.set_expression("skeptical")
        companion._send_cmd.assert_called_with({"command": "expression", "name": "skeptic", "duration": 0.28})

        companion.set_expression("joy")
        companion._send_cmd.assert_called_with({"command": "expression", "name": "glee", "duration": 0.28})

        companion.set_expression("sad")
        companion._send_cmd.assert_called_with({"command": "expression", "name": "sad_down", "duration": 0.28})

        # Test duration validation against NaN and non-positive values
        companion.set_expression("neutral", duration=float("nan"))
        companion._send_cmd.assert_called_with({"command": "expression", "name": "neutral", "duration": 0.28})

        companion.set_expression("neutral", duration=-1.0)
        companion._send_cmd.assert_called_with({"command": "expression", "name": "neutral", "duration": 0.28})

    def test_execute_tars_action_hardware_status_and_errors(self):
        from desk_companion import DeskCompanion
        companion = DeskCompanion()
        # Mock hardware commands
        companion.vibrate = MagicMock(return_value={"status": "vibrated"})
        companion.look_at = MagicMock(return_value={"status": "ok", "x": 0.1, "y": -0.2})
        companion.set_torch = MagicMock(return_value={"status": "failed", "error": "hardware_unavailable"})
        companion.set_expression = MagicMock()
        companion.set_status = MagicMock()
        companion.set_speaking = MagicMock()

        action = {
            "speech": "",
            "expression": "neutral",
            "look_at": [0.1, -0.2],
            "torch": True,
            "haptic": "pulse"
        }
        res = companion._execute_tars_action(action)
        # vibrate returned 'vibrated' which is considered valid, not an error
        # torch returned 'failed' which is recorded in _device_errors
        self.assertIn("_device_errors", res)
        self.assertEqual(len(res["_device_errors"]), 1)
        self.assertIn("torch: hardware_unavailable", res["_device_errors"][0])

    def test_run_tars_turn_vision_failure_structured_error(self):
        from desk_companion import DeskCompanion
        companion = DeskCompanion()
        companion.snapshot = MagicMock(return_value={"status": "error", "error": "camera_busy"})
        companion.set_expression = MagicMock()
        companion.set_status = MagicMock()

        result = companion._run_tars_turn("Describe the desk", with_vision=True)
        self.assertEqual(result.get("status"), "error")
        self.assertEqual(result.get("error"), "vision_capture_failed")
        self.assertNotIn("vision_status", result)

    @patch("urllib.request.OpenerDirector.open")
    def test_groq_user_agent_header(self, mock_urlopen):
        mock_urlopen.return_value = make_mock_response({
            "choices": [{"message": {"content": '{"speech": "Nominal", "expression": "neutral"}'}}]
        })
        self.brain._think_groq("Status", "sys_prompt", None, None, [])
        req = mock_urlopen.call_args[0][0]
        self.assertEqual(req.get_header("User-agent"), "TARS-PhysicalAgent/1.0")

        mock_urlopen.return_value = make_mock_response({"text": "Whisper audio test."})
        self.brain._transcribe_groq(b"RIFF\x24\x00\x00\x00WAVEfmt ", "audio.wav")
        req_stt = mock_urlopen.call_args[0][0]
        self.assertEqual(req_stt.get_header("User-agent"), "TARS-PhysicalAgent/1.0")

    @patch("urllib.request.OpenerDirector.open")
    def test_cloudflare_dict_response_handling(self, mock_urlopen):
        # Cloudflare Workers AI can return result.response as an already parsed JSON dict
        mock_urlopen.return_value = make_mock_response({
            "result": {
                "response": {
                    "speech": "Parsed from dict response.",
                    "expression": "skeptical"
                }
            }
        })
        action = self.brain._think_cloudflare("Status", "sys_prompt", None, None, [])
        self.assertIsNotNone(action)
        self.assertEqual(action["speech"], "Parsed from dict response.")
        self.assertEqual(action["expression"], "skeptical")

    @patch("urllib.request.OpenerDirector.open")
    def test_openrouter_default_text_model(self, mock_urlopen):
        mock_urlopen.return_value = make_mock_response({
            "choices": [{"message": {"content": '{"speech": "Nemotron online", "expression": "neutral"}'}}]
        })
        self.brain._think_openrouter("Status", "sys_prompt", None, None, [])
        req = mock_urlopen.call_args[0][0]
        payload = json.loads(req.data.decode("utf-8"))
        self.assertEqual(payload["model"], "nvidia/nemotron-3.5-lightning:free")

    def test_darwin_ssl_cert_file_auto_configured(self):
        from tars_cloud_brain import load_dotenv
        saved_ssl = os.environ.pop("SSL_CERT_FILE", None)
        try:
            with patch("sys.platform", "darwin"), patch("os.path.exists", return_value=True):
                load_dotenv("/dev/null")
                self.assertEqual(os.environ.get("SSL_CERT_FILE"), "/etc/ssl/cert.pem")
        finally:
            if saved_ssl is not None:
                os.environ["SSL_CERT_FILE"] = saved_ssl
            else:
                os.environ.pop("SSL_CERT_FILE", None)

    def test_repository_zero_em_dashes(self):
        """Strict repository-wide verification of anti-AI-slop rule across all project files."""
        repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
        checked_count = 0
        for root, dirs, files in os.walk(repo_root):
            # Exclude git, virtual environments, external SDKs, toolchains, build artifacts, and external research repos
            dirs[:] = [d for d in dirs if d not in (".git", ".venv", "sdks", "toolchain", "research_repos", "__pycache__", "build", "dist")]
            for file in files:
                if file.endswith((".py", ".md", ".json", ".yaml", ".yml", ".m", ".h", ".mjs")):
                    full_path = os.path.join(root, file)
                    rel_path = os.path.relpath(full_path, repo_root)
                    with open(full_path, "r", encoding="utf-8", errors="ignore") as f:
                        content = f.read()
                    self.assertNotIn(chr(0x2014), content, f"Found prohibited em-dash in {rel_path}")
                    checked_count += 1
        self.assertGreater(checked_count, 5, "Should verify multiple repository files")


if __name__ == "__main__":
    unittest.main()
