# Procedural Face Engine Specification

## 1. Overview & Inspiration

The PhysicalAgent Procedural Face Engine provides living, reactive eye animations for the iPhone 4S desk companion. The architecture is synthesized from production robotics research and open-source implementations:

1. **Anki Vector (`digital-dream-labs/vector-animations-build`, `os-vector/wire-os-victor`)**: Production 25-parameter eye model with independent 4-corner curvatures, eyelid bend/angle kinematics, and gaze hotspot tracking.
2. **Anki Cozmo (`zayfod/pycozmo`)**: Procedural face keyframe structures and Ekman universal emotional states based on Catherine Chambers' Bristol Robotics Laboratory research.
3. **`playfultechnology/esp32-eyes`**: Asymmetric emotion presets (e.g. skeptical one-eyebrow raise) and inverse curvature cutout math.
4. **`ggldnl/Procedural-Expression-Library`**: Normalized coordinate space, perspective foreshortening, and dynamic scale adaptation.

---

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
- `faceAngle`: Rotation of the entire face stage in degrees (`[-30.0, 30.0]`).
- `faceCenterX`, `faceCenterY`: Optical center translation offsets (`[-40.0, 40.0]`).
- `faceScaleX`, `faceScaleY`: Whole-face squish/stretch for breathing and impact recoil.
- `scanlineOpacity`: CRT scanline grid contrast overlay (`[0.0, 0.40]`).

---

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

- **Upper Eyelid Fold**:
  * Origin point $A = (-W/2, y_{lid\_top} - \tan(\theta_{lid}) \cdot W/2)$
  * Destination point $B = (W/2, y_{lid\_top} + \tan(\theta_{lid}) \cdot W/2)$
  * Midpoint control curve:
    $$C = \left(0, y_{lid\_top} - bend_{lid\_top} \cdot \frac{H}{3}\right)$$
  * The path closes upwards over the eye bounds to create the occluding mask.

- **Lower Eyelid Fold**:
  * Mirrors the upper eyelid with inverse vertical displacement, enabling smiling crescent eyes or skeptical squinting.

---

## 4. Emotional State Preset Library

The engine defines 12 core emotional presets synthesized from Cozmo, Vector, and Chambers' research:

1. **`neutral`**: Balanced rounded squircle (`radii = 0.35`), relaxed eyelids (`lidY = 0.0`), subtle atmospheric cyber-cyan glow (`#38BFFC`).
2. **`happy`**: Raised lower eyelids (`LowerLidY = 0.55`, `LowerLidBend = 0.60`), slightly tilted corners, vibrant emerald tint (`#33EBA8`).
3. **`glee`**: Deep crescent eyes (`LowerLidY = 0.80`, `UpperLidY = 0.20`), compressed scale (`scaleY = 0.45`), emerald accent.
4. **`curious`**: One eye scaled 1.15x and tilted outward 4 degrees, gaze hotspot shifted diagonally toward point of interest.
5. **`skeptic`**: Asymmetrical expression. Left eye neutral; right eye narrowed (`UpperLidY = 0.45`, `UpperLidAngle = -12.0`, `UpperLidBend = -0.30`).
6. **`surprised`**: Expanded scale (`scaleX = 1.15`, `scaleY = 1.30`), dilated pupil hotspot (`GlowSize = 1.40`), warm amber glow (`#FBBF2E`).
7. **`thinking`**: Both eyes shifted upward and inward (`HotSpotCenterY = -0.70`), slight asymmetrical squint, amethyst accent (`#B066FF`).
8. **`focused`**: Horizontal narrowing (`scaleY = 0.65`), lowered upper lids (`UpperLidY = 0.35`, `UpperLidAngle = 8.0`), sharp cyan glow.
9. **`annoyed`**: Upper eyelids flattened downward (`UpperLidY = 0.50`, `UpperLidBend = -0.40`), crimson-amber accent (`#FA8C16`).
10. **`alert`**: Contracted pupil hotspot (`GlowSize = 0.60`), steep angular upper lids (`UpperLidAngle = 18.0`), crimson glow (`#FA5252`).
11. **`sleepy`**: Upper eyelids drooped to 70% closure (`UpperLidY = 0.70`), dim slate blue glow (`#385B7A`).
12. **`asleep`**: Eyelids fully closed (`UpperLidY = 0.95`), rendering as a calm 2pt horizontal resting slit at optical baseline.

---

## 5. Emil Kowalski Motion Principles & Timing

1. **Ambient State Changes**:
   - Transitions between emotional presets use spring interpolation over **260ms to 320ms**.
   - Timing curve: Custom ease-out on enter (starts fast, feels alive), fast ease-in on exit.
2. **Tactile Interaction**:
   - On screen touch: Immediate 80ms tactile squash (`scale(0.93)`) with simultaneous ERM vibration pulse and Tink click.
   - Zero animation delay for socket commands and telemetry polling.
3. **Organic Blinks**:
   - Fast close: 70ms ease-out via eyelid path closure.
   - Organic rebound open: 110ms ease-in with slight 2% overshoot.
4. **Cause-Based Gaze**:
   - Saccades always move the gaze hotspot first (100ms), followed by subtle corneal follow-through (secondary action).
5. **Reduced Motion**:
   - When enabled via settings, ambient eye saccades and breathing cycles are suppressed, while preserving static parametric expression shapes.
