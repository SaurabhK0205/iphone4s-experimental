#!/usr/bin/env python3
"""
DeskCompanion: Python Host Bridge for PhysicalAgent (iPhone 4S on iOS 6.1.3)
Communicates bi-directionally over 30-pin USB via usbmuxd / iproxy.
"""

import socket
import json
import subprocess
import time
import os
import sys
import re
import math
import uuid
import shlex
import shutil
from tars_cloud_brain import TarsCloudBrain, load_dotenv

# Strict repository standard: verify virtual environment isolation
def is_in_venv():
    """Verify that Python execution is isolated within the project virtual environment."""
    repo_venv = os.path.realpath(os.path.join(os.path.dirname(__file__), ".venv"))
    curr_prefix = os.path.realpath(sys.prefix)
    curr_exec = os.path.realpath(sys.executable)
    return curr_prefix == repo_venv or curr_exec.startswith(repo_venv + os.sep)

SAFE_PATH_REGEX = re.compile(r"^/tmp/companion_[a-zA-Z0-9_-]+\.(jpg|wav|png)$")

def _is_safe_remote_path(path):
    return bool(path and SAFE_PATH_REGEX.match(path))

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 5555
WIFI_HOST = "192.168.0.158"
WIFI_PORT = 5000
SSH_PORT = 2222
WIFI_SSH_PORT = 22

# Canonical expressions supported by PhysicalAgent Procedural Eye Engine:
# neutral, blink_high, happy, glee, blink_low, sad_down, sad_up,
# worried, focused, annoyed, surprised, skeptic, frustrated,
# unimpressed, sleepy, suspicious, squint, angry, furious,
# scared, awe, disgust, curious, thinking, alert, asleep, confused,
# glance_left, glance_right.
EXPRESSION_ALIASES = {
    "skeptical": "skeptic",
    "skepticism": "skeptic",
    "joy": "glee",
    "excited": "glee",
    "unhappy": "sad_down",
    "down": "sad_down",
    "sad": "sad_down",
    "fear": "scared",
    "afraid": "scared",
    "amazed": "awe",
    "amazement": "awe",
    "sleep": "sleepy",
    "tired": "sleepy",
    "anger": "angry",
    "fury": "furious",
    "mad": "angry",
    "determined": "focused",
    "bored": "frustrated",
}

