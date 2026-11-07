// claude-touchbar — a Claude mascot that paces the Touch Bar and reacts to how
// much of your usage window you have burned.
//
// The app holds no credentials and opens no sockets: it shells out to
// ~/bin/claude-touchbar.sh --raw and draws the three numbers it prints. That
// script is the only thing that touches the keychain, via /usr/bin/security,
// which is already on the item's ACL — so nothing ever prompts.
//
// Build & run:  make run
//
// Why private API: a Control Strip tray item is a fixed narrow slot with no
// width control of any kind (checked the public headers and every private
// method on NSTouchBarItem — none exist). A wide surface is only reachable via
// +[NSTouchBar presentSystemModalTouchBar:placement:systemTrayItemIdentifier:].
// placement 0 shares the bar with the Control Strip; placement 1 covers it.

#import <Cocoa/Cocoa.h>
#import "clawd_presets.h"
#import "mascot_physics.h"
#import "usage_model.h"
#import "lens_motion.h"
#import "effects.h"
#import "night_sky.h"
#import "gpt_sprite.h"
#import <string.h>
#import "usage_parser.h"

// Mood pools use indices 0...12. Refuse a stale/partial generated header at
// build time instead of allowing an out-of-bounds read at runtime.
_Static_assert(sizeof(kClawdClips) / sizeof(kClawdClips[0]) == 13,
               "Expected all 13 Clawd clips; regenerate with make assets");

extern void DFRSystemModalShowsCloseBoxWhenFrontMost(BOOL show);

@interface NSTouchBar (PrivateSPI)
+ (void)presentSystemModalTouchBar:(NSTouchBar *)bar
                         placement:(long long)placement
          systemTrayItemIdentifier:(NSTouchBarItemIdentifier)ident;
+ (void)dismissSystemModalTouchBar:(NSTouchBar *)bar;
@end

static NSTouchBarItemIdentifier const kSceneID = @"local.claude-touchbar.scene";
static NSString *const kScript = @"~/bin/claude-touchbar.sh --raw";

// Measured with `make ruler`, which draws ticks at fixed coordinates: the last
// legible label is 600, so that is the usable width beside the Control Strip.
// The window reports 685pt, but part of that is never presented — trusting the
// window figure clipped the third readout cell clean off.
static CGFloat const kSceneW = 600.0;
static CGFloat const kSceneH = 30.0;
static double  const kFPS    = 15.0;    // both reference pet apps land at 14-18

// Readout: every limit gets an identical cell — label, percentage, bar — laid
// out side by side so they can be compared at a glance. Earlier versions gave
// 5h and 7d a row each and demoted the per-model cap to a bare number with no
// bar, which made the one number you could not compare the odd one out.
#define READ_W    380.0
#define READ_X    (kSceneW - READ_W - 8)   // right-aligned: usage is the thing
                                           // you look for, so it sits where the
                                           // eye lands last and stays put
#define CELL_GAP    6.0
// 30pt of height only fits two tiers. A third one for the countdown pushed the
// labels off the top edge, so the countdown rides alongside the first label.
// The detail panel that opens when a bar is touched. One row of text above a
// timeline of the whole window; the ring gauge sits at the left.
#define PANEL_RING_X   (READ_X + 15.0)
#define PANEL_TEXT_X   (READ_X + 34.0)
#define PANEL_TRACK_X0 (READ_X + 34.0)
#define PANEL_TRACK_X1 (READ_X + 236.0)
#define PANEL_RIGHT    (READ_X + READ_W - 6.0)
#define BAR_Y       3.0
#define BAR_H       8.0
#define TEXT_Y     14.0

#pragma mark - Mood

// Mood is a pure function of the 5h burn: the pet's behaviour IS the gauge.
typedef NS_ENUM(NSInteger, Mood) { MoodCalm, MoodBrisk, MoodTired, MoodPanic };

static Mood MoodForUsage(int p5) {
    if (p5 >= 85) return MoodPanic;
    if (p5 >= 60) return MoodTired;
    if (p5 >= 30) return MoodBrisk;
    return MoodCalm;
}

static CGFloat SpeedForMood(Mood m) {
    switch (m) {
        case MoodCalm:  return 34.0;    // points per second
        case MoodBrisk: return 62.0;
        case MoodTired: return 20.0;    // worn out, slows down
        case MoodPanic: return 96.0;    // running around
    }
}

#pragma mark - Scene

// Clawd either paces (drawn from the sprite sheet below) or stops to perform a
// canned animation lifted straight out of Claude.app's own assets.
typedef NS_ENUM(NSInteger, Act) { ActWalk, ActClip, ActJuggle };

// Which official clip suits each mood. Indices follow kClawdClips order:
// 0 breathe 1 blink 2 look_around 3 wink 4 surprise 5 sleep 6 bounce 7 sway 8 think
// Pools per mood, with the previous pick excluded so the same clip never runs
// twice in a row. Panic used to be a single clip on a short cycle, which is the
// worst case: at high usage you see one animation on repeat.
static int ClipForMood(Mood m, int previous) {
    static const int calm[]  = {0,1,2,9,3};        // idle, laptop, wink
    static const int brisk[] = {6,7,3,10,11,12,2}; // dancing + DJ + a glance
    static const int tired[] = {8,5,9,0,1};        // thinking, sleeping, breathing
    static const int panic[] = {4,6,10,12,7};      // startled, then frantic motion

    const int *pool; int n;
    switch (m) {
        case MoodCalm:  pool = calm;  n = sizeof(calm)  / sizeof(int); break;
        case MoodBrisk: pool = brisk; n = sizeof(brisk) / sizeof(int); break;
        case MoodTired: pool = tired; n = sizeof(tired) / sizeof(int); break;
        default:        pool = panic; n = sizeof(panic) / sizeof(int); break;
    }
    for (int tries = 0; tries < 8; tries++) {
        int pick = pool[arc4random_uniform(n)];
        if (pick != previous && pick >= 0 && pick < kClawdClipCount) return pick;
    }
    return pool[0] < kClawdClipCount ? pool[0] : 0;
}

// The healthy-state colour belongs to the provider: Claude is orange, the
// others (ChatGPT/Codex) stay blue. Warning amber and alarm red are shared, so
// "running low" reads the same whichever account it is.
static NSColor *ProviderAccent(NSString *provider, BOOL lens) {
    if ([provider isEqualToString:@"claude"])
        return lens ? [NSColor colorWithSRGBRed:1.00 green:0.58 blue:0.42 alpha:1]
                    : [NSColor colorWithSRGBRed:0.851 green:0.467 blue:0.341 alpha:1];   // #D97757
    return lens ? [NSColor colorWithSRGBRed:0.35 green:0.72 blue:1 alpha:1]
                : [NSColor colorWithSRGBRed:0.173 green:0.533 blue:0.945 alpha:1];
}

@interface PetView : NSView
@property (nonatomic) int p5, p7, resetMin, reset7dMin, ageSec, scopedPct, longDays, codexLongDays;
@property (nonatomic, copy) NSString *plan, *codexPlan;   // subscription level tokens, nil if unknown
@property (nonatomic, copy) NSString *scopedName;   // per-model weekly cap (e.g. Fable)
@property (nonatomic, copy) NSString *state;   // ok | stale | expired | none
@property (nonatomic) int codexP5, codexP7, codexResetMin, codexReset7dMin, codexAgeSec;
@property (nonatomic, copy) NSString *codexState;
@property (nonatomic) BOOL codexHaveData;
@property (nonatomic) BOOL demoMode;
@property (nonatomic) CGFloat x, dir, phase;
@property (nonatomic) CGFloat gptX, gptDir, gptPhase, gptKick;
@property (nonatomic) GPTActivity gptActivity;
@property (nonatomic) CGFloat claudeTapT, gptTapT;
// GPT's life signs: blinks on its own clock, dozes after a long rest, grins
// when tapped, startles when grabbed or flung.
@property (nonatomic) double gptBlinkT, gptNextBlink, gptRestT, gptHappyT;
@property (nonatomic) NSInteger activeUsageCell;
@property (nonatomic) CGFloat usageTapT;
@property (nonatomic, strong) UsageLens *lens;
@property (nonatomic, copy) NSArray *lensCell;
@property (nonatomic, copy) NSString *lensLayout;
@property (nonatomic, strong) NSDate *lensResetDate;
@property (nonatomic, strong) id lensTouchIdentity;
@property (nonatomic) double lensAmbient;
@property (nonatomic) NSUInteger nearResetMask;
@property (nonatomic) double resetLookTime;
- (NSArray<NSArray *> *)usageCells;
- (BOOL)beginLensAt:(CGFloat)x;
- (void)advanceLens:(double)dt;
@property (nonatomic) BOOL haveData;
@property (nonatomic) Act act;
@property (nonatomic) NSInteger clip;           // frame index within the clip
@property (nonatomic) NSInteger clipIdx;        // which clip in kClawdClips
@property (nonatomic) NSTimeInterval clipT, sinceAct;
@property (nonatomic) CGFloat ballY, ballV;   // juggled ball: height above his head, velocity
@property (nonatomic) BOOL dragging;
@property (nonatomic) MascotTarget dragTarget;
@property (nonatomic) CGFloat grabDX, grabStartX, dragVX, lastDragX, throwVX, wiggleT;
@property (nonatomic) CGFloat nextActAt;
@property (nonatomic) NSInteger lastClipIdx, clipLoops;
// Effects ("juice"). Motion lives in effects.m; this view only triggers and draws.
@property (nonatomic) BOOL fxCountUp;                  // new readings count up from 0
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *shownRemaining, *fxTargets, *fxPrevTargets;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *cellFrames;
@property (nonatomic) double fxClock, glossAt, collisionCooldown;
@property (nonatomic) CGFloat claudeSpin, gptSpin;     // 0..1 coin-flip progress on a combo
@property (nonatomic) CGFloat claudeBadgeT, gptBadgeT; // "×3" combo badge
@property (nonatomic) int claudeBadgeN, gptBadgeN;
@property (nonatomic) CGFloat claudeDizzyT, gptDizzyT;   // tapped silly: stars orbit, no more hops
- (void)advanceFX:(double)dt;
- (void)tapMascot:(MascotTarget)target;
@end

@implementation PetView {
    FXSystem *_fx;
    FXHop _claudeHop, _gptHop;
    NightSky *_sky;
}

- (void)dealloc { free(_fx); free(_sky); }

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _x = 40; _dir = 1; _p5 = 0; _p7 = 0; _resetMin = -1; _reset7dMin = -1; _longDays = 7; _codexLongDays = 7;
        _gptX = 155; _gptDir = -1;
        _gptActivity = (GPTActivity){NO, 0, 3.6};
        _gptNextBlink = 2.0;
        _activeUsageCell = -1;
        _lens = [UsageLens new];
        _codexP5 = 0; _codexP7 = 0; _codexResetMin = -1; _codexReset7dMin = -1;
        _state = @"none"; _codexState = @"none";
        _act = ActWalk;
        _nextActAt = 4.0;
        _lastClipIdx = -1;
        _fx = calloc(1, sizeof(FXSystem));
        FXInit(_fx, 0x5eed1234u);
        FXHopInit(&_claudeHop); FXHopInit(&_gptHop);
        _sky = calloc(1, sizeof(NightSky));
        NightSkyInit(_sky, READ_X, kSceneH, 0x57a55u);
        _shownRemaining = [NSMutableDictionary new];
        _fxTargets = [NSMutableDictionary new];
        _fxPrevTargets = [NSMutableDictionary new];
        _cellFrames = [NSMutableDictionary new];
        _glossAt = 2.5;
        // Without this the view gets direct touches only intermittently.
        self.allowedTouchTypes = NSTouchTypeMaskDirect;
    }
    return self;
}

- (BOOL)isFlipped { return NO; }

// The system resizes this view to whatever the bar actually offers; asking for
// more just gets clipped. Report the real number instead of guessing.
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    // Warn if a future macOS gives us a different bar than the one this was
    // sized against, instead of silently drawing off-screen.
    CGFloat win = self.window ? NSWidth(self.window.frame) : 0;
    if (win > 0 && kSceneW > win)
        NSLog(@"claude-touchbar: scene %.0fpt wider than the %.0fpt bar — content will be clipped", kSceneW, win);
}
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

- (BOOL)beginLensAt:(CGFloat)tx {
    NSArray *cells = [self usageCells];
    CGFloat w = (READ_W - CELL_GAP * (cells.count - 1)) / MAX(1, cells.count);
    NSInteger i = (NSInteger)floor((tx - READ_X) / (w + CELL_GAP));
    CGFloat start = READ_X + i * (w + CELL_GAP);
    if (tx < READ_X || i < 0 || i >= cells.count || tx > start + w) return NO;
    if ([cells[i][1] intValue] < 0) return NO;
    self.lensCell = cells[i];
    NSMutableArray *names = [NSMutableArray new];
    for (NSArray *cell in cells) [names addObject:cell[0]];
    self.lensLayout = [names componentsJoinedByString:@"|"];
    int reset = [self.lensCell[3] intValue];
    self.lensResetDate = reset < 0 ? nil : [NSDate dateWithTimeIntervalSinceNow:reset * 60.0];
    // Scrubbing moves a forecast cursor along the panel's timeline.
    [self.lens beginAt:tx minimum:PANEL_TRACK_X0 maximum:PANEL_TRACK_X1];
    self.activeUsageCell = -1; self.usageTapT = 0;
    self.needsDisplay = YES;
    return YES;
}

- (void)advanceLens:(double)dt {
    BOOL visible = self.lens.visible;
    [self.lens advance:dt];
    self.lensAmbient += dt;
    self.resetLookTime = MAX(0, self.resetLookTime - dt);
    int reset[] = {self.resetMin, self.reset7dMin, self.codexResetMin, self.codexReset7dMin};
    BOOL ready[] = {self.haveData && [self.state isEqualToString:@"ok"],
                    self.codexHaveData && [self.codexState isEqualToString:@"ok"]};
    NSUInteger near = 0;
    for (int i = 0; i < 4; i++) if (ready[i / 2] && reset[i] > 0 && reset[i] <= 30) near |= 1 << i;
    if (near & ~self.nearResetMask) self.resetLookTime = 0.9;
    self.nearResetMask = near;
    if (visible || self.lens.visible) self.needsDisplay = YES;
}

// Touch. A view must opt in to direct touches or it receives them only
// sporadically — that inconsistency cost four rounds of testing to spot.
- (void)touchesBeganWithEvent:(NSEvent *)e {
    if (self.lens.touching || self.dragging) return;
    NSTouch *t = [e touchesMatchingPhase:NSTouchPhaseAny inView:self].anyObject
              ?: [e touchesMatchingPhase:NSTouchPhaseAny inView:nil].anyObject;
    if (!t) return;
    // Direct touches report a real point in the view. normalizedPosition and
    // deviceSize belong to indirect (trackpad) touches and raise here.
    CGFloat tx = [t locationInView:self].x;
    if (tx >= READ_X) {
        if ([self beginLensAt:tx]) {
            self.lensTouchIdentity = t.identity;
            // The mascots glance at whatever you are reading. Nothing louder:
            // the panel itself is the response.
            if (!self.dragging) { if (self.act == ActWalk) self.dir = 1; self.gptDir = 1; }
            self.resetLookTime = MAX(self.resetLookTime, 0.9);
        }
        return;
    }
    // Both mascots get the same generous fingertip-sized hit target. If their
    // sprites are close after a collision, the nearest one wins predictably.
    MascotTarget target = MascotTargetAtPoint(tx, self.x, self.gptX, 34);
    if (target != MascotTargetNone) {
        self.dragging = YES;
        self.dragTarget = target;
        CGFloat centre = target == MascotTargetClaude ? self.x : self.gptX;
        self.grabDX = tx - centre;
        self.grabStartX = tx;
        self.dragVX = 0;
        self.lastDragX = tx;
        if (target == MascotTargetGPT) {
            self.gptKick = 0;
            return;
        }
        self.act = ActClip;              // stop pacing while held
        self.clipIdx = 4;                // surprise
        self.clip = 0; self.clipT = 0; self.clipLoops = 2;
    }
}

