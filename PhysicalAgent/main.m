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

@class DeskCompanionViewController;
static DeskCompanionViewController *g_viewController = nil;

@interface DeskCompanionViewController : UIViewController <UIGestureRecognizerDelegate> {
    // HUD Elements
    UIView *_statusBarPill;
    UILabel *_connectionLabel;
    UILabel *_clockLabel;
    UILabel *_batteryLabel;

    // Entity Elements
    UIView *_eyeContainer;
    UIView *_leftEye;
    UIView *_rightEye;
    UIView *_leftPupilHighlight;
    UIView *_rightPupilHighlight;

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
    BOOL _zenMode;
    NSString *_currentExpression;
    CGPoint _defaultEyeCenterLeft;
    CGPoint _defaultEyeCenterRight;

    // Camera Hardware
    AVCaptureSession *_captureSession;
    AVCaptureStillImageOutput *_stillImageOutput;
    AVCaptureDevicePosition _currentCameraPos;
    BOOL _isCameraRunning;
}

- (void)setExpression:(NSString *)expression;
- (void)setStatusTitle:(NSString *)title subtitle:(NSString *)subtitle;
- (void)blink;
- (void)setTorch:(BOOL)enable;
- (void)setSpeaking:(BOOL)speaking;
- (void)playSoundNamed:(NSString *)name;
- (void)takeSnapshot:(NSString *)cameraPosition completion:(void (^)(NSString *path, NSUInteger size, NSError *err))completion;
- (NSDictionary *)getTelemetry;
- (void)toggleZenMode;
@end