class DeskCompanion:
    def __init__(self, host=None, port=None, ssh_port=None, ssh_key=None, strict_host_key_checking=None, known_hosts=None, auth_token=None):
        load_dotenv()
        self.host = host
        self.port = port
        self.ssh_port = ssh_port
        self.ssh_key = ssh_key or os.environ.get("COMPANION_SSH_KEY", os.path.expanduser("~/.ssh/id_rsa_iphone"))
        self.strict_host_key_checking = strict_host_key_checking or os.environ.get("COMPANION_STRICT_HOST_KEY_CHECKING", "yes")
        default_known_hosts = os.path.expanduser("~/.ssh/iphone_known_hosts")
        if not os.path.exists(default_known_hosts):
            default_known_hosts = os.path.expanduser("~/.ssh/known_hosts")
        self.known_hosts = known_hosts or os.environ.get("COMPANION_KNOWN_HOSTS", default_known_hosts)
        self.auth_token = auth_token or os.environ.get("PHYSICAL_AGENT_AUTH_TOKEN")
        self._active_host = None
        self._active_port = None
        self._active_ssh_port = None
        self.brain = TarsCloudBrain()

    def _get_connection_target(self):
        """Auto-detects whether USB or Wi-Fi is reachable (cached)."""
        if self._active_host and self._active_port:
            return self._active_host, self._active_port, self._active_ssh_port

        if self.host and self.port:
            self._active_host = self.host
            self._active_port = self.port
            self._active_ssh_port = self.ssh_port or (2222 if self.host == "127.0.0.1" else 22)
            return self._active_host, self._active_port, self._active_ssh_port

        # Check 1: Try USB only if physical device is detected
        try:
            dev_check = subprocess.run(["ideviceinfo", "-s"], capture_output=True, timeout=1.0)
            if dev_check.returncode == 0:
                test_s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                test_s.settimeout(0.3)
                test_s.connect((DEFAULT_HOST, DEFAULT_PORT))
                test_s.close()
                self._active_host, self._active_port, self._active_ssh_port = DEFAULT_HOST, DEFAULT_PORT, SSH_PORT
                return self._active_host, self._active_port, self._active_ssh_port
        except Exception:
            pass

        # Check 2: Use Wi-Fi
        self._active_host, self._active_port, self._active_ssh_port = WIFI_HOST, WIFI_PORT, WIFI_SSH_PORT
        return self._active_host, self._active_port, self._active_ssh_port

    def _download_file(self, remote_path, local_path, timeout=15.0, retries=3):
        """Downloads remote file from iPhone 4S via SCP with retries and bounds."""
        if not _is_safe_remote_path(remote_path):
            return {"error": "untrusted_remote_path", "details": f"Remote path '{remote_path}' rejected by safety validation filter"}

        ssh_host = self._active_host if self._active_host else "127.0.0.1"
        ssh_port = self._active_ssh_port if self._active_ssh_port else 2222
        key_path = self.ssh_key

        if self.known_hosts:
            if not os.path.exists(self.known_hosts):
                return {"error": "known_hosts_missing", "details": f"Configured known_hosts file '{self.known_hosts}' does not exist"}

        scp_cmd = [
            "scp",
            "-i", key_path,
            "-P", str(ssh_port),
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=3",
            "-o", "ServerAliveCountMax=2",
            "-o", f"StrictHostKeyChecking={self.strict_host_key_checking}",
        ]
        if self.known_hosts:
            scp_cmd.extend(["-o", f"UserKnownHostsFile={self.known_hosts}"])
        scp_cmd.extend([f"root@{ssh_host}:{remote_path}", local_path])

        last_err = ""
        for attempt in range(1, retries + 1):
            try:
                ret = subprocess.run(scp_cmd, capture_output=True, timeout=timeout)
                if ret.returncode == 0 and os.path.exists(local_path) and os.path.getsize(local_path) > 0:
                    # Clean up remote capture file after successful retrieval
                    try:
                        del_cmd = [
                            "ssh",
                            "-i", key_path,
                            "-p", str(ssh_port),
                            "-o", "ConnectTimeout=5",
                            "-o", f"StrictHostKeyChecking={self.strict_host_key_checking}",
                        ]
                        if self.known_hosts:
                            del_cmd.extend(["-o", f"UserKnownHostsFile={self.known_hosts}"])
                        del_cmd.extend([f"root@{ssh_host}", f"rm -f -- {shlex.quote(remote_path)}"])
                        subprocess.run(del_cmd, capture_output=True, timeout=5.0)
                    except Exception:
                        pass
                    return {"status": "ok", "local_file": local_path}
                last_err = ret.stderr.decode("utf-8", errors="replace")
            except subprocess.TimeoutExpired:
                last_err = f"SCP transfer timed out after {timeout} seconds"
            except Exception as e:
                last_err = str(e)
            if attempt < retries:
                time.sleep(0.4 * attempt)

        return {"error": "scp_failed", "details": last_err}

    def _send_cmd(self, cmd_dict, timeout=8.0):
        target_host, target_port, target_ssh = self._get_connection_target()
        self._active_host = target_host
        self._active_port = target_port
        self._active_ssh_port = target_ssh

        # Phase 1: Connect to target (retry on alternate transport only if connect fails before sending)
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect((target_host, target_port))
        except (ConnectionRefusedError, socket.timeout, OSError) as conn_err:
            s.close()
            if self.host is None:
                self._active_host = None
                self._active_port = None
                self._active_ssh_port = None
                alt_host = WIFI_HOST if target_host == DEFAULT_HOST else DEFAULT_HOST
                alt_port = WIFI_PORT if target_port == DEFAULT_PORT else DEFAULT_PORT
                if target_ssh == SSH_PORT:
                    alt_ssh = WIFI_SSH_PORT
                elif target_ssh == WIFI_SSH_PORT:
                    alt_ssh = SSH_PORT
                else:
                    alt_ssh = self.ssh_port or (2222 if alt_host == "127.0.0.1" else 22)
                s_alt = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s_alt.settimeout(timeout)
                try:
                    s_alt.connect((alt_host, alt_port))
                    self._active_host, self._active_port, self._active_ssh_port = alt_host, alt_port, alt_ssh
                    s = s_alt
                except Exception:
                    s_alt.close()
                    return {"error": "connection_refused", "message": f"Companion server unreachable on {target_host}:{target_port} and {alt_host}:{alt_port}."}
            else:
                return {"error": str(conn_err)}

        # Phase 2: Transmission and reception (newline-delimited frames, bounded monotonic deadline and frame size)
        with s:
            try:
                if self.auth_token:
                    cmd_dict = dict(cmd_dict)
                    cmd_dict["token"] = self.auth_token
                payload = json.dumps(cmd_dict).encode("utf-8") + b"\n"
                s.sendall(payload)
                buffer = b""
                deadline = time.monotonic() + timeout
                max_bytes = 65536
                while b"\n" not in buffer:
                    remaining_time = deadline - time.monotonic()
                    if remaining_time <= 0 or len(buffer) >= max_bytes:
                        self._active_host, self._active_port, self._active_ssh_port = None, None, None
                        return {"error": "read_timeout_or_limit_exceeded"}
                    s.settimeout(max(0.1, remaining_time))
                    chunk = s.recv(4096)
                    if not chunk:
                        break
                    buffer += chunk
                if not buffer:
                    self._active_host, self._active_port, self._active_ssh_port = None, None, None
                    return {"error": "empty_response"}
                line = buffer.split(b"\n", 1)[0]
                res = json.loads(line.decode("utf-8"))
                if not isinstance(res, dict):
                    return {"status": "error", "error": "malformed_response", "raw": str(res)}
                return res
            except Exception as e:
                self._active_host, self._active_port, self._active_ssh_port = None, None, None
                return {"error": str(e)}

    def ping(self):
        return self._send_cmd({"command": "ping"})

    def telemetry(self):
        return self._send_cmd({"command": "telemetry"})

    def set_expression(self, expression_name, duration=0.28):
        """Sets procedural robot eye expression.
        Supported official Cozmo presets:
          neutral, blink_high, happy, glee, blink_low, sad_down, sad_up,
          worried, focused, annoyed, surprised, skeptic, frustrated,
          unimpressed, sleepy, suspicious, squint, angry, furious,
          scared, awe.
        Also supports: curious, thinking, alert, asleep, confused,
          glance_left, glance_right.
        """
        exp = str(expression_name).lower().strip()
        exp = EXPRESSION_ALIASES.get(exp, exp)
        try:
            dur = float(duration)
            if math.isnan(dur) or math.isinf(dur) or dur <= 0.0:
                dur = 0.28
        except (ValueError, TypeError):
            dur = 0.28
        return self._send_cmd({"command": "expression", "name": exp, "duration": dur})

    def look_at(self, x=0.0, y=0.0, duration=0.22):
        """Sets companion gaze direction using normalized coordinates [-1.0, 1.0]."""
        x_clamped = max(-1.0, min(1.0, float(x)))
        y_clamped = max(-1.0, min(1.0, float(y)))
        return self._send_cmd({"command": "look_at", "x": x_clamped, "y": y_clamped, "duration": float(duration)})

    def set_eye_params(self, left_params=None, right_params=None, duration=0.28):
        """Sets the 25 procedural parameters for left and/or right eye."""
        cmd = {"command": "procedural_eye_params", "duration": float(duration)}
        if left_params is not None:
            cmd["left"] = list(left_params)
        if right_params is not None:
            cmd["right"] = list(right_params)
        return self._send_cmd(cmd)

    def set_scanlines(self, opacity=0.12):
        """Sets CRT scanline overlay opacity [0.0, 0.40]."""
        opacity_clamped = max(0.0, min(0.40, float(opacity)))
        return self._send_cmd({"command": "scanlines", "opacity": opacity_clamped})

    def set_status(self, title, subtitle=None):
        cmd = {"command": "status", "title": title}
        if subtitle:
            cmd["subtitle"] = subtitle
        return self._send_cmd(cmd)

    def set_speaking(self, enable=True):
        return self._send_cmd({"command": "speaking", "enable": bool(enable)})

    def toggle_zen(self):
        return self._send_cmd({"command": "zen"})

    def blink(self):
        return self._send_cmd({"command": "blink"})

    def vibrate(self):
        return self._send_cmd({"command": "vibrate"})

    def play_sound(self, sound_name="confirm"):
        """confirm, begin, cancel, shutter, tweet, mail, tink, beep, alarm"""
        return self._send_cmd({"command": "sound", "name": sound_name})

    def set_torch(self, enable=True):
        return self._send_cmd({"command": "torch", "enable": bool(enable)})

    def probe_luminance(self, camera="front"):
        """Samples mean scene luminance [0.0, 1.0] from the specified camera ('front' or 'back')."""
        cam = camera if camera in ("front", "back") else "front"
        return self._send_cmd({"command": "probe_luminance", "camera": cam}, timeout=15.0)

    def set_brightness(self, level=1.0):
        level = max(0.0, min(1.0, float(level)))
        return self._send_cmd({"command": "brightness", "level": level})

    def set_reduced_motion(self, enable=True):
        return self._send_cmd({"command": "reduced_motion", "enable": bool(enable)})

    def wake(self, reason="remote_wake"):
        return self._send_cmd({"command": "wake", "reason": str(reason)})

    def sleep(self, mode="obsidian"):
        """Transitions companion into 'obsidian' (pitch-black) or 'ambient' standby."""
        return self._send_cmd({"command": "sleep", "mode": str(mode)})

    def set_standby_config(self, idle_timeout=180.0, standby_timeout=360.0):
        """Configures inactivity timeouts in seconds."""
        try:
            idle_val = float(idle_timeout)
            standby_val = float(standby_timeout)
        except (ValueError, TypeError):
            return {"error": "invalid_parameter", "details": "Timeouts must be numeric"}
        if not (math.isfinite(idle_val) and math.isfinite(standby_val)):
            return {"error": "invalid_parameter", "details": "Timeouts must be finite numbers"}
        return self._send_cmd({
            "command": "standby_config",
            "idle_timeout": idle_val,
            "standby_timeout": standby_val,
        })

    def snapshot(self, camera="back", save_to=None):
        """Captures a photo via iPhone 4S camera ('back' or 'front') and retrieves it."""
        res = self._send_cmd({"command": "snapshot", "camera": camera}, timeout=15.0)
        if res.get("status") == "ok" and "path" in res:
            remote_path = res["path"]
            if save_to is None:
                save_to = f"snapshot_{camera}_{int(time.time())}_{uuid.uuid4().hex[:6]}.jpg"
            save_to = os.path.abspath(save_to)
            dl_res = self._download_file(remote_path, save_to, timeout=12.0)
            if dl_res.get("status") == "ok":
                res["local_file"] = save_to
                return res
            return dl_res
        return res

    def inspect_environment(self, save_dir="."):
        """Captures both front (desk/user) and rear (workspace macro) angles with hardware settle delay."""
        os.makedirs(save_dir, exist_ok=True)
        ts = int(time.time())
        req_id = uuid.uuid4().hex[:6]
        front_path = os.path.join(save_dir, f"inspect_front_{ts}_{req_id}.jpg")
        back_path = os.path.join(save_dir, f"inspect_back_{ts}_{req_id}.jpg")

        front_res = self.snapshot("front", save_to=front_path)
        # Settle delay between camera switches to allow iOS 6 mediaserverd camera ISP hardware release
        time.sleep(1.0)
        back_res = self.snapshot("back", save_to=back_path)

        overall_status = "ok" if (front_res.get("status") == "ok" and back_res.get("status") == "ok") else "partial_failure"
        return {
            "status": overall_status,
            "front": front_res,
            "back": back_res,
            "timestamp": ts
        }

    def record_audio(self, duration=3.0, save_to=None):
        """Records physical microphone audio on iPhone 4S and retrieves linear PCM WAV."""
        try:
            dur = float(duration)
            if math.isnan(dur) or math.isinf(dur) or dur <= 0.0:
                dur = 3.0
            dur = max(0.1, min(dur, 30.0))
        except (ValueError, TypeError):
            dur = 3.0

        res = self._send_cmd({"command": "record_audio", "duration": dur}, timeout=dur + 8.0)
        if res.get("status") == "ok" and "path" in res:
            remote_path = res["path"]
            if save_to is None:
                save_to = f"companion_audio_{int(time.time())}_{uuid.uuid4().hex[:6]}.wav"
            save_to = os.path.abspath(save_to)
            dl_res = self._download_file(remote_path, save_to, timeout=dur + 10.0)
            if dl_res.get("status") == "ok":
                res["local_file"] = save_to
                return res
            return dl_res
        return res

    def screenshot(self, save_to=None):
        """Captures pixel-exact 640x960 Retina screen of PhysicalAgent and retrieves PNG."""
        res = self._send_cmd({"command": "screenshot"}, timeout=10.0)
        if res.get("status") == "ok" and "path" in res:
            remote_path = res["path"]
            if save_to is None:
                save_to = f"companion_screen_{int(time.time())}_{uuid.uuid4().hex[:6]}.png"
            save_to = os.path.abspath(save_to)
            dl_res = self._download_file(remote_path, save_to, timeout=10.0)
            if dl_res.get("status") == "ok":
                res["local_file"] = save_to
                return res
            return dl_res
        return res

    def _speak_text(self, text, voice="Samantha", timeout=15.0):
        """Cross-platform text-to-speech with explicit timeout and fallbacks."""
        if shutil.which("say"):
            proc = subprocess.run(["say", "-v", voice, text], timeout=timeout, capture_output=True, text=True)
            if proc.returncode != 0:
                raise RuntimeError(f"say exited with code {proc.returncode}: {proc.stderr.strip()}")
        elif shutil.which("espeak"):
            proc = subprocess.run(["espeak", text], timeout=timeout, capture_output=True, text=True)
            if proc.returncode != 0:
                raise RuntimeError(f"espeak exited with code {proc.returncode}: {proc.stderr.strip()}")
        else:
            print(f"[AUDIO TTS] {text}")

    def say(self, text, voice="Samantha"):
        """Speaks text using system speech synthesizer while animating companion eyes and spectrum waveform."""
        self.set_expression("thinking")
        self.set_status("AGENT SPEAKING //", text[:40])
        self.set_speaking(True)
        self.play_sound("begin")
        time.sleep(0.2)
        try:
            self._speak_text(text, voice=voice)
        except Exception as e:
            print(f"[TARS Speech] say command error: {e}")
        finally:
            self.set_speaking(False)
            self.set_expression("neutral")
            self.set_status("PHYSICAL AGENT // ONLINE", "Awaiting multimodal input")

    def brain_status(self):
        """Returns the readiness and configured tiers of the multi-cloud TARS brain."""
        return self.brain.get_status()

    def listen_and_think(self, duration=3.0, with_vision=False):
        """Records physical audio from iPhone 4S mic, executes multi-cloud TARS cognition,
        and triggers synchronized physical action and speech output."""
        print(f"\n[TARS] Recording {duration:.1f}s audio from physical iPhone 4S mic...")
        self.set_status("TARS // LISTENING", "Recording microphone audio")
        rec_res = self.record_audio(duration=duration)
        if rec_res.get("status") != "ok" or "local_file" not in rec_res:
            print("[TARS] Failed to capture audio:", rec_res)
            self.set_expression("skeptical")
            self.set_status("PHYSICAL AGENT // ONLINE", "Awaiting input")
            return {"status": "error", "error": "audio_recording_failed", "details": rec_res, "transcript": ""}

        audio_path = rec_res["local_file"]
        try:
            transcript = self.brain.transcribe_audio(audio_path)
            print(f"[TARS Hearing] Transcript: '{transcript}'")
        except Exception as e:
            print(f"[TARS Hearing] Transcription error: {e}")
            if not with_vision:
                self.set_expression("skeptical")
                self.set_status("PHYSICAL AGENT // ONLINE", "Awaiting input")
                return {"status": "error", "error": "transcription_failed", "details": str(e), "transcript": ""}
            transcript = ""

        if not transcript and not with_vision:
            print("[TARS] No audible speech detected.")
            self.set_expression("neutral")
            self.set_status("PHYSICAL AGENT // ONLINE", "Awaiting input")
            return {"status": "silent", "transcript": ""}

        return self._run_tars_turn(prompt=transcript, with_vision=with_vision)

    def interact(self, prompt, with_vision=False):
        """Executes a direct text reasoning turn with multi-cloud TARS brain without audio recording."""
        return self._run_tars_turn(prompt=prompt, with_vision=with_vision)

    def _run_tars_turn(self, prompt, with_vision=False):
        """Shared cognitive execution pipeline for voice and text turns."""
        front_path = None
        if with_vision:
            print("[TARS] Capturing front camera snapshot for visual context...")
            snap_res = self.snapshot("front")
            if not isinstance(snap_res, dict) or snap_res.get("status") != "ok" or "local_file" not in snap_res:
                err_msg = snap_res.get("error", "snapshot_unavailable") if isinstance(snap_res, dict) else "invalid_snapshot_response"
                print(f"[TARS Error] Front camera capture failed: {err_msg}")
                self.set_expression("skeptic")
                self.set_status("PHYSICAL AGENT // ONLINE", "Vision capture failed")
                return {"status": "error", "error": "vision_capture_failed", "details": snap_res, "transcript": prompt}
            front_path = snap_res["local_file"]

        print("[TARS] Setting expression to 'thinking' and processing cloud cascade...")
        self.set_expression("thinking")
        self.set_status("TARS // THINKING", prompt[:30] if prompt else "Visual scene")

        action = self.brain.think_and_act(transcript=prompt, front_image_path=front_path)
        if action.get("_fallback"):
            action["status"] = "fallback"
        else:
            action.setdefault("status", "ok")
        action.setdefault("transcript", prompt)
        print(f"[TARS Cognition] Action plan: {json.dumps(action, indent=2)}")
        return self._execute_tars_action(action)

    def _execute_tars_action(self, action):
        """Applies TarsAction dictionary to physical iPhone 4S hardware."""
        device_errors = []
        # 1. Haptics
        haptic = action.get("haptic")
        if haptic == "double":
            res1 = self.vibrate()
            if not isinstance(res1, dict) or res1.get("status") not in ("ok", "vibrated"):
                err = res1.get("error", "unconfirmed") if isinstance(res1, dict) else "invalid_response"
                device_errors.append(f"vibrate_1: {err}")
            time.sleep(0.08)
            res2 = self.vibrate()
            if not isinstance(res2, dict) or res2.get("status") not in ("ok", "vibrated"):
                err = res2.get("error", "unconfirmed") if isinstance(res2, dict) else "invalid_response"
                device_errors.append(f"vibrate_2: {err}")
        elif haptic == "pulse":
            res = self.vibrate()
            if not isinstance(res, dict) or res.get("status") not in ("ok", "vibrated"):
                err = res.get("error", "unconfirmed") if isinstance(res, dict) else "invalid_response"
                device_errors.append(f"vibrate: {err}")

        # 2. Expression Framing (set expression preset before applying fine gaze offset)
        expression = action.get("expression", "neutral")
        self.set_expression(expression)

        # 3. Look at target (applies gaze target on top of the established expression)
        look_at = action.get("look_at")
        if look_at and isinstance(look_at, (list, tuple)) and len(look_at) == 2:
            res = self.look_at(look_at[0], look_at[1])
            if not isinstance(res, dict) or res.get("status") != "ok":
                err = res.get("error", "unconfirmed") if isinstance(res, dict) else "invalid_response"
                device_errors.append(f"look_at: {err}")

        # 4. Torch
        torch = action.get("torch")
        if torch is not None:
            res = self.set_torch(bool(torch))
            if not isinstance(res, dict) or res.get("status") != "ok":
                err = res.get("error", "unconfirmed") if isinstance(res, dict) else "invalid_response"
                device_errors.append(f"torch: {err}")

        # 5. Speech & Spectrum Synchronization
        speech = action.get("speech", "")
        if speech:
            self.set_status("TARS // SPEAKING", speech[:40])
            self.set_speaking(True)
            voice = os.environ.get("TARS_DEFAULT_VOICE", "Samantha")
            try:
                self._speak_text(speech, voice=voice)
            except Exception as e:
                print(f"[TARS Speech] Playback error: {e}")
                device_errors.append(f"speech: {e}")
            finally:
                self.set_speaking(False)
                self.set_status("PHYSICAL AGENT // ONLINE", "Awaiting input")
        else:
            self.set_status("PHYSICAL AGENT // ONLINE", "Awaiting input")

        if device_errors:
            action["_device_errors"] = device_errors
            print(f"[TARS Hardware Warning] Some hardware actions could not be confirmed: {', '.join(device_errors)}")

        return action

    def run_demo(self):
        print("\n>>> STARTING EMBODIED COMPANION DEMO SEQUENCE <<<")
        print("1. Waking up...")
        self.set_expression("sleep")
        self.set_status("SYSTEM ASLEEP //\nInitializing neural link...")
        time.sleep(1.5)

        print("2. Awakening & Blink...")
        self.set_expression("surprised")
        self.play_sound("begin")
        self.vibrate()
        self.set_status("AGENT AWAKENING //\nHardware sensors initialized")
        time.sleep(1.5)

        print("3. Happy greeting...")
        self.set_expression("happy")
        self.play_sound("confirm")
        self.set_status("HELLO HUMAN!\nPhysical Companion Online")
        time.sleep(1.5)

        print("4. Looking around...")
        self.set_expression("glance_left")
        time.sleep(0.8)
        self.set_expression("glance_right")
        time.sleep(0.8)

        print("5. Thinking...")
        self.set_expression("thinking")
        self.set_status("THINKING //\nProcessing multimodal state")
        time.sleep(1.5)

        print("6. Rear LED Flashlight pulse...")
        self.set_torch(True)
        time.sleep(0.4)
        self.set_torch(False)

        print("7. Front Camera Snapshot (Desk View)...")
        snap = self.snapshot("front", "demo_selfie.jpg")
        print("   Snapshot result:", snap.get("local_file", snap))

        print("8. Telemetry readout...")
        tel = self.telemetry()
        print("   Device:", tel.get("device"), "| Battery:", tel.get("battery_percent"), "% | RAM Free:", tel.get("free_memory_mb"), "MB")

        print("9. Neutral resting stance...")
        self.set_expression("neutral")
        self.set_status("PHYSICAL AGENT // ONLINE\nEmbodied Companion Ready")
        print(">>> DEMO COMPLETE! <<<\n")


