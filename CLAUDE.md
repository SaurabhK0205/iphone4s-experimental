# PhysicalAgent: iPhone 4S Desk Companion — CLAUDE.md

**Hardware**: Physical iPhone 4S (Apple A5, ARMv7, 512MB RAM, 3.5" Retina 960x640) running iOS 6.1.3 (Build 10B329).  
**Host**: MacBook Air M5 (Apple Silicon) running macOS.  
**Transport**: Dual-mode (30-pin USB via `usbmuxd`/`iproxy` + Wireless 802.11n Wi-Fi at `192.168.0.158`).  
**Environment**: Dedicated Python Virtual Environment (`.venv/`).

---

## 1. Architecture

```
                  ┌────────────────────────────────────────┐
                  │          MacBook Air M5 (Host)         │
                  │                                        │
                  │   .venv/bin/python3 desk_companion.py  │
                  │        (Interactive CLI & API)         │
                  └───────────────┬────────────────────────┘
                                  │
          ┌───────────────────────┴───────────────────────┐
          │                                               │
   [USB Mode: 480 Mbps]                           [Wi-Fi Mode: 2.4 GHz]
   usbmuxd (port 5555->5000)                      192.168.0.158:5000
   SSH (port 2222->22)                            192.168.0.158:22
          │                                               │
          └───────────────────────┬───────────────────────┘
                                  │
                  ┌───────────────▼────────────────────────┐
                  │       Physical iPhone 4S (iOS 6.1.3)   │
                  │                                        │
                  │    /Applications/PhysicalAgent.app     │
                  │    • CoreAnimation 60 FPS Retina eyes  │
                  │    • AVFoundation (Front & Rear Cam)   │
                  │    • AudioToolbox (Haptics & Chimes)   │
                  │    • Capacitive Multi-touch Digitizer  │
                  │    • BSD TCP Socket Server (Port 5000) │
                  └────────────────────────────────────────┘
```

---

## 2. Pre-Session Rule & Environment Setup

1. **Virtual Environment**:
   Always activate or use the virtual environment:
   ```bash
   source .venv/bin/activate
   # Or directly:
   .venv/bin/python3 desk_companion.py
   ```
   **NEVER** run `pip install` globally or run scripts using system Python.

2. **Starting the Companion**:
   ```bash
   ./start_companion.sh
   ```

---

## 3. Toolchain & Compilation Workflow

To rebuild and redeploy `PhysicalAgent.app` from Apple Silicon M5:

```bash
# 1. Compile native ARMv7 binary with custom CRT start stub
clang -target armv7-apple-ios6.0 \
  -isysroot sdks/iPhoneOS9.3.sdk \
  -marm -fno-objc-arc \
  -framework UIKit -framework Foundation -framework CoreGraphics \
  -framework QuartzCore -framework AVFoundation -framework AudioToolbox \
  -framework CoreMedia -framework CoreVideo \
  -Wl,-e,_start \
  test_native/start.s PhysicalAgent/main.m \
  -o PhysicalAgent/PhysicalAgent_raw

# 2. Patch Mach-O header (LC_MAIN -> LC_UNIXTHREAD)
python3 tools/fix_macho_ios6.py PhysicalAgent/PhysicalAgent_raw PhysicalAgent/PhysicalAgent

# 3. Deploy, sign, and launch on device
scp -i ~/.ssh/id_rsa_iphone -P 2222 PhysicalAgent/PhysicalAgent root@127.0.0.1:/Applications/PhysicalAgent.app/PhysicalAgent
ssh iphone "chmod +x /Applications/PhysicalAgent.app/PhysicalAgent && ldid -S /Applications/PhysicalAgent.app/PhysicalAgent && killall PhysicalAgent 2>/dev/null; sleep 1; uiopen physicalagent://"
```

---

## 4. BLOCK Violations (Strictly Prohibited)

1. **No Global Python Packages**: Never run `pip install` without active `.venv`.
2. **No Web CRUD Wrappers**: The desk companion must remain a native ARMv7 C / Objective-C system application on iOS 6.
3. **No Unanchored Animations**: Never animate layout properties (`width`, `height`, `margin`, `padding`). Only animate `transform`, `opacity`, and `bounds` on `CALayer`.
4. **No Raw Hardcoded Colors in Views**: Use the semantic palette defined in `DESIGN.md` (`#030406` canvas, `#2ed4fa` cyan, `#34d399` emerald, `#fbbf24` amber, `#a855f7` purple, `#ef4444` crimson).
5. **No Stock AI Tropes**: No purple sparkles, floating cards, or artificial animations with no physical trigger.
6. **No Tight Polling Loops**: Never sleep-loop on socket connections without backoff or event waiting.
7. **No Secrets in Git**: Never commit `.ssh` keys or credentials.
8. **Author Identity**: All commits must be authored by `saurabhk0205 <saurabhk0205@gmail.com>`.
