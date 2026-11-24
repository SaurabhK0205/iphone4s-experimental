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

// ========================================================
// 1. ATMOSPHERIC CANVAS DEPTH (Radial Gradient Background)
// ========================================================
@interface RadialGradientBackgroundView : UIView
@end

@implementation RadialGradientBackgroundView
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (!colorSpace) return;

    // Optical center focal point behind eyes (160, 175)
    CGPoint focalCenter = CGPointMake(self.bounds.size.width / 2.0f, 175.0f);
    CGFloat endRadius = 320.0f;

    // #080c18 deep focal core to #010204 obsidian boundary
    CGFloat components[8] = {
        0.032f, 0.047f, 0.086f, 1.0f, // Optical center core
        0.004f, 0.007f, 0.016f, 1.0f  // Obsidian canvas perimeter
    };
    CGFloat locations[2] = { 0.0f, 1.0f };

    CGGradientRef grad = CGGradientCreateWithColorComponents(colorSpace, components, locations, 2);
    if (grad) {
        CGContextDrawRadialGradient(ctx, grad, focalCenter, 0.0f, focalCenter, endRadius, kCGGradientDrawsAfterEndLocation);
        CGGradientRelease(grad);
    }
    CGColorSpaceRelease(colorSpace);
}

- (void)dealloc {
    [super dealloc];
}
@end

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

    // Entity Elements: Eyes, Iris & Dilating Pupil Core
    UIView *_eyeContainer;
    UIView *_leftEye;
    UIView *_rightEye;
    CAGradientLayer *_leftIrisGradient;
    CAGradientLayer *_rightIrisGradient;
    UIView *_leftPupilCore;
    UIView *_rightPupilCore;

    // Cornea Specular Highlights (Curved Crescent + Micro Glint)
    UIView *_leftSpecularPrimary;
    UIView *_leftSpecularSecondary;
    UIView *_rightSpecularPrimary;
    UIView *_rightSpecularSecondary;

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
    BOOL _isBlinking;
    BOOL _isPanning;
    BOOL _zenMode;
    BOOL _reducedMotion;
    NSString *_currentExpression;
    CGPoint _defaultEyeCenterLeft;
    CGPoint _defaultEyeCenterRight;
    CGRect _defaultEyeFrameLeft;
    CGRect _defaultEyeFrameRight;

    // Audio Microphone Hardware
    AVAudioRecorder *_audioRecorder;
    BOOL _isRecording;
    void (^_audioRecordCompletion)(NSString *path, NSUInteger size, NSError *err);
}

