# Procedural Face Engine Specification

## 1. Overview & Inspiration

The PhysicalAgent Procedural Face Engine provides living, reactive eye animations for the iPhone 4S desk companion. The architecture is synthesized from production robotics research and open-source implementations:

1. **Anki Vector (`digital-dream-labs/vector-animations-build`, `os-vector/wire-os-victor`)**: Production 25-parameter eye model with independent 4-corner curvatures, eyelid bend/angle kinematics, and gaze hotspot tracking.
2. **Anki Cozmo (`zayfod/pycozmo`)**: Procedural face keyframe structures and Ekman universal emotional states based on Catherine Chambers' Bristol Robotics Laboratory research.
3. **`playfultechnology/esp32-eyes`**: Asymmetric emotion presets (e.g. skeptical one-eyebrow raise) and inverse curvature cutout math.
4. **`ggldnl/Procedural-Expression-Library`**: Normalized coordinate space, perspective foreshortening, and dynamic scale adaptation.

***

## 2. Mathematical Parameter Specification

Each eye is mathematically defined by 25 parameters, grouped into five functional categories:

```
+-------------------------------------------------------------------------+
|                        Procedural Eye Structure                         |
|                                                                         |
|         UpperOuterRadius (X, Y)             UpperInnerRadius (X, Y)     |
|                   +-------------------------------+                     |
|                   |   UpperLid (Y, Angle, Bend)   |                     |
|                   |                               |                     |
|                   |         +-----------+         |                     |
|                   |         |  HotSpot  |         |                     |
|                   |         |  (X, Y)   |         |                     |
|                   |         +-----------+         |                     |
|                   |                               |                     |
|                   |   LowerLid (Y, Angle, Bend)   |                     |
|                   +-------------------------------+                     |
|         LowerOuterRadius (X, Y)             LowerInnerRadius (X, Y)     |
+-------------------------------------------------------------------------+
```

### Parameter Index Table

| Index | Name | Range | Default | Description |
|---|---|---|---|---|
| 0 | `EyeCenterX` | `[-60.0, 60.0]` | `0.0` | Horizontal translation from default socket center (pt) |
| 1 | `EyeCenterY` | `[-60.0, 60.0]` | `0.0` | Vertical translation from default socket center (pt) |
| 2 | `EyeScaleX` | `[0.1, 2.5]` | `1.0` | Horizontal width scale factor |
| 3 | `EyeScaleY` | `[0.05, 2.5]` | `1.0` | Vertical height scale factor |
| 4 | `EyeAngle` | `[-45.0, 45.0]` | `0.0` | Slant/tilt rotation of the eye body (degrees) |
| 5 | `LowerInnerRadiusX` | `[0.0, 1.0]` | `0.35` | Normalized corner rounding radius (bottom inside) |
| 6 | `LowerInnerRadiusY` | `[0.0, 1.0]` | `0.35` | Normalized corner rounding radius (bottom inside) |
| 7 | `UpperInnerRadiusX` | `[0.0, 1.0]` | `0.35` | Normalized corner rounding radius (top inside) |
| 8 | `UpperInnerRadiusY` | `[0.0, 1.0]` | `0.35` | Normalized corner rounding radius (top inside) |
| 9 | `UpperOuterRadiusX` | `[0.0, 1.0]` | `0.35` | Normalized corner rounding radius (top outside) |
| 10 | `UpperOuterRadiusY` | `[0.0, 1.0]` | `0.35` | Normalized corner rounding radius (top outside) |
| 11 | `LowerOuterRadiusX` | `[0.0, 1.0]` | `0.35` | Normalized corner rounding radius (bottom outside) |
| 12 | `LowerOuterRadiusY` | `[0.0, 1.0]` | `0.35` | Normalized corner rounding radius (bottom outside) |
| 13 | `UpperLidY` | `[0.0, 1.0]` | `0.0` | Vertical intrusion of upper lid (0.0 = open, 1.0 = closed) |
| 14 | `UpperLidAngle` | `[-45.0, 45.0]` | `0.0` | Tilt angle of upper eyelid edge (degrees) |
| 15 | `UpperLidBend` | `[-1.0, 1.0]` | `0.0` | Curvature arch of upper eyelid (>0 arched up, <0 drooped) |
| 16 | `LowerLidY` | `[0.0, 1.0]` | `0.0` | Vertical intrusion of lower lid (0.0 = open, 1.0 = closed) |
| 17 | `LowerLidAngle` | `[-45.0, 45.0]` | `0.0` | Tilt angle of lower eyelid edge (degrees) |
| 18 | `LowerLidBend` | `[-1.0, 1.0]` | `0.0` | Curvature arch of lower eyelid (>0 curved down, <0 raised) |
| 19 | `Saturation` | `[-1.0, 1.0]` | `0.0` | Color saturation modifier (-1 = monochrome, +1 = vivid) |
| 20 | `Lightness` | `[-1.0, 1.0]` | `0.0` | Color brightness modifier |
| 21 | `GlowSize` | `[0.0, 2.0]` | `1.0` | Cornea light hotspot radius multiplier |
| 22 | `HotSpotCenterX` | `[-1.0, 1.0]` | `0.0` | Normalized horizontal gaze direction within iris |
| 23 | `HotSpotCenterY` | `[-1.0, 1.0]` | `0.0` | Normalized vertical gaze direction within iris |
| 24 | `GlowLightness` | `[0.0, 1.0]` | `0.85` | Specular glare intensity |