- (void)touchesMovedWithEvent:(NSEvent *)e {
    if (self.lens.touching) {
        for (NSTouch *touch in [e touchesMatchingPhase:NSTouchPhaseAny inView:self]) {
            if ([touch.identity isEqual:self.lensTouchIdentity]) {
                [self.lens moveTo:[touch locationInView:self].x];
                self.needsDisplay = YES;
            }
        }
        return;
    }
    if (!self.dragging) return;
    NSTouch *t = [e touchesMatchingPhase:NSTouchPhaseAny inView:self].anyObject
              ?: [e touchesMatchingPhase:NSTouchPhaseAny inView:nil].anyObject;
    if (!t) return;
    CGFloat tx = [t locationInView:self].x;
    CGFloat nx = tx - self.grabDX;
    self.dragVX = tx - self.lastDragX;   // for the throw
    self.lastDragX = tx;
    if (self.dragTarget == MascotTargetGPT) {
        self.gptX = MAX(22, MIN(nx, READ_X - 22));
        if (fabs(self.dragVX) > 0.5) self.gptDir = self.dragVX > 0 ? 1 : -1;
    } else {
        // Same wall the pacing uses: he may not be parked on top of the readout.
        CGFloat wall = READ_X - (CLAWD_N * 1.95) / 2.0 - 8;
        self.x = MAX(20, MIN(nx, wall));
        if (fabs(self.dragVX) > 0.5) self.dir = (self.dragVX > 0) ? 1 : -1;
    }
    self.needsDisplay = YES;
}

- (void)touchesEndedWithEvent:(NSEvent *)e {
    if (self.lens.touching) {
        for (NSTouch *touch in [e touchesMatchingPhase:NSTouchPhaseEnded inView:self]) {
            if ([touch.identity isEqual:self.lensTouchIdentity]) {
                [self.lens end]; self.lensTouchIdentity = nil;
            }
        }
    } else [self releaseDrag];
}
- (void)touchesCancelledWithEvent:(NSEvent *)e {
    [self.lens cancel]; self.lensTouchIdentity = nil; [self releaseDrag];
}

- (void)releaseDrag {
    if (!self.dragging) return;
    self.dragging = NO;
    // Throw: carry the flick into a slide that decays, instead of stopping dead.
    if (self.dragTarget == MascotTargetGPT) {
        self.gptKick = self.dragVX * 12.0;
        if (fabs(self.dragVX) > 0.5) self.gptDir = self.dragVX > 0 ? 1 : -1;
    } else {
        self.throwVX = self.dragVX * 12.0;
        self.act = ActWalk;
    }
    // A stationary release is a tap, not a throw. The brief sparkle gives the
    // fingertip feedback without adding buttons or hiding usage data.
    if (fabs(self.lastDragX - self.grabStartX) < 5.0) {
        [self tapMascot:self.dragTarget];
    } else if (fabs(self.dragVX) > 2.0) {
        // A real throw: kick up dust where it leaves the finger.
        CGFloat from = self.dragTarget == MascotTargetGPT ? self.gptX : self.x;
        FXBurst(_fx, from, 1.5, 10, 12, 40, M_PI * 0.05, M_PI * 0.95, 0.45, 1.6, 60,
                0.85f, 0.80f, 0.74f, FXKindPixel);
    }
    self.dragTarget = MascotTargetNone;
    self.sinceAct = 0;
}

- (void)advanceGPT:(NSTimeInterval)dt mood:(Mood)m {
    // GPT takes irregular rests between patrols, so it has the same relaxed
    // rhythm as Clawd rather than reading as a continuously scrolling icon.
    // GPT stays just behind Clawd at every mood level; the two characters
    // remain readable as a pair instead of GPT repeatedly overtaking him.
    CGFloat gptSpeed = SpeedForMood(m) * 0.90;
    CGFloat gptRight = READ_X - 22;
    GPTActivity activity = self.gptActivity;
    if (AdvanceGPTActivity(&activity, dt)) {
        activity.duration = activity.resting
            ? 1.3 + (CGFloat)arc4random_uniform(180) / 100.0   // 1.3-3.1s rest
            : 3.0 + (CGFloat)arc4random_uniform(500) / 100.0;  // 3-8s walk
    }
    self.gptActivity = activity;
    BOOL moving = !activity.resting || fabs(self.gptKick) > 1.0;
    if (!(self.dragging && self.dragTarget == MascotTargetGPT)) {
        if (moving) self.gptX += (self.gptDir * gptSpeed + self.gptKick) * dt;
        self.gptKick *= 0.88;
        if (self.gptX < 22) { self.gptX = 22; self.gptDir = 1; }
        if (self.gptX > gptRight) { self.gptX = gptRight; self.gptDir = -1; }
    }
    self.gptPhase += dt * (moving ? gptSpeed / 11.0 : 0.7);

    // Blink on an irregular clock; doze off after a long rest, with a drowsy
    // pixel drifting up now and then; wake instantly when anything happens.
    self.gptBlinkT = MAX(0, self.gptBlinkT - dt);
    self.gptHappyT = MAX(0, self.gptHappyT - dt);
    self.gptNextBlink -= dt;
    if (self.gptNextBlink <= 0) {
        self.gptBlinkT = 0.14;
        self.gptNextBlink = 2.5 + (CGFloat)arc4random_uniform(400) / 100.0;
    }
    if (activity.resting && !self.dragging && fabs(self.gptKick) < 1.0) {
        double before = self.gptRestT;
        self.gptRestT += dt;
        if (self.gptRestT > 2.2 && fmod(before, 1.4) > fmod(self.gptRestT, 1.4))
            FXBurst(_fx, self.gptX + 9, 26, 1, 4, 8, M_PI * 0.4, M_PI * 0.6, 1.1, 1.5, -6,
                    0.75f, 0.85f, 1.0f, FXKindPixel);
    } else {
        self.gptRestT = 0;
    }

    MascotPair pair = { self.x, self.dir * SpeedForMood(m),
                        self.gptX, self.gptDir * gptSpeed + self.gptKick };
    if (ResolveMascotCollision(&pair, 34.0)) {
        if (self.collisionCooldown <= 0) {
            self.collisionCooldown = 0.8;
            CGFloat mid = (pair.claudeX + pair.gptX) / 2.0;
            FXBurst(_fx, mid, 22, 6, 25, 55, 0, M_PI * 2, 0.5, 3.0, 40, 1.0f, 0.92f, 0.45f, FXKindStar);
            FXHopKick(&_claudeHop, 34); FXHopKick(&_gptHop, 34);
        }
        self.x = pair.claudeX;
        self.gptX = pair.gptX;
        self.dir = pair.claudeVelocity < 0 ? -1 : 1;
        self.gptDir = pair.gptVelocity < 0 ? -1 : 1;
        self.gptKick = pair.gptVelocity - self.gptDir * gptSpeed;
    }
}

- (void)advance:(NSTimeInterval)dt {
    Mood m = MoodForUsage(self.p5);
    self.claudeTapT = MAX(0, self.claudeTapT - dt);
    self.gptTapT = MAX(0, self.gptTapT - dt);
    self.usageTapT = MAX(0, self.usageTapT - dt);
    if (self.usageTapT <= 0) self.activeUsageCell = -1;

    if (self.dragging) {
        // Held: legs scrabble, body shakes. A limp sprite following a finger
        // reads as a dragged icon; a struggling one reads as a creature.
        self.phase   += dt * 17.0;
        self.wiggleT += dt;
        [self advanceGPT:dt mood:m];
        self.needsDisplay = YES;
        return;
    }

    // A throw slides and decays back into the normal pacing speed.
    if (fabs(self.throwVX) > 1.0) {
        self.x += self.throwVX * dt;
        self.throwVX *= 0.92;
        CGFloat lo = 20, hi = READ_X - (CLAWD_N * 1.95) / 2.0 - 8;
        BOOL hit = NO;
        if (self.x < lo) { self.x = lo; self.throwVX = -self.throwVX * 0.5; self.dir = 1; hit = YES; }
        if (self.x > hi) { self.x = hi; self.throwVX = -self.throwVX * 0.5; self.dir = -1; hit = YES; }
        if (hit && fabs(self.throwVX) > 8) {
            FXBurst(_fx, self.x, 14, 7, 20, 50, 0, M_PI * 2, 0.45, 2.6, 30, 1.0f, 0.9f, 0.5f, FXKindStar);
            FXHopKick(&_claudeHop, 46);
        }
        // Speed lines of pixel dust behind a fast slide.
        if (fabs(self.throwVX) > 25)
            FXBurst(_fx, self.x - (self.throwVX > 0 ? 10 : -10), 2.5, 1, 4, 10,
                    M_PI * 0.3, M_PI * 0.7, 0.35, 1.4, 20, 0.8f, 0.75f, 0.7f, FXKindPixel);
        self.phase += dt * (fabs(self.throwVX) / 9.0);
        [self advanceGPT:dt mood:m];
        self.needsDisplay = YES;
        return;
    }

    if (self.act == ActWalk) {
        self.x += self.dir * SpeedForMood(m) * dt;

        // Turn around before the sprite's own edge — not its centre — reaches
        // the readout, or he walks over the "5h" label.
        CGFloat pad = 30, right = READ_X - (CLAWD_N * 1.95) / 2.0 - 8;
        if (self.x > right) { self.x = right; self.dir = -1; }
        if (self.x < pad)   { self.x = pad;   self.dir =  1; }

        // Step cadence tracks speed, so fast moods visibly scurry.
        self.phase += dt * (SpeedForMood(m) / 9.0);

        // Every so often, stop and do something. Panicking Clawd has no time
        // for hobbies, so the pause only happens when things are calm.
        // A fixed 12s gap put him on a metronome and left three quarters of
        // every cycle as plain pacing. The wait is now short and irregular, so
        // the next thing he does is neither far off nor predictable.
        self.sinceAct += dt;
        if (self.sinceAct > self.nextActAt) {
            self.sinceAct = 0;
            self.nextActAt = 3.0 + (CGFloat)arc4random_uniform(500) / 100.0;   // 3-8s
            self.clip = 0;
            self.clipT = 0;
            if (m != MoodPanic && arc4random_uniform(5) == 0) {   // เดาะบอลเฉพาะตอนไม่ตกใจ
                self.act = ActJuggle; self.ballY = 0; self.ballV = 46;
            } else {
                self.act = ActClip;
                self.clipIdx = ClipForMood(m, (int)self.lastClipIdx);
                self.lastClipIdx = self.clipIdx;
                const ClawdClip *pick = &kClawdClips[self.clipIdx];
                int ms = 0;
                for (int f = 0; f < pick->count; f++) ms += pick->frames[f].hold;
                self.clipLoops = MAX(1, MIN(3, 4000 / MAX(ms, 1)));
            }
        }
    } else if (self.act == ActJuggle) {
        // Simple ballistics: the ball falls, Clawd bumps it back up on contact.
        // ponytail: no collision system, just a floor test — it is one ball.
        self.clipT += dt;
        self.ballV -= 150.0 * dt;                 // gravity, points/s^2
        self.ballY += self.ballV * dt;
        if (self.ballY <= 0 && self.ballV < 0) {  // bounced off his head
            self.ballY = 0;
            self.ballV = 46;
            self.clip++;                          // count the bumps
        }
        self.phase += dt * 4.0;                   // little bob while juggling
        if (self.clipT > 6.0) { self.act = ActWalk; self.sinceAct = 0; }
    } else {
        // Each source frame carries its own hold in ms — honour it rather than
        // forcing a constant fps, or the timing of blinks and beats is wrong.
        const ClawdClip *cl = &kClawdClips[self.clipIdx];
        self.clipT += dt * 1000.0;
        while (self.clip < cl->count && self.clipT >= cl->frames[self.clip].hold) {
            self.clipT -= cl->frames[self.clip].hold;
            self.clip++;
        }
        if (self.clip >= cl->count) {
            // The dance clips run 1.4-2.4s and are built to loop, so playing
            // each exactly once sent him straight back to pacing — the busiest
            // moods ended up the least animated. Short clips repeat until they
            // have held the screen for a few seconds.
            if (--self.clipLoops > 0) {
                self.clip = 0;
            } else {
                self.act = ActWalk; self.clip = 0; self.sinceAct = 0;
            }
        }
    }

    [self advanceGPT:dt mood:m];

    self.needsDisplay = YES;
}

#pragma mark - Effects

// Provider colours as raw components for the particle system.
static void AccentRGB(MascotTarget who, float *r, float *g, float *b) {
    if (who == MascotTargetGPT) { *r = 0.37f; *g = 0.70f; *b = 1.00f; }
    else                        { *r = 1.00f; *g = 0.60f; *b = 0.42f; }
}

// A tap is a small celebration: crouch, hop, a burst of pixel confetti in the
// mascot's colour, a shock ring and a heart. Tapping again quickly chains a
// combo that jumps higher, throws more confetti and flips the mascot.
- (void)tapMascot:(MascotTarget)target {
    if (target == MascotTargetNone) return;
    BOOL gpt = target == MascotTargetGPT;
    FXHop *hop = gpt ? &_gptHop : &_claudeHop;
    CGFloat x = gpt ? self.gptX : self.x;
    float r, g, b; AccentRGB(target, &r, &g, &b);
    // Tapped silly: it needs a breather. A poke only shakes loose a sweat
    // drop until the stars clear; the combo starts over afterwards.
    if ((gpt ? self.gptDizzyT : self.claudeDizzyT) > 0) {
        FXBurst(_fx, x + (FXRandom(_fx) < 0.5 ? -8 : 8), 24, 1, 10, 20, M_PI * 0.3, M_PI * 0.7,
                0.5, 2.0, 90, 0.42f, 0.72f, 0.96f, FXKindPixel);
        self.needsDisplay = YES;
        return;
    }
    int combo = FXHopKick(hop, 48);
    int extra = MIN(combo - 1, 4);

    // Two fountains from the shoulders, so the confetti frames the face
    // instead of covering it.
    int each = 6 + extra * 3;
    FXBurst(_fx, x + 9, 20, each, 30, 70 + extra * 10, M_PI * 0.05, M_PI * 0.42,
            0.75, 1.8, 120, r, g, b, FXKindPixel);
    FXBurst(_fx, x - 9, 20, each, 30, 70 + extra * 10, M_PI * 0.58, M_PI * 0.95,
            0.75, 1.8, 120, r, g, b, FXKindPixel);
    FXBurst(_fx, x + 11, 18, 2 + extra, 40, 90, -M_PI * 0.25, M_PI * 0.4, 0.3, 2.0, 0, 1, 1, 1, FXKindSpark);
    FXBurst(_fx, x - 11, 18, 2 + extra, 40, 90, M_PI * 0.6, M_PI * 1.25, 0.3, 2.0, 0, 1, 1, 1, FXKindSpark);
    // A shock ring on the ground under the feet.
    FXParticle ring = { .x = x, .y = 1.2, .life = 0.45, .maxLife = 0.45, .size = 17 + extra * 3,
                        .r = r, .g = g, .b = b, .kind = FXKindRing };
    FXEmit(_fx, ring);
    CGFloat side = FXRandom(_fx) < 0.5 ? -1 : 1;
    FXParticle heart = { .x = x + side * 13, .y = 16, .vx = side * 8, .vy = 14,
                         .life = 0.9, .maxLife = 0.9, .size = 1.0, .drag = 0.4,
                         .r = 1.0f, .g = 0.36f, .b = 0.52f, .kind = FXKindHeart };
    FXEmit(_fx, heart);

    if (gpt) { self.gptHappyT = 1.2 + 0.3 * extra; self.gptRestT = 0; }
    // x5: a party. Confetti in every colour, both mascots hop, Clawd breaks
    // into a dance and GPT grins for a good while.
    if (combo == 5) {
        static const float party[6][3] = {{1,0.35,0.4},{1,0.8,0.3},{0.4,0.9,0.5},{0.4,0.7,1},{0.8,0.5,1},{1,1,1}};
        for (int i = 0; i < 6; i++)
            FXBurst(_fx, x, 18, 7, 40, 110, M_PI * 0.1, M_PI * 0.9, 1.1, 2.0, 110,
                    party[i][0], party[i][1], party[i][2], FXKindPixel);
        FXParticle big = { .x = x, .y = 1.2, .life = 0.7, .maxLife = 0.7, .size = 34,
                           .r = 1, .g = 1, .b = 1, .kind = FXKindRing };
        FXEmit(_fx, big);
        if (!FXHopIsActive(gpt ? &_claudeHop : &_gptHop)) FXHopKick(gpt ? &_claudeHop : &_gptHop, 44);
        if (!self.dragging && self.act != ActJuggle) {
            self.act = ActClip; self.clipIdx = 6;            // dance_bounce
            self.clip = 0; self.clipT = 0; self.clipLoops = 2;
        }
        self.gptHappyT = MAX(self.gptHappyT, 2.5);
    }
    // x8: dizzy. Stars orbit the head for a few seconds, no more hops, and
    // the combo has to start again from one.
    if (combo >= 8) {
        if (gpt) self.gptDizzyT = 2.6; else self.claudeDizzyT = 2.6;
        hop->combo = 0; hop->comboTimer = 0;
        FXBurst(_fx, x, 22, 10, 30, 80, 0, M_PI * 2, 0.8, 3.0, 20, 1.0f, 0.92f, 0.45f, FXKindStar);
    }
    if (combo >= 2) {
        if (gpt) { self.gptBadgeT = 0.8; self.gptBadgeN = combo; }
        else     { self.claudeBadgeT = 0.8; self.claudeBadgeN = combo; }
    }
    // One flip at a time: restarting it on every tap left the sprite edge-on
    // (zero width) for as long as the tapping went on.
    if (combo >= 3 && (gpt ? self.gptSpin : self.claudeSpin) <= 0) {
        if (gpt) self.gptSpin = 1.0; else self.claudeSpin = 1.0;
        FXBurst(_fx, x + 12, 22, 3 + extra, 30, 70, -M_PI * 0.2, M_PI * 0.45, 0.6, 3.2, 20, 1.0f, 0.92f, 0.45f, FXKindStar);
        FXBurst(_fx, x - 12, 22, 3 + extra, 30, 70, M_PI * 0.55, M_PI * 1.2, 0.6, 3.2, 20, 1.0f, 0.92f, 0.45f, FXKindStar);
    }
    self.needsDisplay = YES;
}