@implementation DeskCompanionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    g_viewController = self;

    // Deep obsidian canvas (#020305) - getdesign.md Linear/Raycast palette
    self.view.backgroundColor = [UIColor colorWithRed:0.01 green:0.015 blue:0.025 alpha:1.0];

    CGFloat screenW = 320.0;
    CGFloat screenH = 480.0;

    // ========================================================
    // 1. TOP STATUS BAR PILL (Frosted Hairline Card)
    // ========================================================
    _statusBarPill = [[UIView alloc] initWithFrame:CGRectMake(16, 14, screenW - 32, 28)];
    _statusBarPill.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.08 alpha:0.85];
    _statusBarPill.layer.cornerRadius = 14.0;
    _statusBarPill.layer.borderWidth = 1.0;
    _statusBarPill.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;
    [self.view addSubview:_statusBarPill];

    // Left Connection Badge
    _connectionLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, 70, 28)];
    _connectionLabel.backgroundColor = [UIColor clearColor];
    _connectionLabel.textColor = [UIColor colorWithRed:0.18 green:0.83 blue:0.98 alpha:1.0]; // Cyber Cyan
    _connectionLabel.font = [UIFont fontWithName:@"Courier-Bold" size:10.0];
    _connectionLabel.text = @"* WI-FI";
    [_statusBarPill addSubview:_connectionLabel];

    // Center Clock
    _clockLabel = [[UILabel alloc] initWithFrame:CGRectMake(80, 0, screenW - 32 - 160, 28)];
    _clockLabel.backgroundColor = [UIColor clearColor];
    _clockLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    _clockLabel.font = [UIFont fontWithName:@"Courier" size:12.0];
    _clockLabel.textAlignment = NSTextAlignmentCenter;
    [_statusBarPill addSubview:_clockLabel];

    // Right Battery
    _batteryLabel = [[UILabel alloc] initWithFrame:CGRectMake(screenW - 32 - 76, 0, 64, 28)];
    _batteryLabel.backgroundColor = [UIColor clearColor];
    _batteryLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    _batteryLabel.font = [UIFont fontWithName:@"Courier" size:10.0];
    _batteryLabel.textAlignment = NSTextAlignmentRight;
    _batteryLabel.text = @"95%";
    [_statusBarPill addSubview:_batteryLabel];

    // ========================================================
    // 2. CENTRAL ENTITY: VECTOR EYES WITH SPECULAR HIGHLIGHTS
    // ========================================================
    _eyeContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, screenW, screenH)];
    _eyeContainer.backgroundColor = [UIColor clearColor];
    [self.view addSubview:_eyeContainer];

    CGFloat eyeW = 50.0;
    CGFloat eyeH = 76.0;
    CGFloat eyeSpacing = 54.0;
    CGFloat eyeY = 175.0; // Optical center on 320x480 screen

    UIColor *cyan = [UIColor colorWithRed:0.18 green:0.83 blue:0.98 alpha:1.0];

    // Left Eye
    CGRect leftFrame = CGRectMake(screenW/2.0 - eyeSpacing - eyeW/2.0, eyeY, eyeW, eyeH);
    _leftEye = [[UIView alloc] initWithFrame:leftFrame];
    _leftEye.backgroundColor = cyan;
    _leftEye.layer.cornerRadius = eyeW / 2.0;
    _leftEye.layer.shadowColor = cyan.CGColor;
    _leftEye.layer.shadowOffset = CGSizeZero;
    _leftEye.layer.shadowRadius = 18.0;
    _leftEye.layer.shadowOpacity = 0.95;
    [_eyeContainer addSubview:_leftEye];

    // Left Pupil Specular Highlight (alive glassy glint)
    _leftPupilHighlight = [[UIView alloc] initWithFrame:CGRectMake(eyeW - 16, 12, 8, 8)];
    _leftPupilHighlight.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    _leftPupilHighlight.layer.cornerRadius = 4.0;
    [_leftEye addSubview:_leftPupilHighlight];

    // Right Eye
    CGRect rightFrame = CGRectMake(screenW/2.0 + eyeSpacing - eyeW/2.0, eyeY, eyeW, eyeH);
    _rightEye = [[UIView alloc] initWithFrame:rightFrame];
    _rightEye.backgroundColor = cyan;
    _rightEye.layer.cornerRadius = eyeW / 2.0;
    _rightEye.layer.shadowColor = cyan.CGColor;
    _rightEye.layer.shadowOffset = CGSizeZero;
    _rightEye.layer.shadowRadius = 18.0;
    _rightEye.layer.shadowOpacity = 0.95;
    [_eyeContainer addSubview:_rightEye];

    // Right Pupil Specular Highlight
    _rightPupilHighlight = [[UIView alloc] initWithFrame:CGRectMake(eyeW - 16, 12, 8, 8)];
    _rightPupilHighlight.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    _rightPupilHighlight.layer.cornerRadius = 4.0;
    [_rightEye addSubview:_rightPupilHighlight];

    _defaultEyeCenterLeft = _leftEye.center;
    _defaultEyeCenterRight = _rightEye.center;

    // ========================================================
    // 3. AUDIO SPECTRUM WAVEFORM (5 bars for voice feedback)
    // ========================================================
    CGFloat waveW = 80.0;
    CGFloat waveH = 20.0;
    _waveformContainer = [[UIView alloc] initWithFrame:CGRectMake((screenW - waveW)/2.0, eyeY + eyeH + 24.0, waveW, waveH)];
    _waveformContainer.backgroundColor = [UIColor clearColor];
    _waveformContainer.alpha = 0.0; // Hidden until speaking/listening
    [self.view addSubview:_waveformContainer];

    CGFloat barW = 4.0;
    CGFloat barGap = 12.0;
    for (int i = 0; i < 5; i++) {
        CGFloat bx = i * (barW + barGap) + 8.0;
        _waveBars[i] = [[UIView alloc] initWithFrame:CGRectMake(bx, waveH/2.0 - 2, barW, 4)];
        _waveBars[i].backgroundColor = cyan;
        _waveBars[i].layer.cornerRadius = 2.0;
        [_waveformContainer addSubview:_waveBars[i]];
    }

    // ========================================================
    // 4. BOTTOM THOUGHT CARD (getdesign.md Linear Card Style)
    // ========================================================
    CGFloat cardW = screenW - 32.0;
    CGFloat cardH = 58.0;
    _thoughtCard = [[UIView alloc] initWithFrame:CGRectMake(16, screenH - cardH - 18, cardW, cardH)];
    _thoughtCard.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.08 alpha:0.9];
    _thoughtCard.layer.cornerRadius = 16.0;
    _thoughtCard.layer.borderWidth = 1.0;
    _thoughtCard.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;
    [self.view addSubview:_thoughtCard];

    // Glowing Status Dot
    _statusDot = [[UIView alloc] initWithFrame:CGRectMake(16, 16, 8, 8)];
    _statusDot.backgroundColor = [UIColor colorWithRed:0.20 green:0.92 blue:0.55 alpha:1.0]; // Emerald
    _statusDot.layer.cornerRadius = 4.0;
    _statusDot.layer.shadowColor = [UIColor colorWithRed:0.20 green:0.92 blue:0.55 alpha:1.0].CGColor;
    _statusDot.layer.shadowOffset = CGSizeZero;
    _statusDot.layer.shadowRadius = 6.0;
    _statusDot.layer.shadowOpacity = 0.9;
    [_thoughtCard addSubview:_statusDot];

    // Status Title (Monospace Bold)
    _statusTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(34, 11, cardW - 48, 18)];
    _statusTitleLabel.backgroundColor = [UIColor clearColor];
    _statusTitleLabel.textColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    _statusTitleLabel.font = [UIFont fontWithName:@"Courier-Bold" size:12.0];
    _statusTitleLabel.text = @"PHYSICAL AGENT // ONLINE";
    [_thoughtCard addSubview:_statusTitleLabel];

    // Status Subtitle (Clean Sans)
    _statusSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(34, 30, cardW - 48, 16)];
    _statusSubtitleLabel.backgroundColor = [UIColor clearColor];
    _statusSubtitleLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    _statusSubtitleLabel.font = [UIFont fontWithName:@"HelveticaNeue" size:11.0];
    _statusSubtitleLabel.text = @"Awaiting multimodal input";
    [_thoughtCard addSubview:_statusSubtitleLabel];

    // ========================================================
    // 5. GESTURE RECOGNIZERS (Emil Kowalski Interactive Touch)
    // ========================================================
    // Pan Gesture: Eyes follow finger across screen
    UIPanGestureRecognizer *pan = [[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)] autorelease];
    pan.delegate = self;
    [self.view addGestureRecognizer:pan];

    // Single Tap: Haptic feedback + happy blink
    UITapGestureRecognizer *singleTap = [[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSingleTap:)] autorelease];
    [self.view addGestureRecognizer:singleTap];

    // Double Tap: Zen Mode toggle (dim HUD for sleep/desk ambiance)
    UITapGestureRecognizer *doubleTap = [[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)] autorelease];
    doubleTap.numberOfTapsRequired = 2;
    [self.view addGestureRecognizer:doubleTap];
    [singleTap requireGestureRecognizerToFail:doubleTap];

    // Timers
    [self updateClock];
    _clockTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateClock) userInfo:nil repeats:YES];
    _blinkTimer = [NSTimer scheduledTimerWithTimeInterval:4.0 target:self selector:@selector(triggerRandomBlink) userInfo:nil repeats:YES];
    _saccadeTimer = [NSTimer scheduledTimerWithTimeInterval:6.5 target:self selector:@selector(triggerMicroSaccade) userInfo:nil repeats:YES];

    [UIApplication sharedApplication].idleTimerDisabled = YES;
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
}