def interactive_cli():
    companion = DeskCompanion()
    print("=" * 60)
    print(" ANTIGRAVITY PHYSICAL AGENT // EMBODIED COMPANION CLI")
    print(" Target: Physical iPhone 4S (iOS 6.1.3) via 30-Pin USB")
    print("=" * 60)
    print("Commands:")
    print("  express <name>      Set procedural expression (neutral, happy, glee, curious, skeptic, surprised, thinking, focused, annoyed, alert, sleepy, asleep, confused, frustrated, sad)")
    print("  look <x> <y>        Direct companion gaze using normalized floats (-1.0 to 1.0)")
    print("  scanlines <opacity> Set retro CRT scanline contrast (0.0 to 0.40)")
    print("  status <text>       Set HUD status text")
    print("  say <text>          Speak aloud and animate companion")
    print("  vibrate             Trigger haptic vibration motor")
    print("  sound <name>        Play acoustic sound (confirm, begin, cancel, shutter, tweet, mail, tink, beep)")
    print("  torch <on|off>      Toggle rear camera LED flashlight")
    print("  photo [front|back]  Capture camera photo and save locally")
    print("  luma [front|back]   Probe camera scene luminance [0.0, 1.0]")
    print("  inspect             Capture both front (desk) and rear (macro) angles")
    print("  listen [duration]   Record audio from iPhone 4S mic and save WAV")
    print("  screenshot          Capture pixel-exact Retina display PNG")
    print("  motion <on|off>     Toggle reduced motion (disable saccades and breathing)")
    print("  blink               Trigger eye blink")
    print("  wave <on|off>       Toggle audio spectrum waveform visualizer")
    print("  zen                 Toggle Zen mode (dim HUD cards for night ambiance)")
    print("  telemetry           Display battery, memory, brightness")
    print("  brain               Inspect multi-cloud TARS brain readiness and tiers")
    print("  tars <prompt>       Direct conversation turn with TARS cloud brain")
    print("  tars_listen [sec]   Record iPhone 4S mic and process via TARS brain")
    print("  tars_see [prompt]   Capture front desk photo and process via TARS vision")
    print("  demo                Run full interactive presentation demo")
    print("  exit / quit         Exit CLI")
    print("=" * 60)

    while True:
        try:
            line = input("\ncompanion> ").strip()
            if not line:
                continue
            parts = line.split(" ", 1)
            cmd = parts[0].lower()
            arg = parts[1].strip() if len(parts) > 1 else ""

            if cmd in ("exit", "quit", "q"):
                print("Exiting.")
                break
            elif cmd == "express":
                res = companion.set_expression(arg if arg else "neutral")
                print("Result:", res)
            elif cmd == "look":
                coords = [float(c) for c in arg.split()] if arg else [0.0, 0.0]
                lx = coords[0] if len(coords) > 0 else 0.0
                ly = coords[1] if len(coords) > 1 else 0.0
                res = companion.look_at(lx, ly)
                print("Result:", res)
            elif cmd == "scanlines":
                op = float(arg) if arg else 0.12
                res = companion.set_scanlines(op)
                print("Result:", res)
            elif cmd == "status":
                res = companion.set_status(arg)
                print("Result:", res)
            elif cmd == "say":
                companion.say(arg if arg else "Hello from your desk companion!")
            elif cmd == "vibrate":
                res = companion.vibrate()
                print("Result:", res)
            elif cmd == "sound":
                res = companion.play_sound(arg if arg else "confirm")
                print("Result:", res)
            elif cmd == "torch":
                res = companion.set_torch(arg.lower() in ("on", "1", "true"))
                print("Result:", res)
            elif cmd == "photo":
                cam = arg if arg in ("front", "back") else "back"
                res = companion.snapshot(cam)
                print("Result:", res)
            elif cmd == "luma":
                cam = arg if arg in ("front", "back") else "front"
                res = companion.probe_luminance(cam)
                print("Result:", res)
            elif cmd == "inspect":
                res = companion.inspect_environment()
                print("Result:", res)
            elif cmd == "listen":
                dur = float(arg) if arg else 3.0
                res = companion.record_audio(dur)
                print("Result:", res)
            elif cmd == "screenshot":
                res = companion.screenshot()
                print("Result:", res)
            elif cmd == "motion":
                val = (arg or "").strip().lower()
                if val in ("on", "1", "true", "yes", "enable"):
                    res = companion.set_reduced_motion(True)
                    print("Result:", res)
                elif val in ("off", "0", "false", "no", "disable"):
                    res = companion.set_reduced_motion(False)
                    print("Result:", res)
                else:
                    print("Usage: motion [on|off]")
            elif cmd == "blink":
                res = companion.blink()
                print("Result:", res)
            elif cmd == "wave":
                res = companion.set_speaking(arg.lower() in ("on", "1", "true"))
                print("Result:", res)
            elif cmd == "zen":
                res = companion.toggle_zen()
                print("Result:", res)
            elif cmd == "telemetry":
                print(json.dumps(companion.telemetry(), indent=2))
            elif cmd == "brain":
                print(json.dumps(companion.brain_status(), indent=2))
            elif cmd == "tars":
                prompt = arg if arg else "Status report, TARS."
                companion.interact(prompt, with_vision=False)
            elif cmd == "tars_listen":
                dur = float(arg) if arg else 3.0
                companion.listen_and_think(duration=dur, with_vision=False)
            elif cmd == "tars_see":
                prompt = arg if arg else "What do you see on my desk?"
                companion.interact(prompt, with_vision=True)
            elif cmd == "demo":
                companion.run_demo()
            else:
                print(f"Unknown command: {cmd}. Type a valid command.")
        except KeyboardInterrupt:
            print("\nExiting.")
            break
        except Exception as e:
            print("Error:", e)

if __name__ == "__main__":
    if not is_in_venv():
        print(
            "FATAL: Execution outside dedicated virtual environment (.venv) is strictly prohibited. "
            "Run via '.venv/bin/python3 desk_companion.py' or './start_companion.sh'.",
            file=sys.stderr,
        )
        sys.exit(1)
    if len(sys.argv) > 1 and sys.argv[1] == "demo":
        DeskCompanion().run_demo()
    else:
        interactive_cli()