- (void)setExpression:(NSString *)expression;
- (void)setStatusTitle:(NSString *)title subtitle:(NSString *)subtitle;
- (void)blink;
- (void)setTorch:(BOOL)enable;
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

    // --- Left Eye Iris & Anatomy ---
    _leftEye = [[UIView alloc] initWithFrame:leftFrame];
    _leftEye.backgroundColor = [UIColor clearColor];
    _leftEye.layer.cornerRadius = eyeW / 2.0;
    _leftEye.layer.shadowColor = [UIColor colorWithRed:0.22 green:0.75 blue:0.98 alpha:1.0].CGColor;
    _leftEye.layer.shadowOffset = CGSizeZero;
    _leftEye.layer.shadowRadius = 14.0;
    _leftEye.layer.shadowOpacity = 0.85;
    _leftEye.clipsToBounds = YES;
    [_eyeContainer addSubview:_leftEye];

    _leftIrisGradient = [CAGradientLayer layer];
    _leftIrisGradient.frame = CGRectMake(0, 0, eyeW, eyeH);
    _leftIrisGradient.cornerRadius = eyeW / 2.0;
    _leftIrisGradient.colors = @[
        (id)[UIColor colorWithRed:0.22 green:0.75 blue:0.98 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.01 green:0.48 blue:0.80 alpha:1.0].CGColor
    ];
    [_leftEye.layer insertSublayer:_leftIrisGradient atIndex:0];

    // Left Dilating Pupil Core
    _leftPupilCore = [[UIView alloc] initWithFrame:CGRectMake((eyeW - 22.0)/2.0, (eyeH - 34.0)/2.0, 22.0, 34.0)];
    _leftPupilCore.backgroundColor = [UIColor colorWithRed:0.015 green:0.025 blue:0.045 alpha:0.95];
    _leftPupilCore.layer.cornerRadius = 11.0;
    [_leftEye addSubview:_leftPupilCore];

    // Left Specular Catchlights (Curved Crescent Primary + Micro Ambient Glint)
    _leftSpecularPrimary = [[UIView alloc] initWithFrame:CGRectMake(eyeW - 17.0, 11.0, 9.0, 7.0)];
    _leftSpecularPrimary.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    _leftSpecularPrimary.layer.cornerRadius = 3.5;
    [_leftEye addSubview:_leftSpecularPrimary];

    _leftSpecularSecondary = [[UIView alloc] initWithFrame:CGRectMake(11.0, eyeH - 19.0, 4.0, 4.0)];
    _leftSpecularSecondary.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.40];
    _leftSpecularSecondary.layer.cornerRadius = 2.0;
    [_leftEye addSubview:_leftSpecularSecondary];

    // --- Right Eye Iris & Anatomy ---
    _rightEye = [[UIView alloc] initWithFrame:rightFrame];
    _rightEye.backgroundColor = [UIColor clearColor];
    _rightEye.layer.cornerRadius = eyeW / 2.0;
    _rightEye.layer.shadowColor = [UIColor colorWithRed:0.22 green:0.75 blue:0.98 alpha:1.0].CGColor;
    _rightEye.layer.shadowOffset = CGSizeZero;
    _rightEye.layer.shadowRadius = 14.0;
    _rightEye.layer.shadowOpacity = 0.85;
    _rightEye.clipsToBounds = YES;
    [_eyeContainer addSubview:_rightEye];

    _rightIrisGradient = [CAGradientLayer layer];
    _rightIrisGradient.frame = CGRectMake(0, 0, eyeW, eyeH);
    _rightIrisGradient.cornerRadius = eyeW / 2.0;
    _rightIrisGradient.colors = @[
        (id)[UIColor colorWithRed:0.22 green:0.75 blue:0.98 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.01 green:0.48 blue:0.80 alpha:1.0].CGColor
    ];
    [_rightEye.layer insertSublayer:_rightIrisGradient atIndex:0];

    // Right Dilating Pupil Core
    _rightPupilCore = [[UIView alloc] initWithFrame:CGRectMake((eyeW - 22.0)/2.0, (eyeH - 34.0)/2.0, 22.0, 34.0)];
    _rightPupilCore.backgroundColor = [UIColor colorWithRed:0.015 green:0.025 blue:0.045 alpha:0.95];
    _rightPupilCore.layer.cornerRadius = 11.0;
    [_rightEye addSubview:_rightPupilCore];

    // Right Specular Catchlights
    _rightSpecularPrimary = [[UIView alloc] initWithFrame:CGRectMake(eyeW - 17.0, 11.0, 9.0, 7.0)];
    _rightSpecularPrimary.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    _rightSpecularPrimary.layer.cornerRadius = 3.5;
    [_rightEye addSubview:_rightSpecularPrimary];

    _rightSpecularSecondary = [[UIView alloc] initWithFrame:CGRectMake(11.0, eyeH - 19.0, 4.0, 4.0)];
    _rightSpecularSecondary.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.40];
    _rightSpecularSecondary.layer.cornerRadius = 2.0;
    [_rightEye addSubview:_rightSpecularSecondary];

    _defaultEyeCenterLeft = _leftEye.center;
    _defaultEyeCenterRight = _rightEye.center;

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

    // Timers
    _reducedMotion = [[NSUserDefaults standardUserDefaults] boolForKey:@"PhysicalAgentReducedMotion"];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAudioInterruption:)
                                                 name:AVAudioSessionInterruptionNotification
                                               object:nil];

    [self updateClock];
    _clockTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateClock) userInfo:nil repeats:YES];
    _blinkTimer = [NSTimer scheduledTimerWithTimeInterval:3.8 target:self selector:@selector(triggerRandomBlink) userInfo:nil repeats:YES];
    _saccadeTimer = [NSTimer scheduledTimerWithTimeInterval:5.5 target:self selector:@selector(triggerMicroSaccade) userInfo:nil repeats:YES];

    [UIApplication sharedApplication].idleTimerDisabled = YES;
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
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
// EMIL KOWALSKI MOTION & ANIMATION FRAMEWORK
// ========================================================
- (void)triggerRandomBlink {
    if (!_isBlinking && !_isSpeaking && ![_currentExpression isEqualToString:@"sleep"]) {
        [self blink];
    }
}