// 60fps: particles, hops, tweens and the occasional gloss sweep. Requests a
// redraw only while something is actually moving, so an idle bar stays cheap.
- (void)advanceFX:(double)dt {
    self.fxClock += dt;
    // The sky scrolls against Clawd's travel, so his walk reads as a journey.
    // Only what actually moves him counts: pacing, a throw, or a drag.
    double drift = 0;
    if (self.dragging && self.dragTarget == MascotTargetClaude) drift = self.dragVX * 6.0;
    else if (fabs(self.throwVX) > 1.0) drift = self.throwVX;
    else if (self.act == ActWalk) drift = self.dir * SpeedForMood(MoodForUsage(self.p5));
    NightSkyAdvance(_sky, dt, drift * 0.35);
    if (_sky->meteorActive) self.needsDisplay = YES;
    self.collisionCooldown = MAX(0, self.collisionCooldown - dt);
    BOOL active = FXAdvance(_fx, dt) > 0;

    if (FXHopAdvance(&_claudeHop, dt))
        FXBurst(_fx, self.x, 1.5, 6, 10, 30, M_PI * 0.1, M_PI * 0.9, 0.35, 1.4, 60, 0.85f, 0.8f, 0.74f, FXKindPixel);
    if (FXHopAdvance(&_gptHop, dt))
        FXBurst(_fx, self.gptX, 1.5, 6, 10, 30, M_PI * 0.1, M_PI * 0.9, 0.35, 1.4, 60, 0.75f, 0.82f, 0.95f, FXKindPixel);
    active |= FXHopIsActive(&_claudeHop) || FXHopIsActive(&_gptHop);

    self.claudeSpin = MAX(0, self.claudeSpin - dt / 0.5);
    self.gptSpin = MAX(0, self.gptSpin - dt / 0.5);
    self.claudeBadgeT = MAX(0, self.claudeBadgeT - dt);
    self.gptBadgeT = MAX(0, self.gptBadgeT - dt);
    self.claudeDizzyT = MAX(0, self.claudeDizzyT - dt);
    self.gptDizzyT = MAX(0, self.gptDizzyT - dt);
    active |= self.claudeDizzyT > 0 || self.gptDizzyT > 0;
    active |= self.claudeSpin > 0 || self.gptSpin > 0 || self.claudeBadgeT > 0 ||
              self.gptBadgeT > 0;

    // Readings glide to their value (and count up on first sight). A change
    // between polls throws sparks off the end of that bar.
    for (NSString *key in self.fxTargets) {
        double target = self.fxTargets[key].doubleValue;
        NSNumber *prev = self.fxPrevTargets[key];
        if (prev && fabs(prev.doubleValue - target) >= 1) {
            NSRect f = self.cellFrames[key].rectValue;
            CGFloat edge = f.origin.x + f.size.width * target / 100.0;
            FXBurst(_fx, edge, BAR_Y + BAR_H / 2, 10, 20, 60, 0, M_PI * 2, 0.6, 1.6, 50, 1, 1, 1, FXKindSpark);
            active = YES;
        }
        self.fxPrevTargets[key] = @(target);
        NSNumber *shown = self.shownRemaining[key];
        double from = shown ? shown.doubleValue : (self.fxCountUp ? 0 : target);
        double next = FXApproach(from, target, 5.0, dt);
        self.shownRemaining[key] = @(next);
        active |= next != target;
    }

    // A highlight sweeps across the bars every few seconds, staggered per cell.
    if (self.fxClock >= self.glossAt + 2.0) self.glossAt = self.fxClock + 5.0 + FXRandom(_fx) * 3.0;
    active |= self.fxClock >= self.glossAt;

    if (active) self.needsDisplay = YES;
}

- (double)shownFor:(NSString *)key target:(double)target {
    NSNumber *shown = self.shownRemaining[key];
    return shown ? shown.doubleValue : (self.fxCountUp ? 0 : target);
}

static void DrawPixelHeart(CGFloat cx, CGFloat cy, CGFloat px) {
    static const char *rows[] = {".X.X.", "XXXXX", "XXXXX", ".XXX.", "..X.."};
    for (int r = 0; r < 5; r++)
        for (int c = 0; c < 5; c++)
            if (rows[r][c] == 'X')
                NSRectFill(NSMakeRect(cx + (c - 2.5) * px, cy + (2 - r) * px, px + 0.2, px + 0.2));
}

- (void)drawParticles {
    for (int i = 0; i < _fx->count; i++) {
        FXParticle p = _fx->particles[i];
        CGFloat t = p.life / p.maxLife;                  // 1 → 0
        CGFloat alpha = MIN(1.0, t * 1.8);
        NSColor *c = [NSColor colorWithSRGBRed:p.r green:p.g blue:p.b alpha:alpha];
        [c set];
        switch (p.kind) {
            case FXKindPixel:
                NSRectFill(NSMakeRect(p.x - p.size / 2, p.y - p.size / 2, p.size, p.size));
                break;
            case FXKindSpark: {
                NSBezierPath *line = [NSBezierPath bezierPath];
                line.lineWidth = MAX(0.6, p.size * 0.45);
                line.lineCapStyle = NSLineCapStyleRound;
                [line moveToPoint:NSMakePoint(p.x, p.y)];
                [line lineToPoint:NSMakePoint(p.x - p.vx * 0.035, p.y - p.vy * 0.035)];
                [line stroke];
                break;
            }
            case FXKindHeart:
                DrawPixelHeart(p.x, p.y, 1.1 + 0.5 * (1 - t));
                break;
            case FXKindStar: {
                CGFloat a = p.size * (0.6 + 0.4 * sin(t * M_PI));
                NSRectFill(NSMakeRect(p.x - a, p.y - 0.4, 2 * a, 0.8));
                NSRectFill(NSMakeRect(p.x - 0.4, p.y - a, 0.8, 2 * a));
                NSRectFill(NSMakeRect(p.x - 0.7, p.y - 0.7, 1.4, 1.4));
                break;
            }
            case FXKindRing: {
                CGFloat grow = 1 - t * t;                 // ease out
                CGFloat radius = p.size * grow;
                NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:
                    NSMakeRect(p.x - radius, p.y - radius * 0.28, radius * 2, radius * 0.56)];
                ring.lineWidth = 1.2 * t + 0.3;
                [[c colorWithAlphaComponent:alpha * 0.8] set];
                [ring stroke];
                break;
            }
        }
    }
}

// A soft pool of light under each mascot (a shadow is invisible on the black
// bar). It shrinks and fades as the mascot leaves the ground.
static void DrawGroundGlow(CGFloat x, CGFloat height, NSColor *color) {
    CGFloat k = MAX(0.35, 1.0 - height / 10.0);
    NSRect r = NSMakeRect(x - 13 * k, -0.6, 26 * k, 3.2);
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:[color colorWithAlphaComponent:0.38 * k]
                                                  endingColor:[color colorWithAlphaComponent:0]];
    [g drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:r] relativeCenterPosition:NSZeroPoint];
}

static void DrawComboBadge(CGFloat x, CGFloat t, int n, NSColor *color) {
    if (t <= 0 || n < 2) return;
    CGFloat prog = 1 - t / 0.8;
    CGFloat pop = prog < 0.2 ? 0.7 + prog * 2.5 : 1.2 - (prog - 0.2) * 0.25;
    NSFont *font = [NSFont systemFontOfSize:9 * pop weight:NSFontWeightHeavy];
    NSShadow *glow = [NSShadow new];
    glow.shadowColor = [color colorWithAlphaComponent:0.9];
    glow.shadowBlurRadius = 3;
    NSDictionary *at = @{ NSFontAttributeName: font,
                          NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:MIN(1, t * 3)],
                          NSShadowAttributeName: glow };
    NSString *s = [NSString stringWithFormat:@"×%d", n];
    [s drawAtPoint:NSMakePoint(x + 9, 14 + prog * 6) withAttributes:at];
}

// Three little stars circling above a dizzy head, with a slight sway.
static void DrawDizzyStars(CGFloat x, CGFloat t, double clock) {
    if (t <= 0) return;
    CGFloat fade = MIN(1, t * 2.5);
    for (int i = 0; i < 3; i++) {
        CGFloat ang = clock * 5.0 + i * (2 * M_PI / 3);
        CGFloat sx = x + cos(ang) * 10.0, sy = 25.5 + sin(ang) * 2.2;
        CGFloat depth = 0.6 + 0.4 * (sin(ang) + 1) / 2;         // the far side is dimmer
        [[NSColor colorWithSRGBRed:1.0 green:0.92 blue:0.45 alpha:fade * depth] set];
        CGFloat a = 2.2 * depth;
        NSRectFill(NSMakeRect(sx - a, sy - 0.45, 2 * a, 0.9));
        NSRectFill(NSMakeRect(sx - 0.45, sy - a, 0.9, 2 * a));
    }
}

#pragma mark - Sprite


// Walk cycle: the official art has no walking pose, so build one from the base
// grid by moving the four legs. Row 14-16 hold the legs at columns 5, 8, 12, 15.
// ponytail: mutate a copy of the base rather than storing extra 400-byte frames.
static const unsigned char *WalkFrame(const unsigned char *base, int step) {
    static unsigned char buf[CLAWD_N * CLAWD_N];
    memcpy(buf, base, sizeof(buf));

    // Clear the existing legs, then redraw them at the offsets for this step.
    for (int r = 14; r <= 16; r++)
        for (int c = 0; c < CLAWD_N; c++)
            if (buf[r * CLAWD_N + c] == 1) buf[r * CLAWD_N + c] = 0;

    // Two pairs in counter-phase — front pair forward while back pair trails.
    static const int kLegX[4] = {5, 8, 12, 15};
    // Four genuinely distinct poses. Legs 0,2 lead while 1,3 trail (diagonal
    // gait) — a leg swings forward only while it is lifted, and plants when down.
    static const int kSwing[4][4] = {   // horizontal offset per step, per leg
        { -1, +1, -1, +1},
        {  0,  0,  0,  0},
        { +1, -1, +1, -1},
        {  0,  0,  0,  0},
    };
    static const int kLift[4][4]  = {   // 1 = lifted (drawn one row shorter)
        { 0, 1, 0, 1},
        { 0, 0, 0, 0},
        { 1, 0, 1, 0},
        { 0, 0, 0, 0},
    };

    int ph = step & 3;
    for (int i = 0; i < 4; i++) {
        int c = kLegX[i] + kSwing[ph][i];
        if (c < 0 || c >= CLAWD_N) continue;
        int bottom = kLift[ph][i] ? 15 : 16;         // lifted legs stop short
        for (int r = 14; r <= bottom; r++) buf[r * CLAWD_N + c] = 1;
    }
    return buf;
}

// Draw one 20x20 official frame. Rows run top-down; the view is not flipped.
// The base pose only occupies rows 4..16 — the rest of the 20x20 canvas is
// padding. Skipping it lets each pixel be ~60% larger in the same 30pt bar.
#define CLAWD_TOP 3
#define CLAWD_BOT 17
#define CLAWD_ROWS (CLAWD_BOT - CLAWD_TOP + 1)

static void DrawGridLean(const unsigned char *g, NSPoint origin, CGFloat px,
                         BOOL flip, NSColor *body, CGFloat lean,
                         const unsigned char (*pal)[3], int palCount,
                         int top, int bot);

// A clip either carries its own palette (scenes with props — laptop, desk,
// headphones) or is the plain 0/1/2 creature, in which case the caller's body
// colour applies so mood tinting still reaches it.
static void DrawGridPal(const unsigned char *g, NSPoint origin, CGFloat px,
                        BOOL flip, NSColor *body,
                        const unsigned char (*pal)[3], int palCount,
                        int top, int bot) {
    DrawGridLean(g, origin, px, flip, body, 0, pal, palCount, top, bot);
}

// lean shears the sprite: rows further from the feet shift further, so he
// tilts against the direction he is being pulled instead of sliding rigid.
static void DrawGridLean(const unsigned char *g, NSPoint origin, CGFloat px,
                         BOOL flip, NSColor *body, CGFloat lean,
                         const unsigned char (*pal)[3], int palCount,
                         int top, int bot) {
    NSColor *eye = [NSColor colorWithSRGBRed:0.06 green:0.06 blue:0.06 alpha:1.0];
    NSColor *cache[16] = {0};
    for (int r = top; r <= bot; r++) {
        for (int c = 0; c < CLAWD_N; c++) {
            unsigned char v = g[r * CLAWD_N + c];
            if (!v) continue;
            NSColor *ink;
            if (pal && v < palCount) {
                if (!cache[v])
                    cache[v] = [NSColor colorWithSRGBRed:pal[v][0] / 255.0
                                                   green:pal[v][1] / 255.0
                                                    blue:pal[v][2] / 255.0 alpha:1.0];
                ink = cache[v];
            } else {
                ink = (v == 2) ? eye : body;
            }
            [ink set];
            int cx = flip ? (CLAWD_N - 1 - c) : c;
            CGFloat rowUp = (bot - r);                // 0 at the feet
            NSRectFill(NSMakeRect(origin.x + (cx - CLAWD_N / 2.0) * px + lean * rowUp,
                                  origin.y + rowUp * px,
                                  px + 0.4, px + 0.4));
        }
    }
}

static void DrawGrid(const unsigned char *g, NSPoint origin, CGFloat px,
                     BOOL flip, NSColor *body) {
    DrawGridPal(g, origin, px, flip, body, NULL, 0, CLAWD_TOP, CLAWD_BOT);
}

// The user-provided bot stays raster rather than being approximated with a
// vector icon. Nearest-neighbour interpolation keeps its deliberately chunky
// pixels crisp at Touch Bar size.
static void DrawGPTMascot(CGFloat x, CGFloat direction, GPTFace face, int step, CGFloat bob,
                          CGFloat hopY, CGFloat squash, CGFloat spin) {
    static unsigned char grid[GPT_N * GPT_N];
    GPTSpriteFrame(face, step, grid);
    CGFloat const px = 1.72;                         // the same cell as Clawd
    NSPoint feet = NSMakePoint(x, 2.2 + bob);
    // Hop, squash/stretch about the feet, the coin-flip spin on a combo, and
    // the walking mirror, as one transform. The lift is clamped so the cloud
    // never leaves the 30pt bar.
    CGFloat rows = GPT_BOT - GPT_TOP + 1;
    CGFloat lift = MIN(hopY, MAX(0, 30.8 - feet.y - rows * px * squash));
    CGFloat flip = (direction < 0 ? -1 : 1) * cos(spin * 2 * M_PI);
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *xf = NSAffineTransform.transform;
    [xf translateXBy:x yBy:feet.y + lift];
    [xf scaleXBy:flip / squash yBy:squash];
    [xf translateXBy:-x yBy:-feet.y];
    [xf concat];
    DrawGridPal(grid, feet, px, NO, NSColor.whiteColor, kGPTPalette, GPTInkCount, GPT_TOP, GPT_BOT);
    [NSGraphicsContext restoreGraphicsState];
}

