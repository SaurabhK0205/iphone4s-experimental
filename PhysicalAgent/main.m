#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <signal.h>
#include <libkern/OSAtomic.h>

// ========================================================
// 1. ATMOSPHERIC CANVAS DEPTH (Radial Gradient Background)
// ========================================================
@interface RadialGradientBackgroundView : UIView {
    CGGradientRef _gradient;
    CGColorSpaceRef _colorSpace;
}
@end

@implementation RadialGradientBackgroundView

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _colorSpace = CGColorSpaceCreateDeviceRGB();
        if (_colorSpace) {
            CGFloat components[8] = {
                0.032f, 0.047f, 0.086f, 1.0f, // Optical center core
                0.004f, 0.007f, 0.016f, 1.0f  // Obsidian canvas perimeter
            };
            CGFloat locations[2] = { 0.0f, 1.0f };
            _gradient = CGGradientCreateWithColorComponents(_colorSpace, components, locations, 2);
        }
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    if (!_gradient) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGPoint focalCenter = CGPointMake(self.bounds.size.width / 2.0f, 175.0f);
    CGFloat endRadius = 320.0f;
    CGContextDrawRadialGradient(ctx, _gradient, focalCenter, 0.0f, focalCenter, endRadius, kCGGradientDrawsAfterEndLocation);
}

- (void)dealloc {
    if (_gradient) {
        CGGradientRelease(_gradient);
        _gradient = NULL;
    }
    if (_colorSpace) {
        CGColorSpaceRelease(_colorSpace);
        _colorSpace = NULL;
    }
    [super dealloc];
}
@end

// ========================================================
// 2. PROCEDURAL EYE CONFIGURATION & MATHEMATICAL UTILITIES
// ========================================================
typedef struct {
    CGFloat centerX;
    CGFloat centerY;
    CGFloat scaleX;
    CGFloat scaleY;
    CGFloat angle;
    CGFloat lowerInnerRadiusX;
    CGFloat lowerInnerRadiusY;
    CGFloat upperInnerRadiusX;
    CGFloat upperInnerRadiusY;
    CGFloat upperOuterRadiusX;
    CGFloat upperOuterRadiusY;
    CGFloat lowerOuterRadiusX;
    CGFloat lowerOuterRadiusY;
    CGFloat upperLidY;
    CGFloat upperLidAngle;
    CGFloat upperLidBend;
    CGFloat lowerLidY;
    CGFloat lowerLidAngle;
    CGFloat lowerLidBend;
    CGFloat saturation;
    CGFloat lightness;
    CGFloat glowSize;
    CGFloat hotSpotCenterX;
    CGFloat hotSpotCenterY;
    CGFloat glowLightness;
} ProceduralEyeConfig;

static inline CGFloat ClampF(CGFloat v, CGFloat minV, CGFloat maxV) {
    if (v < minV) return minV;
    if (v > maxV) return maxV;
    return v;
}

static inline CGFloat LerpF(CGFloat a, CGFloat b, CGFloat t) {
    return a + (b - a) * t;
}

static inline ProceduralEyeConfig ProceduralEyeConfigDefault(void) {
    ProceduralEyeConfig c;
    c.centerX = 0.0f;
    c.centerY = 0.0f;
    c.scaleX = 1.0f;
    c.scaleY = 1.0f;
    c.angle = 0.0f;
    c.lowerInnerRadiusX = 0.35f;
    c.lowerInnerRadiusY = 0.35f;
    c.upperInnerRadiusX = 0.35f;
    c.upperInnerRadiusY = 0.35f;
    c.upperOuterRadiusX = 0.35f;
    c.upperOuterRadiusY = 0.35f;
    c.lowerOuterRadiusX = 0.35f;
    c.lowerOuterRadiusY = 0.35f;
    c.upperLidY = 0.0f;
    c.upperLidAngle = 0.0f;
    c.upperLidBend = 0.0f;
    c.lowerLidY = 0.0f;
    c.lowerLidAngle = 0.0f;
    c.lowerLidBend = 0.0f;
    c.saturation = 0.0f;
    c.lightness = 0.0f;
    c.glowSize = 1.0f;
    c.hotSpotCenterX = 0.0f;
    c.hotSpotCenterY = 0.0f;
    c.glowLightness = 0.85f;
    return c;
}

static inline ProceduralEyeConfig ProceduralEyeConfigLerp(ProceduralEyeConfig a, ProceduralEyeConfig b, CGFloat t) {
    ProceduralEyeConfig c;
    c.centerX = LerpF(a.centerX, b.centerX, t);
    c.centerY = LerpF(a.centerY, b.centerY, t);
    c.scaleX = LerpF(a.scaleX, b.scaleX, t);
    c.scaleY = LerpF(a.scaleY, b.scaleY, t);
    c.angle = LerpF(a.angle, b.angle, t);
    c.lowerInnerRadiusX = LerpF(a.lowerInnerRadiusX, b.lowerInnerRadiusX, t);
    c.lowerInnerRadiusY = LerpF(a.lowerInnerRadiusY, b.lowerInnerRadiusY, t);
    c.upperInnerRadiusX = LerpF(a.upperInnerRadiusX, b.upperInnerRadiusX, t);
    c.upperInnerRadiusY = LerpF(a.upperInnerRadiusY, b.upperInnerRadiusY, t);
    c.upperOuterRadiusX = LerpF(a.upperOuterRadiusX, b.upperOuterRadiusX, t);
    c.upperOuterRadiusY = LerpF(a.upperOuterRadiusY, b.upperOuterRadiusY, t);
    c.lowerOuterRadiusX = LerpF(a.lowerOuterRadiusX, b.lowerOuterRadiusX, t);
    c.lowerOuterRadiusY = LerpF(a.lowerOuterRadiusY, b.lowerOuterRadiusY, t);
    c.upperLidY = LerpF(a.upperLidY, b.upperLidY, t);
    c.upperLidAngle = LerpF(a.upperLidAngle, b.upperLidAngle, t);
    c.upperLidBend = LerpF(a.upperLidBend, b.upperLidBend, t);
    c.lowerLidY = LerpF(a.lowerLidY, b.lowerLidY, t);
    c.lowerLidAngle = LerpF(a.lowerLidAngle, b.lowerLidAngle, t);
    c.lowerLidBend = LerpF(a.lowerLidBend, b.lowerLidBend, t);
    c.saturation = LerpF(a.saturation, b.saturation, t);
    c.lightness = LerpF(a.lightness, b.lightness, t);
    c.glowSize = LerpF(a.glowSize, b.glowSize, t);
    c.hotSpotCenterX = LerpF(a.hotSpotCenterX, b.hotSpotCenterX, t);
    c.hotSpotCenterY = LerpF(a.hotSpotCenterY, b.hotSpotCenterY, t);
    c.glowLightness = LerpF(a.glowLightness, b.glowLightness, t);
    return c;
}

static ProceduralEyeConfig ProceduralEyeConfigFromArray(NSArray *arr, ProceduralEyeConfig fallback) {
    if (!arr || ![arr isKindOfClass:[NSArray class]] || [arr count] < 25) {
        return fallback;
    }
    ProceduralEyeConfig c;
    c.centerX = [[arr objectAtIndex:0] floatValue];
    c.centerY = [[arr objectAtIndex:1] floatValue];
    c.scaleX = [[arr objectAtIndex:2] floatValue];
    c.scaleY = [[arr objectAtIndex:3] floatValue];
    c.angle = [[arr objectAtIndex:4] floatValue];
    c.lowerInnerRadiusX = [[arr objectAtIndex:5] floatValue];
    c.lowerInnerRadiusY = [[arr objectAtIndex:6] floatValue];
    c.upperInnerRadiusX = [[arr objectAtIndex:7] floatValue];
    c.upperInnerRadiusY = [[arr objectAtIndex:8] floatValue];
    c.upperOuterRadiusX = [[arr objectAtIndex:9] floatValue];
    c.upperOuterRadiusY = [[arr objectAtIndex:10] floatValue];
    c.lowerOuterRadiusX = [[arr objectAtIndex:11] floatValue];
    c.lowerOuterRadiusY = [[arr objectAtIndex:12] floatValue];
    c.upperLidY = [[arr objectAtIndex:13] floatValue];
    c.upperLidAngle = [[arr objectAtIndex:14] floatValue];
    c.upperLidBend = [[arr objectAtIndex:15] floatValue];
    c.lowerLidY = [[arr objectAtIndex:16] floatValue];
    c.lowerLidAngle = [[arr objectAtIndex:17] floatValue];
    c.lowerLidBend = [[arr objectAtIndex:18] floatValue];
    c.saturation = [[arr objectAtIndex:19] floatValue];
    c.lightness = [[arr objectAtIndex:20] floatValue];
    c.glowSize = [[arr objectAtIndex:21] floatValue];
    c.hotSpotCenterX = [[arr objectAtIndex:22] floatValue];
    c.hotSpotCenterY = [[arr objectAtIndex:23] floatValue];
    c.glowLightness = [[arr objectAtIndex:24] floatValue];
    return c;
}

static NSArray *ProceduralEyeConfigToArray(ProceduralEyeConfig c) {
    return @[
        @(c.centerX), @(c.centerY), @(c.scaleX), @(c.scaleY), @(c.angle),
        @(c.lowerInnerRadiusX), @(c.lowerInnerRadiusY), @(c.upperInnerRadiusX), @(c.upperInnerRadiusY),
        @(c.upperOuterRadiusX), @(c.upperOuterRadiusY), @(c.lowerOuterRadiusX), @(c.lowerOuterRadiusY),
        @(c.upperLidY), @(c.upperLidAngle), @(c.upperLidBend),
        @(c.lowerLidY), @(c.lowerLidAngle), @(c.lowerLidBend),
        @(c.saturation), @(c.lightness), @(c.glowSize),
        @(c.hotSpotCenterX), @(c.hotSpotCenterY), @(c.glowLightness)
    ];
}

// ========================================================
// 3. RETRO CRT SCANLINE OVERLAY
// ========================================================
@interface ScanlineOverlayView : UIView {
    CGFloat _scanlineOpacity;
}
@property (nonatomic, assign) CGFloat scanlineOpacity;
@end

@implementation ScanlineOverlayView
@synthesize scanlineOpacity = _scanlineOpacity;

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        _scanlineOpacity = 0.12f;
    }
    return self;
}

- (void)setScanlineOpacity:(CGFloat)opacity {
    _scanlineOpacity = opacity;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    if (_scanlineOpacity <= 0.001f) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGContextSetRGBFillColor(ctx, 0.0f, 0.0f, 0.0f, _scanlineOpacity);
    for (CGFloat y = 0.0f; y < rect.size.height; y += 3.0f) {
        CGContextFillRect(ctx, CGRectMake(0.0f, y, rect.size.width, 1.0f));
    }
}
@end

// ========================================================
// 4. PROCEDURAL EYE VIEW (Vector & Cozmo Geometry Engine)
// ========================================================
@interface ProceduralEyeView : UIView {
    BOOL _isLeftEye;
    CGPoint _defaultCenter;
    ProceduralEyeConfig _config;

    UIView *_eyeContentContainer;
    CAShapeLayer *_eyeBodyShapeLayer;
    CAGradientLayer *_irisGradientLayer;
    CAShapeLayer *_eyelidMaskLayer;

    UIView *_pupilCore;
    UIView *_specularPrimary;
    UIView *_specularSecondary;
}
@property (nonatomic, assign) ProceduralEyeConfig config;
@property (nonatomic, assign) CGPoint defaultCenter;

- (id)initWithFrame:(CGRect)frame isLeft:(BOOL)isLeft;
- (void)applyConfig:(ProceduralEyeConfig)config;
- (void)setGradientColors:(NSArray *)colors;
- (void)setGlowColor:(UIColor *)color;
@end

@implementation ProceduralEyeView
@synthesize config = _config;
@synthesize defaultCenter = _defaultCenter;

