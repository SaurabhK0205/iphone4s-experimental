# PHYSICAL AGENT // DESK COMPANION — Agent Instructions & Operating Rules

See [CLAUDE.md](./CLAUDE.md) for the complete, canonical rules and conventions governing this repository, and [DESIGN.md](./DESIGN.md) for the visual and motion design system.

---

## 1. Engineering Reliability — GRAVITAS Workflow (MANDATORY)

Follow GRAVITAS invariants for all implementation, debugging, refactoring, toolchain updates, and hardware interaction:

1. **Ground before mutating**: Read target files, device status, and relevant headers/tests before editing. Never act on assumed file or device state.
2. **Stay in declared scope**: Work strictly within `/Users/thismac/projects/found_iphone4s/`. Never touch unrelated projects or global host paths.
3. **Completion needs evidence**: A task is done ONLY when verified via live command/execution output observed in this session (`VERDICT: PASS` / `VERDICT: FAIL`). Self-review and unverified assumptions do not count.
4. **Never exact-retry a failure**: If a build, flash, or command fails, diagnose the root cause, change context, strategy, or compiler flags before retrying. Byte-identical retries are blocked.
5. **Satisfy the contract**: All acceptance criteria must be explicitly demonstrated and verified.
6. **State unknowns honestly**: If something cannot be tested (e.g., physical touch when testing headlessly, or unmeasured latency), explicitly report it instead of fabricating certainty.

---

## 2. Design Engineering & Motion — Emil Kowalski Rules (MANDATORY)

Applied to both the iOS 6 Retina display UI (`PhysicalAgent.app`) and any host companion GUI/Web surfaces:

1. **The Decision Framework**:
   - 100+ times/day interactions (polling, background telemetry, CLI commands): Zero animation delay. Immediate execution.
   - Ambient state changes (expressions, status shifts, eye tracking): Smooth, purposeful transitions.
   - Easing: Always use `ease-out` (starts fast, feels responsive) on entering, and fast `ease-in` on exit.
2. **Tactile Feedback Requirement**:
   - Every physical and interactive control MUST provide tactile feedback:
     * On physical iPhone 4S screen tap: Immediate ERM haptic pulse (`AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)`) and acoustic click (`Tink.caf`).
     * On host controls: `:active` scale state (`scale(0.95)` to `scale(0.97)` over ~0.08s).
3. **Performance & GPU Acceleration**:
   - On iOS 6 (PowerVR SGX543MP2): Animate `CALayer` transform, bounds, and opacity only. Never thrash layouts.
   - Frame budget: 60 FPS locked (16.6ms per frame). Memory budget: Maintain >= 150MB free RAM at all times.
4. **Mandatory Review Format**:
   - When reviewing or proposing UI or motion changes, ALWAYS output a markdown table with `| Before | After | Why |` columns. Never use informal bullet lists.
5. **Reduced Motion**:
   - Respect user preference by disabling ambient eye saccades or rapid wobbling while preserving static expression framing.

---

## 3. Visual Craft & UI Quality — Impeccable 7-Pass Review (MANDATORY)

Whenever touching `PhysicalAgent` UI or companion frontend interfaces, run the Impeccable review passes before committing:

| Pass | Focus | Applied to PhysicalAgent |
|------|-------|--------------------------|
| **Critique** | Contrast, spacing, hierarchy | Contrast ratio >= 7:1 against obsidian `#030406` canvas. Clear visual hierarchy between eyes, HUD, and clock. |
| **Layout** | Grid density, focal point | 320x480pt Retina stage; focal point placed at optical center (Y: 175pt). Generous breathing room. |
| **Typeset** | Font hierarchy, tabular figures | Courier monospace for telemetry and clock (`font-variant-numeric: tabular-nums`). Helvetica Neue for brand labels. |
| **Animate** | Micro-interactions & transitions | Organic eye blinks (80ms close, 110ms open), directional eye saccades, spring morphing between emotions. |
| **Adapt** | Display ergonomics & angles | Optimized for 45° to 60° desk dock viewing angles. Legible from 2 to 3 feet away. Touch targets >= 44x44pt. |
| **Harden** | Disconnections & edge cases | Graceful fallback when USB/Wi-Fi drops. Zero crashing on malformed socket JSON. Screen stays awake (`idleTimerDisabled = YES`). |
| **Polish** | Final craft pass | Glow radius, shadow opacity, sub-pixel layer alignment, zero text clipping. |

---

## 4. Believable Product UI & Restraint — Benji Taylor Rules (MANDATORY)

1. **Restraint over Slop**: Real words only where the story is about. Budget of 3 to 7 real strings on screen. No filler slop, no stock AI tropes (no purple sparkles, no decorative fluff).
2. **Every Motion has a Cause**: The companion blinks because living eyes dry out; eyes glance left because an alert occurred on the left; pupils contract because bright light was detected. No random frantic animations.
3. **Believable Companion Identity**: Framed with intent. High-contrast cyber-cyan / obsidian palette with semantic accents (emerald for happy/ready, amber for surprise/caution, crimson for alert/error).

---

## 5. Branching, Pull Requests & AI Review Gates (MANDATORY & BLOCKING)

Adapted from the production standards of `reeler` (`instagram-saved-reels`):

1. **No Direct Pushes to Main**:
   - **NEVER push or commit directly to `main`**. Every single unit of work must live on a dedicated topic branch (`feat/*`, `fix/*`, `refactor/*`, `ui/*`, `hardware/*`, `chore/*`).
   - All integrations must merge via GitHub Pull Request targeting `main`.
2. **Multi-Model AI Code Review Gates (BLOCKING)**:
   Every opened or updated PR is automatically audited by four specialized AI reviewers:
   - **CodeRabbit AI**: Real-time architectural and diff analysis via `.coderabbit.yaml`.
   - **Qodo PR-Agent**: Automated code review powered by Gemini via `.github/workflows/pr-agent.yml` and `.pr_agent.toml`.
   - **Gemini Code Auditor**: Production quality, anti-AI-slop, and hardware constraint review via `.github/workflows/ai-code-review.yml`.
   - **NVIDIA Nemotron 3 Ultra 550B Auditor**: Deep architectural, concurrency, and security reasoning via `.github/workflows/ai-code-review.yml`.
3. **Addressing Review Findings**:
   - **NEVER merge while an automated review or re-check is running**.
   - Review every finding: for valid issues, fix and push to the topic branch; for false positives, provide documented technical reasoning.
   - All reviewer checks must be completed and passing before merge.
4. **Zero AI Slop Rule**:
   - Strictly ban em-dashes (`—`) in code, documentation, strings, or commit messages. Use colons (:), standard hyphens (-), or parentheses instead.
   - Ban sycophantic praise, robot apologies, conversational filler, and generic boilerplate.

---

## 6. Strict Repository & Runtime Invariants

1. **Python Virtual Environment**:
   - ALWAYS run Python scripts and tools using the dedicated project virtual environment at `.venv/bin/python3`.
   - NEVER install libraries into global system Python.
2. **Author Identity**:
   - Commits must always be authored by `saurabhk0205 <saurabhk0205@gmail.com>`.
3. **Secrets & Security**:
   - Never commit SSH keys, tokens, or credentials into git.
4. **Toolchain Integrity**:
   - ARMv7 Mach-O binaries targeting iOS 6.1.3 must strictly use `test_native/start.s` CRT entry and `tools/fix_macho_ios6.py` header conversion.
5. **No Tight Polling Loops**:
   - Never run tight busy-wait loops polling sockets, files, or processes. Use reactive timers or sleep intervals.