// The sky lives behind the runway only and stops at a clean edge where the
// readout begins, so the numbers keep their dark panel.
- (void)drawNightSky {
    CGFloat skyW = READ_X - 4;
    NSRect sky = NSMakeRect(0, 0, skyW, kSceneH);
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(sky);
    // Deep night: near-black indigo at the top, a faint violet-blue glow at the
    // horizon, as if a city were just over the edge of the bar.
    NSGradient *night = [[NSGradient alloc] initWithColorsAndLocations:
        [NSColor colorWithSRGBRed:0.015 green:0.020 blue:0.060 alpha:1], 0.0,
        [NSColor colorWithSRGBRed:0.035 green:0.045 blue:0.120 alpha:1], 0.45,
        [NSColor colorWithSRGBRed:0.10 green:0.075 blue:0.200 alpha:1], 0.86,
        [NSColor colorWithSRGBRed:0.16 green:0.10 blue:0.22 alpha:1], 1.0, nil];
    [night drawInRect:sky angle:270];
    // A soft band of distant haze just above the ground line.
    NSGradient *haze = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.30 green:0.22 blue:0.45 alpha:0.22]
                                                    endingColor:[NSColor colorWithSRGBRed:0.30 green:0.22 blue:0.45 alpha:0]];
    [haze drawInRect:NSMakeRect(0, 0.5, skyW, 7) angle:90];

    // Stars: far ones are cold pinpricks, near ones warmer and larger, with a
    // four-point glint on the brightest moments.
    for (int i = 0; i < SKY_STARS; i++) {
        const SkyStar *st = &_sky->stars[i];
        double x = NightSkyStarX(_sky, i), b = NightSkyStarBrightness(_sky, i);
        NSColor *c = [NSColor colorWithSRGBRed:0.80 + 0.20 * st->warmth
                                         green:0.86 + 0.08 * st->warmth
                                          blue:1.00 - 0.30 * st->warmth alpha:b * 0.95];
        [c set];
        CGFloat sz = st->size;
        NSRectFill(NSMakeRect(x - sz / 2, st->y - sz / 2, sz, sz));
        // Only a true glint (the rare sharp flash, not the slow breathing)
        // earns a tiny four-point sparkle, kept small enough to stay a star.
        if (b > 0.96 && st->depth > 0.35) {
            CGFloat arm = sz * 0.9 + (b - 0.96) * 30;
            [[c colorWithAlphaComponent:(b - 0.96) * 14] set];
            NSRectFill(NSMakeRect(x - arm, st->y - 0.25, arm * 2, 0.5));
            NSRectFill(NSMakeRect(x - 0.25, st->y - arm, 0.5, arm * 2));
        }
    }

    // A thin crescent, high and to the left, out of the mascots' way.
    NSPoint moon = NSMakePoint(22 - fmod(_sky->scroll * 0.03, 8), 24.5);
    CGFloat mr = 3.4;
    for (int i = 3; i >= 1; i--) {
        [[NSColor colorWithSRGBRed:0.92 green:0.93 blue:1.0 alpha:0.035] set];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(moon.x - mr - i * 1.4, moon.y - mr - i * 1.4,
                                                            2 * (mr + i * 1.4), 2 * (mr + i * 1.4))] fill];
    }
    [[NSColor colorWithSRGBRed:0.95 green:0.95 blue:1.0 alpha:0.9] set];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(moon.x - mr, moon.y - mr, 2 * mr, 2 * mr)] fill];
    [[NSColor colorWithSRGBRed:0.02 green:0.025 blue:0.07 alpha:1] set];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(moon.x - mr + 1.9, moon.y - mr + 0.7, 2 * mr, 2 * mr)] fill];

    // Meteor: a bright head with a tail that fades to nothing.
    double hx, hy, tx, ty, fade;
    if (NightSkyMeteor(_sky, &hx, &hy, &tx, &ty, &fade)) {
        NSBezierPath *tail = [NSBezierPath bezierPath];
        [tail moveToPoint:NSMakePoint(hx, hy)];
        [tail lineToPoint:NSMakePoint(tx, ty)];
        tail.lineCapStyle = NSLineCapStyleRound;
        for (int k = 3; k >= 0; k--) {
            tail.lineWidth = 0.7 + k * 0.9;
            [[NSColor colorWithSRGBRed:0.85 green:0.92 blue:1.0 alpha:fade * (k == 0 ? 0.95 : 0.10)] set];
            [tail stroke];
        }
        [[NSColor colorWithWhite:1 alpha:fade] set];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(hx - 1.1, hy - 1.1, 2.2, 2.2)] fill];
    }

    [NSGraphicsContext restoreGraphicsState];
}

- (void)drawRect:(NSRect)dirty {
    [NSColor.clearColor set];
    NSRectFill(dirty);
    [self drawNightSky];

    CGFloat midY = NSHeight(self.bounds) / 2.0;

    if (!self.haveData) {
        NSDictionary *at = @{ NSFontAttributeName: [NSFont systemFontOfSize:12],
                              NSForegroundColorAttributeName: NSColor.secondaryLabelColor };
        [@"claude …" drawAtPoint:NSMakePoint(20, midY - 8) withAttributes:at];
        return;
    }

    Mood mood = MoodForUsage(self.p5);

    // Anthropic coral, desaturating toward alarm red as the window fills.
    NSColor *body = (mood == MoodPanic)
        ? [NSColor colorWithSRGBRed:0.86 green:0.30 blue:0.22 alpha:1.0]
        : [NSColor colorWithSRGBRed:0.804 green:0.498 blue:0.416 alpha:1.0];  // #CD7F6A — official, from creature-engine.js

    // 15 rows at 1.95 filled 29.2 of the 30pt bar, leaving 0.8pt of margin —
    // less than the bob, so his head clipped, and the sweat drawn above it was
    // off-screen entirely. 1.72 keeps him large while leaving room to move.
    CGFloat const px = 1.72;
    CGFloat bob = (mood == MoodTired) ? 0 : (((int)(self.phase * 2.0) & 1) ? 0.7 : 0);
    // Sit him slightly low: the space above his head is where the sweat goes.
    NSPoint feet = NSMakePoint(self.x, 2.2 + bob);   // 2.2 clears the ground line at feet.y-1.5

    // Ground line, like the reference art.
    [[NSColor colorWithWhite:1.0 alpha:0.14] set];
    NSRectFill(NSMakeRect(0, feet.y - 1.5, NSWidth(self.bounds), 1.0));

    // Both characters occupy the same runway. Collision physics in advance:
    // keeps their centres apart, so drawing order never hides a collision.
    DrawGroundGlow(self.gptX, _gptHop.y, [NSColor colorWithSRGBRed:0.37 green:0.70 blue:1.0 alpha:1]);
    DrawGroundGlow(self.x, _claudeHop.y, [NSColor colorWithSRGBRed:1.0 green:0.60 blue:0.42 alpha:1]);
    {
        BOOL held = self.dragging && self.dragTarget == MascotTargetGPT;
        BOOL moving = !self.gptActivity.resting || fabs(self.gptKick) > 1.0;
        GPTFace face = GPTFaceNormal;
        if (held || fabs(self.gptKick) > 40)      face = GPTFaceSurprised;
        else if (self.gptDizzyT > 0)              face = GPTFaceDizzy;
        else if (self.gptHappyT > 0)              face = GPTFaceHappy;
        else if (self.gptBlinkT > 0)              face = GPTFaceBlink;
        else if (self.resetLookTime > 0)          face = GPTFaceLook;
        else if (self.gptRestT > 2.2)             face = GPTFaceSleepy;
        int step = (moving && !held) ? ((int)(self.gptPhase * 2.0) & 3) : -1;
        // Pixel bob: a half-cell hop on the walk beat, a slow breath at rest.
        CGFloat gbob = moving ? ((((int)(self.gptPhase * 2.0)) & 1) ? 0.7 : 0)
                              : ((((int)(self.gptPhase * 0.6)) & 1) ? 0.5 : 0);
        if (held) gbob = sin(self.wiggleT * 15.0) * 1.2;
        CGFloat sway = self.gptDizzyT > 0 ? sin(self.fxClock * 9.0) * 1.1 : 0;
        DrawGPTMascot(self.gptX + sway, self.resetLookTime > 0 ? 1 : self.gptDir, face, step, gbob,
                      _gptHop.y, _gptHop.squash, self.gptSpin);
    }

    // Panic: motion streaks trailing behind.
    if (mood == MoodPanic) {
        [[body colorWithAlphaComponent:0.28] set];
        for (int i = 1; i <= 3; i++) {
            CGFloat sx = self.x - self.dir * (CLAWD_N * px * 0.4 + i * 5.0);
            NSRectFill(NSMakeRect(MIN(sx, sx - self.dir * 4.0), feet.y + 8, 4.0, 1.6));
        }
    }

    const unsigned char *base = kClawdClips[0].frames[0].grid;   // canonical pose

    // Hop, squash/stretch about the feet, and a coin-flip spin on a combo.
    [NSGraphicsContext saveGraphicsState];
    {
        NSAffineTransform *xf = NSAffineTransform.transform;
        CGFloat sq = _claudeHop.squash;
        // Clawd nearly fills the 30pt bar: limit the drawn lift so his head
        // never leaves it; the squash, flip and confetti carry the jump.
        CGFloat lift = MIN(_claudeHop.y, MAX(0, 30.8 - 2.2 - CLAWD_ROWS * 1.72 * sq));
        CGFloat sway = self.claudeDizzyT > 0 ? sin(self.fxClock * 9.0) * 1.1 : 0;
        [xf translateXBy:self.x + sway yBy:2.2 + lift];
        [xf scaleXBy:cos(self.claudeSpin * 2 * M_PI) / sq yBy:sq];
        [xf translateXBy:-self.x yBy:-2.2];
        [xf concat];
    }

    if (self.dragging) {
        // Startled, not malfunctioning: a fast wobble with a slow sway under
        // it, so the motion has a shape instead of reading as vibration.
        CGFloat t = self.wiggleT;
        CGFloat jx = sin(t * 16.0) * 1.3 + sin(t * 6.0) * 0.6;
        CGFloat jy = sin(t * 13.0) * 1.5 + cos(t * 21.0) * 0.5;
        CGFloat lean = MAX(-0.35, MIN(0.35, -self.dragVX * 0.04));
        NSPoint p = NSMakePoint(feet.x + jx, feet.y + jy);
        DrawGridLean(WalkFrame(base, (int)(self.phase * 2.0)), p, px,
                     (self.dir < 0), body, lean, NULL, 0, CLAWD_TOP, CLAWD_BOT);

        // Sweat: three drops on staggered cycles, each arcing up and out from
        // the head and fading. Position comes from the clock, so no particle
        // state has to be kept anywhere.
        CGFloat headY = p.y + CLAWD_ROWS * px;
        for (int i = 0; i < 3; i++) {
            CGFloat prog = fmod(t * 1.6 + i * 0.37, 1.0);       // 0..1 per drop
            if (prog > 0.85) continue;                          // brief gap
            CGFloat side = (i == 1) ? -1.0 : 1.0;
            CGFloat dx = side * (5.0 + prog * 13.0) + ((i == 2) ? 3.0 : 0);
            CGFloat dy = sin(prog * M_PI) * 7.0 - prog * 2.0;   // arc up, then fall
            CGFloat fade = MIN(1.0, (1.0 - prog) * 1.6);   // stay opaque until well clear
            [[NSColor colorWithSRGBRed:0.42 green:0.72 blue:0.96
                                  alpha:0.95 * fade] set];
            CGFloat sz = 2.6 * (1.0 - prog * 0.3);
            NSRectFill(NSMakeRect(p.x + dx, headY + dy - 2, sz, sz * 1.35));
        }
    } else if (self.act == ActWalk) {
        DrawGrid(WalkFrame(base, (int)(self.phase * 2.0)), feet, px, (self.dir < 0), body);
    } else if (self.act == ActJuggle) {
        DrawGrid(base, feet, px, (self.dir < 0), body);
        // The ball, sitting above his head.
        CGFloat top = feet.y + CLAWD_ROWS * px;
        NSRect b = NSMakeRect(self.x - px, top + 1 + self.ballY, px * 2, px * 2);
        [NSColor.whiteColor set];
        NSRectFill(b);
    } else {
        const ClawdClip *cl = &kClawdClips[self.clipIdx];
        NSInteger i = MIN(MAX(self.clip, 0), (NSInteger)cl->count - 1);
        // Prop scenes must not be mirrored: a laptop drawn backwards reads as
        // a glitch, unlike the creature itself which is symmetric enough.
        // Clips carry their own row window. The prop scenes are taller than the
        // creature alone, so shrink the pixel just enough to fit rather than
        // cropping desks and thought bubbles off the top — which is what the
        // fixed 3..17 window had been doing to every clip, old ones included.
        int ctop = cl->top, cbot = cl->bot;
        CGFloat cpx = MIN(px, (kSceneH - 1.0) / (cbot - ctop + 1));
        NSPoint cfeet = NSMakePoint(self.x, midY - ((cbot - ctop + 1) * cpx) / 2.0);
        DrawGridPal(cl->frames[i].grid, cfeet, cpx,
                    cl->pal ? NO : (self.dir < 0), body, cl->pal, cl->palCount,
                    ctop, cbot);
    }
    [NSGraphicsContext restoreGraphicsState];

    // Tired: a sweat drop above the head.
    if (mood == MoodTired) {
        [[NSColor colorWithSRGBRed:0.42 green:0.70 blue:0.94 alpha:0.95] set];
        NSRectFill(NSMakeRect(self.x + 8, feet.y + CLAWD_ROWS * px * 0.9, 2.4, 3.4));
    }

    [self drawReadout];

    DrawDizzyStars(self.x, self.claudeDizzyT, self.fxClock);
    DrawDizzyStars(self.gptX, self.gptDizzyT, self.fxClock);
    DrawComboBadge(self.x, self.claudeBadgeT, self.claudeBadgeN,
                   [NSColor colorWithSRGBRed:1.0 green:0.60 blue:0.42 alpha:1]);
    DrawComboBadge(self.gptX, self.gptBadgeT, self.gptBadgeN,
                   [NSColor colorWithSRGBRed:0.37 green:0.70 blue:1.0 alpha:1]);
    [self drawParticles];
}

static void DrawRight(NSString *s, CGFloat rightEdge, CGFloat y, NSDictionary *at) {
    CGFloat w = [s sizeWithAttributes:at].width;
    [s drawAtPoint:NSMakePoint(rightEdge - w, y) withAttributes:at];
}