- (id)initWithFrame:(CGRect)frame isLeft:(BOOL)isLeft {
    self = [super initWithFrame:frame];
    if (self) {
        _isLeftEye = isLeft;
        _defaultCenter = CGPointMake(frame.origin.x + frame.size.width / 2.0f, frame.origin.y + frame.size.height / 2.0f);
        self.backgroundColor = [UIColor clearColor];

        // Container clipped by eyelids
        _eyeContentContainer = [[UIView alloc] initWithFrame:self.bounds];
        _eyeContentContainer.backgroundColor = [UIColor clearColor];
        _eyeContentContainer.clipsToBounds = YES;
        [self addSubview:_eyeContentContainer];

        // Eye Body Squircle Mask
        _eyeBodyShapeLayer = [[CAShapeLayer alloc] init];
        _eyeBodyShapeLayer.frame = self.bounds;
        _eyeBodyShapeLayer.fillColor = [UIColor whiteColor].CGColor;

        // Iris Gradient Layer
        _irisGradientLayer = [[CAGradientLayer alloc] init];
        _irisGradientLayer.frame = self.bounds;
        _irisGradientLayer.colors = @[
            (id)[UIColor colorWithRed:0.22 green:0.75 blue:0.98 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.01 green:0.48 blue:0.80 alpha:1.0].CGColor
        ];
        _irisGradientLayer.mask = _eyeBodyShapeLayer;
        [_eyeContentContainer.layer insertSublayer:_irisGradientLayer atIndex:0];

        // Pupil Core
        _pupilCore = [[UIView alloc] initWithFrame:CGRectMake((frame.size.width - 22.0f)/2.0f, (frame.size.height - 34.0f)/2.0f, 22.0f, 34.0f)];
        _pupilCore.backgroundColor = [UIColor colorWithRed:0.015 green:0.025 blue:0.045 alpha:0.95];
        _pupilCore.layer.cornerRadius = 11.0f;
        [_eyeContentContainer addSubview:_pupilCore];

        // Specular Catchlights
        _specularPrimary = [[UIView alloc] initWithFrame:CGRectMake(frame.size.width - 17.0f, 11.0f, 9.0f, 7.0f)];
        _specularPrimary.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.85];
        _specularPrimary.layer.cornerRadius = 3.5f;
        [_eyeContentContainer addSubview:_specularPrimary];

        _specularSecondary = [[UIView alloc] initWithFrame:CGRectMake(11.0f, frame.size.height - 19.0f, 4.0f, 4.0f)];
        _specularSecondary.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.40];
        _specularSecondary.layer.cornerRadius = 2.0f;
        [_eyeContentContainer addSubview:_specularSecondary];

        // Eyelid Mask Layer applied to _eyeContentContainer so all interior elements are clipped
        _eyelidMaskLayer = [[CAShapeLayer alloc] init];
        _eyelidMaskLayer.frame = CGRectMake(-15.0f, -15.0f, frame.size.width + 30.0f, frame.size.height + 30.0f);
        _eyelidMaskLayer.fillColor = [UIColor blackColor].CGColor;
        _eyeContentContainer.layer.mask = _eyelidMaskLayer;

        // Outer Glow on self
        self.layer.shadowColor = [UIColor colorWithRed:0.22 green:0.75 blue:0.98 alpha:1.0].CGColor;
        self.layer.shadowOffset = CGSizeZero;
        self.layer.shadowRadius = 14.0f;
        self.layer.shadowOpacity = 0.85f;

        _config = ProceduralEyeConfigDefault();
        [self applyConfig:_config];
    }
    return self;
}

- (void)setGradientColors:(NSArray *)colors {
    if (colors && _irisGradientLayer) {
        _irisGradientLayer.colors = colors;
    }
}

- (void)setGlowColor:(UIColor *)color {
    if (color) {
        self.layer.shadowColor = color.CGColor;
    }
}

- (void)applyConfig:(ProceduralEyeConfig)config {
    _config = config;

    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;
    if (W <= 0.0f || H <= 0.0f) return;

    // Corner radius assignment based on eye orientation:
    // Left eye: Top-Left is Outer, Top-Right is Inner, Bottom-Right is Inner, Bottom-Left is Outer
    // Right eye: Top-Left is Inner, Top-Right is Outer, Bottom-Right is Outer, Bottom-Left is Inner
    CGFloat rTL_x, rTL_y, rTR_x, rTR_y, rBR_x, rBR_y, rBL_x, rBL_y;
    if (_isLeftEye) {
        rTL_x = ClampF(config.upperOuterRadiusX, 0.02f, 1.0f) * (W * 0.5f);
        rTL_y = ClampF(config.upperOuterRadiusY, 0.02f, 1.0f) * (H * 0.5f);
        rTR_x = ClampF(config.upperInnerRadiusX, 0.02f, 1.0f) * (W * 0.5f);
        rTR_y = ClampF(config.upperInnerRadiusY, 0.02f, 1.0f) * (H * 0.5f);
        rBR_x = ClampF(config.lowerInnerRadiusX, 0.02f, 1.0f) * (W * 0.5f);
        rBR_y = ClampF(config.lowerInnerRadiusY, 0.02f, 1.0f) * (H * 0.5f);
        rBL_x = ClampF(config.lowerOuterRadiusX, 0.02f, 1.0f) * (W * 0.5f);
        rBL_y = ClampF(config.lowerOuterRadiusY, 0.02f, 1.0f) * (H * 0.5f);
    } else {
        rTL_x = ClampF(config.upperInnerRadiusX, 0.02f, 1.0f) * (W * 0.5f);
        rTL_y = ClampF(config.upperInnerRadiusY, 0.02f, 1.0f) * (H * 0.5f);
        rTR_x = ClampF(config.upperOuterRadiusX, 0.02f, 1.0f) * (W * 0.5f);
        rTR_y = ClampF(config.upperOuterRadiusY, 0.02f, 1.0f) * (H * 0.5f);
        rBR_x = ClampF(config.lowerOuterRadiusX, 0.02f, 1.0f) * (W * 0.5f);
        rBR_y = ClampF(config.lowerOuterRadiusY, 0.02f, 1.0f) * (H * 0.5f);
        rBL_x = ClampF(config.lowerInnerRadiusX, 0.02f, 1.0f) * (W * 0.5f);
        rBL_y = ClampF(config.lowerInnerRadiusY, 0.02f, 1.0f) * (H * 0.5f);
    }

    const CGFloat kappa = 0.55228475f;
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(rTL_x, 0.0f)];
    [path addLineToPoint:CGPointMake(W - rTR_x, 0.0f)];
    [path addCurveToPoint:CGPointMake(W, rTR_y)
            controlPoint1:CGPointMake(W - rTR_x + rTR_x * kappa, 0.0f)
            controlPoint2:CGPointMake(W, rTR_y - rTR_y * kappa)];
    [path addLineToPoint:CGPointMake(W, H - rBR_y)];
    [path addCurveToPoint:CGPointMake(W - rBR_x, H)
            controlPoint1:CGPointMake(W, H - rBR_y + rBR_y * kappa)
            controlPoint2:CGPointMake(W - rBR_x + rBR_x * kappa, H)];
    [path addLineToPoint:CGPointMake(rBL_x, H)];
    [path addCurveToPoint:CGPointMake(0.0f, H - rBL_y)
            controlPoint1:CGPointMake(rBL_x - rBL_x * kappa, H)
            controlPoint2:CGPointMake(0.0f, H - rBL_y + rBL_y * kappa)];
    [path addLineToPoint:CGPointMake(0.0f, rTL_y)];
    [path addCurveToPoint:CGPointMake(rTL_x, 0.0f)
            controlPoint1:CGPointMake(0.0f, rTL_y - rTL_y * kappa)
            controlPoint2:CGPointMake(rTL_x - rTL_x * kappa, 0.0f)];
    [path closePath];

    _eyeBodyShapeLayer.path = path.CGPath;

    // Eyelid mask geometry
    CGFloat topLidY = ClampF(config.upperLidY, 0.0f, 1.0f) * H;
    CGFloat bottomLidY = H - ClampF(config.lowerLidY, 0.0f, 1.0f) * H;
    if (bottomLidY < topLidY) bottomLidY = topLidY;

    CGFloat angleSign = _isLeftEye ? 1.0f : -1.0f;
    CGFloat topSlope = tanf(config.upperLidAngle * (CGFloat)(M_PI / 180.0) * angleSign);
    CGFloat bottomSlope = tanf(config.lowerLidAngle * (CGFloat)(M_PI / 180.0) * angleSign);

    CGFloat topBendOffset = config.upperLidBend * (H * 0.25f);
    CGFloat bottomBendOffset = config.lowerLidBend * (H * 0.25f);

    CGFloat pad = 12.0f;
    CGFloat xLeft = -pad;
    CGFloat xRight = W + pad;
    CGFloat xMid = W * 0.5f;

    CGFloat yTopLeft = topLidY - topSlope * (W * 0.5f + pad);
    CGFloat yTopRight = topLidY + topSlope * (W * 0.5f + pad);
    CGFloat yTopMid = topLidY + topBendOffset;

    CGFloat yBottomRight = bottomLidY + bottomSlope * (W * 0.5f + pad);
    CGFloat yBottomLeft = bottomLidY - bottomSlope * (W * 0.5f + pad);
    CGFloat yBottomMid = bottomLidY - bottomBendOffset;

    UIBezierPath *maskPath = [UIBezierPath bezierPath];
    [maskPath moveToPoint:CGPointMake(xLeft, yTopLeft)];
    [maskPath addQuadCurveToPoint:CGPointMake(xRight, yTopRight) controlPoint:CGPointMake(xMid, yTopMid)];
    [maskPath addLineToPoint:CGPointMake(xRight, yBottomRight)];
    [maskPath addQuadCurveToPoint:CGPointMake(xLeft, yBottomLeft) controlPoint:CGPointMake(xMid, yBottomMid)];
    [maskPath closePath];

    _eyelidMaskLayer.path = maskPath.CGPath;

    // Pupil Core and Specular Glints
    CGFloat pScale = ClampF(config.glowSize, 0.15f, 2.0f);
    _pupilCore.transform = CGAffineTransformMakeScale(pScale, pScale);

    CGFloat pupilDx = ClampF(config.hotSpotCenterX, -1.0f, 1.0f) * (W * 0.22f);
    CGFloat pupilDy = ClampF(config.hotSpotCenterY, -1.0f, 1.0f) * (H * 0.22f);
    _pupilCore.center = CGPointMake(W * 0.5f + pupilDx, H * 0.5f + pupilDy);

    _specularPrimary.center = CGPointMake(W - 17.0f + pupilDx * 0.40f, 11.0f + pupilDy * 0.40f);
    _specularSecondary.center = CGPointMake(11.0f + pupilDx * 0.20f, H - 19.0f + pupilDy * 0.20f);

    _specularPrimary.alpha = config.glowLightness;
    _specularSecondary.alpha = config.glowLightness * 0.45f;

    // View Transform and Position
    CGFloat rad = config.angle * (CGFloat)(M_PI / 180.0);
    CGAffineTransform t = CGAffineTransformMakeRotation(rad);
    t = CGAffineTransformScale(t, ClampF(config.scaleX, 0.05f, 3.0f), ClampF(config.scaleY, 0.05f, 3.0f));
    self.transform = t;
    self.center = CGPointMake(_defaultCenter.x + config.centerX, _defaultCenter.y + config.centerY);
}

- (void)dealloc {
    [_eyeBodyShapeLayer release];
    [_irisGradientLayer release];
    [_eyelidMaskLayer release];
    [_eyeContentContainer release];
    [_pupilCore release];
    [_specularPrimary release];
    [_specularSecondary release];
    [super dealloc];
}
@end

