# PhysicalAgent: iPhone 4S Embodied Desk Companion

A fully native, embodied multimodal AI desk companion built on a physical **iPhone 4S** (A5 chip, ARMv7, 512MB RAM, 3.5" Retina display) running untethered **iOS 6.1.3**, controlled over a 30-pin USB cable from a **MacBook Air M5 (Apple Silicon)**.

No web CRUD wrappers. Pure native Objective-C/C communicating directly over USB (`usbmuxd`).

---

## 1. Capabilities

| Capability | Hardware Used | Protocol / Method |
|---|---|---|
| **Retina Face Renderer** | 3.5" 960x640 Retina Display | Native `CoreAnimation` / `CALayer` animated glowing vector eyes with sub-millisecond 60 FPS transitions. |
| **Expressions** | Display + Haptics | `happy`, `surprised`, `thinking`, `alert`, `sleep`, `glance_left`, `glance_right`, `neutral`. |
| **Acoustic Audio FX** | Bottom stereo speaker chamber | Hardware `AudioServices` playing iOS system sounds (`confirm`, `begin`, `cancel`, `shutter`, `tweet`, `beep`, `tink`). |
| **Haptic Feedback** | Internal eccentric rotating mass (ERM) motor | Native `kSystemSoundID_Vibrate` triggered on touch or alert commands. |
| **Multimodal Vision** | Front (VGA) & Rear (8MP 1080p) cameras | Native `AVCaptureSession` capturing hardware JPEG stills on demand. |
| **Flashlight / Torch** | Rear camera LED flash | `AVCaptureTorchModeOn` / `AVCaptureTorchModeOff`. |
| **Touch Sensor** | Capacitive multi-touch digitizer | Physical screen taps trigger immediate haptic vibration, blink animation, and companion happiness response. |
| **Telemetry HUD** | Battery, clock, memory, screen | Live battery %, charging state, Mach VM free RAM, uptime, and screen brightness. |
| **USB Link** | 30-pin Dock Connector | High-speed 480 Mbps bi-directional TCP communication via `usbmuxd` / `iproxy`. |

---

## 2. Quick Start

### Launch the Companion
```bash
./start_companion.sh
```
This automatically verifies device connectivity, checks port forwarders, starts `PhysicalAgent.app` on the phone's screen, and drops into the interactive CLI.

### Interactive CLI Commands
```
companion> express happy
companion> express thinking
companion> express alert
companion> status "Compiling neural model..."
companion> say "Hello! I am your physical desk companion."
companion> photo front
companion> photo back
companion> torch on
companion> torch off
companion> vibrate
companion> sound confirm
companion> telemetry
companion> demo
```

---

## 3. Python API Usage

You can import `DeskCompanion` into any agent or Python script:

```python
from desk_companion import DeskCompanion

companion = DeskCompanion()

# Check live device telemetry
telemetry = companion.telemetry()
print(telemetry)

# Set expression and status
companion.set_expression("happy")
companion.set_status("Task completed successfully!")

# Play sound and vibrate
companion.play_sound("confirm")
companion.vibrate()

# Capture desk image via camera
result = companion.snapshot(camera="front", save_to="desk_view.jpg")
print("Saved photo to:", result["local_file"])

# Speak aloud with companion animation
companion.say("Everything is running smoothly.")
```

---

## 4. Native Toolchain & Architecture

### Compiling Native ARMv7 for iOS 6.1.3 on Apple Silicon
Modern macOS Xcode dropped ARMv7 and legacy Mach-O support. We solved this with:
1. **Target**: `armv7-apple-ios6.0` using cleaned `iPhoneOS9.3.sdk` (stripped of modern simulator architectures).
2. **C Runtime (`_start`)**: Custom ARM assembly entrypoint in `test_native/start.s` handling stack argument setup (`argc`, `argv`, `envp`, `apple`) and dyld initialization.
3. **Mach-O Header Conversion**: `tools/fix_macho_ios6.py` patches modern `LC_MAIN` (`0x80000028`) into legacy `LC_UNIXTHREAD` (`0x5`, flavor 1, count 17) within Mach-O header padding, preserving section offsets and alignment.
4. **Code Signing**: Jailbreak pseudo-codesigning via `ldid -S`.

### Build & Deploy Command
```bash
clang -target armv7-apple-ios6.0 \
  -isysroot sdks/iPhoneOS9.3.sdk \
  -marm -fno-objc-arc \
  -framework UIKit -framework Foundation -framework CoreGraphics \
  -framework QuartzCore -framework AVFoundation -framework AudioToolbox \
  -framework CoreMedia -framework CoreVideo -framework CoreMotion \
  -Wl,-e,_start \
  test_native/start.s PhysicalAgent/main.m \
  -o PhysicalAgent/PhysicalAgent_raw

python3 tools/fix_macho_ios6.py PhysicalAgent/PhysicalAgent_raw PhysicalAgent/PhysicalAgent
scp -i ~/.ssh/id_rsa_iphone -P 2222 PhysicalAgent/PhysicalAgent root@127.0.0.1:/Applications/PhysicalAgent.app/PhysicalAgent
scp -i ~/.ssh/id_rsa_iphone -P 2222 PhysicalAgent/entitlements.xml root@127.0.0.1:/tmp/pa_entitlements.xml
ssh iphone "chmod +x /Applications/PhysicalAgent.app/PhysicalAgent && ldid -S/tmp/pa_entitlements.xml /Applications/PhysicalAgent.app/PhysicalAgent && rm -f /tmp/pa_entitlements.xml && uiopen physicalagent://"
```