// Asymmetrical Eyelid Kinematics (82% upper lid descent, 18% lower lid rise)
- (void)blink {
    _isBlinking = YES;
    CGFloat origLeftH = _defaultEyeFrameLeft.size.height;
    CGFloat origRightH = _defaultEyeFrameRight.size.height;
    CGFloat origLeftY = _defaultEyeFrameLeft.origin.y;
    CGFloat origRightY = _defaultEyeFrameRight.origin.y;

    CGFloat closedH = 3.5;
    CGFloat deltaLeft = origLeftH - closedH;
    CGFloat deltaRight = origRightH - closedH;

    CGFloat upperDescentLeft = deltaLeft * 0.82;
    CGFloat upperDescentRight = deltaRight * 0.82;

    // Fast organic close: 75ms ease-out
    [UIView animateWithDuration:0.075 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        CGRect lFrame = self->_leftEye.frame;
        lFrame.size.height = closedH;
        lFrame.origin.y = origLeftY + upperDescentLeft;
        self->_leftEye.frame = lFrame;

        CGRect rFrame = self->_rightEye.frame;
        rFrame.size.height = closedH;
        rFrame.origin.y = origRightY + upperDescentRight;
        self->_rightEye.frame = rFrame;

        self->_leftSpecularPrimary.alpha = 0.0;
        self->_leftSpecularSecondary.alpha = 0.0;
        self->_rightSpecularPrimary.alpha = 0.0;
        self->_rightSpecularSecondary.alpha = 0.0;
        self->_leftPupilCore.alpha = 0.0;
        self->_rightPupilCore.alpha = 0.0;
    } completion:^(BOOL finished) {
        // Organic bounce open: 110ms ease-in
        [UIView animateWithDuration:0.11 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
            CGRect lFrame = self->_leftEye.frame;
            lFrame.size.height = origLeftH;
            lFrame.origin.y = origLeftY;
            self->_leftEye.frame = lFrame;

            CGRect rFrame = self->_rightEye.frame;
            rFrame.size.height = origRightH;
            rFrame.origin.y = origRightY;
            self->_rightEye.frame = rFrame;

            self->_leftSpecularPrimary.alpha = 0.85;
            self->_leftSpecularSecondary.alpha = 0.40;
            self->_rightSpecularPrimary.alpha = 0.85;
            self->_rightSpecularSecondary.alpha = 0.40;
            self->_leftPupilCore.alpha = 0.95;
            self->_rightPupilCore.alpha = 0.95;
        } completion:^(BOOL fin) {
            self->_isBlinking = NO;
        }];
    }];
}

// Organic Saccade Clusters with Parallax Cornea Catchlights
- (void)triggerMicroSaccade {
    if (_isBlinking || _isSpeaking || _isPanning || _reducedMotion || [_currentExpression isEqualToString:@"sleep"]) return;

    // Natural saccadic displacement: -4 to +4 pt horizontal, -2 to +2 pt vertical
    int rx = (int)arc4random_uniform(9) - 4;
    int ry = (int)arc4random_uniform(5) - 2;
    CGFloat dx = (CGFloat)rx;
    CGFloat dy = (CGFloat)ry;

    // 120ms rapid saccade burst
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_leftEye.center = CGPointMake(self->_defaultEyeCenterLeft.x + dx, self->_defaultEyeCenterLeft.y + dy);
        self->_rightEye.center = CGPointMake(self->_defaultEyeCenterRight.x + dx, self->_defaultEyeCenterRight.y + dy);

        // Specular catchlight parallax: cornea glints shift slightly faster than iris
        self->_leftSpecularPrimary.transform = CGAffineTransformMakeTranslation(dx * 0.25, dy * 0.25);
        self->_rightSpecularPrimary.transform = CGAffineTransformMakeTranslation(dx * 0.25, dy * 0.25);
    } completion:^(BOOL finished) {
        // Hold fixation for 1.8 seconds, then perform subtle micro-correction and return
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_isPanning) return;
            [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
                self->_leftEye.center = self->_defaultEyeCenterLeft;
                self->_rightEye.center = self->_defaultEyeCenterRight;
                self->_leftSpecularPrimary.transform = CGAffineTransformIdentity;
                self->_rightSpecularPrimary.transform = CGAffineTransformIdentity;
            } completion:nil];
        });
    }];
}