// ========================================================
// 5. EMOTION PRESET GENERATOR
// ========================================================
static void GetEmotionPreset(NSString *name, ProceduralEyeConfig *outLeft, ProceduralEyeConfig *outRight, UIColor **outTop, UIColor **outBottom) {
    ProceduralEyeConfig left = ProceduralEyeConfigDefault();
    ProceduralEyeConfig right = ProceduralEyeConfigDefault();

    // Semantic Accents
    UIColor *cyanTop = [UIColor colorWithRed:0.22 green:0.75 blue:0.98 alpha:1.0];
    UIColor *cyanBottom = [UIColor colorWithRed:0.01 green:0.48 blue:0.80 alpha:1.0];

    UIColor *emeraldTop = [UIColor colorWithRed:0.20 green:0.92 blue:0.55 alpha:1.0];
    UIColor *emeraldBottom = [UIColor colorWithRed:0.04 green:0.65 blue:0.35 alpha:1.0];

    UIColor *amberTop = [UIColor colorWithRed:0.98 green:0.75 blue:0.18 alpha:1.0];
    UIColor *amberBottom = [UIColor colorWithRed:0.85 green:0.52 blue:0.02 alpha:1.0];

    UIColor *amethystTop = [UIColor colorWithRed:0.75 green:0.45 blue:0.98 alpha:1.0];
    UIColor *amethystBottom = [UIColor colorWithRed:0.48 green:0.18 blue:0.85 alpha:1.0];

    UIColor *crimsonTop = [UIColor colorWithRed:0.98 green:0.32 blue:0.32 alpha:1.0];
    UIColor *crimsonBottom = [UIColor colorWithRed:0.78 green:0.08 blue:0.08 alpha:1.0];

    UIColor *crimsonAmberTop = [UIColor colorWithRed:0.98 green:0.55 blue:0.09 alpha:1.0];
    UIColor *crimsonAmberBottom = [UIColor colorWithRed:0.77 green:0.35 blue:0.00 alpha:1.0];

    UIColor *slateBlueTop = [UIColor colorWithRed:0.22 green:0.36 blue:0.48 alpha:0.85];
    UIColor *slateBlueBottom = [UIColor colorWithRed:0.08 green:0.14 blue:0.20 alpha:0.85];

    UIColor *topColor = cyanTop;
    UIColor *bottomColor = cyanBottom;

    if ([name isEqualToString:@"happy"]) {
        left.lowerLidY = 0.50f;
        left.lowerLidBend = 0.50f;
        left.upperOuterRadiusX = 0.60f;
        left.upperInnerRadiusX = 0.60f;
        left.angle = -3.0f;
        left.hotSpotCenterY = -0.15f;

        right.lowerLidY = 0.50f;
        right.lowerLidBend = 0.50f;
        right.upperOuterRadiusX = 0.60f;
        right.upperInnerRadiusX = 0.60f;
        right.angle = 3.0f;
        right.hotSpotCenterY = -0.15f;

        topColor = emeraldTop;
        bottomColor = emeraldBottom;
    } else if ([name isEqualToString:@"glee"]) {
        left.scaleY = 0.55f;
        left.scaleX = 1.05f;
        left.lowerLidY = 0.75f;
        left.lowerLidBend = 0.70f;
        left.upperLidY = 0.15f;
        left.upperOuterRadiusX = 0.85f;
        left.upperInnerRadiusX = 0.85f;

        right.scaleY = 0.55f;
        right.scaleX = 1.05f;
        right.lowerLidY = 0.75f;
        right.lowerLidBend = 0.70f;
        right.upperLidY = 0.15f;
        right.upperOuterRadiusX = 0.85f;
        right.upperInnerRadiusX = 0.85f;

        topColor = emeraldTop;
        bottomColor = emeraldBottom;
    } else if ([name isEqualToString:@"curious"]) {
        left.scaleX = 1.10f;
        left.scaleY = 1.15f;
        left.upperOuterRadiusY = 0.65f;
        left.angle = -4.0f;
        left.hotSpotCenterX = 0.35f;
        left.hotSpotCenterY = -0.30f;

        right.scaleX = 0.95f;
        right.scaleY = 0.95f;
        right.upperLidY = 0.15f;
        right.angle = -2.0f;
        right.hotSpotCenterX = 0.35f;
        right.hotSpotCenterY = -0.30f;

        topColor = amberTop;
        bottomColor = amberBottom;
    } else if ([name isEqualToString:@"skeptic"]) {
        left.upperLidY = 0.10f;
        left.angle = -2.0f;
        left.hotSpotCenterX = 0.20f;
        left.hotSpotCenterY = -0.20f;

        right.upperLidY = 0.48f;
        right.upperLidAngle = -10.0f;
        right.upperLidBend = -0.35f;
        right.scaleY = 0.82f;
        right.hotSpotCenterX = 0.20f;
        right.hotSpotCenterY = -0.20f;

        topColor = amberTop;
        bottomColor = amberBottom;
    } else if ([name isEqualToString:@"surprised"]) {
        left.scaleX = 1.15f;
        left.scaleY = 1.30f;
        left.glowSize = 1.45f;
        left.upperOuterRadiusX = 0.80f;
        left.upperInnerRadiusX = 0.80f;
        left.lowerOuterRadiusX = 0.80f;
        left.lowerInnerRadiusX = 0.80f;

        right.scaleX = 1.15f;
        right.scaleY = 1.30f;
        right.glowSize = 1.45f;
        right.upperOuterRadiusX = 0.80f;
        right.upperInnerRadiusX = 0.80f;
        right.lowerOuterRadiusX = 0.80f;
        right.lowerInnerRadiusX = 0.80f;

        topColor = amberTop;
        bottomColor = amberBottom;
    } else if ([name isEqualToString:@"thinking"]) {
        left.scaleX = 0.90f;
        left.scaleY = 0.90f;
        left.upperLidY = 0.25f;
        left.angle = 4.0f;
        left.hotSpotCenterX = 0.30f;
        left.hotSpotCenterY = -0.65f;

        right.scaleX = 0.95f;
        right.scaleY = 0.95f;
        right.upperLidY = 0.15f;
        right.angle = 4.0f;
        right.hotSpotCenterX = 0.30f;
        right.hotSpotCenterY = -0.65f;

        topColor = amethystTop;
        bottomColor = amethystBottom;
    } else if ([name isEqualToString:@"focused"]) {
        left.scaleY = 0.70f;
        left.scaleX = 1.05f;
        left.upperLidY = 0.32f;
        left.upperLidAngle = 6.0f;
        left.glowSize = 0.85f;
        left.angle = 3.0f;

        right.scaleY = 0.70f;
        right.scaleX = 1.05f;
        right.upperLidY = 0.32f;
        right.upperLidAngle = -6.0f;
        right.glowSize = 0.85f;
        right.angle = -3.0f;

        topColor = cyanTop;
        bottomColor = cyanBottom;
    } else if ([name isEqualToString:@"annoyed"]) {
        left.upperLidY = 0.45f;
        left.upperLidBend = -0.30f;
        left.scaleY = 0.85f;
        left.upperLidAngle = 6.0f;

        right.upperLidY = 0.45f;
        right.upperLidBend = -0.30f;
        right.scaleY = 0.85f;
        right.upperLidAngle = -6.0f;

        topColor = crimsonAmberTop;
        bottomColor = crimsonAmberBottom;
    } else if ([name isEqualToString:@"alert"]) {
        left.scaleX = 1.05f;
        left.scaleY = 1.15f;
        left.upperLidY = 0.20f;
        left.upperLidAngle = 14.0f;
        left.glowSize = 0.65f;
        left.angle = 5.0f;

        right.scaleX = 1.05f;
        right.scaleY = 1.15f;
        right.upperLidY = 0.20f;
        right.upperLidAngle = -14.0f;
        right.glowSize = 0.65f;
        right.angle = -5.0f;

        topColor = crimsonTop;
        bottomColor = crimsonBottom;
    } else if ([name isEqualToString:@"sleep"] || [name isEqualToString:@"sleepy"]) {
        left.upperLidY = 0.72f;
        left.upperLidBend = 0.15f;
        left.scaleY = 0.70f;
        left.centerY = 14.0f;

        right.upperLidY = 0.72f;
        right.upperLidBend = 0.15f;
        right.scaleY = 0.70f;
        right.centerY = 14.0f;

        topColor = slateBlueTop;
        bottomColor = slateBlueBottom;
    } else if ([name isEqualToString:@"asleep"]) {
        left.upperLidY = 0.95f;
        left.lowerLidY = 0.05f;
        left.scaleY = 0.10f;
        left.centerY = 26.0f;
        left.glowLightness = 0.0f;

        right.upperLidY = 0.95f;
        right.lowerLidY = 0.05f;
        right.scaleY = 0.10f;
        right.centerY = 26.0f;
        right.glowLightness = 0.0f;

        topColor = slateBlueTop;
        bottomColor = slateBlueBottom;
    } else if ([name isEqualToString:@"confused"]) {
        left.scaleX = 1.10f;
        left.scaleY = 1.15f;
        left.angle = -8.0f;
        left.upperOuterRadiusY = 0.70f;

        right.scaleX = 0.75f;
        right.scaleY = 0.65f;
        right.upperLidY = 0.40f;
        right.angle = -6.0f;

        topColor = amberTop;
        bottomColor = amberBottom;
    } else if ([name isEqualToString:@"frustrated"]) {
        left.scaleY = 0.80f;
        left.upperLidY = 0.50f;
        left.upperLidAngle = 12.0f;
        left.lowerLidY = 0.20f;
        left.lowerLidBend = -0.30f;
        left.angle = 6.0f;

        right.scaleY = 0.80f;
        right.upperLidY = 0.50f;
        right.upperLidAngle = -12.0f;
        right.lowerLidY = 0.20f;
        right.lowerLidBend = -0.30f;
        right.angle = -6.0f;

        topColor = crimsonTop;
        bottomColor = crimsonBottom;
    } else if ([name isEqualToString:@"sad"]) {
        left.upperLidY = 0.40f;
        left.upperLidAngle = -14.0f;
        left.upperLidBend = 0.25f;
        left.scaleY = 0.85f;
        left.angle = -5.0f;

        right.upperLidY = 0.40f;
        right.upperLidAngle = 14.0f;
        right.upperLidBend = 0.25f;
        right.scaleY = 0.85f;
        right.angle = 5.0f;

        topColor = cyanTop;
        bottomColor = cyanBottom;
    } else if ([name isEqualToString:@"glance_left"]) {
        left.hotSpotCenterX = -0.65f;
        left.centerX = -8.0f;
        right.hotSpotCenterX = -0.65f;
        right.centerX = -8.0f;

        topColor = cyanTop;
        bottomColor = cyanBottom;
    } else if ([name isEqualToString:@"glance_right"]) {
        left.hotSpotCenterX = 0.65f;
        left.centerX = 8.0f;
        right.hotSpotCenterX = 0.65f;
        right.centerX = 8.0f;

        topColor = cyanTop;
        bottomColor = cyanBottom;
    } else {
        // Default Neutral
        topColor = cyanTop;
        bottomColor = cyanBottom;
    }

    if (outLeft) *outLeft = left;
    if (outRight) *outRight = right;
    if (outTop) *outTop = topColor;
    if (outBottom) *outBottom = bottomColor;
}

// ========================================================
// DISK & MEMORY HYGIENE (/tmp Artifact Pruner)
// ========================================================
static dispatch_queue_t GetPruneQueue(void) {
    static dispatch_queue_t s_pruneQueue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_pruneQueue = dispatch_queue_create("com.physicalagent.prune", DISPATCH_QUEUE_SERIAL);
    });
    return s_pruneQueue;
}

static void PruneOldTmpArtifacts(void) {
    dispatch_async(GetPruneQueue(), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *candidateDirs = @[@"/tmp", @"/private/var/tmp"];
        NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-1800];

        for (NSString *tmpDir in candidateDirs) {
            NSError *err = nil;
            NSArray *files = [fm contentsOfDirectoryAtPath:tmpDir error:&err];
            if (!files || err) continue;

            for (NSString *file in files) {
                if ([file hasPrefix:@"companion_snapshot_"] ||
                    [file hasPrefix:@"companion_audio_"] ||
                    [file hasPrefix:@"companion_screen_"]) {
                    NSString *ext = [file pathExtension];
                    if (![ext isEqualToString:@"jpg"] && ![ext isEqualToString:@"wav"] && ![ext isEqualToString:@"png"]) {
                        continue;
                    }
                    NSString *fullPath = [tmpDir stringByAppendingPathComponent:file];
                    NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
                    if (![[attrs fileType] isEqualToString:NSFileTypeRegular]) {
                        continue;
                    }
                    NSDate *modDate = [attrs fileModificationDate];
                    if (modDate && [modDate compare:cutoff] == NSOrderedAscending) {
                        [fm removeItemAtPath:fullPath error:nil];
                    }
                }
            }
        }
    });
}

@class DeskCompanionViewController;
static DeskCompanionViewController *g_viewController = nil;

@interface DeskCompanionViewController : UIViewController <UIGestureRecognizerDelegate, AVAudioRecorderDelegate> {
    // Canvas Background
    RadialGradientBackgroundView *_bgView;

    // HUD Elements
    UIView *_statusBarPill;
    UILabel *_connectionLabel;
    UILabel *_clockLabel;
    UILabel *_batteryLabel;

    // Entity Elements: Recessed Sockets
    UIView *_leftSocket;
    UIView *_rightSocket;

    // Entity Elements: Procedural Vector Eyes (Vector & Cozmo Architecture)
    UIView *_eyeContainer;
    ProceduralEyeView *_leftEye;
    ProceduralEyeView *_rightEye;
    ScanlineOverlayView *_scanlineOverlay;

    // Procedural Interpolator State
    CADisplayLink *_proceduralDisplayLink;
    ProceduralEyeConfig _leftCurrentConfig;
    ProceduralEyeConfig _leftTargetConfig;
    ProceduralEyeConfig _leftStartConfig;
    ProceduralEyeConfig _rightCurrentConfig;
    ProceduralEyeConfig _rightTargetConfig;
    ProceduralEyeConfig _rightStartConfig;
    ProceduralEyeConfig _leftTargetExpressionConfig;
    ProceduralEyeConfig _rightTargetExpressionConfig;
    NSTimeInterval _animStartTime;
    NSTimeInterval _animDuration;
    BOOL _isInterpolating;
    BOOL _interpolateEaseOut;
    void (^_interpolationCompletion)(void);