- (NSArray<NSArray *> *)usageCells {
    // Four fixed cells prevent a provider that has an extra model-specific
    // cap from moving the other provider. Labels expand to human names when
    // one provider is shown, and stay compact but explicit when both appear.
    BOOL claudeReady = ![self.state isEqualToString:@"none"] && ![self.state isEqualToString:@"expired"];
    BOOL codexReady = self.codexHaveData && ![self.codexState isEqualToString:@"expired"];
    NSString *(^usageLabel)(NSString *, NSString *, NSString *) = ^NSString *(NSString *name, NSString *period, NSString *providerState) {
        if ([providerState isEqualToString:@"expired"]) return [name stringByAppendingString:@" login"];
        if ([providerState isEqualToString:@"none"]) return [name stringByAppendingString:@" —"];
        if ([providerState isEqualToString:@"stale"]) return [name stringByAppendingString:@" stale"];
        return [NSString stringWithFormat:@"%@ %@", name, period];
    };

    UsageProvider *claude = [UsageProvider new]; claude.state = self.state;
    UsageProvider *codex = [UsageProvider new]; codex.state = self.codexState;
    NSArray<NSString *> *visible = VisibleUsageProviderNames(claude, codex);
    BOOL oneProvider = visible.count == 1;
    NSString *claudeName = @"Claude";
    NSString *codexName = oneProvider ? @"ChatGPT" : @"GPT";
    NSMutableArray<NSArray *> *cells = [NSMutableArray arrayWithCapacity:4];

    // Show a window only if the account actually has one. A reading of -1 on a
    // live provider means "no such window" — Claude Max 20x has no 5h limit and
    // a free ChatGPT plan has neither a 5h nor a weekly one — so an empty gauge
    // there is noise. A provider that is expired or has no data keeps both
    // placeholder cells, because then we simply do not know what it has.
    void (^addProvider)(NSString *, NSString *, BOOL, NSString *, int, int, int, int, int, NSString *) =
        ^(NSString *name, NSString *provider, BOOL ready, NSString *providerState,
          int p5, int p7, int reset5, int reset7, int longDays, NSString *planToken) {
            // "Claude Max 20x · 7d": the same label with the subscription level
            // after the name. Only a live provider shows it; login/stale/none
            // labels already say something more urgent.
            NSString *planName = UsagePlanDisplay(planToken);
            NSString *(^planned)(NSString *) = ^NSString *(NSString *period) {
                if (!ready || !planName || ![providerState isEqualToString:@"ok"])
                    return usageLabel(name, period, providerState);
                return [NSString stringWithFormat:@"%@ %@ · %@", name, planName, period];
            };
            BOOL has5 = !ready || p5 >= 0;
            BOOL has7 = !ready || p7 >= 0;
            // cell: label, used%, state, resetMin, provider, label-with-plan, windowMin
            if (has5)
                [cells addObject:@[usageLabel(name, @"5h", providerState),
                                   @(ready ? p5 : -1), providerState, @(reset5), provider, planned(@"5h"), @300]];
            if (has7)
                [cells addObject:@[usageLabel(name, UsagePeriodLabel(longDays), providerState),
                                   @(ready ? p7 : -1), providerState, @(reset7), provider,
                                   planned(UsagePeriodLabel(longDays)), @(MAX(1, longDays) * 1440)]];
            if (!has5 && !has7)   // live but reporting nothing: one honest placeholder
                [cells addObject:@[[name stringByAppendingString:@" —"], @-1, providerState, @-1, provider,
                                   [name stringByAppendingString:@" —"], @0]];
        };
    if ([visible containsObject:@"claude"])
        addProvider(claudeName, @"claude", claudeReady, self.state,
                    self.p5, self.p7, self.resetMin, self.reset7dMin, self.longDays, self.plan);
    if ([visible containsObject:@"codex"])
        addProvider(codexName, @"codex", codexReady, self.codexState,
                    self.codexP5, self.codexP7, self.codexResetMin, self.codexReset7dMin,
                    self.codexLongDays, self.codexPlan);

    return cells;
}

- (void)drawReadout {
    NSArray *cells = [self usageCells];
    NSMutableArray *names = [NSMutableArray new];
    for (NSArray *cell in cells) [names addObject:cell[0]];
    if (self.lens.visible && ![self.lensLayout isEqualToString:[names componentsJoinedByString:@"|"]]) {
        [self.lens cancel]; self.lensCell = nil;
    }
    CGFloat cellW = (READ_W - CELL_GAP * (cells.count - 1)) / cells.count;

    // Show the subscription level in a provider's labels only if it fits in
    // every one of that provider's cells, beside the widest figure. Decided per
    // provider so its cells never disagree; the lens always carries it.
    NSMutableSet<NSString *> *roomForPlan = [NSMutableSet set];
    NSMutableSet<NSString *> *noRoom = [NSMutableSet set];
    NSDictionary *labelAt = @{ NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold] };
    CGFloat figureW = [@"100%" sizeWithAttributes:@{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightBold] }].width;
    for (NSArray *cell in cells) {
        NSString *provider = cell[4];
        if (cellW < 82 || [cell[5] length] == 0 ||
            [cell[5] sizeWithAttributes:labelAt].width + figureW + 6 > cellW)
            [noRoom addObject:provider];
        else [roomForPlan addObject:provider];
    }
    for (NSInteger i = 0; i < cells.count; i++) {
        NSString *providerState = cells[i][2];
        NSString *shown = ([roomForPlan containsObject:cells[i][4]] && ![noRoom containsObject:cells[i][4]])
            ? cells[i][5] : cells[i][0];
        CGFloat dim = [providerState isEqualToString:@"stale"] ? 0.72 : 1.0;
        BOOL selected = self.usageTapT > 0 && self.activeUsageCell == i;
        NSString *label = selected ? UsageResetDisplay([cells[i][3] intValue]) : shown;
        int usedPct = [cells[i][1] intValue];
        NSString *key = cells[i][0];
        CGFloat cellX = READ_X + i * (cellW + CELL_GAP);
        double target = usedPct < 0 ? 0 : UsageRemainingPercent(usedPct);
        if (usedPct >= 0) {
            self.fxTargets[key] = @(target);
            self.cellFrames[key] = [NSValue valueWithRect:NSMakeRect(cellX, BAR_Y, cellW, BAR_H)];
        }
        [self drawCell:shown pct:usedPct provider:cells[i][4]
                 shown:[self shownFor:key target:target] index:i
                     x:cellX width:cellW dim:dim
                  effect:(selected ? self.usageTapT / 2.5 : 0) resetLabel:label];
        int reset = [cells[i][3] intValue];
        int used = [cells[i][1] intValue];
        if ([providerState isEqualToString:@"ok"] && used >= 0 && reset > 0 && reset <= 30) {
            CGFloat start = READ_X + i * (cellW + CELL_GAP);
            CGFloat endOfFill = cellW * UsageRemainingPercent(used) / 100.0;
            CGFloat progress = (1 - cos(fmod(self.lensAmbient, 5.0) / 5.0 * M_PI)) / 2;
            CGFloat cx = start + endOfFill + (cellW - endOfFill) * progress;
            [NSGraphicsContext saveGraphicsState];
            NSRectClip(NSMakeRect(start, BAR_Y, cellW, BAR_H));
            for (int j = 3; j >= 0; j--) {
                [[NSColor colorWithWhite:1 alpha:(0.48 - j * 0.12) * sin(progress * M_PI)] set];
                [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - j * 1.6 - 0.6, BAR_Y + BAR_H - 1.8, 1.2, 1.2)] fill];
            }
            [NSGraphicsContext restoreGraphicsState];
        }
    }
    if (self.lens.visible && self.lensCell) [self drawUsageLens];
}

// The detail panel. Touching a bar replaces the readout with the facts about
// that one window, laid out to be read in a glance:
//   ring   — remaining %, sweeping in as the panel opens
//   title  — "Claude Ultra · 7d  52% left"      right: "resets in 2d 3h · Sun 12:00"
//   track  — the whole window as a timeline: how much has passed, and "now"
//   scrub  — drag along the track to read the clock at any point of the window
static NSString *ClockLabel(NSDate *date, BOOL withDay) {
    static NSDateFormatter *time, *dayTime;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        time = [NSDateFormatter new]; time.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        time.dateFormat = @"HH:mm";
        dayTime = [NSDateFormatter new]; dayTime.locale = time.locale;
        dayTime.dateFormat = @"EEE HH:mm";
    });
    return [(withDay ? dayTime : time) stringFromDate:date];
}

- (void)drawUsageLens {
    UsageLens *l = self.lens;
    CGFloat a = MIN(1, l.amount);
    if (a < 0.003) return;
    CGFloat ease = 1 - pow(1 - a, 3);                      // open fast, settle softly
    int pct = [self.lensCell[1] intValue];
    int remaining = UsageRemainingPercent(pct);
    int windowMin = [self.lensCell[6] intValue];
    int resetMin = self.lensResetDate ? MAX(0, (int)ceil([self.lensResetDate timeIntervalSinceNow] / 60)) : -1;
    // Where we are in the window. The API gives minutes to the reset; the
    // window length is fixed, so the elapsed part follows.
    BOOL timed = resetMin >= 0 && windowMin > 0;
    double remainingMin = timed ? MIN(resetMin, windowMin) : 0;
    double elapsedMin = timed ? windowMin - remainingMin : 0;
    NSColor *tint = remaining <= 10
        ? [NSColor colorWithSRGBRed:1 green:0.32 blue:0.34 alpha:1]
        : remaining <= 50 ? [NSColor colorWithSRGBRed:1 green:0.76 blue:0.34 alpha:1]
        : ProviderAccent(self.lensCell[4], YES);

    [NSGraphicsContext saveGraphicsState];
    NSRectClip(NSMakeRect(READ_X - 2, 0, READ_W + 4, kSceneH));
    // Backdrop: the readout goes dark, with a breath of the provider's colour
    // rising from the bottom edge so the panel feels lit rather than cut out.
    [[NSColor colorWithWhite:0 alpha:a * 0.985] set];
    NSRectFill(NSMakeRect(READ_X - 2, 0, READ_W + 4, kSceneH));
    NSGradient *wash = [[NSGradient alloc] initWithStartingColor:[tint colorWithAlphaComponent:a * 0.10]
                                                    endingColor:[tint colorWithAlphaComponent:0]];
    [wash drawInRect:NSMakeRect(READ_X - 2, 0, READ_W + 4, 14) angle:90];

    // --- ring gauge ---------------------------------------------------------
    CGFloat cx = PANEL_RING_X, cy = 15, r = 10.2;
    for (int i = 4; i >= 1; i--) {                             // bloom behind the glass
        [[tint colorWithAlphaComponent:a * 0.03] set];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - r - i * 1.5, cy - r - i * 1.5,
                                                            2 * (r + i * 1.5), 2 * (r + i * 1.5))] fill];
    }
    NSBezierPath *ringTrack = [NSBezierPath bezierPath];
    [ringTrack appendBezierPathWithArcWithCenter:NSMakePoint(cx, cy) radius:r startAngle:0 endAngle:360];
    ringTrack.lineWidth = 2.4;
    [[NSColor colorWithWhite:1 alpha:a * 0.13] set]; [ringTrack stroke];
    CGFloat sweep = 360.0 * MAX(0, remaining) / 100.0 * ease;
    if (sweep > 0.5) {
        NSBezierPath *arc = [NSBezierPath bezierPath];
        [arc appendBezierPathWithArcWithCenter:NSMakePoint(cx, cy) radius:r
                                    startAngle:90 endAngle:90 - sweep clockwise:YES];
        arc.lineWidth = 2.4; arc.lineCapStyle = NSLineCapStyleRound;
        [[tint colorWithAlphaComponent:a * 0.35] set]; arc.lineWidth = 4.2; [arc stroke];   // glow
        [[tint colorWithAlphaComponent:a] set]; arc.lineWidth = 2.4; [arc stroke];
        // A bright bead at the arc's leading end.
        CGFloat ang = (90 - sweep) * M_PI / 180;
        [[NSColor colorWithWhite:1 alpha:a * 0.9] set];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx + cos(ang) * r - 1.3, cy + sin(ang) * r - 1.3, 2.6, 2.6)] fill];
    }
    if (remaining <= 10) {                                   // critical: the ring breathes
        CGFloat beat = pow(MAX(0, sin(l.clock * M_PI * 2 / 2.2)), 4);
        [[tint colorWithAlphaComponent:beat * a * 0.22] set];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - r + 1, cy - r + 1, 2 * r - 2, 2 * r - 2)] fill];
    }
    NSString *core = remaining < 0 ? @"—" : [NSString stringWithFormat:@"%d", (int)lround(remaining * ease)];
    NSDictionary *coreStyle = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:(core.length > 2 ? 7.5 : 9) weight:NSFontWeightBold],
                                 NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:a] };
    [core drawAtPoint:NSMakePoint(cx - [core sizeWithAttributes:coreStyle].width / 2, cy - 5.5) withAttributes:coreStyle];

    // --- title row --------------------------------------------------------------
    CGFloat slide = (1 - ease) * 6;
    NSDictionary *titleStyle = @{ NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
                                  NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:a] };
    NSDictionary *leftStyle  = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightBold],
                                  NSForegroundColorAttributeName: [tint colorWithAlphaComponent:a] };
    NSDictionary *dimStyle   = @{ NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightMedium],
                                  NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:a * 0.55] };
    NSDictionary *strongStyle = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightBold],
                                   NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:a] };
    NSString *title = self.lensCell[5];
    [title drawAtPoint:NSMakePoint(PANEL_TEXT_X + slide, 16) withAttributes:titleStyle];
    CGFloat tw = [title sizeWithAttributes:titleStyle].width;
    if (remaining >= 0)
        [[NSString stringWithFormat:@"%d%% left", remaining]
            drawAtPoint:NSMakePoint(PANEL_TEXT_X + slide + tw + 8, 16) withAttributes:leftStyle];

    // Right: when it resets, as a countdown and as a clock.
    NSString *resetDur = resetMin < 0 ? @"—" : UsageDurationDisplay(resetMin);
    NSString *clock = self.lensResetDate ? ClockLabel(self.lensResetDate, resetMin >= 20 * 60) : @"";
    NSAttributedString *right = [[NSAttributedString alloc] initWithString:@""];
    NSMutableAttributedString *rs = [NSMutableAttributedString new];
    [rs appendAttributedString:[[NSAttributedString alloc] initWithString:@"resets in " attributes:dimStyle]];
    [rs appendAttributedString:[[NSAttributedString alloc] initWithString:resetDur attributes:strongStyle]];
    if (clock.length)
        [rs appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:clock] attributes:dimStyle]];
    right = rs;
    [right drawAtPoint:NSMakePoint(PANEL_RIGHT - right.size.width - slide, 16)];

    // --- timeline ---------------------------------------------------------------
    CGFloat tx0 = PANEL_TRACK_X0, tx1 = PANEL_TRACK_X1, tw0 = tx1 - tx0, ty = 4.0, th = 5.0;
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(tx0, ty, tw0, th) xRadius:2.5 yRadius:2.5];
    [[NSColor colorWithWhite:1 alpha:a * 0.10] set]; [track fill];
    CGFloat nowX = tx0;
    if (timed) {
        nowX = tx0 + tw0 * (elapsedMin / windowMin) * ease;
        [NSGraphicsContext saveGraphicsState];
        [track addClip];
        [[NSColor colorWithWhite:1 alpha:a * 0.22] set];                 // passed
        NSRectFill(NSMakeRect(tx0, ty, nowX - tx0, th));
        NSGradient *future = [[NSGradient alloc] initWithStartingColor:[tint colorWithAlphaComponent:a * 0.50]
                                                          endingColor:[tint colorWithAlphaComponent:a * 0.16]];
        [future drawInRect:NSMakeRect(nowX, ty, tx1 - nowX, th) angle:0];  // still to come
        [NSGraphicsContext restoreGraphicsState];
        // Quarter ticks turn the track into a scale.
        [[NSColor colorWithWhite:1 alpha:a * 0.25] set];
        for (int q = 1; q < 4; q++) NSRectFill(NSMakeRect(tx0 + tw0 * q / 4.0, ty, 0.8, th));
        // "Now": a bright marker with a soft pulse.
        CGFloat pulse = 0.6 + 0.4 * sin(l.clock * 4.0);
        [[tint colorWithAlphaComponent:a * 0.35 * pulse] set];
        NSRectFill(NSMakeRect(nowX - 2.5, ty - 1.5, 5, th + 3));
        [[NSColor colorWithWhite:1 alpha:a] set];
        NSRectFill(NSMakeRect(nowX - 0.8, ty - 1.5, 1.6, th + 3));
    }

    // --- bottom-right copy: where we are, or the clock under the finger --------
    NSString *copy;
    NSColor *copyInk = [NSColor colorWithWhite:1 alpha:0.75];
    if (l.scrubbing && timed) {
        CGFloat fx = MAX(tx0, MIN(tx1, l.x));
        double delta = (fx - tx0) / tw0 * windowMin - elapsedMin;          // minutes from now
        NSDate *at = [NSDate dateWithTimeIntervalSinceNow:delta * 60];
        BOOL withDay = fabs(delta) >= 20 * 60;
        if (delta >= 1)       copy = [NSString stringWithFormat:@"in %@ · %@", UsageDurationDisplay((int)delta), ClockLabel(at, withDay)];
        else if (delta <= -1) copy = [NSString stringWithFormat:@"%@ ago · %@", UsageDurationDisplay((int)-delta), ClockLabel(at, withDay)];
        else                  copy = [NSString stringWithFormat:@"now · %@", ClockLabel(at, NO)];
        copyInk = NSColor.whiteColor;
        // Cursor: a line through the track with a bead on top, and the span
        // between it and now lit up.
        [[tint colorWithAlphaComponent:a * 0.30] set];
        NSRectFill(NSMakeRect(MIN(nowX, fx), ty, fabs(fx - nowX), th));
        [[NSColor colorWithWhite:1 alpha:a * 0.9] set];
        NSRectFill(NSMakeRect(fx - 0.5, 1.5, 1, th + 5));
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(fx - 1.8, ty + th + 1.2, 3.6, 3.6)] fill];
    } else if (timed) {
        NSString *span = windowMin % 1440 == 0 ? [NSString stringWithFormat:@"%dd", windowMin / 1440]
                                              : [NSString stringWithFormat:@"%dh", windowMin / 60];
        copy = [NSString stringWithFormat:@"%@ into the %@ window", UsageDurationDisplay((int)elapsedMin), span];
    } else {
        copy = @"reset time unavailable";
    }
    NSMutableDictionary *copyStyle = [@{ NSFontAttributeName: [NSFont systemFontOfSize:8.5 weight:NSFontWeightSemibold],
                                         NSForegroundColorAttributeName: [copyInk colorWithAlphaComponent:a] } mutableCopy];
    CGFloat maxW = PANEL_RIGHT - tx1 - 10, size = 8.5;
    while ([copy sizeWithAttributes:copyStyle].width > maxW && size > 7) {
        size -= 0.25;
        copyStyle[NSFontAttributeName] = [NSFont systemFontOfSize:size weight:NSFontWeightSemibold];
    }
    [copy drawAtPoint:NSMakePoint(PANEL_RIGHT - [copy sizeWithAttributes:copyStyle].width, 2.5) withAttributes:copyStyle];

    [NSGraphicsContext restoreGraphicsState];
}