- (void)setExpression:(NSString *)expression {
    [_currentExpression release];
    _currentExpression = [expression copy];

    CGFloat screenW = 320.0;
    CGFloat eyeSpacing = 54.0;
    CGFloat eyeY = 175.0;

    // Semantic Accents
    UIColor *cyanTop = [UIColor colorWithRed:0.22 green:0.75 blue:0.98 alpha:1.0];
    UIColor *cyanBottom = [UIColor colorWithRed:0.01 green:0.48 blue:0.80 alpha:1.0];

    UIColor *amberTop = [UIColor colorWithRed:0.98 green:0.75 blue:0.18 alpha:1.0];
    UIColor *amberBottom = [UIColor colorWithRed:0.85 green:0.52 blue:0.02 alpha:1.0];

    UIColor *greenTop = [UIColor colorWithRed:0.20 green:0.92 blue:0.55 alpha:1.0];
    UIColor *greenBottom = [UIColor colorWithRed:0.04 green:0.65 blue:0.35 alpha:1.0];

    UIColor *purpleTop = [UIColor colorWithRed:0.75 green:0.45 blue:0.98 alpha:1.0];
    UIColor *purpleBottom = [UIColor colorWithRed:0.48 green:0.18 blue:0.85 alpha:1.0];

    UIColor *redTop = [UIColor colorWithRed:0.98 green:0.32 blue:0.32 alpha:1.0];
    UIColor *redBottom = [UIColor colorWithRed:0.78 green:0.08 blue:0.08 alpha:1.0];

    UIColor *dimBlueTop = [UIColor colorWithRed:0.15 green:0.25 blue:0.38 alpha:0.6];
    UIColor *dimBlueBottom = [UIColor colorWithRed:0.06 green:0.12 blue:0.20 alpha:0.6];

    [UIView animateWithDuration:0.26 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        // Reset eye transforms to identity before adjusting frames (UIKit invariant)
        self->_leftEye.transform = CGAffineTransformIdentity;
        self->_rightEye.transform = CGAffineTransformIdentity;

        if ([expression isEqualToString:@"happy"]) {
            self->_leftEye.frame = CGRectMake(screenW/2.0 - eyeSpacing - 25, eyeY - 6, 50, 56);
            self->_rightEye.frame = CGRectMake(screenW/2.0 + eyeSpacing - 25, eyeY - 6, 50, 56);
            self->_leftIrisGradient.frame = self->_leftEye.bounds;
            self->_rightIrisGradient.frame = self->_rightEye.bounds;
            self->_leftIrisGradient.colors = @[(id)greenTop.CGColor, (id)greenBottom.CGColor];
            self->_rightIrisGradient.colors = @[(id)greenTop.CGColor, (id)greenBottom.CGColor];
            self->_leftEye.layer.shadowColor = greenTop.CGColor;
            self->_rightEye.layer.shadowColor = greenTop.CGColor;
            self->_leftEye.transform = CGAffineTransformMakeRotation(-0.14);
            self->_rightEye.transform = CGAffineTransformMakeRotation(0.14);
            self->_leftPupilCore.transform = CGAffineTransformMakeScale(0.88, 0.88);
            self->_rightPupilCore.transform = CGAffineTransformMakeScale(0.88, 0.88);
            self->_leftSpecularPrimary.alpha = 0.85;
            self->_leftSpecularSecondary.alpha = 0.40;
            self->_rightSpecularPrimary.alpha = 0.85;
            self->_rightSpecularSecondary.alpha = 0.40;
            self->_statusDot.backgroundColor = greenTop;
            self->_statusDot.layer.shadowColor = greenTop.CGColor;
        } else if ([expression isEqualToString:@"surprised"]) {
            // Dilating pupil core (1.35x) and expanded curious eye
            self->_leftEye.frame = CGRectMake(screenW/2.0 - eyeSpacing - 30, eyeY - 14, 60, 84);
            self->_rightEye.frame = CGRectMake(screenW/2.0 + eyeSpacing - 30, eyeY - 14, 60, 84);
            self->_leftIrisGradient.frame = self->_leftEye.bounds;
            self->_rightIrisGradient.frame = self->_rightEye.bounds;
            self->_leftIrisGradient.colors = @[(id)amberTop.CGColor, (id)amberBottom.CGColor];
            self->_rightIrisGradient.colors = @[(id)amberTop.CGColor, (id)amberBottom.CGColor];
            self->_leftEye.layer.shadowColor = amberTop.CGColor;
            self->_rightEye.layer.shadowColor = amberTop.CGColor;
            self->_leftEye.transform = CGAffineTransformIdentity;
            self->_rightEye.transform = CGAffineTransformIdentity;
            self->_leftPupilCore.transform = CGAffineTransformMakeScale(1.35, 1.35);
            self->_rightPupilCore.transform = CGAffineTransformMakeScale(1.35, 1.35);
            self->_leftSpecularPrimary.alpha = 0.85;
            self->_leftSpecularSecondary.alpha = 0.40;
            self->_rightSpecularPrimary.alpha = 0.85;
            self->_rightSpecularSecondary.alpha = 0.40;
            self->_statusDot.backgroundColor = amberTop;
            self->_statusDot.layer.shadowColor = amberTop.CGColor;
        } else if ([expression isEqualToString:@"thinking"]) {
            self->_leftEye.frame = CGRectMake(screenW/2.0 - eyeSpacing - 22, eyeY - 18, 46, 46);
            self->_rightEye.frame = CGRectMake(screenW/2.0 + eyeSpacing - 22, eyeY - 22, 48, 50);
            self->_leftIrisGradient.frame = self->_leftEye.bounds;
            self->_rightIrisGradient.frame = self->_rightEye.bounds;
            self->_leftIrisGradient.colors = @[(id)purpleTop.CGColor, (id)purpleBottom.CGColor];
            self->_rightIrisGradient.colors = @[(id)purpleTop.CGColor, (id)purpleBottom.CGColor];
            self->_leftEye.layer.shadowColor = purpleTop.CGColor;
            self->_rightEye.layer.shadowColor = purpleTop.CGColor;
            self->_leftEye.transform = CGAffineTransformMakeRotation(0.12);
            self->_rightEye.transform = CGAffineTransformMakeRotation(0.12);
            self->_leftPupilCore.transform = CGAffineTransformMakeScale(1.10, 1.10);
            self->_rightPupilCore.transform = CGAffineTransformMakeScale(1.10, 1.10);
            self->_leftSpecularPrimary.alpha = 0.85;
            self->_leftSpecularSecondary.alpha = 0.40;
            self->_rightSpecularPrimary.alpha = 0.85;
            self->_rightSpecularSecondary.alpha = 0.40;
            self->_statusDot.backgroundColor = purpleTop;
            self->_statusDot.layer.shadowColor = purpleTop.CGColor;
        } else if ([expression isEqualToString:@"alert"]) {
            // Contracted sharp pupil core (0.65x)
            self->_leftEye.frame = CGRectMake(screenW/2.0 - eyeSpacing - 25, eyeY, 50, 76);
            self->_rightEye.frame = CGRectMake(screenW/2.0 + eyeSpacing - 25, eyeY, 50, 76);
            self->_leftIrisGradient.frame = self->_leftEye.bounds;
            self->_rightIrisGradient.frame = self->_rightEye.bounds;
            self->_leftIrisGradient.colors = @[(id)redTop.CGColor, (id)redBottom.CGColor];
            self->_rightIrisGradient.colors = @[(id)redTop.CGColor, (id)redBottom.CGColor];
            self->_leftEye.layer.shadowColor = redTop.CGColor;
            self->_rightEye.layer.shadowColor = redTop.CGColor;
            self->_leftEye.transform = CGAffineTransformMakeRotation(0.20);
            self->_rightEye.transform = CGAffineTransformMakeRotation(-0.20);
            self->_leftPupilCore.transform = CGAffineTransformMakeScale(0.65, 0.65);
            self->_rightPupilCore.transform = CGAffineTransformMakeScale(0.65, 0.65);
            self->_leftSpecularPrimary.alpha = 0.85;
            self->_leftSpecularSecondary.alpha = 0.40;
            self->_rightSpecularPrimary.alpha = 0.85;
            self->_rightSpecularSecondary.alpha = 0.40;
            self->_statusDot.backgroundColor = redTop;
            self->_statusDot.layer.shadowColor = redTop.CGColor;
        } else if ([expression isEqualToString:@"sleep"]) {
            self->_leftEye.frame = CGRectMake(screenW/2.0 - eyeSpacing - 25, eyeY + 28, 50, 4);
            self->_rightEye.frame = CGRectMake(screenW/2.0 + eyeSpacing - 25, eyeY + 28, 50, 4);
            self->_leftIrisGradient.frame = self->_leftEye.bounds;
            self->_rightIrisGradient.frame = self->_rightEye.bounds;
            self->_leftIrisGradient.colors = @[(id)dimBlueTop.CGColor, (id)dimBlueBottom.CGColor];
            self->_rightIrisGradient.colors = @[(id)dimBlueTop.CGColor, (id)dimBlueBottom.CGColor];
            self->_leftEye.layer.shadowColor = dimBlueTop.CGColor;
            self->_rightEye.layer.shadowColor = dimBlueTop.CGColor;
            self->_leftEye.transform = CGAffineTransformIdentity;
            self->_rightEye.transform = CGAffineTransformIdentity;
            self->_leftPupilCore.transform = CGAffineTransformMakeScale(0.01, 0.01);
            self->_rightPupilCore.transform = CGAffineTransformMakeScale(0.01, 0.01);
            self->_leftSpecularPrimary.alpha = 0.0;
            self->_leftSpecularSecondary.alpha = 0.0;
            self->_rightSpecularPrimary.alpha = 0.0;
            self->_rightSpecularSecondary.alpha = 0.0;
            self->_statusDot.backgroundColor = dimBlueTop;
            self->_statusDot.layer.shadowColor = dimBlueTop.CGColor;
        } else if ([expression isEqualToString:@"glance_left"]) {
            self->_leftEye.frame = CGRectMake(screenW/2.0 - eyeSpacing - 38, eyeY, 50, 76);
            self->_rightEye.frame = CGRectMake(screenW/2.0 + eyeSpacing - 38, eyeY, 50, 76);
            self->_leftIrisGradient.frame = self->_leftEye.bounds;
            self->_rightIrisGradient.frame = self->_rightEye.bounds;
            self->_leftIrisGradient.colors = @[(id)cyanTop.CGColor, (id)cyanBottom.CGColor];
            self->_rightIrisGradient.colors = @[(id)cyanTop.CGColor, (id)cyanBottom.CGColor];
            self->_leftEye.layer.shadowColor = cyanTop.CGColor;
            self->_rightEye.layer.shadowColor = cyanTop.CGColor;
            self->_leftEye.transform = CGAffineTransformIdentity;
            self->_rightEye.transform = CGAffineTransformIdentity;
            self->_leftPupilCore.transform = CGAffineTransformIdentity;
            self->_rightPupilCore.transform = CGAffineTransformIdentity;
            self->_leftSpecularPrimary.alpha = 0.85;
            self->_leftSpecularSecondary.alpha = 0.40;
            self->_rightSpecularPrimary.alpha = 0.85;
            self->_rightSpecularSecondary.alpha = 0.40;
        } else if ([expression isEqualToString:@"glance_right"]) {
            self->_leftEye.frame = CGRectMake(screenW/2.0 - eyeSpacing - 12, eyeY, 50, 76);
            self->_rightEye.frame = CGRectMake(screenW/2.0 + eyeSpacing - 12, eyeY, 50, 76);
            self->_leftIrisGradient.frame = self->_leftEye.bounds;
            self->_rightIrisGradient.frame = self->_rightEye.bounds;
            self->_leftIrisGradient.colors = @[(id)cyanTop.CGColor, (id)cyanBottom.CGColor];
            self->_rightIrisGradient.colors = @[(id)cyanTop.CGColor, (id)cyanBottom.CGColor];
            self->_leftEye.layer.shadowColor = cyanTop.CGColor;
            self->_rightEye.layer.shadowColor = cyanTop.CGColor;
            self->_leftEye.transform = CGAffineTransformIdentity;
            self->_rightEye.transform = CGAffineTransformIdentity;
            self->_leftPupilCore.transform = CGAffineTransformIdentity;
            self->_rightPupilCore.transform = CGAffineTransformIdentity;
            self->_leftSpecularPrimary.alpha = 0.85;
            self->_leftSpecularSecondary.alpha = 0.40;
            self->_rightSpecularPrimary.alpha = 0.85;
            self->_rightSpecularSecondary.alpha = 0.40;
        } else {
            // Default Neutral Stance
            self->_leftEye.frame = self->_defaultEyeFrameLeft;
            self->_rightEye.frame = self->_defaultEyeFrameRight;
            self->_leftIrisGradient.frame = self->_leftEye.bounds;
            self->_rightIrisGradient.frame = self->_rightEye.bounds;
            self->_leftIrisGradient.colors = @[(id)cyanTop.CGColor, (id)cyanBottom.CGColor];
            self->_rightIrisGradient.colors = @[(id)cyanTop.CGColor, (id)cyanBottom.CGColor];
            self->_leftEye.layer.shadowColor = cyanTop.CGColor;
            self->_rightEye.layer.shadowColor = cyanTop.CGColor;
            self->_leftEye.transform = CGAffineTransformIdentity;
            self->_rightEye.transform = CGAffineTransformIdentity;
            self->_leftPupilCore.transform = CGAffineTransformIdentity;
            self->_rightPupilCore.transform = CGAffineTransformIdentity;
            self->_leftSpecularPrimary.alpha = 0.85;
            self->_leftSpecularSecondary.alpha = 0.40;
            self->_rightSpecularPrimary.alpha = 0.85;
            self->_rightSpecularSecondary.alpha = 0.40;
            self->_statusDot.backgroundColor = greenTop;
            self->_statusDot.layer.shadowColor = greenTop.CGColor;
        }
    } completion:nil];
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
- (void)handleSingleTap:(UITapGestureRecognizer *)gesture {
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    [self playSoundNamed:@"tink"];

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

// Interactive Gaze Pan: Eyes follow finger across screen with parallax catchlights
- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.view];

    CGFloat dx = translation.x * 0.18;
    CGFloat dy = translation.y * 0.15;

    dx = fmaxf(-18.0, fminf(18.0, dx));
    dy = fmaxf(-14.0, fminf(14.0, dy));

    if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) {
        _isPanning = YES;
        _leftEye.center = CGPointMake(_defaultEyeCenterLeft.x + dx, _defaultEyeCenterLeft.y + dy);
        _rightEye.center = CGPointMake(_defaultEyeCenterRight.x + dx, _defaultEyeCenterRight.y + dy);

        // Catchlight parallax
        _leftSpecularPrimary.transform = CGAffineTransformMakeTranslation(dx * 0.22, dy * 0.22);
        _rightSpecularPrimary.transform = CGAffineTransformMakeTranslation(dx * 0.22, dy * 0.22);
    } else if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        _isPanning = NO;
        [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            self->_leftEye.center = self->_defaultEyeCenterLeft;
            self->_rightEye.center = self->_defaultEyeCenterRight;
            self->_leftSpecularPrimary.transform = CGAffineTransformIdentity;
            self->_rightSpecularPrimary.transform = CGAffineTransformIdentity;
        } completion:nil];
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

