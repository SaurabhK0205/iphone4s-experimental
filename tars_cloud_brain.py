"""Multi-Cloud TARS Brain Adapter.

Provides resilient, zero-local-inference edge AI capabilities for PhysicalAgent.
Merges Groq Cloud, Cloudflare Workers AI, OpenRouter, and Google Gemini into an
autonomous failover cascade for speech transcription (Whisper), multimodal vision,
and structured physical action generation.

Strict anti-AI-slop rule: Zero em-dash characters allowed.
"""

import base64
import json
import logging
import mimetypes
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger("TarsCloudBrain")


def load_dotenv(filepath: Optional[str] = None) -> None:
    """Loads key-value pairs from a .env file into os.environ if not already set."""
    if filepath is None:
        filepath = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    if not os.path.isfile(filepath):
        return

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


# Initialize environment on module import
load_dotenv()


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
        "neutral", "happy", "surprised", "skeptical", "angry", "sleep", "thinking"
    }

    def __init__(
        self,
        groq_api_key: Optional[str] = None,
        cf_api_token: Optional[str] = None,
        cf_account_id: Optional[str] = None,
        openrouter_api_key: Optional[str] = None,
        gemini_api_key: Optional[str] = None,
        humor_percent: int = 75,
        honesty_percent: int = 90,
    ):
        load_dotenv()
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
            self.humor_percent = int(env_humor)
        else:
            self.humor_percent = 75

        env_honesty = os.environ.get("TARS_HONESTY_PERCENT")
        if honesty_percent is not None:
            self.honesty_percent = int(honesty_percent)
        elif env_honesty:
            self.honesty_percent = int(env_honesty)
        else:
            self.honesty_percent = 90

        self.conversation_history: List[Dict[str, Any]] = []

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
                audio_bytes = f.read()
            filename = os.path.basename(audio_path_or_bytes)
        elif isinstance(audio_path_or_bytes, (bytes, bytearray)):
            audio_bytes = bytes(audio_path_or_bytes)
            filename = f"audio_{int(time.time())}.wav"
        else:
            raise ValueError("Expected filepath string or audio bytes")

        # Tier 1: Groq Whisper
        if self.groq_api_key:
            try:
                transcript = self._transcribe_groq(audio_bytes, filename)
                if transcript:
                    return transcript
            except Exception as e:
                logger.warning(f"Groq Whisper failed, trying Cloudflare failover: {e}")

        # Tier 2: Cloudflare Workers AI Whisper
        if self.cf_api_token and self.cf_account_id:
            try:
                transcript = self._transcribe_cloudflare(audio_bytes)
                if transcript:
                    return transcript
            except Exception as e:
                logger.warning(f"Cloudflare Workers AI Whisper failed: {e}")

        if not self.groq_api_key and not (self.cf_api_token and self.cf_account_id):
            raise RuntimeError("No speech-to-text API keys configured (set GROQ_API_KEY or CLOUDFLARE_API_TOKEN)")

        raise RuntimeError("All configured speech-to-text tiers failed to transcribe audio")

    def _transcribe_groq(self, audio_bytes: bytes, filename: str) -> str:
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

        with urllib.request.urlopen(req, timeout=15.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return data.get("text", "").strip()

    def _transcribe_cloudflare(self, audio_bytes: bytes) -> str:
        """Transcribes audio using Cloudflare Workers AI @cf/openai/whisper."""
        url = f"https://api.cloudflare.com/client/v4/accounts/{self.cf_account_id}/ai/run/@cf/openai/whisper"
        req = urllib.request.Request(url, data=audio_bytes, method="POST")
        req.add_header("Authorization", f"Bearer {self.cf_api_token}")
        req.add_header("Content-Type", "application/octet-stream")

        with urllib.request.urlopen(req, timeout=20.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            result = data.get("result", {})
            return result.get("text", "").strip()

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
    ) -> Dict[str, Any]:
        """Executes a cognitive turn through the multi-cloud cascade.

        Cascade Priority:
          Tier 1: Groq Cloud (llama-3.3-70b-versatile / llama-3.2-11b-vision-preview)
          Tier 2: Cloudflare Workers AI (@cf/meta/llama-3.3-70b / @cf/meta/llama-3.2-11b-vision)
          Tier 3: OpenRouter Free Pool (llama-3.3-70b-instruct:free / qwen-2.5-72b:free)
          Tier 4: Google Gemini API (gemini-2.5-flash)
        """
        system_prompt = self._build_system_prompt()
        has_vision = bool(front_image_path or back_image_path)
        front_b64 = self._read_image_b64(front_image_path) if front_image_path else None
        back_b64 = self._read_image_b64(back_image_path) if back_image_path else None

        active_history = history if history is not None else self.conversation_history

        # Tier 1: Groq Cloud
        if self.groq_api_key:
            try:
                action = self._think_groq(transcript, system_prompt, front_b64, back_b64, active_history)
                if action:
                    self._record_turn(active_history, transcript, action.get("speech", ""))
                    return action
            except Exception as e:
                logger.warning(f"Tier 1 (Groq) failed with: {e}. Falling back to Tier 2.")

        # Tier 2: Cloudflare Workers AI
        if self.cf_api_token and self.cf_account_id:
            try:
                action = self._think_cloudflare(transcript, system_prompt, front_b64, back_b64, active_history)
                if action:
                    self._record_turn(active_history, transcript, action.get("speech", ""))
                    return action
            except Exception as e:
                logger.warning(f"Tier 2 (Cloudflare) failed with: {e}. Falling back to Tier 3.")

        # Tier 3: OpenRouter Free Pool
        if self.openrouter_api_key:
            try:
                action = self._think_openrouter(transcript, system_prompt, front_b64, back_b64, active_history)
                if action:
                    self._record_turn(active_history, transcript, action.get("speech", ""))
                    return action
            except Exception as e:
                logger.warning(f"Tier 3 (OpenRouter) failed with: {e}. Falling back to Tier 4.")

        # Tier 4: Google Gemini API
        if self.gemini_api_key:
            try:
                action = self._think_gemini(transcript, system_prompt, front_b64, back_b64, active_history)
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
    ) -> Optional[Dict[str, Any]]:
        """Queries Groq Cloud with vision or text models."""
        url = "https://api.groq.com/openai/v1/chat/completions"
        has_vision = bool(front_b64 or back_b64)
        model = "llama-3.2-11b-vision-preview" if has_vision else "llama-3.3-70b-versatile"

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
            "max_tokens": 512,
            "response_format": {"type": "json_object"} if not has_vision else None,
        }
        data_bytes = json.dumps(payload).encode("utf-8")

        req = urllib.request.Request(url, data=data_bytes, method="POST")
        req.add_header("Authorization", f"Bearer {self.groq_api_key}")
        req.add_header("Content-Type", "application/json")

        with urllib.request.urlopen(req, timeout=15.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            content = data["choices"][0]["message"]["content"]
            return self._parse_action_json(content)

    def _think_cloudflare(
        self,
        transcript: str,
        system_prompt: str,
        front_b64: Optional[str],
        back_b64: Optional[str],
        history: List[Dict[str, Any]],
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
        if has_vision and (front_b64 or back_b64):
            # Cloudflare vision model expects image array of bytes or raw buffer
            target_b64 = front_b64 or back_b64
            if target_b64:
                raw_bytes = list(base64.b64decode(target_b64))
                payload["image"] = raw_bytes

        data_bytes = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(url, data=data_bytes, method="POST")
        req.add_header("Authorization", f"Bearer {self.cf_api_token}")
        req.add_header("Content-Type", "application/json")

        with urllib.request.urlopen(req, timeout=20.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            result = data.get("result", {})
            content = result.get("response", "")
            return self._parse_action_json(content)

    def _think_openrouter(
        self,
        transcript: str,
        system_prompt: str,
        front_b64: Optional[str],
        back_b64: Optional[str],
        history: List[Dict[str, Any]],
    ) -> Optional[Dict[str, Any]]:
        """Queries OpenRouter free pooled models."""
        has_vision = bool(front_b64 or back_b64)
        if has_vision:
            # Skip text-only OpenRouter free model when multimodal vision is required
            return None

        url = "https://openrouter.ai/api/v1/chat/completions"
        model = "meta-llama/llama-3.3-70b-instruct:free"

        messages: List[Dict[str, Any]] = [{"role": "system", "content": system_prompt}]
        for turn in history[-4:]:
            messages.append(turn)
        messages.append({"role": "user", "content": transcript})

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

        with urllib.request.urlopen(req, timeout=15.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            content = data["choices"][0]["message"]["content"]
            return self._parse_action_json(content)

    def _think_gemini(
        self,
        transcript: str,
        system_prompt: str,
        front_b64: Optional[str],
        back_b64: Optional[str],
        history: Optional[List[Dict[str, Any]]] = None,
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

        with urllib.request.urlopen(req, timeout=15.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            candidates = data.get("candidates", [])
            if candidates:
                content_parts = candidates[0].get("content", {}).get("parts", [])
                if content_parts:
                    text = content_parts[0].get("text", "")
                    return self._parse_action_json(text)
        return None

        with urllib.request.urlopen(req, timeout=15.0) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            candidates = data.get("candidates", [])
            if candidates:
                content_parts = candidates[0].get("content", {}).get("parts", [])
                if content_parts:
                    text = content_parts[0].get("text", "")
                    return self._parse_action_json(text)
        return None

    # =========================================================================
    # 3. HELPER METHODS & VALIDATION
    # =========================================================================

    def _read_image_b64(self, image_path: str) -> Optional[str]:
        """Reads local JPEG image file and returns base64 encoded string."""
        if not image_path or not os.path.isfile(image_path):
            return None
        try:
            with open(image_path, "rb") as f:
                return base64.b64encode(f.read()).decode("utf-8")
        except Exception as e:
            logger.warning(f"Could not read image for base64 encoding: {e}")
            return None

    def _parse_action_json(self, raw_text: str) -> Dict[str, Any]:
        """Extracts and validates TARS action JSON object from raw LLM output."""
        text = raw_text.strip()
        # Remove markdown code block if present
        if "```" in text:
            match = re.search(r"```(?:json)?\s*([\s\S]*?)\s*```", text)
            if match:
                text = match.group(1).strip()

        # Sanitize any accidental em-dashes
        text = text.replace("\u2014", ":").replace("\u2013", "-")

        try:
            action = json.loads(text)
        except Exception:
            # Fallback if raw text wasn't valid JSON
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
            history.append({"role": "user", "content": user_text})
        if assistant_text:
            history.append({"role": "assistant", "content": assistant_text})
        while len(history) > 10:
            history.pop(0)