- (void)drawCell:(NSString *)label pct:(int)pct provider:(NSString *)provider
           shown:(double)shownRemaining index:(NSInteger)index
               x:(CGFloat)x width:(CGFloat)w dim:(CGFloat)dim
          effect:(CGFloat)effect resetLabel:(NSString *)resetLabel {
    BOOL unavailable = pct < 0;
    // Colour follows the real reading; the figure and fill follow the glide.
    int remaining = unavailable ? -1 : (int)lround(shownRemaining);
    UsageRemainingLevel level = UsageRemainingLevelForUsedPercent(pct);
    NSColor *ink;
    if (level == UsageRemainingLevelCritical)
        ink = [NSColor colorWithSRGBRed:0.902 green:0.208 blue:0.180 alpha:1.0];  // ≤10% left
    else if (level == UsageRemainingLevelWarning)
        ink = [NSColor colorWithSRGBRed:0.949 green:0.706 blue:0.161 alpha:1.0];  // ≤50% left
    else
        ink = ProviderAccent(provider, NO);

    BOOL compact = w < 82;
    CGFloat labelSize = effect > 0 ? 8.0 : (compact ? 7.0 : 10.0);
    // A window with no reading is deliberately quieter than a live gauge: it
    // should read as "nothing to report here", not as a loading bar that broke.
    CGFloat quiet = unavailable ? 0.55 : 1.0;
    NSDictionary *lb = @{ NSFontAttributeName: [NSFont systemFontOfSize:labelSize weight:NSFontWeightSemibold],
                          NSForegroundColorAttributeName: [ProviderAccent(provider, NO)
                              colorWithAlphaComponent:(0.85 + effect * 0.15) * dim * quiet] };
    [resetLabel drawAtPoint:NSMakePoint(x, TEXT_Y) withAttributes:lb];

    NSString *num = unavailable ? @"—" : UsageRemainingDisplay(pct);
    NSDictionary *nu = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:(compact ? 8 : 12)
                                                                                weight:NSFontWeightBold],
                          NSForegroundColorAttributeName: unavailable
                              ? [NSColor colorWithWhite:1.0 alpha:0.40 * dim]
                              : [ink colorWithAlphaComponent:dim] };
    if (!compact) {
        // Big figure, then a small "left" on the same baseline. Measure rather
        // than assume: drop the suffix first, then shrink, so the number never
        // collides with the label whatever the cell width turns out to be.
        CGFloat budget = w - [resetLabel sizeWithAttributes:lb].width - 6;
        NSString *figure = unavailable ? @"—" : [NSString stringWithFormat:@"%d%%", remaining];
        NSColor *figInk = unavailable ? [NSColor colorWithWhite:1.0 alpha:0.40 * dim]
                                      : [ink colorWithAlphaComponent:dim];
        NSFont *big = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightBold];
        NSFont *small = [NSFont systemFontOfSize:7.5 weight:NSFontWeightSemibold];
        NSDictionary *bigAt = @{ NSFontAttributeName: big, NSForegroundColorAttributeName: figInk };
        NSDictionary *smallAt = @{ NSFontAttributeName: small,
                                   NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.5 * dim] };
        CGFloat bigW = [figure sizeWithAttributes:bigAt].width;
        if (bigW > budget) {
            big = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightBold];
            bigAt = @{ NSFontAttributeName: big, NSForegroundColorAttributeName: figInk };
            bigW = [figure sizeWithAttributes:bigAt].width;
        }
        // Whether "left" fits is decided once for the whole row, from the worst
        // case (the longest label beside the widest figure), so a bar never has
        // the suffix on some cells and not others as the numbers change.
        NSString *suffix = unavailable ? nil : @"left";
        CGFloat sufW = suffix ? [suffix sizeWithAttributes:smallAt].width + 2 : 0;
        NSFont *refBig = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightBold];
        CGFloat worst = [@"Claude 5h" sizeWithAttributes:lb].width +
                        [@"100%" sizeWithAttributes:@{ NSFontAttributeName: refBig }].width + sufW + 6;
        if (worst > w) sufW = 0;
        CGFloat baseline = (TEXT_Y - 1) - big.descender;
        if (sufW > 0)
            [suffix drawAtPoint:NSMakePoint(x + w - sufW + 2, baseline + small.descender) withAttributes:smallAt];
        [figure drawAtPoint:NSMakePoint(x + w - sufW - bigW, baseline + big.descender) withAttributes:bigAt];
    }

    // The selected cell briefly grows upward and gains a soft halo. It is
    // feedback for a fingertip, not a persistent fifth visual state.
    CGFloat barH = BAR_H + effect * 3.0;
    CGFloat barY = BAR_Y;
    if (effect > 0) {
        [[ink colorWithAlphaComponent:0.15 * effect] set];
        NSRectFill(NSInsetRect(NSMakeRect(x, barY, w, barH), -2.0, -1.2));
    }
    // Nearly out: the bar breathes a red halo so it is noticed at a glance.
    if (!unavailable && level == UsageRemainingLevelCritical) {
        CGFloat pulse = 0.5 + 0.5 * sin(self.fxClock * 5.0);
        for (int k = 3; k >= 1; k--) {
            [[ink colorWithAlphaComponent:(0.10 + 0.14 * pulse) / k * dim] set];
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(NSMakeRect(x, barY, w, barH), -k * 0.9, -k * 0.9)
                                             xRadius:3 + k yRadius:3 + k] fill];
        }
    }
    // The track is the 100% reference, not decoration — keep it readable.
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, barY, w, barH) xRadius:3 yRadius:3];
    if (unavailable) {
        // Hollow track with fine diagonal hatching: empty by design.
        [[NSColor colorWithWhite:0.11 alpha:dim] set];
        [track fill];
        [NSGraphicsContext saveGraphicsState];
        [track addClip];
        [[NSColor colorWithWhite:1.0 alpha:0.10 * dim] set];
        NSBezierPath *hatch = [NSBezierPath bezierPath];
        hatch.lineWidth = 0.8;
        for (CGFloat hx = x - barH; hx < x + w; hx += 4.0) {
            [hatch moveToPoint:NSMakePoint(hx, barY)];
            [hatch lineToPoint:NSMakePoint(hx + barH, barY + barH)];
        }
        [hatch stroke];
        [NSGraphicsContext restoreGraphicsState];
        [[NSColor colorWithWhite:1.0 alpha:0.14 * dim] set];
        track.lineWidth = 0.6;
        [track stroke];
    } else {
        [[NSColor colorWithWhite:0.20 alpha:dim] set];
        [track fill];
    }

    CGFloat fillW = unavailable ? 0 : w * MAX(0, MIN(100, shownRemaining)) / 100.0;
    if (fillW > 0) {
        [NSGraphicsContext saveGraphicsState];
        [track addClip];
        NSRectClip(NSMakeRect(x, barY, fillW, barH));
        NSColor *top = [ink blendedColorWithFraction:0.18 ofColor:NSColor.whiteColor];
        NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:[ink colorWithAlphaComponent:dim]
                                                           endingColor:[top colorWithAlphaComponent:dim]];
        [gradient drawInRect:NSMakeRect(x, barY, w, barH) angle:90];
        [[NSColor colorWithWhite:1 alpha:0.15 * dim] set];
        NSRectFill(NSMakeRect(x, barY + barH - 1, fillW, 0.5));

        // Gloss: a slanted highlight runs along the fill every few seconds,
        // each cell a beat after the previous one.
        double local = (self.fxClock - self.glossAt - index * 0.14) / 0.9;
        if (local >= 0 && local <= 1) {
            CGFloat bx = x - 16 + local * (fillW + 32);
            NSGradient *shine = [[NSGradient alloc] initWithColorsAndLocations:
                [NSColor colorWithWhite:1 alpha:0], 0.0,
                [NSColor colorWithWhite:1 alpha:0.55 * dim], 0.5,
                [NSColor colorWithWhite:1 alpha:0], 1.0, nil];
            NSAffineTransform *slant = NSAffineTransform.transform;
            NSBezierPath *band = [NSBezierPath bezierPathWithRect:NSMakeRect(bx - 7, barY - 2, 14, barH + 4)];
            [slant translateXBy:bx yBy:barY + barH / 2];
            [slant rotateByDegrees:-22];
            [slant translateXBy:-bx yBy:-(barY + barH / 2)];
            [band transformUsingAffineTransform:slant];
            [shine drawInBezierPath:band angle:0];
        }
        [NSGraphicsContext restoreGraphicsState];

        // A lit leading edge makes the fill read as live liquid, not paint.
        if (fillW < w - 1) {
            [NSGraphicsContext saveGraphicsState];
            [track addClip];
            CGFloat flicker = 0.75 + 0.25 * sin(self.fxClock * 7.0 + index);
            [[top colorWithAlphaComponent:0.30 * flicker * dim] set];
            NSRectFill(NSMakeRect(x + fillW - 1.5, barY, 4.0, barH));
            [[NSColor colorWithWhite:1 alpha:0.75 * flicker * dim] set];
            NSRectFill(NSMakeRect(x + fillW - 0.9, barY + 0.5, 1.0, barH - 1));
            [NSGraphicsContext restoreGraphicsState];
        }
    }

    // Four limits leave a narrow cell. Keep the full provider/window label on
    // its own line and print the longer "38% left" inside the bar, rather than
    // squeezing the two strings until they overlap.
    if (compact && unavailable) {
        NSDictionary *muted = @{ NSFontAttributeName: nu[NSFontAttributeName],
                                 NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.45 * dim] };
        CGFloat dw = [num sizeWithAttributes:muted].width;
        [num drawAtPoint:NSMakePoint(x + (w - dw) / 2, barY - 0.5) withAttributes:muted];
    } else if (compact) {
        NSShadow *shadow = [NSShadow new];
        shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.9];
        shadow.shadowOffset = NSMakeSize(0, -1);
        NSDictionary *compactNum = @{ NSFontAttributeName: nu[NSFontAttributeName],
                                      NSForegroundColorAttributeName: NSColor.whiteColor,
                                      NSShadowAttributeName: shadow };
        DrawRight(num, x + w - 2, barY - 0.5, compactNum);
    }
}

@end

#pragma mark - App

#pragma mark - Palette picker

// `--palette` puts candidate colours on the actual Touch Bar side by side.
// Renders to PNG are useful for layout, but a colour has to be judged on the
// panel it will live on — this one is dim, warm, and viewed at a glance.
@interface PaletteView : NSView
@end

// `--ruler`: how much width does the system actually give us? Ask for far more
// than we think we have and read the answer off the bar.
@interface RulerView : NSView
@end

// `--sweat`: four sweat treatments animating side by side on the real panel.
// Sweat is motion, so a still render cannot settle it — and neither can I,
// since the bar cannot be screenshotted.
@interface SweatView : NSView
@property (nonatomic) NSTimeInterval t;
@end
@implementation PaletteView
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)dirty {
    [NSColor.clearColor set];
    NSRectFill(dirty);

    // Two rows: amber candidates above, red below. Both are judged against the
    // blue that was already chosen, so that one is drawn at the far left as a
    // fixed reference rather than left to memory.
    NSColor *chosenBlue = [NSColor colorWithSRGBRed:0.173 green:0.533 blue:0.945 alpha:1.0];  // E

    NSArray *ambers = @[
        @[@"1", [NSColor colorWithSRGBRed:0.961 green:0.831 blue:0.400 alpha:1.0]],  // F5D466
        @[@"2", [NSColor colorWithSRGBRed:0.957 green:0.773 blue:0.267 alpha:1.0]],  // F4C544
        @[@"3", [NSColor colorWithSRGBRed:0.949 green:0.706 blue:0.161 alpha:1.0]],  // F2B429
        @[@"4", [NSColor colorWithSRGBRed:0.937 green:0.639 blue:0.129 alpha:1.0]],  // EFA321
    ];
    NSArray *reds = @[
        @[@"1", [NSColor colorWithSRGBRed:0.937 green:0.427 blue:0.376 alpha:1.0]],  // EF6D60
        @[@"2", [NSColor colorWithSRGBRed:0.925 green:0.318 blue:0.263 alpha:1.0]],  // EC5143
        @[@"3", [NSColor colorWithSRGBRed:0.902 green:0.208 blue:0.180 alpha:1.0]],  // E6352E
        @[@"4", [NSColor colorWithSRGBRed:0.996 green:0.271 blue:0.227 alpha:1.0]],  // FE453A
    ];

    NSDictionary *lb = @{ NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightBold],
                          NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.75] };

    // Reference: the chosen blue, full height, so both rows sit next to it.
    [@"blue" drawAtPoint:NSMakePoint(4, 9) withAttributes:lb];
    [[NSColor colorWithWhite:1.0 alpha:0.36] set];
    NSRectFill(NSMakeRect(34, 2, 44, 26));
    [chosenBlue set];
    NSRectFill(NSMakeRect(34, 2, 44 * 0.48, 26));

    CGFloat x0 = 92, avail = NSWidth(self.bounds) - x0 - 6;
    CGFloat w = avail / ambers.count;

    for (NSInteger i = 0; i < ambers.count; i++) {
        CGFloat x = x0 + i * w, cw = w - 10;
        // amber row (top)
        [[NSString stringWithFormat:@"A%@", ambers[i][0]] drawAtPoint:NSMakePoint(x, 16) withAttributes:lb];
        [[NSColor colorWithWhite:1.0 alpha:0.36] set];
        NSRectFill(NSMakeRect(x + 22, 17, cw - 22, 9));
        [(NSColor *)ambers[i][1] set];
        NSRectFill(NSMakeRect(x + 22, 17, (cw - 22) * 0.68, 9));

        // red row (bottom)
        [[NSString stringWithFormat:@"R%@", reds[i][0]] drawAtPoint:NSMakePoint(x, 2) withAttributes:lb];
        [[NSColor colorWithWhite:1.0 alpha:0.36] set];
        NSRectFill(NSMakeRect(x + 22, 3, cw - 22, 9));
        [(NSColor *)reds[i][1] set];
        NSRectFill(NSMakeRect(x + 22, 3, (cw - 22) * 0.94, 9));
    }
}
@end

@implementation SweatView
- (BOOL)isFlipped { return NO; }
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        [NSTimer scheduledTimerWithTimeInterval:1.0/15.0 repeats:YES block:^(NSTimer *tm) {
            self.t += 1.0/15.0; self.needsDisplay = YES;
        }];
    }
    return self;
}
// A pixel teardrop: narrow at the top, widest just below centre, rounded off.
// Two flat rectangles read as a blob; the silhouette is what makes it water.
static void DrawDrop(CGFloat x, CGFloat y, CGFloat scale, NSColor *c, CGFloat alpha) {
    [[c colorWithAlphaComponent:alpha] set];
    CGFloat u = scale;
    NSRectFill(NSMakeRect(x + u * 0.9, y + u * 3.4, u * 1.0, u * 1.1));   // tip
    NSRectFill(NSMakeRect(x + u * 0.5, y + u * 2.3, u * 1.8, u * 1.2));
    NSRectFill(NSMakeRect(x,           y + u * 0.9, u * 2.8, u * 1.5));   // belly
    NSRectFill(NSMakeRect(x + u * 0.4, y,           u * 2.0, u * 1.0));   // base
    [[NSColor colorWithWhite:1.0 alpha:alpha * 0.55] set];
    NSRectFill(NSMakeRect(x + u * 0.55, y + u * 1.7, u * 0.7, u * 0.9));  // highlight
}