- (void)setTorch:(BOOL)enable {
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
        }
    }
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
    if (_isRecording) {
        if (completion) {
            NSError *busyErr = [NSError errorWithDomain:@"DeskCompanionAudio" code:-10 userInfo:@{NSLocalizedDescriptionKey: @"Audio recording already in progress"}];
            completion(nil, 0, busyErr);
        }
        return;
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
        [audioSession setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
        if (completion) completion(nil, 0, recorderErr ? recorderErr : [NSError errorWithDomain:@"DeskCompanionAudio" code:-3 userInfo:nil]);
        return;
    }

    _audioRecorder.delegate = self;
    _audioRecordCompletion = Block_copy(completion);
    _isRecording = YES;

    if (![_audioRecorder recordForDuration:duration]) {
        _isRecording = NO;
        _audioRecorder.delegate = nil;
        [_audioRecorder release];
        _audioRecorder = nil;
        if (_audioRecordCompletion) {
            Block_release(_audioRecordCompletion);
            _audioRecordCompletion = nil;
        }
        [audioSession setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
        if (completion) completion(nil, 0, [NSError errorWithDomain:@"DeskCompanionAudio" code:-4 userInfo:nil]);
        return;
    }

    // Animate audio waveform to reflect active listening
    [self setSpeaking:YES];
    [self setStatusTitle:@"AGENT LISTENING //" subtitle:@"Recording audio via iPhone 4S mic"];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((duration + 1.5) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_isRecording && self->_audioRecorder) {
            [self->_audioRecorder stop];
        }
    });
}