- (void)updateClock {
    NSDateFormatter *df = [[[NSDateFormatter alloc] init] autorelease];
    [df setDateFormat:@"HH:mm:ss"];
    _clockLabel.text = [df stringFromDate:[NSDate date]];

    float batt = [UIDevice currentDevice].batteryLevel * 100.0f;
    UIDeviceBatteryState bState = [UIDevice currentDevice].batteryState;
    if (bState == UIDeviceBatteryStateCharging || bState == UIDeviceBatteryStateFull) {
        _connectionLabel.text = @"* USB LINK";
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
    if (!_isBlinking && !_isSpeaking) {
        [self blink];
    }
}

- (void)blink {
    _isBlinking = YES;
    CGFloat origLeftH = _leftEye.bounds.size.height;
    CGFloat origRightH = _rightEye.bounds.size.height;

    // Fast organic close: 80ms ease-out
    [UIView animateWithDuration:0.08 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        CGRect lFrame = self->_leftEye.frame;
        lFrame.size.height = 4.0;
        lFrame.origin.y += (origLeftH - 4.0) / 2.0;
        self->_leftEye.frame = lFrame;

        CGRect rFrame = self->_rightEye.frame;
        rFrame.size.height = 4.0;
        rFrame.origin.y += (origRightH - 4.0) / 2.0;
        self->_rightEye.frame = rFrame;
        self->_leftPupilHighlight.alpha = 0.0;
        self->_rightPupilHighlight.alpha = 0.0;
    } completion:^(BOOL finished) {
        // Organic bounce open: 110ms ease-in
        [UIView animateWithDuration:0.11 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
            CGRect lFrame = self->_leftEye.frame;
            lFrame.size.height = origLeftH;
            lFrame.origin.y -= (origLeftH - 4.0) / 2.0;
            self->_leftEye.frame = lFrame;

            CGRect rFrame = self->_rightEye.frame;
            rFrame.size.height = origRightH;
            rFrame.origin.y -= (origRightH - 4.0) / 2.0;
            self->_rightEye.frame = rFrame;
            self->_leftPupilHighlight.alpha = 0.75;
            self->_rightPupilHighlight.alpha = 0.75;
        } completion:^(BOOL fin) {
            self->_isBlinking = NO;
        }];
    }];
}

