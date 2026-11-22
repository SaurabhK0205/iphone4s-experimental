# Design System: PhysicalAgent Obsidian Companion

<!-- impeccable:design-schema 1 -->

## 1. Design Philosophy

The PhysicalAgent UI transforms the 3.5" Retina display (`640x960` pixels @ 326 ppi, `320x480` points) into a living, tactile cybernetic desk companion. The canvas recedes into deep obsidian black (`#030406`), letting the high-density glowing vector eyes become the focal entity. The interface balances high-contrast legibility for 2-to-3-foot desk viewing with fine typographic details visible up close.

---

## 2. Color Palette

### Surfaces & Canvas
- **Deep Obsidian Canvas** (`--canvas`): `#030406` (pure non-reflective dark background, minimizing OLED/LCD bleed)
- **Subtle Surface Hairline** (`--hairline`): `rgba(255, 255, 255, 0.08)`
- **Hairline Strong** (`--hairline-strong`): `rgba(255, 255, 255, 0.16)`
- **Gaze Focus Glow** (`--glow-active`): `rgba(46, 212, 250, 0.45)`

### Semantic Eye & Entity Tints
- **Cyber Cyan (Neutral / Idle)**: `#2ed4fa` (`rgb(46, 212, 250)`) — Steady, alert, intelligent resting state.
- **Emerald Green (Happy / Confirmed)**: `#34d399` (`rgb(52, 211, 153)`) — Success, physical touch acknowledgment, positive affirmation.
- **Amber Gold (Surprised / Inquisitive)**: `#fbbf24` (`rgb(251, 191, 36)`) — Curiosity, attention, unexpected stimulus.
- **Deep Purple / Violet (Thinking / Processing)**: `#a855f7` (`rgb(168, 85, 247)`) — Deep neural inference, code analysis, complex reasoning.
- **Crimson Red (Alert / Warning)**: `#ef4444` (`rgb(239, 68, 68)`) — Error, hardware disconnect, build failure.
- **Dim Sapphire (Sleep / Low Power)**: `rgba(26, 102, 153, 0.60)` — Slit eyes, resting ambient state.

### HUD & Ink Typography
- **Primary Ink (Eyes & Active Badges)**: `#ffffff` (20:1+ contrast on obsidian canvas)
- **Status Emerald Ink**: `#34d399` (14:1 contrast on obsidian)
- **Telemetry Cyan Ink**: `#38bdf8` (12:1 contrast)
- **Clock Muted Ink**: `#94a3b8` (7.0:1 contrast — exceeds WCAG AA 4.5:1)
- **Brand Sub-Label Ink**: `#475569` (Subtle grounding watermark)

---

## 3. Typography & Numerical Rhythm

- **Monospace Telemetry Stack**: `"Courier", monospace` for all real-time clocks, timestamps, memory stats, and battery meters. All figures use tabular alignment (`font-variant-numeric: tabular-nums`) so numbers never jitter during updates.
- **Brand & Headings Stack**: `"HelveticaNeue-Medium", -apple-system, sans-serif` for clean Apple-native grounding labels.
- **Typographic Scale on 320x480pt Retina**:
  - `Clock`: `13pt` Courier, regular, letter-spacing `0.04em`, centered at `Y: 20pt`.
  - `Mini-HUD Telemetry`: `10pt` Courier, bold, opacity `0.75`, centered at `Y: 44pt`.
  - `Main Status Message`: `13pt` Courier-Bold, 2 lines max, line-height `1.3`, centered at `Y: 385pt`.
  - `Brand Watermark`: `10pt` HelveticaNeue-Medium, opacity `0.35`, centered at `Y: 445pt`.

---

## 4. Motion & Animation Choreography (Emil Kowalski Guidelines)

### The Eye Anatomy
- Default Resting Dimensions: `48pt × 70pt` (rounded pill, `cornerRadius: 24pt`).
- Inter-eye distance: `52pt` center-to-center offset from midline (`X: 160pt`).
- Glow radius: `16pt` shadow blur with `0.95` opacity matching the current semantic tint.

### Easing & Timing Matrix
| Action | Duration | Curve | Behavior |
|---|---|---|---|
| **Natural Blink** | `80ms` close, `100ms` open | `ease-in-out` | Height squashes from `70pt` to `4pt` around center anchor. |
| **Expression Morph** | `250ms` | `ease-out` (enter), `ease-in` (exit) | Frame, rotation, and color transition smoothly together. |
| **Eye Glance (Saccade)** | `180ms` | Fast `ease-out` | Quick horizontal translation (`±12pt`) mimicking human gaze shifts. |
| **Speaking Wobble** | `120ms` | Rhythmic bounce | Micro scale adjustment (`±4pt` height) reactive to audio syllables. |
| **Sleep Transition** | `600ms` | Smooth decelerate | Height compresses to `6pt`, glow fades, color shifts to dim sapphire. |

### Performance Rule
All animations execute via GPU-accelerated `CALayer` properties (`transform`, `opacity`, `bounds`, `backgroundColor`). Layout passes (`setNeedsLayout`) are strictly prohibited during animations.

---

## 5. Acoustic & Haptic Ergonomics

1. **Tactile Touch Response**:
   - Physical capacitive tap on screen: Immediate `<10ms` trigger of `AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)` + `Tink.caf` audio click.
   - Companion blinks instantly and shifts to `happy` expression for 2.5 seconds.
2. **Acoustic Soundscapes**:
   - Audio feedback is tuned to the iPhone 4S bottom acoustic chamber:
     * `jbl_confirm.caf`: Dual-tone ascending chime for completed commands / successful responses.
     * `jbl_begin.caf`: Listening / prompt received chime.
     * `photoShutter.caf`: Mechanical camera shutter click on snapshot capture.
     * `tweet_sent.caf`: Light whoosh on telemetry transmit.
     * `beep-beep.caf`: Attention / warning ping.

---

## 6. Physical Ergonomics & Viewing Angles

- **Desk Dock Angle**: Designed for `45°` to `60°` tilted charging stands or dock cradles.
- **Distance Legibility**: Expressions and large status lines are distinguishable from up to 4 feet away.
- **Touch Target Safeguards**: Screen touch detection covers the entire `320×480pt` viewport (effective `320×480px` touch area), ensuring effortless interaction without requiring precision taps.