#pragma mark - AVAudioRecorderDelegate

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder successfully:(BOOL)flag {
    [self setSpeaking:NO];
    [self setStatusTitle:@"PHYSICAL AGENT // ONLINE" subtitle:@"Awaiting multimodal input"];

    NSString *filePath = [recorder.url path];
    _isRecording = NO;

    if (_audioRecorder) {
        _audioRecorder.delegate = nil;
        [_audioRecorder release];
        _audioRecorder = nil;
    }

    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
    NSUInteger fileSize = [attrs fileSize];

    if (_audioRecordCompletion) {
        void (^comp)(NSString *, NSUInteger, NSError *) = _audioRecordCompletion;
        _audioRecordCompletion = nil;
        if (flag && fileSize > 0) {
            comp(filePath, fileSize, nil);
        } else {
            NSError *err = [NSError errorWithDomain:@"DeskCompanionAudio" code:-5 userInfo:@{NSLocalizedDescriptionKey: @"Audio recording failed to write valid data"}];
            comp(nil, 0, err);
        }
        Block_release(comp);
    }
}

- (void)audioRecorderEncodeErrorDidOccur:(AVAudioRecorder *)recorder error:(NSError *)error {
    [self setSpeaking:NO];
    [self setStatusTitle:@"PHYSICAL AGENT // ONLINE" subtitle:@"Awaiting multimodal input"];
    _isRecording = NO;

    if (_audioRecorder) {
        _audioRecorder.delegate = nil;
        [_audioRecorder release];
        _audioRecorder = nil;
    }

    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];

    if (_audioRecordCompletion) {
        void (^comp)(NSString *, NSUInteger, NSError *) = _audioRecordCompletion;
        _audioRecordCompletion = nil;
        comp(nil, 0, error ? error : [NSError errorWithDomain:@"DeskCompanionAudio" code:-6 userInfo:nil]);
        Block_release(comp);
    }
}