// Micro-saccades: subtle natural eye wandering (1-3px gaze shift)
- (void)triggerMicroSaccade {
    if (_isBlinking || _isSpeaking || [_currentExpression isEqualToString:@"sleep"]) return;

    CGFloat dx = (arc4random_uniform(7) - 3.0); // -3 to +3 pt
    CGFloat dy = (arc4random_uniform(5) - 2.0);

    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_leftEye.center = CGPointMake(self->_defaultEyeCenterLeft.x + dx, self->_defaultEyeCenterLeft.y + dy);
        self->_rightEye.center = CGPointMake(self->_defaultEyeCenterRight.x + dx, self->_defaultEyeCenterRight.y + dy);
    } completion:^(BOOL finished) {
        // Return gently to center after 1.2s
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                self->_leftEye.center = self->_defaultEyeCenterLeft;
                self->_rightEye.center = self->_defaultEyeCenterRight;
            }];
        });
    }];
}

- (void)setExpression:(NSString *)expression {
    [_currentExpression release];
    _currentExpression = [expression copy];

    CGFloat screenW = 320.0;
    CGFloat eyeSpacing = 54.0;
    CGFloat eyeY = 175.0;

    UIColor *cyan = [UIColor colorWithRed:0.18 green:0.83 blue:0.98 alpha:1.0];
    UIColor *amber = [UIColor colorWithRed:1.00 green:0.75 blue:0.10 alpha:1.0];
    UIColor *green = [UIColor colorWithRed:0.20 green:0.92 blue:0.55 alpha:1.0];
    UIColor *purple = [UIColor colorWithRed:0.80 green:0.35 blue:0.98 alpha:1.0];
    UIColor *red = [UIColor colorWithRed:1.00 green:0.25 blue:0.25 alpha:1.0];
    UIColor *dimBlue = [UIColor colorWithRed:0.10 green:0.40 blue:0.60 alpha:0.6];

    [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        if ([expression isEqualToString:@"happy"]) {
            // Arched, joyful smiling eyes
            self->_leftEye.frame = CGRectMake(screenW/2.0 - eyeSpacing - 25, eyeY - 6, 50, 56);
            self->_rightEye.frame = CGRectMake(screenW/2.0 + eyeSpacing - 25, eyeY - 6, 50, 56);
            self->_leftEye.backgroundColor = green;
            self->_rightEye.backgroundColor = green;
            self->_leftEye.layer.shadowColor = green.CGColor;
            self->_rightEye.layer.shadowColor = green.CGColor;
            self->_leftEye.transform = CGAffineTransformMakeRotation(-0.16);
            self->_rightEye.transform = CGAffineTransformMakeRotation(0.16);
            self->_statusDot.backgroundColor = green;
            self->_statusDot.layer.shadowColor = green.CGColor;
        } else if ([expression isEqualToString:@"surprised"]) {
            // Expanded, inquisitive circular eyes
            self->_leftEye.frame = CGRectMake(screenW/2.0 - eyeSpacing - 33, eyeY - 16, 66, 88);
            self->_rightEye.frame = CGRectMake(screenW/2.0 + eyeSpacing - 33, eyeY - 16, 66, 88);
            self->_leftEye.backgroundColor = amber;
            self->_rightEye.backgroundColor = amber;
            self->_leftEye.layer.shadowColor = amber.CGColor;
            self->_rightEye.layer.shadowColor = amber.CGColor;
            self->_leftEye.transform = CGAffineTransformIdentity;
            self->_rightEye.transform = CGAffineTransformIdentity;
            self->_statusDot.backgroundColor = amber;
            self->_statusDot.layer.shadowColor = amber.CGColor;
        } else if ([expression isEqualToString:@"thinking"]) {
            // Angular squint looking upward-right
            self->_leftEye.frame = CGRectMake(screenW/2.0 - eyeSpacing - 22, eyeY - 20, 46, 42);
            self->_rightEye.frame = CGRectMake(screenW/2.0 + eyeSpacing - 22, eyeY - 24, 50, 48);
            self->_leftEye.backgroundColor = purple;
            self->_rightEye.backgroundColor = purple;
            self->_leftEye.layer.shadowColor = purple.CGColor;
            self->_rightEye.layer.shadowColor = purple.CGColor;
            self->_leftEye.transform = CGAffineTransformMakeRotation(0.12);
            self->_rightEye.transform = CGAffineTransformMakeRotation(0.12);
            self->_statusDot.backgroundColor = purple;
            self->_statusDot.layer.shadowColor = purple.CGColor;
        } else if ([expression isEqualToString:@"alert"]) {
            // Focused crimson warning
            self->_leftEye.frame = CGRectMake(screenW/2.0 - eyeSpacing - 25, eyeY, 50, 76);
            self->_rightEye.frame = CGRectMake(screenW/2.0 + eyeSpacing - 25, eyeY, 50, 76);
            self->_leftEye.backgroundColor = red;
            self->_rightEye.backgroundColor = red;
            self->_leftEye.layer.shadowColor = red.CGColor;
            self->_rightEye.layer.shadowColor = red.CGColor;
            self->_leftEye.transform = CGAffineTransformMakeRotation(0.22);
            self->_rightEye.transform = CGAffineTransformMakeRotation(-0.22);
            self->_statusDot.backgroundColor = red;
            self->_statusDot.layer.shadowColor = red.CGColor;
        } else if ([expression isEqualToString:@"sleep"]) {
            // Dimmed resting slits
            self->_leftEye.frame = CGRectMake(screenW/2.0 - eyeSpacing - 25, eyeY + 28, 50, 6);
            self->_rightEye.frame = CGRectMake(screenW/2.0 + eyeSpacing - 25, eyeY + 28, 50, 6);
            self->_leftEye.backgroundColor = dimBlue;
            self->_rightEye.backgroundColor = dimBlue;
            self->_leftEye.layer.shadowColor = dimBlue.CGColor;
            self->_rightEye.layer.shadowColor = dimBlue.CGColor;
            self->_leftEye.transform = CGAffineTransformIdentity;
            self->_rightEye.transform = CGAffineTransformIdentity;
            self->_statusDot.backgroundColor = dimBlue;
            self->_statusDot.layer.shadowColor = dimBlue.CGColor;
        } else if ([expression isEqualToString:@"glance_left"]) {
            self->_leftEye.frame = CGRectMake(screenW/2.0 - eyeSpacing - 38, eyeY, 50, 76);
            self->_rightEye.frame = CGRectMake(screenW/2.0 + eyeSpacing - 38, eyeY, 50, 76);
            self->_leftEye.backgroundColor = cyan;
            self->_rightEye.backgroundColor = cyan;
            self->_leftEye.layer.shadowColor = cyan.CGColor;
            self->_rightEye.layer.shadowColor = cyan.CGColor;
            self->_leftEye.transform = CGAffineTransformIdentity;
            self->_rightEye.transform = CGAffineTransformIdentity;
        } else if ([expression isEqualToString:@"glance_right"]) {
            self->_leftEye.frame = CGRectMake(screenW/2.0 - eyeSpacing - 12, eyeY, 50, 76);
            self->_rightEye.frame = CGRectMake(screenW/2.0 + eyeSpacing - 12, eyeY, 50, 76);
            self->_leftEye.backgroundColor = cyan;
            self->_rightEye.backgroundColor = cyan;
            self->_leftEye.layer.shadowColor = cyan.CGColor;
            self->_rightEye.layer.shadowColor = cyan.CGColor;
            self->_leftEye.transform = CGAffineTransformIdentity;
            self->_rightEye.transform = CGAffineTransformIdentity;
        } else {
            // Default Neutral
            self->_leftEye.frame = CGRectMake(screenW/2.0 - eyeSpacing - 25, eyeY, 50, 76);
            self->_rightEye.frame = CGRectMake(screenW/2.0 + eyeSpacing - 25, eyeY, 50, 76);
            self->_leftEye.backgroundColor = cyan;
            self->_rightEye.backgroundColor = cyan;
            self->_leftEye.layer.shadowColor = cyan.CGColor;
            self->_rightEye.layer.shadowColor = cyan.CGColor;
            self->_leftEye.transform = CGAffineTransformIdentity;
            self->_rightEye.transform = CGAffineTransformIdentity;
            self->_statusDot.backgroundColor = green;
            self->_statusDot.layer.shadowColor = green.CGColor;
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

    // Immediate tactile squash: scale(0.93) over 80ms
    [UIView animateWithDuration:0.08 animations:^{
        self->_eyeContainer.transform = CGAffineTransformMakeScale(0.93, 0.93);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.15 animations:^{
            self->_eyeContainer.transform = CGAffineTransformIdentity;
        }];
    }];

    [self blink];
    [self setExpression:@"happy"];
    [self setStatusTitle:@"PHYSICAL TOUCH DETECTED" subtitle:@"Companion acknowledged your press"];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self setExpression:@"neutral"];
        [self setStatusTitle:@"PHYSICAL AGENT // ONLINE" subtitle:@"Awaiting multimodal input"];
    });
}

