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
import unittest
import urllib.error
from unittest.mock import MagicMock, patch

from tars_cloud_brain import (
    TarsCloudBrain,
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
        for key in ("TARS_HUMOR_PERCENT", "TARS_HONESTY_PERCENT"):
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
        )

    def tearDown(self):
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

    @patch("tars_cloud_brain.urllib.request.urlopen")
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

        mock_urlopen.side_effect = [error_429, cf_response]

        action = self.brain.think_and_act("Hello TARS")
        self.assertEqual(action["speech"], "Cloudflare edge fallback online.")
        self.assertEqual(action["expression"], "happy")

    @patch("tars_cloud_brain.urllib.request.urlopen")
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

        mock_urlopen.side_effect = [err1, err2, openrouter_response]

        action = self.brain.think_and_act("Status report")
        self.assertEqual(action["speech"], "OpenRouter free pool activated.")
        self.assertEqual(action["expression"], "happy")

    @patch("tars_cloud_brain.urllib.request.urlopen")
    def test_stt_whisper_groq_failover_to_cloudflare(self, mock_urlopen):
        err_groq = urllib.error.HTTPError(url="", code=429, msg="Rate Limited", hdrs={}, fp=None)
        cf_response = make_mock_response({
            "result": {
                "text": "Initiating docking sequence."
            }
        })

        mock_urlopen.side_effect = [err_groq, cf_response]

        transcript = self.brain.transcribe_audio(b"RIFFmockwavdata")
        self.assertEqual(transcript, "Initiating docking sequence.")

    @patch("tars_cloud_brain.urllib.request.urlopen")
    def test_stt_whisper_all_fail_raises_runtime_error(self, mock_urlopen):
        err_groq = urllib.error.HTTPError(url="", code=429, msg="Rate Limited", hdrs={}, fp=None)
        err_cf = urllib.error.HTTPError(url="", code=500, msg="Server Error", hdrs={}, fp=None)

        mock_urlopen.side_effect = [err_groq, err_cf]

        with self.assertRaises(RuntimeError) as ctx:
            self.brain.transcribe_audio(b"RIFFmockwavdata")
        self.assertIn("All configured speech-to-text tiers failed", str(ctx.exception))

    @patch("tars_cloud_brain.urllib.request.urlopen")
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

    def test_repository_zero_em_dashes(self):
        """Strict verification of anti-AI-slop rule across all modified and new files."""
        repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
        files_to_check = [
            "tars_cloud_brain.py",
            "desk_companion.py",
            ".env.example",
            "tests/test_tars_cloud_brain.py"
        ]
        for rel_path in files_to_check:
            full_path = os.path.join(repo_root, rel_path)
            self.assertTrue(os.path.isfile(full_path), f"File {rel_path} must exist at {full_path}")
            with open(full_path, "r", encoding="utf-8") as f:
                content = f.read()
            self.assertNotIn("\u2014", content, f"Found prohibited em-dash in {rel_path}")


if __name__ == "__main__":
    unittest.main()
