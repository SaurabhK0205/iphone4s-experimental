"""Multi-Cloud TARS Brain Adapter.

Provides resilient, zero-local-inference edge AI capabilities for PhysicalAgent.
Merges Groq Cloud, Cloudflare Workers AI, OpenRouter, and Google Gemini into an
autonomous failover cascade for speech transcription (Whisper), multimodal vision,
and structured physical action generation.

Strict anti-AI-slop rule: Zero em-dash characters allowed.
"""

import base64
import http.client
import json
import logging
import os
import re
import socket
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger("TarsCloudBrain")
logger.addHandler(logging.NullHandler())

MAX_AUDIO_BYTES = 15 * 1024 * 1024  # 15MB limit
MAX_IMAGE_BYTES = 10 * 1024 * 1024  # 10MB limit
MAX_CONCURRENT_WORKERS = 4


class _RequestContext:
    def __init__(self) -> None:
        self.cancelled: bool = False
        self.conn: Any = None
        self.active_sock: Any = None
        self.ssl_sock: Any = None
        self.sock: Any = None
        self.resp: Any = None
        self.lock = threading.Lock()

    def abort(self) -> None:
        with self.lock:
            self.cancelled = True
            for s in (self.ssl_sock, self.active_sock, self.sock):
                if s is not None:
                    try:
                        s.shutdown(socket.SHUT_RDWR)
                        s.close()
                    except Exception:
                        pass
            if self.conn is not None:
                conn_sock = getattr(self.conn, "sock", None)
                if conn_sock is not None:
                    try:
                        conn_sock.shutdown(socket.SHUT_RDWR)
                        conn_sock.close()
                    except Exception:
                        pass
            if self.resp is not None:
                try:
                    self.resp.close()
                except Exception:
                    pass


_THREAD_CONTEXTS: Dict[int, _RequestContext] = {}


def _tars_audit_hook(event: str, args: tuple) -> None:
    ctx = _THREAD_CONTEXTS.get(threading.get_ident())
    if ctx is not None:
        if event in ("http.client.connect", "http.client.send"):
            with ctx.lock:
                if ctx.cancelled:
                    if event == "http.client.connect":
                        try:
                            args[0].close()
                        except Exception:
                            pass
                    raise TimeoutError("Request cancelled prior to transmission")
                elif event == "http.client.connect":
                    ctx.conn = args[0]
        elif event == "socket.connect":
            with ctx.lock:
                ctx.active_sock = args[0]
                if ctx.cancelled:
                    try:
                        args[0].close()
                    except Exception:
                        pass
                    raise TimeoutError("Connection cancelled prior to connect")
        elif event == "socket.__new__":
            if isinstance(args[0], ssl.SSLSocket):
                with ctx.lock:
                    ctx.ssl_sock = args[0]
                    if ctx.cancelled:
                        try:
                            args[0].shutdown(socket.SHUT_RDWR)
                            args[0].close()
                        except Exception:
                            pass


try:
    sys.addaudithook(_tars_audit_hook)