    // Audio Visualizer Waveform (5 bars)
    UIView *_waveformContainer;
    UIView *_waveBars[5];
    NSTimer *_waveTimer;
    BOOL _isSpeaking;

    // Bottom Thought Pill
    UIView *_thoughtCard;
    UIView *_statusDot;
    UILabel *_statusTitleLabel;
    UILabel *_statusSubtitleLabel;

    // Timers & State
    NSTimer *_clockTimer;
    NSTimer *_blinkTimer;
    NSTimer *_saccadeTimer;
    NSTimer *_pruneTimer;
    BOOL _isBlinking;
    BOOL _isPanning;
    BOOL _zenMode;
    BOOL _reducedMotion;
    BOOL _observersAdded;
    NSString *_currentExpression;
    CGPoint _defaultEyePositionLeft;
    CGPoint _defaultEyePositionRight;
    CGRect _defaultEyeFrameLeft;
    CGRect _defaultEyeFrameRight;

    // Audio Microphone Hardware
    AVAudioRecorder *_audioRecorder;
    NSTimer *_audioTimeoutTimer;
    BOOL _isRecording;
    void (^_audioRecordCompletion)(NSString *path, NSUInteger size, NSError *err);
}

- (void)setupProceduralEngine;
- (void)onProceduralDisplayLink:(CADisplayLink *)link;
- (void)interpolateToLeft:(ProceduralEyeConfig)left right:(ProceduralEyeConfig)right duration:(NSTimeInterval)dur easeOut:(BOOL)easeOut completion:(void (^)(void))completion;
- (void)setExpression:(NSString *)expression;
- (void)setExpression:(NSString *)expression duration:(NSTimeInterval)dur;
- (void)lookAtX:(CGFloat)x y:(CGFloat)y duration:(NSTimeInterval)dur;
- (void)setProceduralParamsLeft:(NSArray *)left right:(NSArray *)right duration:(NSTimeInterval)dur;
- (void)setScanlineOpacity:(CGFloat)opacity;
- (void)setStatusTitle:(NSString *)title subtitle:(NSString *)subtitle;
- (void)blink;
- (BOOL)setTorch:(BOOL)enable;
- (void)setSpeaking:(BOOL)speaking;
- (void)playSoundNamed:(NSString *)name;
- (void)setReducedMotion:(BOOL)reduced;
- (void)takeSnapshot:(NSString *)cameraPosition completion:(void (^)(NSString *path, NSUInteger size, NSError *err))completion;
- (void)recordAudioDuration:(NSTimeInterval)duration completion:(void (^)(NSString *path, NSUInteger size, NSError *err))completion;
- (void)captureScreenToPath:(NSString *)path completion:(void (^)(NSString *path, NSUInteger size, NSError *err))completion;
- (NSDictionary *)getTelemetry;
- (void)toggleZenMode;
@end

@implementation DeskCompanionViewController

- (void)loadView {
    [super loadView];
    // Radial gradient obsidian depth background
    _bgView = [[RadialGradientBackgroundView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    _bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = _bgView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    g_viewController = self;

    CGFloat screenW = 320.0;
    CGFloat screenH = 480.0;

    // ========================================================
    // 1. TOP STATUS BAR PILL (Frosted Hairline Card)
    // ========================================================
    _statusBarPill = [[UIView alloc] initWithFrame:CGRectMake(16, 14, screenW - 32, 28)];
    _statusBarPill.backgroundColor = [UIColor colorWithRed:0.04 green:0.06 blue:0.09 alpha:0.88];
    _statusBarPill.layer.cornerRadius = 14.0;
    _statusBarPill.layer.borderWidth = 1.0;
    _statusBarPill.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;
    [self.view addSubview:_statusBarPill];

    // Left Connection Badge
    _connectionLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, 85, 28)];
    _connectionLabel.backgroundColor = [UIColor clearColor];
    _connectionLabel.textColor = [UIColor colorWithRed:0.22 green:0.75 blue:0.98 alpha:1.0]; // Cyber Cyan
    _connectionLabel.font = [UIFont fontWithName:@"Courier-Bold" size:10.0];
    _connectionLabel.text = @"* USB 30-PIN";
    [_statusBarPill addSubview:_connectionLabel];

    // Center Clock
    _clockLabel = [[UILabel alloc] initWithFrame:CGRectMake(95, 0, screenW - 32 - 170, 28)];
    _clockLabel.backgroundColor = [UIColor clearColor];
    _clockLabel.textColor = [UIColor colorWithWhite:0.88 alpha:1.0];
    _clockLabel.font = [UIFont fontWithName:@"Courier" size:12.0];
    _clockLabel.textAlignment = NSTextAlignmentCenter;
    [_statusBarPill addSubview:_clockLabel];

    // Right Battery
    _batteryLabel = [[UILabel alloc] initWithFrame:CGRectMake(screenW - 32 - 75, 0, 63, 28)];
    _batteryLabel.backgroundColor = [UIColor clearColor];
    _batteryLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    _batteryLabel.font = [UIFont fontWithName:@"Courier" size:10.0];
    _batteryLabel.textAlignment = NSTextAlignmentRight;
    _batteryLabel.text = @"95%";
    [_statusBarPill addSubview:_batteryLabel];

    // ========================================================
    // 2. CENTRAL ENTITY: LIVING VECTOR EYES WITH ANATOMY
    // ========================================================
    _eyeContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, screenW, screenH)];
    _eyeContainer.backgroundColor = [UIColor clearColor];
    [self.view addSubview:_eyeContainer];

    CGFloat eyeW = 50.0;
    CGFloat eyeH = 76.0;
    CGFloat eyeSpacing = 54.0;
    CGFloat eyeY = 175.0; // Optical center on 320x480 Retina stage

    CGRect leftFrame = CGRectMake(screenW/2.0 - eyeSpacing - eyeW/2.0, eyeY, eyeW, eyeH);
    CGRect rightFrame = CGRectMake(screenW/2.0 + eyeSpacing - eyeW/2.0, eyeY, eyeW, eyeH);

    _defaultEyeFrameLeft = leftFrame;
    _defaultEyeFrameRight = rightFrame;

    // Recessed Eye Sockets (Believable Spatial Enclosure)
    _leftSocket = [[UIView alloc] initWithFrame:CGRectMake(leftFrame.origin.x - 3.0, leftFrame.origin.y - 3.0, eyeW + 6.0, eyeH + 6.0)];
    _leftSocket.backgroundColor = [UIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.35];
    _leftSocket.layer.cornerRadius = (eyeW + 6.0) / 2.0;
    _leftSocket.layer.borderWidth = 1.0;
    _leftSocket.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.04].CGColor;
    [_eyeContainer addSubview:_leftSocket];

    _rightSocket = [[UIView alloc] initWithFrame:CGRectMake(rightFrame.origin.x - 3.0, rightFrame.origin.y - 3.0, eyeW + 6.0, eyeH + 6.0)];
    _rightSocket.backgroundColor = [UIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.35];
    _rightSocket.layer.cornerRadius = (eyeW + 6.0) / 2.0;
    _rightSocket.layer.borderWidth = 1.0;
    _rightSocket.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.04].CGColor;
    [_eyeContainer addSubview:_rightSocket];

    // --- Procedural Vector Eyes (Vector & Cozmo Architecture) ---
    _leftEye = [[ProceduralEyeView alloc] initWithFrame:leftFrame isLeft:YES];
    [_eyeContainer addSubview:_leftEye];

    _rightEye = [[ProceduralEyeView alloc] initWithFrame:rightFrame isLeft:NO];
    [_eyeContainer addSubview:_rightEye];

    _defaultEyePositionLeft = _leftEye.layer.position;
    _defaultEyePositionRight = _rightEye.layer.position;

    // Scanline CRT Overlay (Retro Screen Texture)
    _scanlineOverlay = [[ScanlineOverlayView alloc] initWithFrame:CGRectMake(0, 0, screenW, screenH)];
    [self.view addSubview:_scanlineOverlay];

    // Initialize Procedural Interpolator Engine
    [self setupProceduralEngine];

    _reducedMotion = [[NSUserDefaults standardUserDefaults] boolForKey:@"PhysicalAgentReducedMotion"];

    // ========================================================
    // 3. SUB-PERCEPTUAL BREATHING CYCLE (PowerVR SGX GPU)
    // ========================================================
    [self startBreathingCycle];

    // ========================================================
    // 4. AUDIO SPECTRUM WAVEFORM (5 bars for voice feedback)
    // ========================================================
    CGFloat waveW = 80.0;
    CGFloat waveH = 20.0;
    _waveformContainer = [[UIView alloc] initWithFrame:CGRectMake((screenW - waveW)/2.0, eyeY + eyeH + 24.0, waveW, waveH)];
    _waveformContainer.backgroundColor = [UIColor clearColor];
    _waveformContainer.alpha = 0.0;
    [self.view addSubview:_waveformContainer];

    CGFloat barW = 4.0;
    CGFloat barGap = 12.0;
    for (int i = 0; i < 5; i++) {
        CGFloat bx = i * (barW + barGap) + 8.0;
        _waveBars[i] = [[UIView alloc] initWithFrame:CGRectMake(bx, waveH/2.0 - 2, barW, 4)];
        _waveBars[i].backgroundColor = [UIColor colorWithRed:0.22 green:0.75 blue:0.98 alpha:1.0];
        _waveBars[i].layer.cornerRadius = 2.0;
        [_waveformContainer addSubview:_waveBars[i]];
    }

    // ========================================================
    // 5. BOTTOM THOUGHT CARD (Refined Hairline Linear Card)
    // ========================================================
    CGFloat cardW = screenW - 32.0;
    CGFloat cardH = 52.0;
    _thoughtCard = [[UIView alloc] initWithFrame:CGRectMake(16, screenH - cardH - 18, cardW, cardH)];
    _thoughtCard.backgroundColor = [UIColor colorWithRed:0.04 green:0.055 blue:0.08 alpha:0.92];
    _thoughtCard.layer.cornerRadius = 14.0;
    _thoughtCard.layer.borderWidth = 1.0;
    _thoughtCard.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.07].CGColor;
    [self.view addSubview:_thoughtCard];

    // Glowing Status Dot
    _statusDot = [[UIView alloc] initWithFrame:CGRectMake(14, 15, 7, 7)];
    _statusDot.backgroundColor = [UIColor colorWithRed:0.20 green:0.92 blue:0.55 alpha:1.0]; // Emerald
    _statusDot.layer.cornerRadius = 3.5;
    _statusDot.layer.shadowColor = [UIColor colorWithRed:0.20 green:0.92 blue:0.55 alpha:1.0].CGColor;
    _statusDot.layer.shadowOffset = CGSizeZero;
    _statusDot.layer.shadowRadius = 5.0;
    _statusDot.layer.shadowOpacity = 0.9;
    [_thoughtCard addSubview:_statusDot];

    // Status Title (Monospace Bold)
    _statusTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(30, 9, cardW - 44, 18)];
    _statusTitleLabel.backgroundColor = [UIColor clearColor];
    _statusTitleLabel.textColor = [UIColor colorWithWhite:0.94 alpha:1.0];
    _statusTitleLabel.font = [UIFont fontWithName:@"Courier-Bold" size:11.0];
    _statusTitleLabel.text = @"PHYSICAL AGENT // ONLINE";
    [_thoughtCard addSubview:_statusTitleLabel];

    // Status Subtitle (Clean Sans)
    _statusSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(30, 27, cardW - 44, 16)];
    _statusSubtitleLabel.backgroundColor = [UIColor clearColor];
    _statusSubtitleLabel.textColor = [UIColor colorWithWhite:0.52 alpha:1.0];
    _statusSubtitleLabel.font = [UIFont fontWithName:@"HelveticaNeue" size:10.5];
    _statusSubtitleLabel.text = @"Awaiting multimodal input";
    [_thoughtCard addSubview:_statusSubtitleLabel];

    // ========================================================
    // 6. GESTURE RECOGNIZERS (Emil Kowalski Interactive Touch)
    // ========================================================
    UIPanGestureRecognizer *pan = [[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)] autorelease];
    pan.delegate = self;
    [self.view addGestureRecognizer:pan];

    UITapGestureRecognizer *singleTap = [[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSingleTap:)] autorelease];
    [self.view addGestureRecognizer:singleTap];

    UITapGestureRecognizer *doubleTap = [[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)] autorelease];
    doubleTap.numberOfTapsRequired = 2;
    [self.view addGestureRecognizer:doubleTap];
    [singleTap requireGestureRecognizerToFail:doubleTap];

    // Timers & Observers
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAudioInterruption:)
                                                 name:AVAudioSessionInterruptionNotification
                                               object:nil];
    _observersAdded = YES;

    [self updateClock];
    _clockTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateClock) userInfo:nil repeats:YES];
    _blinkTimer = [NSTimer scheduledTimerWithTimeInterval:3.8 target:self selector:@selector(triggerRandomBlink) userInfo:nil repeats:YES];
    _saccadeTimer = [NSTimer scheduledTimerWithTimeInterval:5.5 target:self selector:@selector(triggerMicroSaccade) userInfo:nil repeats:YES];
    _pruneTimer = [NSTimer scheduledTimerWithTimeInterval:300.0 target:self selector:@selector(periodicPrune:) userInfo:nil repeats:YES];

    [UIApplication sharedApplication].idleTimerDisabled = YES;
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
}

