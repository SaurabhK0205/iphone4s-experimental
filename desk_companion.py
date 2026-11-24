#!/usr/bin/env python3
"""
DeskCompanion - Python Host Bridge for PhysicalAgent (iPhone 4S on iOS 6.1.3)
Communicates bi-directionally over 30-pin USB via usbmuxd / iproxy.
"""

import socket
import json
import subprocess
import time
import os
import sys

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 5555
WIFI_HOST = "192.168.0.158"
WIFI_PORT = 5000
SSH_PORT = 2222
WIFI_SSH_PORT = 22

class DeskCompanion:
    def __init__(self, host=None, port=None, ssh_port=None):
        self.host = host
        self.port = port
        self.ssh_port = ssh_port
        self._active_host = None
        self._active_port = None
        self._active_ssh_port = None

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

    def _send_cmd(self, cmd_dict, timeout=8.0):
        target_host, target_port, target_ssh = self._get_connection_target()
        self._active_host = target_host
        self._active_port = target_port
        self._active_ssh_port = target_ssh

        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(timeout)
            s.connect((target_host, target_port))
            payload = json.dumps(cmd_dict).encode("utf-8")
            s.sendall(payload)
            data = s.recv(8192)
            s.close()
            if not data:
                return {"error": "empty_response"}
            return json.loads(data.decode("utf-8"))
        except ConnectionRefusedError:
            return {"error": "connection_refused", "message": f"Companion server not reachable at {target_host}:{target_port}."}
        except Exception as e:
            return {"error": str(e)}

    def ping(self):
        return self._send_cmd({"command": "ping"})

    def telemetry(self):
        return self._send_cmd({"command": "telemetry"})

    def set_expression(self, expression_name):
        """happy, surprised, thinking, alert, sleep, glance_left, glance_right, neutral"""
        return self._send_cmd({"command": "expression", "name": expression_name})

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

    def set_brightness(self, level=1.0):
        level = max(0.0, min(1.0, float(level)))
        return self._send_cmd({"command": "brightness", "level": level})

    def set_reduced_motion(self, enable=True):
        return self._send_cmd({"command": "reduced_motion", "enable": bool(enable)})

    def snapshot(self, camera="back", save_to=None):
        """Captures a photo via iPhone 4S camera ('back' or 'front') and retrieves it."""
        res = self._send_cmd({"command": "snapshot", "camera": camera}, timeout=12.0)
        if res.get("status") == "ok" and "path" in res:
            remote_path = res["path"]
            if save_to is None:
                save_to = f"snapshot_{camera}_{int(time.time())}.jpg"
            save_to = os.path.abspath(save_to)
            
            # Retrieve file via scp (over USB or Wi-Fi)
            ssh_host = self._active_host if self._active_host else "127.0.0.1"
            ssh_port = self._active_ssh_port if self._active_ssh_port else 2222
            scp_cmd = [
                "scp",
                "-i", os.path.expanduser("~/.ssh/id_rsa_iphone"),
                "-P", str(ssh_port),
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                f"root@{ssh_host}:{remote_path}",
                save_to
            ]
            ret = subprocess.run(scp_cmd, capture_output=True)
            if ret.returncode == 0 and os.path.exists(save_to):
                res["local_file"] = save_to
                return res
            else:
                return {"error": "scp_failed", "details": ret.stderr.decode()}
        return res

    def inspect_environment(self, save_dir="."):
        """Captures both front (desk/user) and rear (workspace macro) angles."""
        os.makedirs(save_dir, exist_ok=True)
        ts = int(time.time())
        front_path = os.path.join(save_dir, f"inspect_front_{ts}.jpg")
        back_path = os.path.join(save_dir, f"inspect_back_{ts}.jpg")

        front_res = self.snapshot("front", save_to=front_path)
        time.sleep(0.5)
        back_res = self.snapshot("back", save_to=back_path)

        return {
            "status": "ok",
            "front": front_res,
            "back": back_res,
            "timestamp": ts
        }

    def record_audio(self, duration=3.0, save_to=None):
        """Records physical microphone audio on iPhone 4S and retrieves linear PCM WAV."""
        res = self._send_cmd({"command": "record_audio", "duration": float(duration)}, timeout=float(duration) + 8.0)
        if res.get("status") == "ok" and "path" in res:
            remote_path = res["path"]
            if save_to is None:
                save_to = f"companion_audio_{int(time.time())}.wav"
            save_to = os.path.abspath(save_to)

            ssh_host = self._active_host if self._active_host else "127.0.0.1"
            ssh_port = self._active_ssh_port if self._active_ssh_port else 2222
            scp_cmd = [
                "scp",
                "-i", os.path.expanduser("~/.ssh/id_rsa_iphone"),
                "-P", str(ssh_port),
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                f"root@{ssh_host}:{remote_path}",
                save_to
            ]
            ret = subprocess.run(scp_cmd, capture_output=True)
            if ret.returncode == 0 and os.path.exists(save_to):
                res["local_file"] = save_to
                return res
            else:
                return {"error": "scp_failed", "details": ret.stderr.decode()}
        return res

    def screenshot(self, save_to=None):
        """Captures pixel-exact 640x960 Retina screen of PhysicalAgent and retrieves PNG."""
        res = self._send_cmd({"command": "screenshot"}, timeout=8.0)
        if res.get("status") == "ok" and "path" in res:
            remote_path = res["path"]
            if save_to is None:
                save_to = f"companion_screen_{int(time.time())}.png"
            save_to = os.path.abspath(save_to)

            ssh_host = self._active_host if self._active_host else "127.0.0.1"
            ssh_port = self._active_ssh_port if self._active_ssh_port else 2222
            scp_cmd = [
                "scp",
                "-i", os.path.expanduser("~/.ssh/id_rsa_iphone"),
                "-P", str(ssh_port),
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                f"root@{ssh_host}:{remote_path}",
                save_to
            ]
            ret = subprocess.run(scp_cmd, capture_output=True)
            if ret.returncode == 0 and os.path.exists(save_to):
                res["local_file"] = save_to
                return res
            else:
                return {"error": "scp_failed", "details": ret.stderr.decode()}
        return res

    def say(self, text, voice="Samantha"):
        """Speaks text using Mac speech synthesizer while animating companion eyes and spectrum waveform."""
        self.set_expression("thinking")
        self.set_status("AGENT SPEAKING //", text[:40])
        self.set_speaking(True)
        self.play_sound("begin")
        time.sleep(0.2)
        subprocess.run(["say", "-v", voice, text])
        self.set_speaking(False)
        self.set_expression("neutral")
        self.set_status("PHYSICAL AGENT // ONLINE", "Awaiting multimodal input")

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
    print("  express <name>      Set expression (happy, surprised, thinking, alert, sleep, neutral, glance_left, glance_right)")
    print("  status <text>       Set HUD status text")
    print("  say <text>          Speak aloud and animate companion")
    print("  vibrate             Trigger haptic vibration motor")
    print("  sound <name>        Play acoustic sound (confirm, begin, cancel, shutter, tweet, mail, tink, beep)")
    print("  torch <on|off>      Toggle rear camera LED flashlight")
    print("  photo [front|back]  Capture camera photo and save locally")
    print("  inspect             Capture both front (desk) and rear (macro) angles")
    print("  listen [duration]   Record audio from iPhone 4S mic and save WAV")
    print("  screenshot          Capture pixel-exact Retina display PNG")
    print("  motion <on|off>     Toggle reduced motion (disable saccades and breathing)")
    print("  blink               Trigger eye blink")
    print("  wave <on|off>       Toggle audio spectrum waveform visualizer")
    print("  zen                 Toggle Zen mode (dim HUD cards for night ambiance)")
    print("  telemetry           Display battery, memory, brightness")
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
                res = companion.set_reduced_motion(arg.lower() not in ("off", "0", "false"))
                print("Result:", res)
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
    if len(sys.argv) > 1 and sys.argv[1] == "demo":
        DeskCompanion().run_demo()
    else:
        interactive_cli()