- (void)handleAudioInterruption:(NSNotification *)notification {
    NSNumber *interruptionType = [notification.userInfo objectForKey:AVAudioSessionInterruptionTypeKey];
    if ([interruptionType unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan) {
        if (_isRecording && _audioRecorder && [_audioRecorder isRecording]) {
            [_audioRecorder stop];
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
        @"reduced_motion": @(_reducedMotion)
    };
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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
    [_leftPupilCore release];
    [_rightPupilCore release];
    [_leftSpecularPrimary release];
    [_leftSpecularSecondary release];
    [_rightSpecularPrimary release];
    [_rightSpecularSecondary release];
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

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            char buffer[4096];
            ssize_t bytes_read = read(client_fd, buffer, sizeof(buffer) - 1);
            if (bytes_read > 0) {
                buffer[bytes_read] = '\0';
                NSData *jsonData = [NSData dataWithBytes:buffer length:bytes_read];
                NSDictionary *cmdDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
                NSMutableDictionary *response = [NSMutableDictionary dictionary];

                if (cmdDict && [cmdDict isKindOfClass:[NSDictionary class]]) {
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
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) [g_viewController setExpression:exp];
                        });
                        [response setObject:@"ok" forKey:@"status"];
                        [response setObject:(exp ? exp : @"") forKey:@"expression"];
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
                        BOOL isSpk = [en respondsToSelector:@selector(boolValue)] ? [en boolValue] : NO;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) [g_viewController setSpeaking:isSpk];
                        });
                        [response setObject:@"ok" forKey:@"status"];
                    } else if ([command isEqualToString:@"zen"]) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) [g_viewController toggleZenMode];
                        });
                        [response setObject:@"ok" forKey:@"status"];
                    } else if ([command isEqualToString:@"reduced_motion"]) {
                        id en = [cmdDict objectForKey:@"enable"];
                        BOOL red = [en respondsToSelector:@selector(boolValue)] ? [en boolValue] : NO;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) [g_viewController setReducedMotion:red];
                        });
                        [response setObject:@"ok" forKey:@"status"];
                        [response setObject:@(red) forKey:@"reduced_motion"];
                    } else if ([command isEqualToString:@"blink"]) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) [g_viewController blink];
                        });
                        [response setObject:@"ok" forKey:@"status"];
                    } else if ([command isEqualToString:@"torch"]) {
                        id en = [cmdDict objectForKey:@"enable"];
                        BOOL torchOn = [en respondsToSelector:@selector(boolValue)] ? [en boolValue] : NO;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) [g_viewController setTorch:torchOn];
                        });
                        [response setObject:@"ok" forKey:@"status"];
                        [response setObject:@(torchOn) forKey:@"torch"];
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
                                    if (data) {
                                        write(client_fd, [data bytes], [data length]);
                                        write(client_fd, "\n", 1);
                                    }
                                    close(client_fd);
                                }];
                            } else {
                                NSMutableDictionary *resp = [NSMutableDictionary dictionaryWithObject:@"controller_unavailable" forKey:@"error"];
                                NSData *data = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
                                if (data) {
                                    write(client_fd, [data bytes], [data length]);
                                    write(client_fd, "\n", 1);
                                }
                                close(client_fd);
                            }
                        });
                    } else if ([command isEqualToString:@"record_audio"]) {
                        handledAsynchronously = YES;
                        NSTimeInterval duration = 3.0;
                        id durObj = [cmdDict objectForKey:@"duration"];
                        if (durObj && [durObj respondsToSelector:@selector(doubleValue)]) {
                            duration = [durObj doubleValue];
                        }
                        if (duration <= 0.1) duration = 3.0;
                        if (duration > 30.0) duration = 30.0;

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
                                    if (data) {
                                        write(client_fd, [data bytes], [data length]);
                                        write(client_fd, "\n", 1);
                                    }
                                    close(client_fd);
                                }];
                            } else {
                                NSMutableDictionary *resp = [NSMutableDictionary dictionaryWithObject:@"controller_unavailable" forKey:@"error"];
                                NSData *data = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
                                if (data) {
                                    write(client_fd, [data bytes], [data length]);
                                    write(client_fd, "\n", 1);
                                }
                                close(client_fd);
                            }
                        });
                    } else if ([command isEqualToString:@"screenshot"]) {
                        handledAsynchronously = YES;
                        NSString *shotId = [[NSProcessInfo processInfo] globallyUniqueString];
                        NSString *savePath = [NSString stringWithFormat:@"/tmp/companion_screen_%@.png", shotId];

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
                                    if (data) {
                                        write(client_fd, [data bytes], [data length]);
                                        write(client_fd, "\n", 1);
                                    }
                                    close(client_fd);
                                }];
                            } else {
                                NSMutableDictionary *resp = [NSMutableDictionary dictionaryWithObject:@"controller_unavailable" forKey:@"error"];
                                NSData *data = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
                                if (data) {
                                    write(client_fd, [data bytes], [data length]);
                                    write(client_fd, "\n", 1);
                                }
                                close(client_fd);
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
                        if (respData) {
                            write(client_fd, [respData bytes], [respData length]);
                            write(client_fd, "\n", 1);
                        }
                        close(client_fd);
                    }
                } else {
                    [response setObject:@"invalid_json" forKey:@"error"];
                    NSData *respData = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
                    if (respData) {
                        write(client_fd, [respData bytes], [respData length]);
                        write(client_fd, "\n", 1);
                    }
                    close(client_fd);
                }
            } else {
                close(client_fd);
            }
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
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