// Interactive Gaze Pan: Eyes follow finger across screen
- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.view];

    // Dampen translation so eyes don't leave the head bounds
    CGFloat dx = translation.x * 0.18;
    CGFloat dy = translation.y * 0.15;

    dx = fmaxf(-18.0, fminf(18.0, dx));
    dy = fmaxf(-14.0, fminf(14.0, dy));

    if (gesture.state == UIGestureRecognizerStateChanged) {
        _leftEye.center = CGPointMake(_defaultEyeCenterLeft.x + dx, _defaultEyeCenterLeft.y + dy);
        _rightEye.center = CGPointMake(_defaultEyeCenterRight.x + dx, _defaultEyeCenterRight.y + dy);
    } else if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        // Smooth spring return to center
        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            self->_leftEye.center = self->_defaultEyeCenterLeft;
            self->_rightEye.center = self->_defaultEyeCenterRight;
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
// HARDWARE ACTUATORS & SENSORS
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
        [device lockForConfiguration:nil];
        if (enable) {
            [device setTorchMode:AVCaptureTorchModeOn];
        } else {
            [device setTorchMode:AVCaptureTorchModeOff];
        }
        [device unlockForConfiguration];
    }
}

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
            NSString *savePath = @"/tmp/companion_snapshot.jpg";
            [jpeg writeToFile:savePath atomically:YES];
            [self playSoundNamed:@"shutter"];
            if (completion) completion(savePath, [jpeg length], nil);
        }];
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
        @"zen_mode": @(_zenMode)
    };
}