- (void)drawRect:(NSRect)d {
    [NSColor.clearColor set]; NSRectFill(d);
    NSColor *body = [NSColor colorWithSRGBRed:0.804 green:0.498 blue:0.416 alpha:1.0];
    NSColor *drop = [NSColor colorWithSRGBRed:0.45 green:0.76 blue:0.98 alpha:1.0];
    NSDictionary *lb = @{ NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightBold],
                          NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.8] };
    const unsigned char *base = kClawdClips[0].frames[0].grid;
    CGFloat px = 1.95, t = self.t;
    CGFloat w = NSWidth(self.bounds) / 4.0;

    for (int v = 0; v < 4; v++) {
        CGFloat cx = v * w + w * 0.45;
        [[NSString stringWithFormat:@"%c", 'A' + v] drawAtPoint:NSMakePoint(v * w + 6, 16) withAttributes:lb];

        CGFloat jx = sin(t * 16.0) * 1.3 + sin(t * 6.0) * 0.6;
        CGFloat jy = sin(t * 13.0) * 1.5 + cos(t * 21.0) * 0.5;
        NSPoint p = NSMakePoint(cx + jx, 2 + jy);
        DrawGridLean(WalkFrame(base, (int)(t * 34.0)), p, px, NO, body, 0.15, NULL, 0,
                     CLAWD_TOP, CLAWD_BOT);
        CGFloat hy = p.y + CLAWD_ROWS * px;

        if (v == 0) {          // A: หยดเดียว ค้างข้างหัว ทรงหยดน้ำ สั่นตามตัว
            DrawDrop(p.x + 10, hy - 5, 1.5, drop, 0.95);
        } else if (v == 1) {   // B: หยดค้าง + ไหลลงช้าๆ แล้ววนใหม่
            CGFloat pr = fmod(t * 0.55, 1.0);
            DrawDrop(p.x + 10, hy - 3 - pr * 11, 1.5, drop, pr > 0.75 ? (1 - pr) * 4 : 0.95);
        } else if (v == 2) {   // C: หยดใหญ่ค้าง + หยดเล็กกระเด็นอีกฝั่ง
            DrawDrop(p.x + 10, hy - 4, 1.8, drop, 0.95);
            for (int i = 0; i < 2; i++) {
                CGFloat pr = fmod(t * 1.7 + i * 0.5, 1.0);
                if (pr > 0.7) continue;
                DrawDrop(p.x - 12 - pr * 7, hy - 1 + pr * 4, 0.9, drop, 0.9 * (1 - pr / 0.7));
            }
        } else {               // D: 2 หยดคนละข้าง สั่นคนละจังหวะ
            DrawDrop(p.x + 10, hy - 4 + sin(t * 11.0) * 0.8, 1.5, drop, 0.95);
            DrawDrop(p.x - 13, hy - 6 + sin(t * 9.0 + 1.7) * 0.8, 1.2, drop, 0.9);
        }
    }
}
@end

@implementation RulerView
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)d {
    [NSColor.clearColor set]; NSRectFill(d);
    NSDictionary *a = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10
                                                                              weight:NSFontWeightBold],
                         NSForegroundColorAttributeName: NSColor.whiteColor };
    // Ticks at fixed coordinates only. An earlier version drew a marker at
    // NSWidth(bounds)-6, which sits at the view's own edge no matter how wide
    // the view is — it always looked like the full width had been granted.
    for (int x = 0; x <= 900; x += 25) {
        BOOL hundred = (x % 100 == 0), fifty = (x % 50 == 0);
        [[NSColor colorWithWhite:1.0 alpha:hundred ? 1.0 : (fifty ? 0.6 : 0.3)] set];
        NSRectFill(NSMakeRect(x, 0, hundred ? 2 : 1, hundred ? 12 : (fifty ? 7 : 4)));
        if (hundred && x > 0)
            [[NSString stringWithFormat:@"%d", x] drawAtPoint:NSMakePoint(x + 3, 14) withAttributes:a];
    }
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTouchBarDelegate>
@property (nonatomic) BOOL paletteMode;
@property (nonatomic) BOOL rulerMode;
@property (nonatomic) BOOL sweatMode;
@property (nonatomic) BOOL demoMode;
@property (nonatomic, strong) NSTouchBar *bar;
@property (nonatomic, strong) PetView *pet;
@property (nonatomic, strong) NSTimer *frameTimer;
@property (nonatomic, strong) dispatch_queue_t shell;
@property (nonatomic, strong) id activity;
@property (nonatomic) NSTimeInterval lastFrame;
@property (nonatomic) NSTimeInterval lastPoll;
@property (nonatomic) BOOL polling, asleep, dark;
@property (nonatomic) double petFrameAccumulator;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.shell = dispatch_queue_create("local.claude-touchbar.shell", DISPATCH_QUEUE_SERIAL);
    // LaunchServices can deliver the application-finished notification while
    // it is still normalising launch arguments. Re-read the process arguments
    // here so --demo-pro reaches the view even in an app-bundle launch.
    self.demoMode = self.demoMode ||
        [NSProcessInfo.processInfo.arguments containsObject:@"--demo-pro"];

    if (![NSTouchBar respondsToSelector:@selector(presentSystemModalTouchBar:placement:systemTrayItemIdentifier:)]) {
        NSLog(@"claude-touchbar: system-modal Touch Bar SPI missing — exiting.");
        [NSApp terminate:nil];
        return;
    }

    DFRSystemModalShowsCloseBoxWhenFrontMost(NO);

    if (self.paletteMode || self.rulerMode || self.sweatMode) {
        self.bar = [NSTouchBar new];
        self.bar.delegate = self;
        self.bar.defaultItemIdentifiers = @[kSceneID];
        [self present];
        NSLog(@"palette mode — press Ctrl-C to exit");
        return;
    }

    self.pet = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, kSceneW, kSceneH)];
    self.pet.fxCountUp = YES;   // the live bar counts its readings up on arrival
    if (self.demoMode) {
        UsageProvider *claude = DemoUsageProvider(@"claude");
        UsageProvider *codex = DemoUsageProvider(@"codex");
        self.pet.p5 = claude.p5; self.pet.p7 = claude.p7;
        self.pet.resetMin = claude.resetMin; self.pet.reset7dMin = claude.reset7dMin;
        self.pet.ageSec = claude.ageSec;
        self.pet.state = claude.state;
        self.pet.codexP5 = codex.p5; self.pet.codexP7 = codex.p7;
        self.pet.codexResetMin = codex.resetMin; self.pet.codexReset7dMin = codex.reset7dMin;
        self.pet.codexAgeSec = codex.ageSec;
        self.pet.codexState = codex.state; self.pet.codexHaveData = YES;
        self.pet.haveData = YES; self.pet.demoMode = YES;
    }

    self.bar = [NSTouchBar new];
    self.bar.delegate = self;
    self.bar.defaultItemIdentifiers = @[kSceneID];

    [self present];

    // App Nap will freeze the animation the moment you switch away, which is
    // precisely when the pet is worth watching. Do not prevent idle sleep.
    self.activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                                                                 reason:@"animate the Touch Bar pet"];

    self.lastFrame = NSDate.timeIntervalSinceReferenceDate;
    self.frameTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0 repeats:YES
                                                        block:^(NSTimer *t) { [self frame]; }];
    // .common mode: default-mode timers stall inside menu/tracking loops.
    [NSRunLoop.mainRunLoop addTimer:self.frameTimer forMode:NSRunLoopCommonModes];

    // A presented bar yields when another app presents its own, so re-assert on
    // every app switch. Cheap and idempotent.
    [NSWorkspace.sharedWorkspace.notificationCenter
        addObserver:self selector:@selector(present)
               name:NSWorkspaceDidActivateApplicationNotification object:nil];

    // Don't animate into a locked screen.
    [NSDistributedNotificationCenter.defaultCenter
        addObserver:self selector:@selector(sleep) name:@"com.apple.screenIsLocked" object:nil];
    [NSDistributedNotificationCenter.defaultCenter
        addObserver:self selector:@selector(wake) name:@"com.apple.screenIsUnlocked" object:nil];
    // A display may sleep without locking. Keep these states independent so
    // waking the display does not resume animation while the screen is locked.
    [NSWorkspace.sharedWorkspace.notificationCenter
        addObserver:self selector:@selector(screensSlept:)
               name:NSWorkspaceScreensDidSleepNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter
        addObserver:self selector:@selector(screensWoke:)
               name:NSWorkspaceScreensDidWakeNotification object:nil];

    if (self.demoMode) NSLog(@"Claude Pro + ChatGPT Pro demo mode — no account data queried");
    else [self poll];
}

- (void)present {
    [NSTouchBar presentSystemModalTouchBar:self.bar placement:0 systemTrayItemIdentifier:nil];
}

- (void)sleep { self.asleep = YES; [self.pet.lens cancel]; }
- (void)wake  { self.asleep = NO; self.lastFrame = NSDate.timeIntervalSinceReferenceDate; [self present]; }
- (void)screensSlept:(NSNotification *)note { self.dark = YES; [self.pet.lens cancel]; }
- (void)screensWoke:(NSNotification *)note {
    self.dark = NO;
    self.lastFrame = NSDate.timeIntervalSinceReferenceDate;
}

- (nullable NSTouchBarItem *)touchBar:(NSTouchBar *)bar
                makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier {
    if ([identifier isEqualToString:kSceneID]) {
        NSCustomTouchBarItem *it = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
        if (self.sweatMode)
            it.view = [[SweatView alloc] initWithFrame:NSMakeRect(0, 0, kSceneW, kSceneH)];
        else if (self.rulerMode)
            it.view = [[RulerView alloc] initWithFrame:NSMakeRect(0, 0, 900, kSceneH)];
        else if (self.paletteMode)
            it.view = [[PaletteView alloc] initWithFrame:NSMakeRect(0, 0, kSceneW, kSceneH)];
        else
            it.view = self.pet;
        return it;
    }
    return nil;
}

- (void)frame {
    if (self.asleep || self.dark) return;

    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    NSTimeInterval dt = MIN(now - self.lastFrame, 0.25);   // clamp after a stall
    self.lastFrame = now;

    [self.pet advanceLens:dt];
    [self.pet advanceFX:dt];
    self.petFrameAccumulator += dt;
    while (self.petFrameAccumulator >= 1.0 / kFPS) {
        [self.pet advance:1.0 / kFPS];
        self.petFrameAccumulator -= 1.0 / kFPS;
    }

    // Demo values are intentionally isolated from real credentials. Without
    // this guard the 30-second poll overwrites its Claude sample with the
    // account's expired state after the demo first appears.
    if (!self.demoMode && now - self.lastPoll >= 30.0) {
        self.lastPoll = now;
        [self poll];
    }
}

- (void)poll {
    if (self.polling) return;
    self.polling = YES;

    dispatch_async(self.shell, ^{
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
        task.arguments = @[@"-lc", kScript];
        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = NSFileHandle.fileHandleWithNullDevice;

        NSString *out = nil;
        NSError *err = nil;
        if ([task launchAndReturnError:&err]) {
            NSData *d = [pipe.fileHandleForReading readDataToEndOfFile];
            [task waitUntilExit];
            out = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        }

        // Parse only complete, validated protocol lines. A provider with no
        // usable record keeps its last good reading, so shell noise, malformed
        // numbers or truncated output cannot blank or corrupt the widget. The
        // same C parser is exercised by tools/test-usage-parser.c.
        NSData *outputData = [out dataUsingEncoding:NSUTF8StringEncoding];
        UsageOutput parsed;
        BOOL valid = ParseUsageOutput(outputData.bytes, outputData.length, &parsed) > 0;

        dispatch_async(dispatch_get_main_queue(), ^{
            UsageProvider *claude = (valid && parsed.valid[UsageProviderClaude])
                ? UsageProviderFromReading(UsageProviderClaude, &parsed.reading[UsageProviderClaude]) : nil;
            UsageProvider *codex = (valid && parsed.valid[UsageProviderCodex])
                ? UsageProviderFromReading(UsageProviderCodex, &parsed.reading[UsageProviderCodex]) : nil;
            if (claude) {
                self.pet.p5 = claude.p5;
                self.pet.p7 = claude.p7;
                self.pet.resetMin = claude.resetMin;
                self.pet.reset7dMin = claude.reset7dMin;
                self.pet.longDays = claude.longDays;
                self.pet.plan = claude.plan;
                self.pet.ageSec = claude.ageSec;
                self.pet.state = claude.state;
            }
            if (codex) {
                self.pet.codexP5 = codex.p5;
                self.pet.codexP7 = codex.p7;
                self.pet.codexResetMin = codex.resetMin;
                self.pet.codexReset7dMin = codex.reset7dMin;
                self.pet.codexLongDays = codex.longDays;
                self.pet.codexPlan = codex.plan;
                self.pet.codexAgeSec = codex.ageSec;
                self.pet.codexState = codex.state;
                self.pet.codexHaveData = codex.available;
            }
            if (claude || codex) self.pet.haveData = YES;   // otherwise keep the last good reading
            self.polling = NO;
        });
    });
}

- (void)applicationWillTerminate:(NSNotification *)note {
    [NSTouchBar dismissSystemModalTouchBar:self.bar];
    if (self.activity) [NSProcessInfo.processInfo endActivity:self.activity];
}

@end

// --render <dir>: draw the readout to PNGs at a spread of states and exit.
// The Touch Bar cannot be screenshotted, so this is the only way to actually
// look at what drawRect: produces instead of guessing from the code.
static int RenderStates(NSString *dir) {
    NSDictionary *states = @{
        @"01-low":      @[@12, @4,  @185, @"ok",      @0,  @""],
        @"02-mid":      @[@48, @31, @92,  @"ok",      @0,  @""],
        @"03-scoped":   @[@48, @31, @92,  @"ok",      @37, @"Fable"],
        @"04-high":     @[@91, @68, @14,  @"ok",      @0,  @""],
        @"05-both-high":@[@94, @96, @3,   @"ok",      @88, @"Fable"],
        @"06-stale":    @[@48, @31, @92,  @"stale",   @0,  @""],
        @"07-expired":  @[@48, @31, @-1,  @"expired", @0,  @""],
        @"08-zero":     @[@0,  @0,  @300, @"ok",      @0,  @""],
        @"09-claude-codex": @[@26, @91, @125, @"ok", @0, @"", @18, @42, @44, @"ok"],
        @"10-codex-stale": @[@26, @91, @125, @"ok", @0, @"", @18, @42, @44, @"stale"],
        @"11-codex-expired": @[@26, @91, @125, @"ok", @0, @"", @0, @0, @-1, @"expired"],
        @"13-no-5h-either": @[@-1, @41, @-1, @"ok", @0, @"", @-1, @0, @-1, @"ok"],
        @"15-free-chatgpt-30d": @[@-1, @41, @-1, @"ok", @0, @"", @-1, @12, @-1, @"ok", @30],
        @"18-plans-two-cells": @[@-1, @53, @-1, @"ok", @0, @"", @-1, @100, @-1, @"ok", @30, @"max_20x", @"free"],
        @"19-plans-three-cells": @[@-1, @53, @-1, @"ok", @0, @"", @18, @42, @44, @"ok", @7, @"max_20x", @"plus"],
        @"20-plans-four-cells": @[@26, @91, @125, @"ok", @0, @"", @18, @42, @44, @"ok", @7, @"pro", @"plus"],
        @"14-claude-no-5h": @[@-1, @41, @-1, @"ok", @0, @"", @18, @42, @44, @"ok"],
        @"12-claude-none": @[@0, @0, @-1, @"none", @0, @"", @18, @42, @44, @"ok"],
    };
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];

    for (NSString *name in [states.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSArray *s = states[name];
        PetView *v = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, kSceneW, kSceneH)];
        v.p5 = [s[0] intValue]; v.p7 = [s[1] intValue]; v.resetMin = [s[2] intValue];
        v.state = s[3]; v.scopedPct = [s[4] intValue]; v.scopedName = s[5];
        if (s.count >= 10) {
            v.codexP5 = [s[6] intValue]; v.codexP7 = [s[7] intValue];
            v.codexResetMin = [s[8] intValue]; v.codexState = s[9];
            v.codexAgeSec = 300;
            if (s.count >= 11) v.codexLongDays = [s[10] intValue];
            if (s.count >= 13) { v.plan = s[11]; v.codexPlan = s[12]; }
            v.codexHaveData = ![v.codexState isEqualToString:@"none"] &&
                               ![v.codexState isEqualToString:@"expired"];
        }
        v.ageSec = 300; v.haveData = YES; v.x = 60;

        // Two passes, and the order matters. drawRect: opens by filling itself
        // with clearColor in copy mode, so anything painted underneath first is
        // wiped — the widget must be drawn onto a transparent surface and only
        // then composited over the dark backdrop, exactly as the Touch Bar
        // does it. Flattening the two into one pass makes every translucent
        // fill read as solid white.
        NSImage *layer = [[NSImage alloc] initWithSize:v.bounds.size];
        [layer lockFocus];
        [v drawRect:v.bounds];
        [layer unlockFocus];

        NSImage *img = [[NSImage alloc] initWithSize:v.bounds.size];
        [img lockFocus];
        // Black, exactly like the Touch Bar: a lighter backdrop lifts every
        // translucent fill and makes measured contrast look better than it is.
        [[NSColor blackColor] set];
        NSRectFill(v.bounds);
        [layer drawInRect:v.bounds fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver fraction:1.0];
        [img unlockFocus];

        NSBitmapImageRep *out = [[NSBitmapImageRep alloc]
            initWithData:[img TIFFRepresentation]];
        NSData *png = [out representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSString *path = [dir stringByAppendingPathComponent:
                          [name stringByAppendingString:@".png"]];
        [png writeToFile:path atomically:YES];
        printf("%s\n", path.UTF8String);
    }
    return 0;
}