- (void)periodicPrune:(NSTimer *)timer {
    PruneOldTmpArtifacts();
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    PruneOldTmpArtifacts();
}

- (void)startBreathingCycle {
    if (_reducedMotion) return;

    CABasicAnimation *breatheScale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    breatheScale.fromValue = [NSNumber numberWithFloat:1.0f];
    breatheScale.toValue = [NSNumber numberWithFloat:1.018f];
    breatheScale.duration = 4.2;
    breatheScale.autoreverses = YES;
    breatheScale.repeatCount = HUGE_VALF;
    breatheScale.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_eyeContainer.layer addAnimation:breatheScale forKey:@"breatheScale"];

    CABasicAnimation *breatheGlow = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    breatheGlow.fromValue = [NSNumber numberWithFloat:0.75f];
    breatheGlow.toValue = [NSNumber numberWithFloat:0.95f];
    breatheGlow.duration = 4.2;
    breatheGlow.autoreverses = YES;
    breatheGlow.repeatCount = HUGE_VALF;
    breatheGlow.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_leftEye.layer addAnimation:breatheGlow forKey:@"breatheGlow"];
    [_rightEye.layer addAnimation:breatheGlow forKey:@"breatheGlow"];
}

- (void)setReducedMotion:(BOOL)reduced {
    _reducedMotion = reduced;
    [[NSUserDefaults standardUserDefaults] setBool:reduced forKey:@"PhysicalAgentReducedMotion"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (_reducedMotion) {
        [_eyeContainer.layer removeAnimationForKey:@"breatheScale"];
        [_leftEye.layer removeAnimationForKey:@"breatheGlow"];
        [_rightEye.layer removeAnimationForKey:@"breatheGlow"];
    } else {
        [self startBreathingCycle];
    }
}

- (void)updateClock {
    NSDateFormatter *df = [[[NSDateFormatter alloc] init] autorelease];
    [df setDateFormat:@"HH:mm:ss"];
    _clockLabel.text = [df stringFromDate:[NSDate date]];

    float batt = [UIDevice currentDevice].batteryLevel * 100.0f;
    UIDeviceBatteryState bState = [UIDevice currentDevice].batteryState;
    if (bState == UIDeviceBatteryStateCharging || bState == UIDeviceBatteryStateFull) {
        _connectionLabel.text = @"* USB 30-PIN";
        _batteryLabel.text = [NSString stringWithFormat:@"⚡%d%%", (int)batt];
    } else {
        _connectionLabel.text = @"* WI-FI";
        _batteryLabel.text = [NSString stringWithFormat:@"%d%%", (int)batt];
    }
}

// ========================================================
// EMIL KOWALSKI MOTION & PROCEDURAL ANIMATION FRAMEWORK
// ========================================================
- (void)setupProceduralEngine {
    _leftCurrentConfig = ProceduralEyeConfigDefault();
    _rightCurrentConfig = ProceduralEyeConfigDefault();
    _leftTargetConfig = _leftCurrentConfig;
    _rightTargetConfig = _rightCurrentConfig;
    _leftTargetExpressionConfig = _leftCurrentConfig;
    _rightTargetExpressionConfig = _rightCurrentConfig;
    _leftStartConfig = _leftCurrentConfig;
    _rightStartConfig = _rightCurrentConfig;

    _proceduralDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onProceduralDisplayLink:)];
    [_proceduralDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    _proceduralDisplayLink.paused = YES;
}

- (void)onProceduralDisplayLink:(CADisplayLink *)link {
    if (!_isInterpolating) return;

    NSTimeInterval elapsed = CACurrentMediaTime() - _animStartTime;
    CGFloat t = (_animDuration > 0.001) ? (CGFloat)(elapsed / _animDuration) : 1.0f;
    if (t >= 1.0f) {
        t = 1.0f;
        _isInterpolating = NO;
        _proceduralDisplayLink.paused = YES;
    }

    CGFloat easeT;
    if (_interpolateEaseOut) {
        CGFloat inv = 1.0f - t;
        easeT = 1.0f - (inv * inv * inv);
    } else {
        easeT = t * t * t;
    }

    _leftCurrentConfig = ProceduralEyeConfigLerp(_leftStartConfig, _leftTargetConfig, easeT);
    _rightCurrentConfig = ProceduralEyeConfigLerp(_rightStartConfig, _rightTargetConfig, easeT);

    [_leftEye applyConfig:_leftCurrentConfig];
    [_rightEye applyConfig:_rightCurrentConfig];

    if (!_isInterpolating && _interpolationCompletion) {
        void (^comp)(void) = _interpolationCompletion;
        _interpolationCompletion = nil;
        comp();
        Block_release(comp);
    }
}

- (void)interpolateToLeft:(ProceduralEyeConfig)left right:(ProceduralEyeConfig)right duration:(NSTimeInterval)dur easeOut:(BOOL)easeOut completion:(void (^)(void))completion {
    if (dur <= 0.005) {
        _leftCurrentConfig = left;
        _rightCurrentConfig = right;
        [_leftEye applyConfig:_leftCurrentConfig];
        [_rightEye applyConfig:_rightCurrentConfig];
        if (completion) completion();
        return;
    }

    if (_interpolationCompletion) {
        Block_release(_interpolationCompletion);
        _interpolationCompletion = nil;
    }
    if (completion) {
        _interpolationCompletion = Block_copy(completion);
    }

    _leftStartConfig = _leftCurrentConfig;
    _rightStartConfig = _rightCurrentConfig;
    _leftTargetConfig = left;
    _rightTargetConfig = right;
    _animStartTime = CACurrentMediaTime();
    _animDuration = dur;
    _interpolateEaseOut = easeOut;
    _isInterpolating = YES;
    _proceduralDisplayLink.paused = NO;
}

- (void)setExpression:(NSString *)expression {
    [self setExpression:expression duration:0.28];
}

- (void)setExpression:(NSString *)expression duration:(NSTimeInterval)dur {
    [_currentExpression release];
    _currentExpression = [expression copy];

    ProceduralEyeConfig targetLeft, targetRight;
    UIColor *topColor = nil;
    UIColor *bottomColor = nil;
    GetEmotionPreset(expression, &targetLeft, &targetRight, &topColor, &bottomColor);

    _leftTargetExpressionConfig = targetLeft;
    _rightTargetExpressionConfig = targetRight;

    [_leftEye setGradientColors:@[ (id)topColor.CGColor, (id)bottomColor.CGColor ]];
    [_rightEye setGradientColors:@[ (id)topColor.CGColor, (id)bottomColor.CGColor ]];
    [_leftEye setGlowColor:topColor];
    [_rightEye setGlowColor:topColor];
    _statusDot.backgroundColor = topColor;
    _statusDot.layer.shadowColor = topColor.CGColor;

    [self interpolateToLeft:targetLeft right:targetRight duration:dur easeOut:YES completion:nil];
}

- (void)lookAtX:(CGFloat)x y:(CGFloat)y duration:(NSTimeInterval)dur {
    ProceduralEyeConfig lookLeft = _leftTargetExpressionConfig;
    ProceduralEyeConfig lookRight = _rightTargetExpressionConfig;

    CGFloat cX = ClampF(x, -1.0f, 1.0f);
    CGFloat cY = ClampF(y, -1.0f, 1.0f);

    lookLeft.hotSpotCenterX = cX;
    lookLeft.hotSpotCenterY = cY;
    lookRight.hotSpotCenterX = cX;
    lookRight.hotSpotCenterY = cY;

    lookLeft.centerX = cX * 10.0f;
    lookLeft.centerY = cY * 8.0f;
    lookRight.centerX = cX * 10.0f;
    lookRight.centerY = cY * 8.0f;

    _leftTargetExpressionConfig = lookLeft;
    _rightTargetExpressionConfig = lookRight;

    [self interpolateToLeft:lookLeft right:lookRight duration:(dur > 0 ? dur : 0.22) easeOut:YES completion:nil];
}

- (void)setProceduralParamsLeft:(NSArray *)left right:(NSArray *)right duration:(NSTimeInterval)dur {
    ProceduralEyeConfig leftCfg = ProceduralEyeConfigFromArray(left, _leftCurrentConfig);
    ProceduralEyeConfig rightCfg = ProceduralEyeConfigFromArray(right, _rightCurrentConfig);

    _leftTargetExpressionConfig = leftCfg;
    _rightTargetExpressionConfig = rightCfg;

    [self interpolateToLeft:leftCfg right:rightCfg duration:(dur > 0 ? dur : 0.28) easeOut:YES completion:nil];
}

- (void)setScanlineOpacity:(CGFloat)opacity {
    if (_scanlineOverlay) {
        _scanlineOverlay.scanlineOpacity = ClampF(opacity, 0.0f, 0.40f);
    }
}

- (void)triggerRandomBlink {
    if (!_isBlinking && !_isSpeaking && !_isPanning && ![_currentExpression isEqualToString:@"sleep"] && ![_currentExpression isEqualToString:@"asleep"]) {
        [self blink];
    }
}

// Procedural Asymmetrical Eyelid Kinematics (0% CPU Overhead)
- (void)blink {
    if (_isPanning || _isBlinking) return;
    _isBlinking = YES;

    // Fast organic close: 70ms ease-out via eyelid path closure
    ProceduralEyeConfig blinkLeft = _leftCurrentConfig;
    ProceduralEyeConfig blinkRight = _rightCurrentConfig;
    blinkLeft.upperLidY = 1.0f;
    blinkLeft.lowerLidY = 0.25f;
    blinkRight.upperLidY = 1.0f;
    blinkRight.lowerLidY = 0.25f;

    [self interpolateToLeft:blinkLeft right:blinkRight duration:0.070 easeOut:YES completion:^{
        // Organic bounce open: 110ms ease-in back to active expression
        [self interpolateToLeft:self->_leftTargetExpressionConfig right:self->_rightTargetExpressionConfig duration:0.110 easeOut:NO completion:^{
            self->_isBlinking = NO;
        }];
    }];
}

// Organic Saccade Clusters with Gaze Hotspot Parallax
- (void)triggerMicroSaccade {
    if (_isBlinking || _isSpeaking || _isPanning || _reducedMotion || [_currentExpression isEqualToString:@"sleep"] || [_currentExpression isEqualToString:@"asleep"]) return;

    // Natural saccadic displacement in normalized hotspot space: -0.32 to +0.32
    float rx = ((float)(arc4random_uniform(9)) - 4.0f) * 0.08f;
    float ry = ((float)(arc4random_uniform(5)) - 2.0f) * 0.08f;

    ProceduralEyeConfig saccadeLeft = _leftTargetExpressionConfig;
    ProceduralEyeConfig saccadeRight = _rightTargetExpressionConfig;
    saccadeLeft.hotSpotCenterX = ClampF(saccadeLeft.hotSpotCenterX + rx, -1.0f, 1.0f);
    saccadeLeft.hotSpotCenterY = ClampF(saccadeLeft.hotSpotCenterY + ry, -1.0f, 1.0f);
    saccadeRight.hotSpotCenterX = ClampF(saccadeRight.hotSpotCenterX + rx, -1.0f, 1.0f);
    saccadeRight.hotSpotCenterY = ClampF(saccadeRight.hotSpotCenterY + ry, -1.0f, 1.0f);

    // 100ms rapid saccade burst
    [self interpolateToLeft:saccadeLeft right:saccadeRight duration:0.10 easeOut:YES completion:^{
        // Hold fixation for 1.8 seconds, then return
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self->_isBlinking && !self->_isPanning) {
                [self interpolateToLeft:self->_leftTargetExpressionConfig right:self->_rightTargetExpressionConfig duration:0.22 easeOut:YES completion:nil];
            }
        });
    }];
}

- (void)setStatusTitle:(NSString *)title subtitle:(NSString *)subtitle {
    [UIView transitionWithView:_thoughtCard duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        if (title) self->_statusTitleLabel.text = title;
        if (subtitle) self->_statusSubtitleLabel.text = subtitle;
    } completion:nil];
}