### Whole Face Global Parameters
* `faceAngle`: Rotation of the entire face stage in degrees (`[-30.0, 30.0]`).
* `faceCenterX`, `faceCenterY`: Optical center translation offsets (`[-40.0, 40.0]`).
* `faceScaleX`, `faceScaleY`: Whole-face squish/stretch for breathing and impact recoil.
* `scanlineOpacity`: CRT scanline grid contrast overlay (`[0.0, 0.40]`).

***

## 3. Bézier Geometry & Clipping Math

### 3.1 Base Eye Path Generation
The base eye contour is generated via an 8-point cubic Bézier path (`UIBezierPath`). Given bounding rectangle $(W, H)$ and corner radii $(r_{tl}, r_{tr}, r_{br}, r_{bl})$:

1. Top edge: Straight line from $(r_{tl}.x, 0)$ to $(W - r_{tr}.x, 0)$.
2. Top-right corner: Cubic Bézier curve with control points approximating an elliptical arc of radii $(r_{tr}.x, r_{tr}.y)$.
3. Right edge: Straight line to $(W, H - r_{br}.y)$.
4. Bottom-right corner: Cubic Bézier curve with radii $(r_{br}.x, r_{br}.y)$.
5. Bottom edge: Straight line to $(r_{bl}.x, H)$.
6. Bottom-left corner: Cubic Bézier curve with radii $(r_{bl}.x, r_{bl}.y)$.
7. Left edge: Straight line to $(0, r_{tl}.y)$.
8. Top-left corner: Cubic Bézier curve with radii $(r_{tl}.x, r_{tl}.y)$.

### 3.2 Eyelid Mask Kinematics
Instead of simple rectangular clipping, eyelids are rendered as curved vector masks:

* **Upper Eyelid Fold**:
  * Origin point $A = (-W/2, y_{lid\_top} - \tan(\theta_{lid}) \cdot W/2)$
  * Destination point $B = (W/2, y_{lid\_top} + \tan(\theta_{lid}) \cdot W/2)$
  * Midpoint control curve:
    $$C = \left(0, y_{lid\_top} - bend_{lid\_top} \cdot \frac{H}{3}\right)$$
  * The path closes upwards over the eye bounds to create the occluding mask.

* **Lower Eyelid Fold**:
  * Mirrors the upper eyelid with inverse vertical displacement, enabling smiling crescent eyes or skeptical squinting.

***

## 4. Emotional State Preset Library (Official Cozmo & Vector 21 Rig)

The engine defines 21 core emotional presets synthesized directly from official Anki Cozmo and Vector robotics rigs:

1. **`neutral`**: Balanced rounded squircle (`radii = 0.55`), relaxed eyelids (`lidY = 0.0`), radiant electric cyber-cyan glow (`#00E5FF`).
2. **`blink_high`**: Thin horizontal cyan slit high in socket (`UpperLidY = 0.22`, `LowerLidY = 0.72`).
3. **`happy`**: Arched dome (`⌒ ⌒`): lower eyelid cuts upward with concave bend (`LowerLidY = 0.52`, `LowerLidBend = 0.50`), upper corners rounded (`radii = 0.85`).
4. **`glee`**: Deep squeezed joy crescent (`LowerLidY = 0.65`, `UpperLidY = 0.12`, `radii = 0.90`).
5. **`blink_low`**: Thin horizontal cyan slit low in socket (`UpperLidY = 0.72`, `LowerLidY = 0.22`).
6. **`sad_down`**: Drooping eyelids (`/ \`) with gaze shifted downward (`UpperLidY = 0.38`, `UpperLidAngle = -15.0`, `centerY = 14.0`).
7. **`sad_up`**: Drooping eyelids (`/ \`) with gaze shifted upward pleadingly (`UpperLidY = 0.38`, `UpperLidAngle = -15.0`, `centerY = -12.0`).
8. **`worried`**: Upper lids slanted (`/ \`) with inner corners high and outer corners drooped (`UpperLidY = 0.28`, `UpperLidAngle = -14.0`, amber accent).
9. **`focused`**: Sharp horizontal squircle bars with flat eyelids (`UpperLidY = 0.36`, `LowerLidY = 0.36`, `bend = 0.0`).
10. **`annoyed`**: Upper eyelids drooped flat halfway down (`UpperLidY = 0.50`, crimson-amber accent).
11. **`surprised`**: Tall rounded open squircles (`scaleX = 0.95`, `scaleY = 1.25`, `GlowSize = 1.35`, `radii = 0.85`).
12. **`skeptic`**: Asymmetrical: left eye wide open; right eye narrowed with furrowed brow (`UpperLidY = 0.45`, `UpperLidAngle = -12.0`, `LowerLidY = 0.20`).
13. **`frustrated`**: Half-closed flat eyelids (`UpperLidY = 0.45`, `LowerLidY = 0.20`, crimson-amber accent).
14. **`unimpressed`**: Flat drooped deadpan upper lids (`UpperLidY = 0.55`, `scaleY = 0.85`).
15. **`sleepy`**: Upper eyelids drooped with outward slant (`UpperLidY = 0.65`, `UpperLidAngle = -8.0`, slate-blue accent).
16. **`suspicious`**: Narrow horizontal squint with slight inward slant (`UpperLidY = 0.48`, `UpperLidAngle = 8.0`, `LowerLidY = 0.25`).
17. **`squint`**: Tight horizontal slits centered at optical baseline (`UpperLidY = 0.46`, `LowerLidY = 0.46`).
18. **`angry`**: Aggressive V-brow (`\ /`): grounded flat baseline with steep inward-slanted upper brow (`UpperLidY = 0.28`, `UpperLidAngle = 22.0`, signature electric cyber cyan `#00E5FF`).
19. **`furious`**: Deeper angry V-brow (`\ /`): grounded flat baseline with extreme inward-slanted brow (`UpperLidY = 0.38`, `UpperLidAngle = 28.0`, signature electric cyber cyan).
20. **`scared`**: Wide tall eyes with bottom eyelid cut flat across (`scaleY = 1.15`, `LowerLidY = 0.36`, `LowerLidBend = 0.0`).
21. **`awe`**: Giant rounded glowing eyes with maximized luminous core (`scaleX = 1.15`, `scaleY = 1.20`, `GlowSize = 1.50`, `radii = 0.85`).

Additional expressive state aliases:
* `curious`: Tilted asymmetric inquiry with directional gaze offset.
* `thinking`: Eyes shifted upward and inward with subtle brow tilt, amethyst accent.
* `alert`: Contracted gaze hotspot, angular upper lids, crimson accent.
* `asleep`: Eyelids fully closed, rendering as a calm resting slit.
* `glance_left`, `glance_right`: Directed horizontal gaze shifts.

***

## 5. Visual Craft & Pure Obsidian Black Canvas

1. **Bezel Blending Architecture**:
   * The screen canvas is strictly pure pitch black (`#000000`).
   * Zero radial gradient, zero blue vignette, zero light bleed.
   * On the physical iPhone 4S Retina display, the pitch-black pixels blend seamlessly into the front glass bezel, transforming the entire phone into a unified robot head/visor.
2. **Retro CRT & OLED Illumination**:
   * Pure Black Boundaries: Canvas maintains pure RGB(0,0,0) black pixels outside the eye squircle, with outer layer shadows disabled to eliminate backlight bloom and merge invisibly into the glossy front glass bezel.
   * Luminous White-Hot Core: A high-brightness white hotspot (`#FFFFFF` to `#C8FFFF`) radiates inside each cyan eye and smoothly tracks gaze coordinates (`HotSpotCenterX`, `HotSpotCenterY`).
   * CRT Raster Scanlines: A subtle horizontal raster scanline overlay (1pt line every 3pt, 16% opacity) reproduces the analog phosphor monitor texture of 1980s-90s electronics.
3. **Pure Face Mode (Zero HUD Clutter)**:
   * Status bar pills, thought cards, and audio waveforms are hidden by default (`alpha = 0.0`).
   * Double-tapping the physical screen smoothly toggles Zen mode (`toggleZenMode`) to inspect telemetry if needed.

***

## 6. Emil Kowalski Motion Principles & Timing

1. **Ambient State Changes**:
   * Transitions between emotional presets use spring interpolation over **260ms to 320ms**.
   * Timing curve: Custom ease-out on enter (starts fast, feels alive), fast ease-in on exit.
2. **Tactile Interaction**:
   * On screen touch: Immediate 80ms tactile squash (`scale(0.93)`) with simultaneous ERM vibration pulse and Tink click.
   * Zero animation delay for socket commands and telemetry polling.
3. **Organic Blinks**:
   * Fast close: 70ms ease-out via eyelid path closure.
   * Organic rebound open: 110ms ease-in with slight 2% overshoot.
4. **Cause-Based Gaze**:
   * Saccades always move the gaze hotspot first (100ms), followed by subtle corneal follow-through (secondary action).
5. **Reduced Motion**:
   * When enabled via settings, ambient eye saccades and breathing cycles are suppressed, while preserving static parametric expression shapes.