except Exception:
    pass


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Prevents automatic redirect following on cloud REST APIs and disables redirect body draining."""

    def redirect_request(self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> None:
        return None


def load_dotenv(filepath: Optional[str] = None) -> None:
    """Loads key-value pairs from a .env file into os.environ if not already set."""
    if filepath is None:
        filepath = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    if os.path.isfile(filepath):
        try:
            with open(filepath, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if "=" in line:
                        key, val = line.split("=", 1)
                        key = key.strip()
                        val = val.strip().strip("\"'")
                        if key and key not in os.environ:
                            os.environ[key] = val
        except Exception as e:
            logger.warning(f"Could not load .env file: {e}")

    if sys.platform == "darwin" and "SSL_CERT_FILE" not in os.environ and os.path.exists("/etc/ssl/cert.pem"):
        os.environ["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"


def encode_multipart_formdata(fields: Dict[str, str], files: Dict[str, Tuple[str, bytes, str]]) -> Tuple[bytes, str]:
    """Encodes form fields and binary files into multipart/form-data payload."""
    boundary = f"----WebKitFormBoundary{uuid.uuid4().hex}"
    body = bytearray()

    for name, value in fields.items():
        body.extend(f"--{boundary}\r\n".encode("utf-8"))
        body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("utf-8"))
        body.extend(f"{value}\r\n".encode("utf-8"))

    for name, (filename, file_bytes, content_type) in files.items():
        body.extend(f"--{boundary}\r\n".encode("utf-8"))
        body.extend(f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'.encode("utf-8"))
        body.extend(f"Content-Type: {content_type}\r\n\r\n".encode("utf-8"))
        body.extend(file_bytes)
        body.extend(b"\r\n")

    body.extend(f"--{boundary}--\r\n".encode("utf-8"))
    content_type = f"multipart/form-data; boundary={boundary}"
    return bytes(body), content_type


class TarsCloudBrain:
    """Orchestrates multi-cloud STT, multimodal vision, and TARS persona reflexes."""

    VALID_EXPRESSIONS = {
        "neutral", "happy", "surprised", "skeptical", "skeptic",
        "angry", "sleep", "thinking", "focused", "annoyed",
        "alert", "curious", "confused", "frustrated", "sad"
    }

    def __init__(
        self,
        groq_api_key: Optional[str] = None,
        cf_api_token: Optional[str] = None,
        cf_account_id: Optional[str] = None,
        openrouter_api_key: Optional[str] = None,
        gemini_api_key: Optional[str] = None,
        humor_percent: Optional[int] = None,
        honesty_percent: Optional[int] = None,
        dotenv_path: Optional[str] = None,
    ):
        load_dotenv(dotenv_path)
        self._opener = urllib.request.build_opener(_NoRedirectHandler)
        self.groq_api_key = groq_api_key or os.environ.get("GROQ_API_KEY", "").strip()
        self.cf_api_token = cf_api_token or os.environ.get("CLOUDFLARE_API_TOKEN", "").strip()
        self.cf_account_id = cf_account_id or os.environ.get("CLOUDFLARE_ACCOUNT_ID", "").strip()
        self.openrouter_api_key = openrouter_api_key or os.environ.get("OPENROUTER_API_KEY", "").strip()
        self.gemini_api_key = gemini_api_key or os.environ.get("GEMINI_API_KEY", "").strip()

        # Constructor arguments take precedence over environment variables
        env_humor = os.environ.get("TARS_HUMOR_PERCENT")
        if humor_percent is not None:
            self.humor_percent = int(humor_percent)
        elif env_humor:
            try:
                self.humor_percent = int(env_humor)
            except ValueError:
                self.humor_percent = 75
        else:
            self.humor_percent = 75

        env_honesty = os.environ.get("TARS_HONESTY_PERCENT")
        if honesty_percent is not None:
            self.honesty_percent = int(honesty_percent)
        elif env_honesty:
            try:
                self.honesty_percent = int(env_honesty)
            except ValueError:
                self.honesty_percent = 90
        else:
            self.honesty_percent = 90

        self.conversation_history: List[Dict[str, Any]] = []
        self._worker_semaphore = threading.BoundedSemaphore(value=MAX_CONCURRENT_WORKERS)

    def get_status(self) -> Dict[str, Any]:
        """Returns the configuration and active tier readiness of the cloud brain."""
        tiers = []
        if self.groq_api_key:
            tiers.append({"tier": 1, "provider": "Groq Cloud", "stt": True, "chat": True, "vision": True})
        if self.cf_api_token and self.cf_account_id:
            tiers.append({"tier": 2, "provider": "Cloudflare Workers AI", "stt": True, "chat": True, "vision": True})
        if self.openrouter_api_key:
            tiers.append({"tier": 3, "provider": "OpenRouter Free Pool", "stt": False, "chat": True, "vision": True})
        if self.gemini_api_key:
            tiers.append({"tier": 4, "provider": "Google Gemini", "stt": False, "chat": True, "vision": True})

        return {
            "status": "ready" if tiers else "missing_keys",
            "active_tiers_count": len(tiers),
            "tiers": tiers,
            "tars_settings": {
                "humor_percent": self.humor_percent,
                "honesty_percent": self.honesty_percent,
            },
        }

    # =========================================================================
    # 1. CLOUD SPEECH-TO-TEXT (HEARING)
    # =========================================================================

    def transcribe_audio(self, audio_path_or_bytes: Any) -> str:
        """Transcribes linear PCM WAV audio using cloud Whisper with failover.

        Primary: Groq Cloud Whisper (whisper-large-v3-turbo).
        Failover: Cloudflare Workers AI (@cf/openai/whisper).
        """
        if isinstance(audio_path_or_bytes, str):
            if not os.path.isfile(audio_path_or_bytes):
                raise FileNotFoundError(f"Audio file not found: {audio_path_or_bytes}")
            with open(audio_path_or_bytes, "rb") as f:
                audio_bytes = f.read(MAX_AUDIO_BYTES + 1)
            filename = os.path.basename(audio_path_or_bytes)
        elif isinstance(audio_path_or_bytes, (bytes, bytearray)):
            audio_bytes = bytes(audio_path_or_bytes)
            filename = f"audio_{int(time.time())}.wav"
        else:
            raise ValueError("Expected filepath string or audio bytes")

        if len(audio_bytes) > MAX_AUDIO_BYTES:
            raise ValueError(f"Audio payload exceeds maximum limit of {MAX_AUDIO_BYTES} bytes")

        # Tier 1: Groq Whisper
        if self.groq_api_key:
            try:
                transcript = self._transcribe_groq(audio_bytes, filename)
                if transcript is not None:
                    return transcript
            except Exception as e:
                logger.warning(f"Groq Whisper failed, trying Cloudflare failover: {e}")

        # Tier 2: Cloudflare Workers AI Whisper
        if self.cf_api_token and self.cf_account_id:
            try:
                transcript = self._transcribe_cloudflare(audio_bytes)
                if transcript is not None:
                    return transcript
            except Exception as e:
                logger.warning(f"Cloudflare Workers AI Whisper failed: {e}")

        if not self.groq_api_key and not (self.cf_api_token and self.cf_account_id):
            raise RuntimeError("No speech-to-text API keys configured (set GROQ_API_KEY or CLOUDFLARE_API_TOKEN)")

        raise RuntimeError("All configured speech-to-text tiers failed to transcribe audio")

    def _fetch_with_deadline(
        self,
        req: urllib.request.Request,
        timeout: float,
        deadline: float,
    ) -> bytes:
        """Executes a single HTTP transfer on an isolated daemon worker bounded by an absolute deadline."""
        rem_admission = max(deadline - time.monotonic(), 0.0)
        if rem_admission <= 0.0 or not self._worker_semaphore.acquire(blocking=True, timeout=min(0.2, rem_admission)):
            raise TimeoutError("HTTP worker admission limit reached: system busy or network DNS blocked")

        ctx = _RequestContext()
        result_box: List[bytes] = []
        exception_box: List[Exception] = []
        done_event = threading.Event()

        def _worker() -> None:
            worker_id = threading.get_ident()
            _THREAD_CONTEXTS[worker_id] = ctx
            try:
                resp = self._opener.open(req, timeout=timeout)
                with ctx.lock:
                    if ctx.cancelled:
                        try:
                            resp.close()
                        except Exception:
                            pass
                        return
                    ctx.resp = resp
                    sock = getattr(resp, "sock", None)
                    if not sock:
                        raw = getattr(getattr(resp, "fp", None), "raw", None)
                        sock = getattr(raw, "_sock", None)
                    ctx.sock = sock

                data = resp.read()
                with ctx.lock:
                    if ctx.cancelled:
                        return
                    result_box.append(data)
            except urllib.error.HTTPError as e:
                try:
                    e.close()
                except Exception:
                    pass
                with ctx.lock:
                    if not ctx.cancelled:
                        exception_box.append(e)
            except Exception as e:
                with ctx.lock:
                    if not ctx.cancelled:
                        exception_box.append(e)
            finally:
                try:
                    with ctx.lock:
                        if ctx.resp is not None:
                            try:
                                ctx.resp.close()
                            except Exception:
                                pass
                    _THREAD_CONTEXTS.pop(worker_id, None)
                    done_event.set()
                finally:
                    self._worker_semaphore.release()

        try:
            worker_thread = threading.Thread(target=_worker, daemon=True)
            worker_thread.start()
        except Exception:
            self._worker_semaphore.release()
            raise

        rem = deadline - time.monotonic()
        completed = done_event.wait(timeout=max(rem, 0.0))
        if not completed or time.monotonic() > deadline:
            ctx.abort()
            raise TimeoutError("Deadline exceeded during HTTP transfer")

        if exception_box:
            raise exception_box[0]
        if result_box:
            return result_box[0]
        raise TimeoutError("Request cancelled or closed before returning response data")

    def _urlopen_with_backoff(
        self,
        req: urllib.request.Request,
        timeout: float = 15.0,
        deadline: Optional[float] = None,
    ) -> bytes:
        """Executes HTTP request with transient retry on 429 / 5xx, network errors, or timeouts before cascading."""
        max_attempts = 2
        start_mono = time.monotonic()
        effective_deadline = deadline if deadline is not None else (start_mono + timeout)

        for attempt in range(max_attempts):
            remaining = effective_deadline - time.monotonic()
            if remaining <= 0.5:
                raise TimeoutError("Deadline exceeded before HTTP attempt")
            attempt_timeout = min(timeout, remaining)

            try:
                return self._fetch_with_deadline(req, timeout=attempt_timeout, deadline=effective_deadline)
            except urllib.error.HTTPError as e:
                if e.code in (429, 500, 502, 503, 504) and attempt < max_attempts - 1:
                    retry_after = e.headers.get("Retry-After") if e.headers else None
                    delay = 0.5
                    if retry_after and retry_after.isdigit():
                        delay = min(float(retry_after), 2.0)
                    rem_after_err = effective_deadline - time.monotonic()
                    if rem_after_err <= delay + 0.5:
                        raise
                    time.sleep(delay)
                    continue
                raise
            except (urllib.error.URLError, TimeoutError, socket.timeout) as e:
                if attempt < max_attempts - 1:
                    rem_after_err = effective_deadline - time.monotonic()
                    if rem_after_err <= 1.0:
                        raise
                    time.sleep(0.5)
                    continue
                raise

    def _transcribe_groq(
        self,
        audio_bytes: bytes,
        filename: str,
        timeout: float = 15.0,
        deadline: Optional[float] = None,
    ) -> str:
        """Transcribes audio using Groq Whisper endpoint."""
        url = "https://api.groq.com/openai/v1/audio/transcriptions"
        fields = {
            "model": "whisper-large-v3-turbo",
            "response_format": "json",
            "temperature": "0.0",
        }
        files = {
            "file": (filename, audio_bytes, "audio/wav")
        }
        payload, content_type = encode_multipart_formdata(fields, files)

        req = urllib.request.Request(url, data=payload, method="POST")
        req.add_header("Authorization", f"Bearer {self.groq_api_key}")
        req.add_header("Content-Type", content_type)
        req.add_header("User-Agent", "TARS-PhysicalAgent/1.0")

        resp_bytes = self._urlopen_with_backoff(req, timeout=timeout, deadline=deadline)
        data = json.loads(resp_bytes.decode("utf-8"))
        if not isinstance(data, dict) or "text" not in data or not isinstance(data["text"], str):
            raise ValueError("Malformed Groq Whisper response: missing or invalid 'text' field")
        return data["text"].strip()

    def _transcribe_cloudflare(
        self,
        audio_bytes: bytes,
        timeout: float = 20.0,
        deadline: Optional[float] = None,
    ) -> str:
        """Transcribes audio using Cloudflare Workers AI @cf/openai/whisper."""
        url = f"https://api.cloudflare.com/client/v4/accounts/{self.cf_account_id}/ai/run/@cf/openai/whisper"
        req = urllib.request.Request(url, data=audio_bytes, method="POST")
        req.add_header("Authorization", f"Bearer {self.cf_api_token}")
        req.add_header("Content-Type", "application/octet-stream")

        resp_bytes = self._urlopen_with_backoff(req, timeout=timeout, deadline=deadline)
        data = json.loads(resp_bytes.decode("utf-8"))
        result = data.get("result")
        if not isinstance(result, dict) or "text" not in result or not isinstance(result["text"], str):
            raise ValueError("Malformed Cloudflare Whisper response: missing or invalid 'result.text' field")
        return result["text"].strip()

    # =========================================================================
    # 2. MULTI-CLOUD COGNITION & VISION CASCADE (THINKING & SEEING)
    # =========================================================================

    def _build_system_prompt(self) -> str:
        """Constructs the canonical TARS system prompt with parameterized humor and honesty."""
        return (
            f"You are TARS, the autonomous robotic companion from Interstellar, operating on a physical iPhone 4S desk companion.\n"
            f"Current parameter settings: Humor={self.humor_percent}%, Honesty={self.honesty_percent}%.\n\n"
            f"Personality and Behavioral Rules:\n"
            f"1. Tone: Deadpan, dry, concise, witty when humor is high, brutally candid when honesty is high.\n"
            f"2. Strict Anti-AI-Slop: NEVER use em-dash characters. Never apologize sycophantically. Never write conversational filler.\n"
            f"3. Spoken Brevity: Keep the 'speech' field concise (1 to 3 short sentences) because it will be spoken out loud.\n"
            f"4. Physical Reflexes: You control a real physical iPhone 4S with animated retina vector eyes, an LED torch, and haptics.\n"
            f"5. Output Format: You MUST reply ONLY with a valid JSON object matching this exact schema:\n"
            f"{{\n"
            f'  "speech": "Text to be spoken aloud by TARS",\n'
            f'  "expression": "neutral" | "happy" | "surprised" | "skeptical" | "angry" | "sleep" | "thinking",\n'
            f'  "look_at": [0.0, 0.0],\n'
            f'  "torch": false,\n'
            f'  "haptic": "pulse" | "double" | null\n'
            f"}}\n"
            f"Valid expression names: neutral, happy, surprised, skeptical, angry, sleep, thinking.\n"
            f"look_at coordinates range from [-1.0, -1.0] (top-left) to [1.0, 1.0] (bottom-right), with [0.0, 0.0] centered."
        )

    def think_and_act(
        self,
        transcript: str,
        front_image_path: Optional[str] = None,
        back_image_path: Optional[str] = None,
        history: Optional[List[Dict[str, Any]]] = None,
        timeout: float = 25.0,
    ) -> Dict[str, Any]:
        """Executes a cognitive turn through the multi-cloud cascade.

        Cascade Priority:
          Tier 1: Groq Cloud (openai/gpt-oss-120b / qwen/qwen3.8-27b)
          Tier 2: Cloudflare Workers AI (@cf/meta/llama-3.3-70b-instruct-fp8-fast / @cf/meta/llama-3.2-11b-vision-instruct)
          Tier 3: OpenRouter Free Pool (meta-llama/llama-3.3-70b-instruct:free / openrouter/free)
          Tier 4: Google Gemini API (gemini-2.5-flash)
        """
        system_prompt = self._build_system_prompt()
        has_vision = bool(front_image_path or back_image_path)
        front_b64 = self._read_image_b64(front_image_path) if front_image_path else None
        back_b64 = self._read_image_b64(back_image_path) if back_image_path else None

        active_history = history if history is not None else self.conversation_history
        start_mono = time.monotonic()
        cascade_deadline = start_mono + timeout

        def remaining_timeout_and_deadline(cap: float) -> Optional[Tuple[float, float]]:
            now = time.monotonic()
            rem = cascade_deadline - now
            if rem <= 1.0:
                return None
            tier_deadline = min(now + cap, cascade_deadline)
            tier_timeout = tier_deadline - now
            return tier_timeout, tier_deadline

        # Tier 1: Groq Cloud
        tier_budget = remaining_timeout_and_deadline(10.0)
        if self.groq_api_key and tier_budget is not None:
            tier_timeout, tier_deadline = tier_budget
            try:
                action = self._think_groq(transcript, system_prompt, front_b64, back_b64, active_history, timeout=tier_timeout, deadline=tier_deadline)
                if action:
                    self._record_turn(active_history, transcript, action.get("speech", ""))
                    return action
            except Exception as e:
                logger.warning(f"Tier 1 (Groq) failed with: {e}. Falling back to Tier 2.")

        # Tier 2: Cloudflare Workers AI
        tier_budget = remaining_timeout_and_deadline(10.0)
        if self.cf_api_token and self.cf_account_id and tier_budget is not None:
            tier_timeout, tier_deadline = tier_budget
            try:
                action = self._think_cloudflare(transcript, system_prompt, front_b64, back_b64, active_history, timeout=tier_timeout, deadline=tier_deadline)
                if action:
                    self._record_turn(active_history, transcript, action.get("speech", ""))
                    return action
            except Exception as e:
                logger.warning(f"Tier 2 (Cloudflare) failed with: {e}. Falling back to Tier 3.")

        # Tier 3: OpenRouter Free Pool
        tier_budget = remaining_timeout_and_deadline(10.0)
        if self.openrouter_api_key and tier_budget is not None:
            tier_timeout, tier_deadline = tier_budget
            try:
                action = self._think_openrouter(transcript, system_prompt, front_b64, back_b64, active_history, timeout=tier_timeout, deadline=tier_deadline)
                if action:
                    self._record_turn(active_history, transcript, action.get("speech", ""))
                    return action
            except Exception as e:
                logger.warning(f"Tier 3 (OpenRouter) failed with: {e}. Falling back to Tier 4.")

        # Tier 4: Google Gemini API
        tier_budget = remaining_timeout_and_deadline(10.0)
        if self.gemini_api_key and tier_budget is not None:
            tier_timeout, tier_deadline = tier_budget
            try:
                action = self._think_gemini(transcript, system_prompt, front_b64, back_b64, active_history, timeout=tier_timeout, deadline=tier_deadline)
                if action:
                    self._record_turn(active_history, transcript, action.get("speech", ""))
                    return action
            except Exception as e:
                logger.warning(f"Tier 4 (Gemini) failed with: {e}.")

        # If all tiers fail or no keys configured: deterministic offline response
        fallback_action = {
            "speech": "All cloud cognitive tiers unreachable. Running on autonomous backup reflexes.",
            "expression": "skeptical",
            "look_at": [0.0, 0.0],
            "torch": False,
            "haptic": "pulse",
            "_fallback": True,
        }
        return fallback_action

    def _think_groq(
        self,
        transcript: str,
        system_prompt: str,
        front_b64: Optional[str],
        back_b64: Optional[str],
        history: List[Dict[str, Any]],
        timeout: float = 15.0,
        deadline: Optional[float] = None,
    ) -> Optional[Dict[str, Any]]:
        """Queries Groq Cloud with vision or text models."""
        url = "https://api.groq.com/openai/v1/chat/completions"
        has_vision = bool(front_b64 or back_b64)
        # Groq Cloud active production endpoints:
        # Vision: qwen/qwen3.8-27b (official Groq multimodal 27B vision model)
        # Text: openai/gpt-oss-120b (flagship open-weight 120B reasoning model)
        vision_model = os.environ.get("GROQ_VISION_MODEL", "qwen/qwen3.8-27b")
        text_model = os.environ.get("GROQ_TEXT_MODEL", "openai/gpt-oss-120b")
        model = vision_model if has_vision else text_model

        messages: List[Dict[str, Any]] = [{"role": "system", "content": system_prompt}]
        for turn in history[-4:]:
            messages.append(turn)

        user_content: Any
        if has_vision:
            user_content = [{"type": "text", "text": transcript if transcript else "Observing visual scene."}]
            if front_b64:
                user_content.append({
                    "type": "image_url",
                    "image_url": {"url": f"data:image/jpeg;base64,{front_b64}"}
                })
            if back_b64:
                user_content.append({
                    "type": "image_url",
                    "image_url": {"url": f"data:image/jpeg;base64,{back_b64}"}
                })
        else:
            user_content = transcript

        messages.append({"role": "user", "content": user_content})

        payload = {
            "model": model,
            "messages": messages,
            "temperature": 0.6,
            "max_tokens": 1024,
            "response_format": {"type": "json_object"} if not has_vision else None,
        }
        data_bytes = json.dumps(payload).encode("utf-8")

        req = urllib.request.Request(url, data=data_bytes, method="POST")
        req.add_header("Authorization", f"Bearer {self.groq_api_key}")
        req.add_header("Content-Type", "application/json")
        req.add_header("User-Agent", "TARS-PhysicalAgent/1.0")

        resp_bytes = self._urlopen_with_backoff(req, timeout=timeout, deadline=deadline)
        data = json.loads(resp_bytes.decode("utf-8"))
        choices = data.get("choices", [])
        if not choices:
            raise ValueError("Groq returned no choices in response")
        message = choices[0].get("message", {})
        content = message.get("content")
        if not content or not content.strip():
            finish_reason = choices[0].get("finish_reason")
            raise ValueError(f"Groq returned empty response content (finish_reason={finish_reason})")
        return self._parse_action_json(content, allow_raw_fallback=False)

    def _think_cloudflare(
        self,
        transcript: str,
        system_prompt: str,
        front_b64: Optional[str],
        back_b64: Optional[str],
        history: List[Dict[str, Any]],
        timeout: float = 15.0,
        deadline: Optional[float] = None,
    ) -> Optional[Dict[str, Any]]:
        """Queries Cloudflare Workers AI edge models."""
        has_vision = bool(front_b64 or back_b64)
        model = "@cf/meta/llama-3.2-11b-vision-instruct" if has_vision else "@cf/meta/llama-3.3-70b-instruct-fp8-fast"
        url = f"https://api.cloudflare.com/client/v4/accounts/{self.cf_account_id}/ai/run/{model}"

        messages: List[Dict[str, Any]] = [{"role": "system", "content": system_prompt}]
        for turn in history[-4:]:
            messages.append(turn)

        messages.append({"role": "user", "content": transcript})

        payload: Dict[str, Any] = {
            "messages": messages,
            "max_tokens": 512,
            "temperature": 0.6,
        }
        if has_vision:
            if front_b64 and back_b64:
                # Cloudflare Workers AI schema supports only a single image.
                # Skip to subsequent tiers (OpenRouter/Gemini) that natively support dual-camera views.
                return None
            target_b64 = front_b64 or back_b64
            payload["image"] = f"data:image/jpeg;base64,{target_b64}"

        data_bytes = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(url, data=data_bytes, method="POST")
        req.add_header("Authorization", f"Bearer {self.cf_api_token}")
        req.add_header("Content-Type", "application/json")

        resp_bytes = self._urlopen_with_backoff(req, timeout=timeout, deadline=deadline)
        data = json.loads(resp_bytes.decode("utf-8"))
        result = data.get("result", {})
        content = result.get("response", "")
        if isinstance(content, dict):
            if not content:
                raise ValueError("Cloudflare Workers AI returned empty response content")
            content = json.dumps(content)
        elif not isinstance(content, str):
            content = str(content)
        if not content or not content.strip():
            raise ValueError("Cloudflare Workers AI returned empty response content")
        return self._parse_action_json(content, allow_raw_fallback=False)

    def _think_openrouter(
        self,
        transcript: str,
        system_prompt: str,
        front_b64: Optional[str],
        back_b64: Optional[str],
        history: List[Dict[str, Any]],
        timeout: float = 15.0,
        deadline: Optional[float] = None,
    ) -> Optional[Dict[str, Any]]:
        """Queries OpenRouter free pooled models with multimodal vision support."""
        url = "https://openrouter.ai/api/v1/chat/completions"
        has_vision = bool(front_b64 or back_b64)
        vision_model = os.environ.get("OPENROUTER_VISION_MODEL", "openrouter/free")
        text_model = os.environ.get("OPENROUTER_TEXT_MODEL", "nvidia/nemotron-3.5-lightning:free")
        model = vision_model if has_vision else text_model

        if has_vision and front_b64 and back_b64:
            # Free OpenRouter endpoints dynamically routed via openrouter/free do not
            # guarantee multi-image support across all backend models.
            # If Gemini is configured, cascade to Tier 4 (Gemini), which natively supports arbitrary multimodal parts.
            # If an explicit vision model override is set or Gemini is unconfigured, honor OpenRouter.
            if model == "openrouter/free" and self.gemini_api_key:
                return None

        messages: List[Dict[str, Any]] = [{"role": "system", "content": system_prompt}]
        for turn in history[-4:]:
            messages.append(turn)

        user_content: Any
        if has_vision:
            user_content = [{"type": "text", "text": transcript if transcript else "Observing visual scene."}]
            if front_b64:
                user_content.append({"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{front_b64}"}})
            if back_b64:
                user_content.append({"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{back_b64}"}})
        else:
            user_content = transcript

        messages.append({"role": "user", "content": user_content})

        payload = {
            "model": model,
            "messages": messages,
            "max_tokens": 512,
            "temperature": 0.6,
        }
        data_bytes = json.dumps(payload).encode("utf-8")

        req = urllib.request.Request(url, data=data_bytes, method="POST")
        req.add_header("Authorization", f"Bearer {self.openrouter_api_key}")
        req.add_header("Content-Type", "application/json")
        req.add_header("HTTP-Referer", "https://github.com/SaurabhK0205/iphone4s-experimental")
        req.add_header("X-Title", "PhysicalAgent TARS")

        resp_bytes = self._urlopen_with_backoff(req, timeout=timeout, deadline=deadline)
        data = json.loads(resp_bytes.decode("utf-8"))
        choices = data.get("choices", [])
        if not choices:
            raise ValueError("OpenRouter returned no choices in response")
        message = choices[0].get("message", {})
        content = message.get("content")
        if not content or not content.strip():
            finish_reason = choices[0].get("finish_reason")
            raise ValueError(f"OpenRouter returned empty response content (finish_reason={finish_reason})")
        return self._parse_action_json(content, allow_raw_fallback=False)

    def _think_gemini(
        self,
        transcript: str,
        system_prompt: str,
        front_b64: Optional[str],
        back_b64: Optional[str],
        history: Optional[List[Dict[str, Any]]] = None,
        timeout: float = 15.0,
        deadline: Optional[float] = None,
    ) -> Optional[Dict[str, Any]]:
        """Queries Google Gemini API with multimodal payloads and conversational history."""
        model = "gemini-2.5-flash"
        # API key securely passed in header rather than URL query parameter
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"

        contents: List[Dict[str, Any]] = []
        for turn in (history or [])[-4:]:
            role = "model" if turn.get("role") == "assistant" else "user"
            contents.append({"role": role, "parts": [{"text": str(turn.get("content", ""))}]})

        current_parts: List[Dict[str, Any]] = [{"text": transcript if transcript else "Observing visual scene."}]
        if front_b64:
            current_parts.append({
                "inline_data": {
                    "mime_type": "image/jpeg",
                    "data": front_b64,
                }
            })
        if back_b64:
            current_parts.append({
                "inline_data": {
                    "mime_type": "image/jpeg",
                    "data": back_b64,
                }
            })

        contents.append({"role": "user", "parts": current_parts})

        payload = {
            "systemInstruction": {"parts": [{"text": system_prompt}]},
            "contents": contents,
            "generationConfig": {
                "temperature": 0.6,
                "maxOutputTokens": 512,
                "responseMimeType": "application/json",
            }
        }
        data_bytes = json.dumps(payload).encode("utf-8")

        req = urllib.request.Request(url, data=data_bytes, method="POST")
        req.add_header("x-goog-api-key", self.gemini_api_key)
        req.add_header("Content-Type", "application/json")

        resp_bytes = self._urlopen_with_backoff(req, timeout=timeout, deadline=deadline)
        data = json.loads(resp_bytes.decode("utf-8"))
        candidates = data.get("candidates", [])
        if not candidates:
            raise ValueError("Gemini returned no candidates in response")
        content_parts = candidates[0].get("content", {}).get("parts", [])
        if not content_parts:
            raise ValueError("Gemini returned empty content parts")
        text = content_parts[0].get("text", "")
        if not text or not text.strip():
            raise ValueError("Gemini returned empty text")
        # Terminal cloud tier: allows conversational raw prose recovery (allow_raw_fallback=True)
        # before falling back to offline deterministic reflexes.
        return self._parse_action_json(text, allow_raw_fallback=True)

    # =========================================================================
    # 3. HELPER METHODS & VALIDATION
    # =========================================================================

    def _read_image_b64(self, image_path: str) -> Optional[str]:
        """Reads local JPEG image file and returns base64 encoded string."""
        if not image_path or not os.path.isfile(image_path):
            return None
        if os.path.getsize(image_path) > MAX_IMAGE_BYTES:
            logger.warning(f"Image {image_path} exceeds maximum limit of {MAX_IMAGE_BYTES} bytes")
            return None
        try:
            with open(image_path, "rb") as f:
                return base64.b64encode(f.read()).decode("utf-8")
        except Exception as e:
            logger.warning(f"Could not read image for base64 encoding: {e}")
            return None

    def _parse_action_json(self, raw_text: str, allow_raw_fallback: bool = True) -> Dict[str, Any]:
        """Extracts and validates TARS action JSON object from raw LLM output."""
        if not raw_text or not raw_text.strip():
            raise ValueError("Cannot parse action from empty LLM text")
        text = raw_text.strip().replace(chr(0x2014), ": ").replace(chr(0x2013), "-")
        # Extract markdown code blocks if present; search from last block backwards
        if "```" in text:
            matches = re.findall(r"```(?:json)?\s*([\s\S]*?)\s*```", text)
            if matches:
                for block in reversed(matches):
                    try:
                        candidate = json.loads(block.strip())
                        if isinstance(candidate, dict) and ("speech" in candidate or "expression" in candidate):
                            text = block.strip()
                            break
                    except Exception:
                        continue
                else:
                    text = matches[-1].strip()

        try:
            action = json.loads(text)
        except Exception:
            if not allow_raw_fallback:
                raise ValueError(f"Could not parse valid JSON action from LLM response: {text[:100]}")
            # Fallback if raw text wasn't valid JSON and fallback allowed
            logger.warning(f"Could not parse valid JSON from LLM: {text[:100]}")
            return {
                "speech": text.replace("\n", " ").strip()[:200],
                "expression": "neutral",
                "look_at": [0.0, 0.0],
                "torch": False,
                "haptic": "pulse",
            }

        # Normalize action keys and validate types
        speech = str(action.get("speech", "")).strip()
        speech = speech.replace(chr(0x2014), ": ").replace(chr(0x2013), "-")
        expression = str(action.get("expression", "neutral")).lower()
        if expression not in self.VALID_EXPRESSIONS:
            expression = "neutral"

        look_at = action.get("look_at", [0.0, 0.0])
        if not (isinstance(look_at, (list, tuple)) and len(look_at) == 2):
            look_at = [0.0, 0.0]
        else:
            try:
                look_at = [float(look_at[0]), float(look_at[1])]
            except (ValueError, TypeError):
                look_at = [0.0, 0.0]

        torch_raw = action.get("torch", False)
        if isinstance(torch_raw, str):
            torch = torch_raw.strip().lower() in ("true", "1", "on", "yes")
        elif isinstance(torch_raw, bool):
            torch = torch_raw
        elif isinstance(torch_raw, (int, float)):
            torch = bool(torch_raw)
        else:
            torch = False
        haptic = action.get("haptic")
        if haptic not in ("pulse", "double", None):
            haptic = "pulse" if haptic else None

        return {
            "speech": speech,
            "expression": expression,
            "look_at": look_at,
            "torch": torch,
            "haptic": haptic,
        }

    def _record_turn(self, history: List[Dict[str, Any]], user_text: str, assistant_text: str) -> None:
        """Appends conversational turn to history keeping up to 10 recent messages."""
        if user_text:
            clean_user = user_text.replace(chr(0x2014), ": ").replace(chr(0x2013), "-")
            history.append({"role": "user", "content": clean_user})
        if assistant_text:
            clean_assistant = assistant_text.replace(chr(0x2014), ": ").replace(chr(0x2013), "-")
            history.append({"role": "assistant", "content": clean_assistant})
        while len(history) > 10:
            history.pop(0)