// ========================================================
// AUDIO SPECTRUM VISUALIZER (Speaking / Listening)
// ========================================================
- (void)setSpeaking:(BOOL)speaking {
    _isSpeaking = speaking;
    if (speaking) {
        [UIView animateWithDuration:0.2 animations:^{
            self->_waveformContainer.alpha = 1.0;
        }];
        if (!_waveTimer) {
            _waveTimer = [NSTimer scheduledTimerWithTimeInterval:0.08 target:self selector:@selector(animateWaveBars) userInfo:nil repeats:YES];
        }
    } else {
        [_waveTimer invalidate];
        _waveTimer = nil;
        [UIView animateWithDuration:0.25 animations:^{
            self->_waveformContainer.alpha = 0.0;
            for (int i = 0; i < 5; i++) {
                CGRect bf = self->_waveBars[i].frame;
                bf.size.height = 4.0;
                bf.origin.y = 10.0 - 2.0;
                self->_waveBars[i].frame = bf;
            }
        }];
    }
}

- (void)animateWaveBars {
    for (int i = 0; i < 5; i++) {
        CGFloat h = 4.0 + (arc4random_uniform(18));
        CGRect bf = _waveBars[i].frame;
        bf.size.height = h;
        bf.origin.y = (20.0 - h) / 2.0;
        _waveBars[i].frame = bf;
    }
}

// ========================================================
// TOUCH INTERACTIONS & ERGONOMICS (Emil Kowalski Rules)
// ========================================================
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    [self playSoundNamed:@"tink"];
}

- (void)handleSingleTap:(UITapGestureRecognizer *)gesture {
    // Immediate tactile squash: scale(0.93) over 80ms with spring rebound
    [UIView animateWithDuration:0.08 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_eyeContainer.transform = CGAffineTransformMakeScale(0.93, 0.93);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
            self->_eyeContainer.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];

    [self blink];
    [self setExpression:@"happy"];
    [self setStatusTitle:@"PHYSICAL TOUCH DETECTED" subtitle:@"Companion acknowledged your press"];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self setExpression:@"neutral"];
        [self setStatusTitle:@"PHYSICAL AGENT // ONLINE" subtitle:@"Awaiting multimodal input"];
    });
}

// Interactive Gaze Pan: Eyes follow finger across screen with procedural gaze kinematics
- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.view];

    CGFloat normX = ClampF(translation.x / 140.0f, -1.0f, 1.0f);
    CGFloat normY = ClampF(translation.y / 200.0f, -1.0f, 1.0f);

    if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) {
        _isPanning = YES;
        ProceduralEyeConfig panLeft = _leftTargetExpressionConfig;
        ProceduralEyeConfig panRight = _rightTargetExpressionConfig;
        panLeft.hotSpotCenterX = normX;
        panLeft.hotSpotCenterY = normY;
        panRight.hotSpotCenterX = normX;
        panRight.hotSpotCenterY = normY;
        panLeft.centerX = normX * 12.0f;
        panLeft.centerY = normY * 10.0f;
        panRight.centerX = normX * 12.0f;
        panRight.centerY = normY * 10.0f;
        _leftCurrentConfig = panLeft;
        _rightCurrentConfig = panRight;
        [_leftEye applyConfig:_leftCurrentConfig];
        [_rightEye applyConfig:_rightCurrentConfig];
    } else if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        _isPanning = NO;
        [self interpolateToLeft:_leftTargetExpressionConfig right:_rightTargetExpressionConfig duration:0.25 easeOut:YES completion:nil];
    }
}

// Double Tap: Zen Mode (fade HUD cards for night desk ambiance)
- (void)handleDoubleTap:(UITapGestureRecognizer *)gesture {
    [self toggleZenMode];
}

- (void)toggleZenMode {
    _zenMode = !_zenMode;
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    [self playSoundNamed:@"tweet"];

    [UIView animateWithDuration:0.3 animations:^{
        CGFloat alpha = self->_zenMode ? 0.0 : 1.0;
        self->_statusBarPill.alpha = alpha;
        self->_thoughtCard.alpha = alpha;
    }];
}

// ========================================================
// HARDWARE ACTUATORS, SENSORS & MULTIMODAL PERCEPTION
// ========================================================
- (void)playSoundNamed:(NSString *)name {
    NSString *soundFile = nil;
    if ([name isEqualToString:@"confirm"]) soundFile = @"jbl_confirm.caf";
    else if ([name isEqualToString:@"begin"]) soundFile = @"jbl_begin.caf";
    else if ([name isEqualToString:@"cancel"]) soundFile = @"jbl_cancel.caf";
    else if ([name isEqualToString:@"shutter"]) soundFile = @"photoShutter.caf";
    else if ([name isEqualToString:@"tweet"]) soundFile = @"tweet_sent.caf";
    else if ([name isEqualToString:@"mail"]) soundFile = @"new-mail.caf";
    else if ([name isEqualToString:@"tink"]) soundFile = @"Tink.caf";
    else if ([name isEqualToString:@"beep"]) soundFile = @"beep-beep.caf";
    else if ([name isEqualToString:@"alarm"]) soundFile = @"alarm.caf";
    else soundFile = @"jbl_confirm.caf";

    NSString *fullPath = [NSString stringWithFormat:@"/System/Library/Audio/UISounds/%@", soundFile];
    SystemSoundID soundID;
    OSStatus err = AudioServicesCreateSystemSoundID((CFURLRef)[NSURL fileURLWithPath:fullPath], &soundID);
    if (err == kAudioServicesNoError) {
        AudioServicesPlaySystemSound(soundID);
    }
}

- (BOOL)setTorch:(BOOL)enable {
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if ([device hasTorch] && [device hasFlash]) {
        NSError *lockErr = nil;
        if ([device lockForConfiguration:&lockErr]) {
            if (enable) {
                [device setTorchMode:AVCaptureTorchModeOn];
            } else {
                [device setTorchMode:AVCaptureTorchModeOff];
            }
            [device unlockForConfiguration];
            return YES;
        }
    }
    return NO;
}

// Dual-Camera Perception: Front (VGA selfie/desk) and Back (8MP macro scanner)
- (void)takeSnapshot:(NSString *)cameraPosition completion:(void (^)(NSString *path, NSUInteger size, NSError *err))completion {
    AVCaptureDevicePosition pos = [cameraPosition isEqualToString:@"front"] ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;

    AVCaptureSession *session = [[[AVCaptureSession alloc] init] autorelease];
    session.sessionPreset = AVCaptureSessionPreset640x480;

    AVCaptureDevice *chosenDevice = nil;
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    for (AVCaptureDevice *dev in devices) {
        if (dev.position == pos) {
            chosenDevice = dev;
            break;
        }
    }
    if (!chosenDevice) chosenDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];

    NSError *inputErr = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:chosenDevice error:&inputErr];
    if (!input || ![session canAddInput:input]) {
        if (completion) completion(nil, 0, inputErr ? inputErr : [NSError errorWithDomain:@"DeskCompanion" code:-1 userInfo:nil]);
        return;
    }
    [session addInput:input];

    AVCaptureStillImageOutput *output = [[[AVCaptureStillImageOutput alloc] init] autorelease];
    output.outputSettings = @{ AVVideoCodecKey : AVVideoCodecJPEG };
    if (![session canAddOutput:output]) {
        if (completion) completion(nil, 0, [NSError errorWithDomain:@"DeskCompanion" code:-2 userInfo:nil]);
        return;
    }
    [session addOutput:output];

    [session startRunning];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AVCaptureConnection *videoConn = nil;
        for (AVCaptureConnection *conn in output.connections) {
            for (AVCaptureInputPort *port in [conn inputPorts]) {
                if ([[port mediaType] isEqual:AVMediaTypeVideo]) {
                    videoConn = conn;
                    break;
                }
            }
            if (videoConn) break;
        }

        if (!videoConn) {
            [session stopRunning];
            if (completion) completion(nil, 0, [NSError errorWithDomain:@"DeskCompanion" code:-3 userInfo:nil]);
            return;
        }

        [output captureStillImageAsynchronouslyFromConnection:videoConn completionHandler:^(CMSampleBufferRef sbuf, NSError *err) {
            [session stopRunning];
            if (err || !sbuf) {
                if (completion) completion(nil, 0, err);
                return;
            }
            NSData *jpeg = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:sbuf];
            NSString *snapId = [[NSProcessInfo processInfo] globallyUniqueString];
            NSString *savePath = [NSString stringWithFormat:@"/tmp/companion_snapshot_%@.jpg", snapId];
            BOOL written = [jpeg writeToFile:savePath atomically:YES];
            [self playSoundNamed:@"shutter"];
            if (written) {
                if (completion) completion(savePath, [jpeg length], nil);
            } else {
                if (completion) completion(nil, 0, [NSError errorWithDomain:@"DeskCompanion" code:-4 userInfo:nil]);
            }
        }];
    });
}

// Microphone Perception: Record linear PCM 16kHz mono audio on iPhone 4S
- (void)recordAudioDuration:(NSTimeInterval)duration completion:(void (^)(NSString *path, NSUInteger size, NSError *err))completion {
    @synchronized(self) {
        if (_isRecording) {
            if (completion) {
                NSError *busyErr = [NSError errorWithDomain:@"DeskCompanionAudio" code:-10 userInfo:@{NSLocalizedDescriptionKey: @"Audio recording already in progress"}];
                completion(nil, 0, busyErr);
            }
            return;
        }

        if (_audioTimeoutTimer) {
            [_audioTimeoutTimer invalidate];
            _audioTimeoutTimer = nil;
        }
        if (_audioRecorder) {
            if ([_audioRecorder isRecording]) [_audioRecorder stop];
            _audioRecorder.delegate = nil;
            [_audioRecorder release];
            _audioRecorder = nil;
        }
        if (_audioRecordCompletion) {
            Block_release(_audioRecordCompletion);
            _audioRecordCompletion = nil;
        }
    }

    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    NSError *categoryErr = nil;
    if (![audioSession setCategory:AVAudioSessionCategoryPlayAndRecord error:&categoryErr]) {
        if (completion) completion(nil, 0, categoryErr ? categoryErr : [NSError errorWithDomain:@"DeskCompanionAudio" code:-1 userInfo:nil]);
        return;
    }
    NSError *activeErr = nil;
    if (![audioSession setActive:YES error:&activeErr]) {
        if (completion) completion(nil, 0, activeErr ? activeErr : [NSError errorWithDomain:@"DeskCompanionAudio" code:-2 userInfo:nil]);
        return;
    }

    NSString *audioId = [[NSProcessInfo processInfo] globallyUniqueString];
    NSString *recordPath = [NSString stringWithFormat:@"/tmp/companion_audio_%@.wav", audioId];
    NSURL *recordURL = [NSURL fileURLWithPath:recordPath];

    NSDictionary *recordSettings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(16000.0f),
        AVNumberOfChannelsKey: @(1),
        AVLinearPCMBitDepthKey: @(16),
        AVLinearPCMIsBigEndianKey: @(NO),
        AVLinearPCMIsFloatKey: @(NO)
    };

    NSError *recorderErr = nil;
    _audioRecorder = [[AVAudioRecorder alloc] initWithURL:recordURL settings:recordSettings error:&recorderErr];
    if (recorderErr || !_audioRecorder) {
        if (_audioRecorder) {
            [_audioRecorder release];
            _audioRecorder = nil;
        }
        [audioSession setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
        if (completion) completion(nil, 0, recorderErr ? recorderErr : [NSError errorWithDomain:@"DeskCompanionAudio" code:-3 userInfo:nil]);
        return;
    }

    _audioRecorder.delegate = self;
    _audioRecordCompletion = Block_copy(completion);
    _isRecording = YES;

    if (![_audioRecorder recordForDuration:duration]) {
        @synchronized(self) {
            _isRecording = NO;
            _audioRecorder.delegate = nil;
            [_audioRecorder release];
            _audioRecorder = nil;
            if (_audioRecordCompletion) {
                Block_release(_audioRecordCompletion);
                _audioRecordCompletion = nil;
            }
        }
        [audioSession setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
        if (completion) completion(nil, 0, [NSError errorWithDomain:@"DeskCompanionAudio" code:-4 userInfo:nil]);
        return;
    }

    // Animate audio waveform to reflect active listening
    [self setSpeaking:YES];
    [self setStatusTitle:@"AGENT LISTENING //" subtitle:@"Recording audio via iPhone 4S mic"];

    if (_audioTimeoutTimer) {
        [_audioTimeoutTimer invalidate];
        _audioTimeoutTimer = nil;
    }
    _audioTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:(duration + 1.5)
                                                          target:self
                                                        selector:@selector(audioRecordingDidTimeout:)
                                                        userInfo:_audioRecorder
                                                         repeats:NO];
}

