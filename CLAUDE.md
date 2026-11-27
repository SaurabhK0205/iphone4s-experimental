# PhysicalAgent: iPhone 4S Desk Companion: CLAUDE.md

**Hardware Target**: Physical iPhone 4S (Apple A5, ARMv7, 512MB RAM, 3.5" Retina 960x640) running iOS 6.1.3 (Build 10B329).  
**Host Controller**: MacBook Air M5 (Apple Silicon) running macOS.  
**Transport**: Dual-mode (30-pin USB via `usbmuxd`/`iproxy` + Wireless 802.11n Wi-Fi at `192.168.0.158`).  
**Environment**: Dedicated Python Virtual Environment (`.venv/`).  
**Repository**: `SaurabhK0205/iphone4s-experimental` on GitHub.

---

## 1. Complete Tech Stack Overview

| Layer | Component | Technologies & Roles |
|---|---|---|
| **Device Hardware** | iPhone 4S (`N94AP`) | Apple A5 Dual-Core (ARMv7), PowerVR SGX543MP2 GPU, 512MB RAM, 3.5" Retina IPS (`960x640` @ 326 ppi), 8MP Rear + VGA Front Cameras, LED Flash, ERM Vibration Motor, Bottom Stereo Acoustic Chamber. |
| **Device OS** | iOS 6.1.3 (`10B329`) | Untethered jailbreak with activation records stitched, OTA software update daemons permanently blocked, root OpenSSH on port 22. |
| **Device Native App** | `PhysicalAgent.app` | Written in **Objective-C / C (ARMv7)** with `start.s` CRT entry. Uses **CoreAnimation** (`CALayer`), **UIKit** (60 FPS Retina rendering), **AVFoundation** (Front & Rear camera snapshot capture, LED torch), **AudioToolbox** (haptic motor, system sounds), and POSIX BSD socket server listening on `0.0.0.0:5000` with concurrent client dispatch. |
| **Toolchain** | Cross-Compiler Pipeline | Apple Clang (`-target armv7-apple-ios6.0`) with cleaned `iPhoneOS9.3.sdk`, Mach-O header patcher (`tools/fix_macho_ios6.py`) converting `LC_MAIN` (`0x80000028`) to `LC_UNIXTHREAD` (`0x5`), and `ldid -S` code signing. |
| **Transport Layer** | Dual-Mode Network | **USB**: 480 Mbps 30-pin cable forwarded via `usbmuxd` (`iproxy 5555 5000` and `iproxy 2222 22`).<br>**Wi-Fi**: 2.4 GHz 802.11b/g/n connection directly over subnet (`192.168.0.158:5000` socket + port 22 SSH) with automatic transparent failover in host SDK. |
| **Host Controller** | Python Companion SDK | Python 3.15 inside isolated project virtual environment ([`.venv/`](file:///Users/thismac/projects/found_iphone4s/.venv)). Provides `DeskCompanion` object-oriented API and interactive command shell (`desk_companion.py`). Automated launcher in `start_companion.sh`. |
| **CI / PR Reviewers** | Multi-Model Gatekeepers | **CodeRabbit AI**, **Qodo PR-Agent** (Gemini-powered), **Gemini Code Auditor** (`gemini-2.5-flash`), and **NVIDIA Nemotron 3 Ultra 550B Auditor** gating all pull requests. |

---

## 2. Branching & Pull Request Rules (MANDATORY)

1. **Protected Branches and Access Control**:
   - `main` and `staging` are protected branches governed by GitHub Rulesets.
   - Direct pushes to `main` and `staging` are strictly forbidden for everyone except the repository owner (`saurabhk0205`).
   - Every unit of work must live on a dedicated topic branch (`feat/*`, `fix/*`, `refactor/*`, `ui/*`, `hardware/*`, `chore/*`, `ci/*`).
2. **Staging-First Promotion Workflow**:
   - **Step 1 (Topic Branch)**: Branch off `staging` and implement changes.
   - **Step 2 (PR to Staging)**: Open a Pull Request targeting `staging` (never targeting `main` directly).
   - **Step 3 (AI Review Gates)**: Pass all 4 automated AI code reviews on the PR:
     1. **CodeRabbit AI** (`.coderabbit.yaml`)
     2. **Qodo PR-Agent** (`.github/workflows/pr-agent.yml`)
     3. **Gemini Code Auditor** (`scripts/gemini-pr-review.mjs`)
     4. **NVIDIA Nemotron 3 Ultra 550B Auditor** (`scripts/nemotron-pr-review.mjs`)
   - **Step 4 (Hardware Verification)**: Verify on physical iPhone 4S hardware over USB and Wi-Fi before merging to `staging`.
   - **Step 5 (Promotion to Main)**: Once verified healthy on `staging`, open a promotion PR from `staging` into `main`. The repository owner merges the promotion PR to update production `main`.
3. **Anti-AI-Slop Standard**:
   - Zero em-dashes. Use colons (:), standard hyphens (-), or parentheses instead.
   - Direct, human, concise phrasing. Zero sycophantic filler, apologies, or generic templates.

---

## 3. Pre-Session Rule & Environment Setup

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

## 4. Toolchain & Native ARMv7 Compilation Workflow

To rebuild and redeploy `PhysicalAgent.app` from Apple Silicon M5:

```bash
# 1. Compile native ARMv7 binary with custom CRT start stub
clang -target armv7-apple-ios6.0 \
  -isysroot sdks/iPhoneOS9.3.sdk \
  -marm -fno-objc-arc \
  -framework UIKit -framework Foundation -framework CoreGraphics \
  -framework QuartzCore -framework AVFoundation -framework AudioToolbox \
  -framework CoreMedia -framework CoreVideo -framework CoreMotion \
  -Wl,-e,_start \
  test_native/start.s PhysicalAgent/main.m \
  -o PhysicalAgent/PhysicalAgent_raw

# 2. Patch Mach-O header (LC_MAIN -> LC_UNIXTHREAD)
.venv/bin/python3 tools/fix_macho_ios6.py PhysicalAgent/PhysicalAgent_raw PhysicalAgent/PhysicalAgent

# 3. Deploy, sign with BackBoard entitlements, and launch on device
scp -i ~/.ssh/id_rsa_iphone -P 2222 PhysicalAgent/PhysicalAgent root@127.0.0.1:/Applications/PhysicalAgent.app/PhysicalAgent
scp -i ~/.ssh/id_rsa_iphone -P 2222 PhysicalAgent/entitlements.xml root@127.0.0.1:/tmp/pa_entitlements.xml
ssh iphone "chmod +x /Applications/PhysicalAgent.app/PhysicalAgent && ldid -S/tmp/pa_entitlements.xml /Applications/PhysicalAgent.app/PhysicalAgent && rm -f /tmp/pa_entitlements.xml && killall PhysicalAgent 2>/dev/null; sleep 1; uiopen physicalagent://"
```

---

## 5. BLOCK Violations (Strictly Prohibited)

1. **No Direct Pushes to Main**: All code must merge through reviewed PRs.
2. **No Em-Dashes**: Strictly ban em-dash characters across code, docs, and strings.
3. **No Global Python Packages**: Never run `pip install` without active `.venv`.
4. **No Web CRUD Wrappers**: The desk companion must remain a native ARMv7 C / Objective-C system application on iOS 6.
5. **No Unanchored Animations**: Never animate layout properties (`width`, `height`, `margin`, `padding`). Only animate `transform`, `opacity`, and `bounds` on `CALayer`.
6. **No Raw Hardcoded Colors in Views**: Use the semantic palette defined in `DESIGN.md`.
7. **No Tight Polling Loops**: Never sleep-loop on socket connections without backoff.
8. **No Secrets in Git**: Never commit `.ssh` keys or API credentials.
9. **Author Identity**: All commits must be authored by `saurabhk0205 <saurabhk0205@gmail.com>`.