// `--shot <out.png> <p5> <p7> <resetMin> <ageSec> [scopedPct scopedName]`:
// one frame at exactly the numbers you ask for. `--render` covers the eight
// states worth reviewing, but a press shot has to match a state that actually
// happened — a photograph of the bar and a render beside it disagreeing on the
// percentages is the kind of detail that makes both look fabricated.
static int RenderShot(NSString *out, int p5, int p7, int resetMin, int ageSec,
                      int scopedPct, NSString *scopedName) {
    PetView *v = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, kSceneW, kSceneH)];
    v.p5 = p5; v.p7 = p7; v.resetMin = resetMin; v.ageSec = ageSec;
    v.scopedPct = scopedPct; v.scopedName = scopedName;
    v.state = @"ok"; v.haveData = YES; v.x = 60;

    // Two passes, for the reason spelled out in RenderStates: drawRect: opens
    // by clearing itself in copy mode, so the backdrop has to go on afterwards.
    NSImage *layer = [[NSImage alloc] initWithSize:v.bounds.size];
    [layer lockFocus];
    [v drawRect:v.bounds];
    [layer unlockFocus];

    NSImage *img = [[NSImage alloc] initWithSize:v.bounds.size];
    [img lockFocus];
    [NSColor.blackColor set];
    NSRectFill(v.bounds);
    [layer drawInRect:v.bounds fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver fraction:1.0];
    [img unlockFocus];

    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithData:[img TIFFRepresentation]];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:out atomically:YES];
    printf("%s (%.0fx%.0f)\n", out.UTF8String,
           (double)rep.pixelsWide, (double)rep.pixelsHigh);
    return 0;
}

// `--poses <dir>`: one PNG per clip, mid-animation, so a new pose can be
// checked for clipping and palette errors without waiting for it to appear.
// `--film <dir> <seconds>`: run the real animation loop headless and write one
// PNG per frame, so the widget can be turned into a GIF without filming a
// screen. Uses the same advance:/drawRect: path as the live app.
static int RenderFilm(NSString *dir, double secs, BOOL lensFilm) {
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];
    PetView *v = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, kSceneW, kSceneH)];
    // Illustrative sample data, chosen to exercise what the widget can show:
    // a Claude plan with no 5h window beside a ChatGPT plan with both, so the
    // subscription labels fit and the cells share the space unevenly.
    v.fxCountUp = !lensFilm;
    v.p5 = -1; v.p7 = 39; v.resetMin = -1; v.plan = @"max_20x";
    v.state = @"ok"; v.haveData = YES; v.x = 60;
    v.codexP5 = 48; v.codexP7 = 57; v.codexResetMin = 126; v.codexAgeSec = 0;
    v.codexState = @"ok"; v.codexHaveData = YES; v.codexPlan = @"plus";
    v.reset7dMin = 2 * 24 * 60 + 180; v.codexReset7dMin = 4 * 24 * 60 + 120;
    if (lensFilm) { v.p5 = 62; v.resetMin = 93; v.plan = nil; v.codexPlan = nil; }

    double fps = lensFilm ? 60 : kFPS;
    int n = (int)(secs * fps);
    for (int i = 0; i < n; i++) {
        // The README film: readings count in, Clawd is tapped into a combo,
        // GPT is tapped, a bar opens its panel, Clawd is thrown, and the sky's
        // first meteor falls at 17.8s.
        if (!lensFilm) {
            if (i == (int)(2.4 * kFPS) || i == (int)(2.7 * kFPS) || i == (int)(3.0 * kFPS)) [v tapMascot:MascotTargetClaude];
            if (i == (int)(5.0 * kFPS)) [v tapMascot:MascotTargetGPT];
            if (i == (int)(7.5 * kFPS)) [v beginLensAt:READ_X + 60];
            if (i == (int)(8.0 * kFPS)) [v.lens end];
            if (i == (int)(12.5 * kFPS)) { v.throwVX = 240; v.act = ActWalk; v.dir = 1; }
        }
        if (lensFilm) {
            // The same entry points as real fingers: tap, hold, scrub, release.
            // Tap Claude 7d (lasts), tap GPT 5h, then scrub the GPT 5h forecast
            // end to end, then a 5h window that will run out before it resets.
            if (i == 36) [v beginLensAt:READ_X + 130];
            if (i == 45) [v.lens end];
            if (i == 240) [v beginLensAt:READ_X + 230];
            if (i >= 252 && i <= 420) {
                double t = (i - 252) / 168.0;
                [v.lens moveTo:PANEL_TRACK_X0 + (0.5 - 0.5 * cos(t * M_PI * 2)) * (PANEL_TRACK_X1 - PANEL_TRACK_X0)];
            }
            if (i == 421) [v.lens end];
            if (i == 500) { v.p5 = 84; v.resetMin = 150; [v beginLensAt:READ_X + 28]; }
            if (i == 560) [v.lens end];
            [v advanceLens:1.0 / fps];
            [v advanceFX:1.0 / fps];
            if (i % 4 == 0) [v advance:1.0 / kFPS];
        } else { [v advanceLens:1.0 / kFPS]; [v advance:1.0 / kFPS]; [v advanceFX:1.0 / kFPS]; }
        NSImage *layer = [[NSImage alloc] initWithSize:v.bounds.size];
        [layer lockFocus]; [v drawRect:v.bounds]; [layer unlockFocus];
        NSImage *img = [[NSImage alloc] initWithSize:v.bounds.size];
        [img lockFocus];
        [NSColor.blackColor set]; NSRectFill(v.bounds);
        [layer drawInRect:v.bounds fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver fraction:1.0];
        [img unlockFocus];
        NSBitmapImageRep *out = [[NSBitmapImageRep alloc] initWithData:img.TIFFRepresentation];
        [[out representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[dir stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"f%04d.png", i]] atomically:YES];
    }
    printf("%d frames at %.0f fps -> %s\n", n, fps, dir.UTF8String);
    return 0;
}

// `--film-fx <dir>`: a scripted tour of the effects at 60fps — count-up on
// arrival, mascot taps building a combo, a bar press, a collision, a throw
// into the wall, a reading changing between polls, and the critical pulse.
static int RenderFilmFX(NSString *dir) {
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];
    PetView *v = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, kSceneW, kSceneH)];
    v.fxCountUp = YES;
    v.p5 = 26; v.p7 = 47; v.resetMin = 125; v.reset7dMin = 3000; v.plan = @"max_20x";
    v.state = @"ok"; v.haveData = YES; v.x = 50; v.dir = 1;
    v.codexP5 = 18; v.codexP7 = 42; v.codexResetMin = 44; v.codexReset7dMin = 5000;
    v.codexState = @"ok"; v.codexHaveData = YES; v.codexPlan = @"plus"; v.gptX = 130;
    double fps = 60;
    int n = (int)(12 * fps);
    for (int i = 0; i < n; i++) {
        double t = i / fps;
        if (i == (int)(1.6 * fps) || i == (int)(1.85 * fps) || i == (int)(2.1 * fps)) [v tapMascot:MascotTargetClaude];
        if (i == (int)(3.0 * fps)) [v tapMascot:MascotTargetGPT];
        if (i == (int)(4.0 * fps)) [v beginLensAt:READ_X + 60];
        if (i == (int)(4.3 * fps)) [v.lens end];
        if (i == (int)(5.5 * fps)) { v.x = v.gptX - 40; v.dir = 1; v.gptDir = -1; }
        if (i == (int)(7.0 * fps)) { v.throwVX = 260; v.act = ActWalk; }
        if (i == (int)(9.0 * fps)) { v.codexP7 = 12; v.p5 = 92; }
        // Frantic tapping: eight taps in a second -> party at x5, dizzy at x8.
        for (int k = 0; k < 10; k++) if (i == (int)((9.6 + k * 0.13) * fps)) [v tapMascot:MascotTargetGPT];
        [v advanceLens:1.0 / fps];
        [v advanceFX:1.0 / fps];
        if (i % 4 == 0) [v advance:1.0 / kFPS];
        (void)t;
        NSImage *layer = [[NSImage alloc] initWithSize:v.bounds.size];
        [layer lockFocus]; [v drawRect:v.bounds]; [layer unlockFocus];
        NSImage *img = [[NSImage alloc] initWithSize:v.bounds.size];
        [img lockFocus];
        [NSColor.blackColor set]; NSRectFill(v.bounds);
        [layer drawInRect:v.bounds fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
        [img unlockFocus];
        NSBitmapImageRep *out = [[NSBitmapImageRep alloc] initWithData:img.TIFFRepresentation];
        [[out representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"f%04d.png", i]] atomically:YES];
    }
    printf("%d frames at 60 fps -> %s\n", n, dir.UTF8String);
    return 0;
}

// `--film-drag <dir>`: scripted sequence — pacing, then grabbed and dragged,
// then thrown. Drives the same state the touch handlers set, so what it records
// is the real reaction rather than a re-creation of it.
static int RenderFilmDrag(NSString *dir) {
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];
    PetView *v = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, kSceneW, kSceneH)];
    v.p5 = 62; v.p7 = 61; v.resetMin = 93; v.scopedPct = 61; v.scopedName = @"Fable";
    v.state = @"ok"; v.haveData = YES; v.x = 90; v.dir = 1;
    v.codexP5 = 48; v.codexP7 = 57; v.codexResetMin = 126; v.codexAgeSec = 0;
    v.codexState = @"ok"; v.codexHaveData = YES;

    double dt = 1.0 / kFPS;
    __block int i = 0;
    void (^shoot)(void) = ^{
        NSImage *layer = [[NSImage alloc] initWithSize:v.bounds.size];
        [layer lockFocus]; [v drawRect:v.bounds]; [layer unlockFocus];
        NSImage *img = [[NSImage alloc] initWithSize:v.bounds.size];
        [img lockFocus];
        [NSColor.blackColor set]; NSRectFill(v.bounds);
        [layer drawInRect:v.bounds fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver fraction:1.0];
        [img unlockFocus];
        NSBitmapImageRep *o = [[NSBitmapImageRep alloc] initWithData:img.TIFFRepresentation];
        [[o representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[dir stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"f%04d.png", i++]] atomically:YES];
    };

    for (int f = 0; f < 30; f++) { [v advance:dt]; shoot(); }      // pacing, 2s

    v.dragging = YES; v.grabDX = 0; v.act = ActClip; v.clipIdx = 4;
    v.clip = 0; v.clipT = 0; v.clipLoops = 3;
    // Same wall the real handler applies — an earlier version of this recorder
    // moved x directly and produced footage of him standing on the readout,
    // which the app itself does not allow.
    CGFloat wall = READ_X - (CLAWD_N * 1.95) / 2.0 - 8;
    CGFloat path[] = {150, 200, 245, 262, 240, 200, 150, 100, 60, 30, 70, 130, 190, 250};
    for (int p = 0; p < (int)(sizeof(path)/sizeof(CGFloat)); p++) {
        for (int f = 0; f < 4; f++) {                              // ~4s held
            v.dragVX = (path[p] - v.x) / 4.0;
            v.x = MAX(20, MIN(v.x + v.dragVX, wall));
            v.lastDragX = v.x;
            if (fabs(v.dragVX) > 0.5) v.dir = (v.dragVX > 0) ? 1 : -1;
            [v advance:dt]; shoot();
        }
    }
    [v releaseDrag];                                                // thrown
    for (int f = 0; f < 60; f++) { [v advance:dt]; shoot(); }       // slide + settle, 4s

    printf("%d frames -> %s\n", i, dir.UTF8String);
    return 0;
}

static int RenderPoses(NSString *dir) {
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES attributes:nil error:nil];
    for (int i = 0; i < kClawdClipCount; i++) {
        const ClawdClip *cl = &kClawdClips[i];
        PetView *v = [[PetView alloc] initWithFrame:NSMakeRect(0, 0, 120, kSceneH)];
        v.p5 = 20; v.p7 = 10; v.state = @"ok"; v.haveData = YES;
        v.x = 60; v.act = ActClip; v.clipIdx = i; v.clip = cl->count / 2;

        NSImage *layer = [[NSImage alloc] initWithSize:v.bounds.size];
        [layer lockFocus]; [v drawRect:v.bounds]; [layer unlockFocus];
        NSImage *img = [[NSImage alloc] initWithSize:v.bounds.size];
        [img lockFocus];
        [NSColor.blackColor set]; NSRectFill(v.bounds);
        [layer drawInRect:v.bounds fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver fraction:1.0];
        [img unlockFocus];
        NSBitmapImageRep *out = [[NSBitmapImageRep alloc] initWithData:img.TIFFRepresentation];
        [[out representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[dir stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"%02d-%s.png", i, cl->name]] atomically:YES];
        printf("%2d %-20s %2d frames %s\n", i, cl->name, cl->count, cl->pal ? "(own palette)" : "");
    }
    return 0;
}

static BOOL HasOption(int argc, const char **argv, const char *option) {
    for (int i = 1; i < argc; i++)
        if (strcmp(argv[i], option) == 0) return YES;
    return NO;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--film-fx") == 0) {
            [NSApplication sharedApplication];
            return RenderFilmFX(@(argv[2]));
        }
        if (argc == 3 && strcmp(argv[1], "--film-drag") == 0) {
            [NSApplication sharedApplication];
            return RenderFilmDrag(@(argv[2]));
        }
        if (argc == 4 && strcmp(argv[1], "--film") == 0) {
            [NSApplication sharedApplication];
            return RenderFilm(@(argv[2]), atof(argv[3]), NO);
        }
        if (argc == 4 && strcmp(argv[1], "--film-lens") == 0) {
            [NSApplication sharedApplication];
            return RenderFilm(@(argv[2]), atof(argv[3]), YES);
        }
        if (argc == 3 && strcmp(argv[1], "--poses") == 0) {
            [NSApplication sharedApplication];
            return RenderPoses(@(argv[2]));
        }
        if (argc == 3 && strcmp(argv[1], "--render") == 0) {
            [NSApplication sharedApplication];   // AppKit drawing needs this
            return RenderStates(@(argv[2]));
        }
        if ((argc == 7 || argc == 9) && strcmp(argv[1], "--shot") == 0) {
            [NSApplication sharedApplication];
            return RenderShot(@(argv[2]), atoi(argv[3]), atoi(argv[4]),
                              atoi(argv[5]), atoi(argv[6]),
                              argc == 9 ? atoi(argv[7]) : 0,
                              argc == 9 ? @(argv[8]) : @"");
        }
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *d = [AppDelegate new];
        d.paletteMode = (argc == 2 && strcmp(argv[1], "--palette") == 0);
        d.rulerMode  = (argc == 2 && strcmp(argv[1], "--ruler") == 0);
        d.sweatMode  = (argc == 2 && strcmp(argv[1], "--sweat") == 0);
        // LaunchServices adds a -psn_* argument when `open --args` starts a
        // macOS app, so this must not depend on argc being exactly two.
        d.demoMode   = HasOption(argc, argv, "--demo-pro");
        app.delegate = d;
        [app run];
    }
    return 0;
}