- (void)audioRecordingDidTimeout:(NSTimer *)timer {
    @synchronized(self) {
        AVAudioRecorder *targetRecorder = (AVAudioRecorder *)[timer userInfo];
        if (_audioTimeoutTimer == timer) {
            _audioTimeoutTimer = nil;
        }
        if (_isRecording && _audioRecorder && _audioRecorder == targetRecorder) {
            if ([_audioRecorder isRecording]) {
                [_audioRecorder stop];
            }
        }
    }
}

#pragma mark - AVAudioRecorderDelegate

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder successfully:(BOOL)flag {
    [self setSpeaking:NO];
    [self setStatusTitle:@"PHYSICAL AGENT // ONLINE" subtitle:@"Awaiting multimodal input"];

    NSString *filePath = [recorder.url path];
    void (^comp)(NSString *, NSUInteger, NSError *) = nil;

    @synchronized(self) {
        if (_audioTimeoutTimer) {
            [_audioTimeoutTimer invalidate];
            _audioTimeoutTimer = nil;
        }
        _isRecording = NO;
        if (_audioRecorder) {
            _audioRecorder.delegate = nil;
            [_audioRecorder release];
            _audioRecorder = nil;
        }
        if (_audioRecordCompletion) {
            comp = _audioRecordCompletion;
            _audioRecordCompletion = nil;
        }
    }

    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
    NSUInteger fileSize = [attrs fileSize];

    if (comp) {
        if (flag && fileSize > 0) {
            comp(filePath, fileSize, nil);
        } else {
            NSError *err = [NSError errorWithDomain:@"DeskCompanionAudio" code:-5 userInfo:@{NSLocalizedDescriptionKey: @"Audio recording failed to write valid data"}];
            comp(nil, 0, err);
        }
        Block_release(comp);
    }
}

- (void)abortRecordingWithError:(NSError *)error {
    void (^comp)(NSString *, NSUInteger, NSError *) = nil;

    @synchronized(self) {
        if (_audioTimeoutTimer) {
            [_audioTimeoutTimer invalidate];
            _audioTimeoutTimer = nil;
        }
        _isRecording = NO;
        if (_audioRecorder) {
            _audioRecorder.delegate = nil;
            [_audioRecorder release];
            _audioRecorder = nil;
        }
        if (_audioRecordCompletion) {
            comp = _audioRecordCompletion;
            _audioRecordCompletion = nil;
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self setSpeaking:NO];
        [self setStatusTitle:@"PHYSICAL AGENT // ONLINE" subtitle:@"Awaiting multimodal input"];
    });

    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];

    if (comp) {
        comp(nil, 0, error ? error : [NSError errorWithDomain:@"DeskCompanionAudio" code:-6 userInfo:nil]);
        Block_release(comp);
    }
}

- (void)audioRecorderEncodeErrorDidOccur:(AVAudioRecorder *)recorder error:(NSError *)error {
    [self abortRecordingWithError:error];
}

- (void)handleAudioInterruption:(NSNotification *)notification {
    @synchronized(self) {
        NSNumber *interruptionType = [notification.userInfo objectForKey:AVAudioSessionInterruptionTypeKey];
        if ([interruptionType unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan) {
            if (_isRecording) {
                if (_audioRecorder && [_audioRecorder isRecording]) {
                    [_audioRecorder stop];
                }
                NSError *intErr = [NSError errorWithDomain:@"DeskCompanionAudio" code:-7 userInfo:@{NSLocalizedDescriptionKey: @"Audio recording was interrupted"}];
                [self abortRecordingWithError:intErr];
            }
        }
    }
}

// Pixel-Exact Retina Screen Capture
- (void)captureScreenToPath:(NSString *)path completion:(void (^)(NSString *path, NSUInteger size, NSError *err))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        UIGraphicsBeginImageContextWithOptions(self.view.bounds.size, YES, 2.0);
        [self.view.layer renderInContext:UIGraphicsGetCurrentContext()];
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        if (!img) {
            [pool drain];
            if (completion) completion(nil, 0, [NSError errorWithDomain:@"DeskCompanionScreen" code:-1 userInfo:nil]);
            return;
        }

        NSData *pngData = UIImagePNGRepresentation(img);
        BOOL written = [pngData writeToFile:path atomically:YES];
        NSUInteger len = [pngData length];
        [pool drain];

        if (written) {
            if (completion) completion(path, len, nil);
        } else {
            if (completion) completion(nil, 0, [NSError errorWithDomain:@"DeskCompanionScreen" code:-2 userInfo:nil]);
        }
    });
}

- (NSDictionary *)getTelemetry {
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    float batt = [UIDevice currentDevice].batteryLevel * 100.0f;
    UIDeviceBatteryState state = [UIDevice currentDevice].batteryState;
    NSString *stateStr = @"unknown";
    if (state == UIDeviceBatteryStateCharging) stateStr = @"charging";
    else if (state == UIDeviceBatteryStateFull) stateStr = @"full";
    else if (state == UIDeviceBatteryStateUnplugged) stateStr = @"unplugged";

    vm_size_t pagesize;
    mach_port_t host_port = mach_host_self();
    mach_msg_type_number_t host_size = sizeof(vm_statistics_data_t) / sizeof(integer_t);
    host_page_size(host_port, &pagesize);
    vm_statistics_data_t vm_stat;
    int freeMemMB = 0;
    if (host_statistics(host_port, HOST_VM_INFO, (host_info_t)&vm_stat, &host_size) == KERN_SUCCESS) {
        freeMemMB = (int)((vm_stat.free_count * pagesize) / (1024 * 1024));
    }

    return @{
        @"device": @"iPhone 4S (N94AP)",
        @"os": @"iOS 6.1.3 (10B329)",
        @"battery_percent": @((int)batt),
        @"battery_state": stateStr,
        @"screen_brightness": @([UIScreen mainScreen].brightness),
        @"free_memory_mb": @(freeMemMB),
        @"expression": (_currentExpression ? _currentExpression : @"neutral"),
        @"zen_mode": @(_zenMode),
        @"reduced_motion": @(_reducedMotion),
        @"scanline_opacity": @(_scanlineOverlay ? _scanlineOverlay.scanlineOpacity : 0.0f),
        @"left_eye_params": ProceduralEyeConfigToArray(_leftCurrentConfig),
        @"right_eye_params": ProceduralEyeConfigToArray(_rightCurrentConfig)
    };
}

- (void)dealloc {
    if (_observersAdded) {
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        _observersAdded = NO;
    }
    if (_proceduralDisplayLink) {
        [_proceduralDisplayLink invalidate];
        _proceduralDisplayLink = nil;
    }
    if (_interpolationCompletion) {
        Block_release(_interpolationCompletion);
        _interpolationCompletion = nil;
    }
    [_bgView release];
    [_statusBarPill release];
    [_connectionLabel release];
    [_clockLabel release];
    [_batteryLabel release];
    [_leftSocket release];
    [_rightSocket release];
    [_eyeContainer release];
    [_leftEye release];
    [_rightEye release];
    [_scanlineOverlay release];
    [_waveformContainer release];
    for (int i = 0; i < 5; i++) [_waveBars[i] release];
    [_thoughtCard release];
    [_statusDot release];
    [_statusTitleLabel release];
    [_statusSubtitleLabel release];
    [_clockTimer invalidate];
    [_blinkTimer invalidate];
    [_saccadeTimer invalidate];
    [_waveTimer invalidate];
    [_pruneTimer invalidate];
    if (_audioTimeoutTimer) {
        [_audioTimeoutTimer invalidate];
        _audioTimeoutTimer = nil;
    }
    [_currentExpression release];
    if (_audioRecorder) {
        if ([_audioRecorder isRecording]) [_audioRecorder stop];
        _audioRecorder.delegate = nil;
        [_audioRecorder release];
        _audioRecorder = nil;
    }
    if (_audioRecordCompletion) {
        Block_release(_audioRecordCompletion);
        _audioRecordCompletion = nil;
    }
    [super dealloc];
}

@end

// ========================================================
// TCP COMMAND SERVER (Port 5000)
// ========================================================
@interface CompanionClientContext : NSObject {
@public
    int clientFd;
    int64_t generation;
    BOOL isClosed;
}
- (id)initWithFd:(int)fd generation:(int64_t)gen;
@end

@implementation CompanionClientContext
- (id)initWithFd:(int)fd generation:(int64_t)gen {
    self = [super init];
    if (self) {
        clientFd = fd;
        generation = gen;
        isClosed = NO;
    }
    return self;
}
@end

static int64_t g_connectionGeneration = 0;

static void SafeSendAndClose(CompanionClientContext *ctx, NSData *data) {
    if (!ctx) return;
    int fdToClose = -1;
    @synchronized(ctx) {
        if (!ctx->isClosed) {
            ctx->isClosed = YES;
            fdToClose = ctx->clientFd;
            ctx->clientFd = -1;
            if (fdToClose >= 0 && data && [data length] > 0) {
                const char *buf = (const char *)[data bytes];
                size_t remaining = (size_t)[data length];
                int attempts = 0;
                while (remaining > 0 && attempts++ < 100) {
                    ssize_t sent = send(fdToClose, buf, remaining, 0);
                    if (sent <= 0) {
                        if (sent < 0 && (errno == EINTR || errno == EAGAIN)) {
                            continue;
                        }
                        break;
                    }
                    buf += sent;
                    remaining -= sent;
                }
                if (remaining == 0) {
                    send(fdToClose, "\n", 1, 0);
                }
            }
            if (fdToClose >= 0) {
                close(fdToClose);
            }
        }
    }
}