- (void)dealloc {
    [_statusBarPill release];
    [_connectionLabel release];
    [_clockLabel release];
    [_batteryLabel release];
    [_eyeContainer release];
    [_leftEye release];
    [_rightEye release];
    [_leftPupilHighlight release];
    [_rightPupilHighlight release];
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
    if (_captureSession) {
        [_captureSession stopRunning];
        [_captureSession release];
    }
    [_stillImageOutput release];
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
                        [response setObject:soundName forKey:@"sound"];
                    } else if ([command isEqualToString:@"expression"]) {
                        NSString *exp = [cmdDict objectForKey:@"name"];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) [g_viewController setExpression:exp];
                        });
                        [response setObject:@"ok" forKey:@"status"];
                        [response setObject:exp forKey:@"expression"];
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
                        BOOL isSpk = [[cmdDict objectForKey:@"enable"] boolValue];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) [g_viewController setSpeaking:isSpk];
                        });
                        [response setObject:@"ok" forKey:@"status"];
                    } else if ([command isEqualToString:@"zen"]) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) [g_viewController toggleZenMode];
                        });
                        [response setObject:@"ok" forKey:@"status"];
                    } else if ([command isEqualToString:@"blink"]) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) [g_viewController blink];
                        });
                        [response setObject:@"ok" forKey:@"status"];
                    } else if ([command isEqualToString:@"torch"]) {
                        BOOL torchOn = [[cmdDict objectForKey:@"enable"] boolValue];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) [g_viewController setTorch:torchOn];
                        });
                        [response setObject:@"ok" forKey:@"status"];
                        [response setObject:@(torchOn) forKey:@"torch"];
                    } else if ([command isEqualToString:@"brightness"]) {
                        float level = [[cmdDict objectForKey:@"level"] floatValue];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [UIScreen mainScreen].brightness = level;
                        });
                        [response setObject:@"ok" forKey:@"status"];
                        [response setObject:@(level) forKey:@"brightness"];
                    } else if ([command isEqualToString:@"snapshot"]) {
                        NSString *cam = [cmdDict objectForKey:@"camera"];
                        if (!cam) cam = @"back";

                        __block BOOL finished = NO;
                        __block NSString *snapPath = nil;
                        __block NSUInteger snapSize = 0;
                        __block NSError *snapErr = nil;

                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (g_viewController) {
                                [g_viewController takeSnapshot:cam completion:^(NSString *path, NSUInteger size, NSError *err) {
                                    snapPath = [path copy];
                                    snapSize = size;
                                    snapErr = [err retain];
                                    finished = YES;
                                }];
                            } else {
                                finished = YES;
                            }
                        });

                        int waited = 0;
                        while (!finished && waited < 50) {
                            usleep(100000); // 100ms
                            waited++;
                        }

                        if (snapPath) {
                            [response setObject:@"ok" forKey:@"status"];
                            [response setObject:snapPath forKey:@"path"];
                            [response setObject:@(snapSize) forKey:@"size"];
                            [response setObject:cam forKey:@"camera"];
                            [snapPath release];
                        } else {
                            [response setObject:@"failed" forKey:@"status"];
                            if (snapErr) [response setObject:[snapErr localizedDescription] forKey:@"error"];
                        }
                        if (snapErr) [snapErr release];
                    } else if ([command isEqualToString:@"telemetry"]) {
                        [response setObject:@"ok" forKey:@"status"];
                        if (g_viewController) [response addEntriesFromDictionary:[g_viewController getTelemetry]];
                    } else {
                        [response setObject:@"unknown_command" forKey:@"error"];
                    }
                } else {
                    [response setObject:@"invalid_json" forKey:@"error"];
                }

                NSData *respData = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
                if (respData) {
                    write(client_fd, [respData bytes], [respData length]);
                    write(client_fd, "\n", 1);
                }
            }
            close(client_fd);
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