static void *SocketServerThread(void *arg) {
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) return NULL;

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(5000);

    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        close(server_fd);
        return NULL;
    }

    if (listen(server_fd, 5) < 0) {
        close(server_fd);
        return NULL;
    }

    NSLog(@"[Server] DeskCompanion socket server active on port 5000");

    while (1) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);
        int client_fd = accept(server_fd, (struct sockaddr *)&client_addr, &client_len);
        if (client_fd < 0) continue;

        // Network isolation filter: restrict ingress to loopback and private RFC1918 subnets
        uint32_t ip = ntohl(client_addr.sin_addr.s_addr);
        BOOL isLoopback = ((ip >> 24) == 127);
        BOOL isPrivate10 = ((ip >> 24) == 10);
        BOOL isPrivate172 = ((ip >> 20) == 0xAC1);
        BOOL isPrivate192 = ((ip >> 16) == 0xC0A8);
        if (!isLoopback && !isPrivate10 && !isPrivate172 && !isPrivate192) {
            close(client_fd);
            continue;
        }

        int nosigpipe = 1;
        setsockopt(client_fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
        struct timeval tv;
        tv.tv_sec = 10;
        tv.tv_usec = 0;
        setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(client_fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        int64_t gen = OSAtomicIncrement64Barrier(&g_connectionGeneration);
        CompanionClientContext *ctx = [[CompanionClientContext alloc] initWithFd:client_fd generation:gen];

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSMutableData *readBuffer = [NSMutableData data];
            char chunk[1024];
            BOOL hasNewline = NO;
            size_t frameLen = 0;

            while (readBuffer.length < 16384) {
                ssize_t bytes_read = read(ctx->clientFd, chunk, sizeof(chunk));
                if (bytes_read <= 0) break;
                [readBuffer appendBytes:chunk length:bytes_read];
                const char *raw = (const char *)[readBuffer bytes];
                for (size_t i = 0; i < readBuffer.length; i++) {
                    if (raw[i] == '\n') {
                        hasNewline = YES;
                        frameLen = i;
                        break;
                    }
                }
                if (hasNewline) break;
            }

            if (readBuffer.length > 0) {
                if (!hasNewline) frameLen = readBuffer.length;
                NSData *jsonData = [NSData dataWithBytes:[readBuffer bytes] length:frameLen];
                NSDictionary *cmdDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
                NSMutableDictionary *response = [NSMutableDictionary dictionary];

                if (cmdDict && [cmdDict isKindOfClass:[NSDictionary class]]) {
                    // Command authorization validation
                    NSString *configuredToken = [[NSUserDefaults standardUserDefaults] stringForKey:@"PhysicalAgentAuthToken"];
                    if (!configuredToken || [configuredToken length] == 0) {
                        configuredToken = [[[NSProcessInfo processInfo] environment] objectForKey:@"PHYSICAL_AGENT_AUTH_TOKEN"];
                    }
                    if (configuredToken && [configuredToken length] > 0) {
                        NSString *token = [cmdDict objectForKey:@"token"];
                        if (!token || ![token isEqualToString:configuredToken]) {
                            NSDictionary *errResp = @{@"status": @"error", @"error": @"unauthorized", @"message": @"Command authentication required"};
                            NSData *errData = [NSJSONSerialization dataWithJSONObject:errResp options:0 error:nil];
                            SafeSendAndClose(ctx, errData);
                            [ctx release];
                            return;
                        }
                    }

                    NSString *command = [cmdDict objectForKey:@"command"];
                    BOOL handledAsynchronously = NO;

                    if ([command isEqualToString:@"ping"]) {
                        [response setObject:@"pong" forKey:@"status"];
                        if (g_viewController) [response addEntriesFromDictionary:[g_viewController getTelemetry]];
                    } else if ([command isEqualToString:@"vibrate"]) {
                        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
                        [response setObject:@"vibrated" forKey:@"status"];
                    } else if ([command isEqualToString:@"sound"]) {
                        NSString *soundName = [cmdDict objectForKey:@"name"];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) [g_viewController playSoundNamed:soundName];
                        });
                        [response setObject:@"ok" forKey:@"status"];
                        [response setObject:(soundName ? soundName : @"") forKey:@"sound"];
                    } else if ([command isEqualToString:@"expression"]) {
                        NSString *exp = [cmdDict objectForKey:@"name"];
                        id durObj = [cmdDict objectForKey:@"duration"];
                        NSTimeInterval dur = (durObj && [durObj respondsToSelector:@selector(doubleValue)]) ? [durObj doubleValue] : 0.28;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) [g_viewController setExpression:exp duration:dur];
                        });
                        [response setObject:@"ok" forKey:@"status"];
                        [response setObject:(exp ? exp : @"") forKey:@"expression"];
                    } else if ([command isEqualToString:@"look_at"]) {
                        id xObj = [cmdDict objectForKey:@"x"];
                        id yObj = [cmdDict objectForKey:@"y"];
                        id durObj = [cmdDict objectForKey:@"duration"];
                        CGFloat x = (xObj && [xObj respondsToSelector:@selector(floatValue)]) ? [xObj floatValue] : 0.0f;
                        CGFloat y = (yObj && [yObj respondsToSelector:@selector(floatValue)]) ? [yObj floatValue] : 0.0f;
                        NSTimeInterval dur = (durObj && [durObj respondsToSelector:@selector(doubleValue)]) ? [durObj doubleValue] : 0.22;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) [g_viewController lookAtX:x y:y duration:dur];
                        });
                        [response setObject:@"ok" forKey:@"status"];
                        [response setObject:@(x) forKey:@"x"];
                        [response setObject:@(y) forKey:@"y"];
                    } else if ([command isEqualToString:@"procedural_eye_params"]) {
                        NSArray *leftArr = [cmdDict objectForKey:@"left"];
                        NSArray *rightArr = [cmdDict objectForKey:@"right"];
                        id durObj = [cmdDict objectForKey:@"duration"];
                        NSTimeInterval dur = (durObj && [durObj respondsToSelector:@selector(doubleValue)]) ? [durObj doubleValue] : 0.28;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) [g_viewController setProceduralParamsLeft:leftArr right:rightArr duration:dur];
                        });
                        [response setObject:@"ok" forKey:@"status"];
                    } else if ([command isEqualToString:@"scanlines"]) {
                        id opObj = [cmdDict objectForKey:@"opacity"];
                        CGFloat op = (opObj && [opObj respondsToSelector:@selector(floatValue)]) ? [opObj floatValue] : 0.12f;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) [g_viewController setScanlineOpacity:op];
                        });
                        [response setObject:@"ok" forKey:@"status"];
                        [response setObject:@(op) forKey:@"scanlines"];
                    } else if ([command isEqualToString:@"status"]) {
                        NSString *title = [cmdDict objectForKey:@"title"];
                        NSString *subtitle = [cmdDict objectForKey:@"subtitle"];
                        if (!title && [cmdDict objectForKey:@"text"]) {
                            title = [cmdDict objectForKey:@"text"];
                        }
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) [g_viewController setStatusTitle:title subtitle:subtitle];
                        });
                        [response setObject:@"ok" forKey:@"status"];
                    } else if ([command isEqualToString:@"speaking"]) {
                        id en = [cmdDict objectForKey:@"enable"];
                        if (!en || ![en isKindOfClass:[NSNumber class]] || CFGetTypeID((CFTypeRef)en) != CFBooleanGetTypeID()) {
                            [response setObject:@"invalid_parameter" forKey:@"error"];
                            [response setObject:@"'enable' parameter must be a JSON boolean (true or false)" forKey:@"details"];
                        } else {
                            BOOL isSpk = [en boolValue];
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (g_viewController) [g_viewController setSpeaking:isSpk];
                            });
                            [response setObject:@"ok" forKey:@"status"];
                        }
                    } else if ([command isEqualToString:@"zen"]) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) [g_viewController toggleZenMode];
                        });
                        [response setObject:@"ok" forKey:@"status"];
                    } else if ([command isEqualToString:@"reduced_motion"]) {
                        id en = [cmdDict objectForKey:@"enable"];
                        if (!en || ![en isKindOfClass:[NSNumber class]] || CFGetTypeID((CFTypeRef)en) != CFBooleanGetTypeID()) {
                            [response setObject:@"invalid_parameter" forKey:@"error"];
                            [response setObject:@"'enable' parameter must be a JSON boolean (true or false)" forKey:@"details"];
                        } else {
                            BOOL red = [en boolValue];
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (g_viewController) [g_viewController setReducedMotion:red];
                            });
                            [response setObject:@"ok" forKey:@"status"];
                            [response setObject:@(red) forKey:@"reduced_motion"];
                        }
                    } else if ([command isEqualToString:@"blink"]) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) [g_viewController blink];
                        });
                        [response setObject:@"ok" forKey:@"status"];
                    } else if ([command isEqualToString:@"torch"]) {
                        id en = [cmdDict objectForKey:@"enable"];
                        if (!en || ![en isKindOfClass:[NSNumber class]] || CFGetTypeID((CFTypeRef)en) != CFBooleanGetTypeID()) {
                            [response setObject:@"invalid_parameter" forKey:@"error"];
                            [response setObject:@"'enable' parameter must be a JSON boolean (true or false)" forKey:@"details"];
                        } else {
                            BOOL torchOn = [en boolValue];
                            __block BOOL ok = NO;
                            dispatch_sync(dispatch_get_main_queue(), ^{
                                if (g_viewController) ok = [g_viewController setTorch:torchOn];
                            });
                            if (ok) {
                                [response setObject:@"ok" forKey:@"status"];
                                [response setObject:@(torchOn) forKey:@"torch"];
                            } else {
                                [response setObject:@"failed" forKey:@"status"];
                                [response setObject:@"hardware_unavailable" forKey:@"error"];
                            }
                        }
                    } else if ([command isEqualToString:@"brightness"]) {
                        id lvl = [cmdDict objectForKey:@"level"];
                        float level = [lvl respondsToSelector:@selector(floatValue)] ? [lvl floatValue] : 0.5f;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [UIScreen mainScreen].brightness = level;
                        });
                        [response setObject:@"ok" forKey:@"status"];
                        [response setObject:@(level) forKey:@"brightness"];
                    } else if ([command isEqualToString:@"snapshot"]) {
                        handledAsynchronously = YES;
                        NSString *cam = [cmdDict objectForKey:@"camera"];
                        if (!cam || ![cam isKindOfClass:[NSString class]]) cam = @"back";

                        [ctx retain];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) {
                                [g_viewController takeSnapshot:cam completion:^(NSString *path, NSUInteger size, NSError *err) {
                                    NSMutableDictionary *resp = [NSMutableDictionary dictionary];
                                    if (path) {
                                        [resp setObject:@"ok" forKey:@"status"];
                                        [resp setObject:path forKey:@"path"];
                                        [resp setObject:@(size) forKey:@"size"];
                                        [resp setObject:cam forKey:@"camera"];
                                    } else {
                                        [resp setObject:@"failed" forKey:@"status"];
                                        if (err) [resp setObject:[err localizedDescription] forKey:@"error"];
                                    }
                                    NSData *data = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
                                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                        SafeSendAndClose(ctx, data);
                                        [ctx release];
                                    });
                                }];
                            } else {
                                NSMutableDictionary *resp = [NSMutableDictionary dictionaryWithObject:@"controller_unavailable" forKey:@"error"];
                                NSData *data = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
                                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                    SafeSendAndClose(ctx, data);
                                    [ctx release];
                                });
                            }
                        });
                    } else if ([command isEqualToString:@"record_audio"]) {
                        handledAsynchronously = YES;
                        NSTimeInterval duration = 3.0;
                        id durObj = [cmdDict objectForKey:@"duration"];
                        if (durObj && [durObj respondsToSelector:@selector(doubleValue)]) {
                            duration = [durObj doubleValue];
                        }
                        if (duration <= 0.0) duration = 3.0;
                        else if (duration < 0.1) duration = 0.1;
                        else if (duration > 30.0) duration = 30.0;

                        [ctx retain];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) {
                                [g_viewController recordAudioDuration:duration completion:^(NSString *path, NSUInteger size, NSError *err) {
                                    NSMutableDictionary *resp = [NSMutableDictionary dictionary];
                                    if (path) {
                                        [resp setObject:@"ok" forKey:@"status"];
                                        [resp setObject:path forKey:@"path"];
                                        [resp setObject:@(size) forKey:@"size"];
                                        [resp setObject:@(duration) forKey:@"duration"];
                                    } else {
                                        [resp setObject:@"failed" forKey:@"status"];
                                        if (err) [resp setObject:[err localizedDescription] forKey:@"error"];
                                    }
                                    NSData *data = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
                                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                        SafeSendAndClose(ctx, data);
                                        [ctx release];
                                    });
                                }];
                            } else {
                                NSMutableDictionary *resp = [NSMutableDictionary dictionaryWithObject:@"controller_unavailable" forKey:@"error"];
                                NSData *data = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
                                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                    SafeSendAndClose(ctx, data);
                                    [ctx release];
                                });
                            }
                        });
                    } else if ([command isEqualToString:@"screenshot"]) {
                        handledAsynchronously = YES;
                        NSString *shotId = [[NSProcessInfo processInfo] globallyUniqueString];
                        NSString *savePath = [NSString stringWithFormat:@"/tmp/companion_screen_%@.png", shotId];

                        [ctx retain];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) {
                                [g_viewController captureScreenToPath:savePath completion:^(NSString *path, NSUInteger size, NSError *err) {
                                    NSMutableDictionary *resp = [NSMutableDictionary dictionary];
                                    if (path) {
                                        [resp setObject:@"ok" forKey:@"status"];
                                        [resp setObject:path forKey:@"path"];
                                        [resp setObject:@(size) forKey:@"size"];
                                    } else {
                                        [resp setObject:@"failed" forKey:@"status"];
                                        if (err) [resp setObject:[err localizedDescription] forKey:@"error"];
                                    }
                                    NSData *data = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
                                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                        SafeSendAndClose(ctx, data);
                                        [ctx release];
                                    });
                                }];
                            } else {
                                NSMutableDictionary *resp = [NSMutableDictionary dictionaryWithObject:@"controller_unavailable" forKey:@"error"];
                                NSData *data = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
                                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                    SafeSendAndClose(ctx, data);
                                    [ctx release];
                                });
                            }
                        });
                    } else if ([command isEqualToString:@"telemetry"]) {
                        [response setObject:@"ok" forKey:@"status"];
                        if (g_viewController) [response addEntriesFromDictionary:[g_viewController getTelemetry]];
                    } else {
                        [response setObject:@"unknown_command" forKey:@"error"];
                    }

                    if (!handledAsynchronously) {
                        NSData *respData = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
                        SafeSendAndClose(ctx, respData);
                    }
                } else {
                    [response setObject:@"invalid_json" forKey:@"error"];
                    NSData *respData = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
                    SafeSendAndClose(ctx, respData);
                }
            } else {
                SafeSendAndClose(ctx, nil);
            }
            [ctx release];
        });
    }
    return NULL;
}

// ========================================================
// APPLICATION DELEGATE
// ========================================================
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@property (strong, nonatomic) DeskCompanionViewController *viewController;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    self.viewController = [[[DeskCompanionViewController alloc] init] autorelease];
    self.window.rootViewController = self.viewController;
    [self.window makeKeyAndVisible];

    pthread_t thread;
    pthread_create(&thread, NULL, SocketServerThread, NULL);

    return YES;
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation {
    return YES;
}

- (void)dealloc {
    [_window release];
    [_viewController release];
    [super dealloc];
}

@end

int main(int argc, char *argv[]) {
    signal(SIGPIPE, SIG_IGN);
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
