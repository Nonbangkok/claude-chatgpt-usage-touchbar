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
#define READ_W    300.0
#define READ_X    (kSceneW - READ_W - 8)   // right-aligned: usage is the thing
                                           // you look for, so it sits where the
                                           // eye lands last and stays put
#define CELL_GAP    9.0
// 30pt of height only fits two tiers. A third one for the countdown pushed the
// labels off the top edge, so the countdown rides alongside the first label.
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

@interface PetView : NSView
@property (nonatomic) int p5, p7, resetMin, reset7dMin, ageSec, scopedPct;
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
@end

@implementation PetView

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _x = 40; _dir = 1; _p5 = 0; _p7 = 0; _resetMin = -1; _reset7dMin = -1;
        _gptX = 155; _gptDir = -1;
        _gptActivity = (GPTActivity){NO, 0, 3.6};
        _activeUsageCell = -1;
        _lens = [UsageLens new];
        _codexP5 = 0; _codexP7 = 0; _codexResetMin = -1; _codexReset7dMin = -1;
        _state = @"none"; _codexState = @"none";
        _act = ActWalk;
        _nextActAt = 4.0;
        _lastClipIdx = -1;
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
    [self.lens beginAt:tx minimum:start maximum:start + w];
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
        if ([self beginLensAt:tx]) self.lensTouchIdentity = t.identity;
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
        if (self.dragTarget == MascotTargetGPT) self.gptTapT = 0.65;
        else self.claudeTapT = 0.65;
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

    MascotPair pair = { self.x, self.dir * SpeedForMood(m),
                        self.gptX, self.gptDir * gptSpeed + self.gptKick };
    if (ResolveMascotCollision(&pair, 34.0)) {
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
        if (self.x < lo) { self.x = lo; self.throwVX = -self.throwVX * 0.5; self.dir = 1; }
        if (self.x > hi) { self.x = hi; self.throwVX = -self.throwVX * 0.5; self.dir = -1; }
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
static void DrawTapSparkles(CGFloat x, CGFloat t, NSColor *color) {
    if (t <= 0) return;
    CGFloat progress = 1.0 - t / 0.65;
    CGFloat alpha = MIN(1.0, t * 2.4);
    [[color colorWithAlphaComponent:alpha] set];
    for (int i = 0; i < 4; i++) {
        CGFloat angle = (CGFloat)i * M_PI_2 + progress * 0.6;
        CGFloat radius = 7.0 + progress * 10.0;
        CGFloat sx = x + cos(angle) * radius;
        CGFloat sy = 18.0 + sin(angle) * radius * 0.55;
        NSRectFill(NSMakeRect(sx - 1.0, sy - 1.0, 2.0, 2.0));
    }
}

static void DrawGPTMascot(CGFloat x, CGFloat direction, CGFloat phase, BOOL resting, CGFloat tapT) {
    static NSImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [NSBundle.mainBundle URLForResource:@"GPTMascot" withExtension:@"png"];
        image = [[NSImage alloc] initWithContentsOfURL:url];
    });
    if (!image) return;

    NSGraphicsContext *context = NSGraphicsContext.currentContext;
    NSImageInterpolation oldInterpolation = context.imageInterpolation;
    context.imageInterpolation = NSImageInterpolationNone;
    CGFloat bob = sin(phase * (resting ? 1.1 : 2.0)) * (resting ? 0.35 : 0.7);
    DrawTapSparkles(x, tapT, [NSColor colorWithSRGBRed:0.37 green:0.70 blue:1.0 alpha:1.0]);
    NSRect frame = NSMakeRect(x - 15, 0.1 + bob, 30, 32.2);
    if (direction < 0) {
        [context saveGraphicsState];
        NSAffineTransform *mirror = NSAffineTransform.transform;
        [mirror translateXBy:NSMidX(frame) yBy:0];
        [mirror scaleXBy:-1 yBy:1];
        [mirror translateXBy:-NSMidX(frame) yBy:0];
        [mirror concat];
    }
    [image drawInRect:frame
              fromRect:NSMakeRect(0, 0, image.size.width, image.size.height)
             operation:NSCompositingOperationSourceOver fraction:1.0];
    if (direction < 0) [context restoreGraphicsState];
    context.imageInterpolation = oldInterpolation;
}

- (void)drawRect:(NSRect)dirty {
    [NSColor.clearColor set];
    NSRectFill(dirty);

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
    DrawGPTMascot(self.gptX, self.resetLookTime > 0 ? 1 : self.gptDir, self.gptPhase, self.gptActivity.resting, self.gptTapT);

    // Panic: motion streaks trailing behind.
    if (mood == MoodPanic) {
        [[body colorWithAlphaComponent:0.28] set];
        for (int i = 1; i <= 3; i++) {
            CGFloat sx = self.x - self.dir * (CLAWD_N * px * 0.4 + i * 5.0);
            NSRectFill(NSMakeRect(MIN(sx, sx - self.dir * 4.0), feet.y + 8, 4.0, 1.6));
        }
    }

    const unsigned char *base = kClawdClips[0].frames[0].grid;   // canonical pose

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

    // Tired: a sweat drop above the head.
    if (mood == MoodTired) {
        [[NSColor colorWithSRGBRed:0.42 green:0.70 blue:0.94 alpha:0.95] set];
        NSRectFill(NSMakeRect(self.x + 8, feet.y + CLAWD_ROWS * px * 0.9, 2.4, 3.4));
    }

    DrawTapSparkles(self.x, self.claudeTapT,
                    [NSColor colorWithSRGBRed:1.0 green:0.72 blue:0.43 alpha:1.0]);

    [self drawReadout];
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
    if ([visible containsObject:@"claude"]) {
        [cells addObject:@[usageLabel(claudeName, @"5h", self.state),
                          @(claudeReady ? self.p5 : -1), self.state, @(self.resetMin)]];
        [cells addObject:@[usageLabel(claudeName, @"7d", self.state),
                          @(claudeReady ? self.p7 : -1), self.state, @(self.reset7dMin)]];
    }
    if ([visible containsObject:@"codex"]) {
        [cells addObject:@[usageLabel(codexName, @"5h", self.codexState),
                          @(codexReady ? self.codexP5 : -1), self.codexState, @(self.codexResetMin)]];
        [cells addObject:@[usageLabel(codexName, @"7d", self.codexState),
                          @(codexReady ? self.codexP7 : -1), self.codexState, @(self.codexReset7dMin)]];
    }

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
    for (NSInteger i = 0; i < cells.count; i++) {
        NSString *providerState = cells[i][2];
        CGFloat dim = [providerState isEqualToString:@"stale"] ? 0.72 : 1.0;
        BOOL selected = self.usageTapT > 0 && self.activeUsageCell == i;
        NSString *label = selected ? UsageResetDisplay([cells[i][3] intValue]) : cells[i][0];
        [self drawCell:cells[i][0] pct:[cells[i][1] intValue]
                     x:READ_X + i * (cellW + CELL_GAP) width:cellW dim:dim
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

// The focus surface lives inside the actual 30pt Touch Bar. Text changes sides
// to give the moving glass lens room; none of it is drawn above the hardware.
- (void)drawUsageLens {
    UsageLens *l = self.lens;
    CGFloat a = MIN(1, l.amount);
    if (a < 0.003) return;
    int pct = [self.lensCell[1] intValue];
    int remaining = UsageRemainingPercent(pct);
    NSColor *tint = remaining <= 10
        ? [NSColor colorWithSRGBRed:1 green:0.32 blue:0.34 alpha:1]
        : remaining <= 50 ? [NSColor colorWithSRGBRed:1 green:0.76 blue:0.34 alpha:1]
        : [NSColor colorWithSRGBRed:0.35 green:0.72 blue:1 alpha:1];
    CGFloat cx = MAX(READ_X + 17, MIN(l.x, READ_X + READ_W - 17));
    CGFloat cy = 15;
    CGFloat r = 10.6 * MAX(0.15, l.amount);
    CGFloat stretch = MIN(3.2, fabs(l.velocity) * 0.012);
    NSRect glass = NSMakeRect(cx - r - stretch, cy - r, 2 * (r + stretch), 2 * r);
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(NSMakeRect(READ_X - 2, 0, READ_W + 4, 30));
    [[NSColor colorWithWhite:0 alpha:a * 0.985] set];
    NSRectFill(NSMakeRect(READ_X - 2, 0, READ_W + 4, 30));
    [[tint colorWithAlphaComponent:a * 0.12] set];
    NSRectFill(NSMakeRect(READ_X + 7, 0.5, READ_W - 14, 1));
    [[tint colorWithAlphaComponent:a * 0.5] set];
    NSRectFill(NSMakeRect(READ_X + 7, 0.5, (READ_W - 14) * remaining / 100.0, 1));

    // Colored bloom is deliberately behind glass and text.
    for (int i = 5; i >= 1; i--) {
        [[tint colorWithAlphaComponent:a * 0.016] set];
        [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(glass, -i * 1.6, -i * 1.6)] fill];
    }
    if (l.scrubbing) {
        for (int i = 5; i >= 1; i--) {
            CGFloat tx = cx - l.velocity * 0.012 * i;
            [[tint colorWithAlphaComponent:a * (0.075 - i * 0.010)] set];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(tx - 3, cy - 3, 6, 6)] fill];
        }
    }
    if (l.rippleTime < 0.65) {
        for (int i = 0; i < 2; i++) {
            CGFloat p = MAX(0, l.rippleTime - i * 0.1) / 0.65;
            CGFloat rr = r + 12 * p;
            [[tint colorWithAlphaComponent:a * 0.30 * (1 - p)] set];
            NSBezierPath *ripple = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - rr, cy - rr * 0.55, rr * 2, rr * 1.1)];
            ripple.lineWidth = 0.6; [ripple stroke];
        }
    }

    NSBezierPath *shell = [NSBezierPath bezierPathWithOvalInRect:glass];
    [NSGraphicsContext saveGraphicsState]; [shell addClip];
    NSGradient *surface = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:0.22 alpha:a]
                                                      endingColor:[NSColor colorWithWhite:0.025 alpha:a]];
    [surface drawInRect:glass angle:270];
    [[tint colorWithAlphaComponent:0.42 * a] set];
    NSRectFill(NSMakeRect(glass.origin.x, glass.origin.y, glass.size.width,
                          glass.size.height * remaining / 100.0));
    NSBezierPath *reflection = [NSBezierPath bezierPath];
    [reflection moveToPoint:NSMakePoint(cx - r + 3, cy + 4)];
    [reflection curveToPoint:NSMakePoint(cx + r - 3, cy + 6)
              controlPoint1:NSMakePoint(cx - 3, cy + r - 2)
              controlPoint2:NSMakePoint(cx + 3, cy + r - 2)];
    [[NSColor colorWithWhite:1 alpha:a * 0.4] set];
    reflection.lineWidth = 0.8; [reflection stroke];
    [NSGraphicsContext restoreGraphicsState];
    [[tint colorWithAlphaComponent:a * 0.9] set]; shell.lineWidth = 0.75; [shell stroke];

    if (l.holding) {
        for (int i = 0; i < 3; i++) {
            CGFloat angle = l.clock * (i == 1 ? -82 : 58 + i * 30) + i * 120;
            NSBezierPath *arc = [NSBezierPath bezierPath];
            [arc appendBezierPathWithArcWithCenter:NSMakePoint(cx, cy) radius:11.3 + i * 0.9
                                       startAngle:angle endAngle:angle + 75];
            [[tint colorWithAlphaComponent:a * (0.7 - i * 0.15)] set];
            arc.lineWidth = 0.65; [arc stroke];
        }
    }
    if (remaining <= 10) {
        CGFloat beat = pow(MAX(0, sin(l.clock * M_PI * 2 / 2.5)), 6);
        [[tint colorWithAlphaComponent:beat * a * 0.16] set]; [shell fill];
    }
    if (!l.touching && l.releaseTime >= 0 && l.releaseTime < 0.65) {
        CGFloat p = l.releaseTime / 0.65;
        for (int i = 0; i < 6; i++) {
            CGFloat angle = i * M_PI / 3;
            CGFloat dist = (1 - p) * 16;
            [[tint colorWithAlphaComponent:a * (1 - p) * 0.65] set];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx + cos(angle) * dist - 0.7,
                                                              cy + sin(angle) * dist * 0.55 - 0.7, 1.4, 1.4)] fill];
        }
    }
    NSString *core = [NSString stringWithFormat:@"%d", remaining];
    NSDictionary *coreStyle = @{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:9 weight:NSFontWeightBold],
                                 NSForegroundColorAttributeName:[NSColor colorWithWhite:1 alpha:a]};
    [core drawAtPoint:NSMakePoint(cx - [core sizeWithAttributes:coreStyle].width / 2, cy - 5.5) withAttributes:coreStyle];

    BOOL textRight = cx < READ_X + READ_W / 2;
    CGFloat textX = textRight ? cx + r + stretch + 12 : READ_X + 9;
    CGFloat textW = textRight ? READ_X + READ_W - 6 - textX : cx - r - stretch - 12 - textX;
    NSString *title = [NSString stringWithFormat:@"%@ · %d%% left", self.lensCell[0], remaining];
    int reset = self.lensResetDate ? MAX(0, (int)ceil([self.lensResetDate timeIntervalSinceNow] / 60)) : -1;
    NSString *detail = self.lensResetDate ? [@"resets in " stringByAppendingString:[UsageResetDisplay(reset) substringFromIndex:2]] : @"reset time unavailable";
    if (l.holding && self.lensResetDate) {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = reset >= 24 * 60 ? @"d MMM HH:mm" : @"HH:mm";
        detail = [@"reset at " stringByAppendingString:[formatter stringFromDate:self.lensResetDate]];
    }
    if (l.scrubbing && l.checkpoint >= 0) {
        title = [title stringByAppendingFormat:@"   | %ld%% mark", (long)l.checkpoint];
    }
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(NSMakeRect(textX, 0, MAX(0, textW), 30));
    for (int row = 0; row < 2; row++) {
        NSString *s = row == 0 ? title : detail;
        CGFloat fontSize = row == 0 ? 10.0 : 9.0;
        NSMutableDictionary *style = [@{NSFontAttributeName:[NSFont systemFontOfSize:fontSize weight:row == 0 ? NSFontWeightSemibold : NSFontWeightMedium],
                                       NSForegroundColorAttributeName:row == 0 ? [NSColor colorWithWhite:1 alpha:a] : [tint colorWithAlphaComponent:a * 0.86]} mutableCopy];
        while ([s sizeWithAttributes:style].width > textW && fontSize > 7.5) {
            fontSize -= 0.25;
            style[NSFontAttributeName] = [NSFont systemFontOfSize:fontSize weight:NSFontWeightMedium];
        }
        [s drawAtPoint:NSMakePoint(textX, row == 0 ? 15 : 3.5) withAttributes:style];
    }
    [NSGraphicsContext restoreGraphicsState];
    if (l.scrubbing) {
        CGFloat mark = l.minimumX + (l.maximumX - l.minimumX) * l.checkpoint / 100.0;
        [[tint colorWithAlphaComponent:a * (0.4 + 0.6 * l.checkpointPulse)] set];
        NSRectFill(NSMakeRect(mark - 0.5, 0, 1, 2 + l.checkpointPulse * 2));
    }
    [NSGraphicsContext restoreGraphicsState];
}

// A cell shows remaining allowance: label and value on one line, bar underneath.
// The stored provider percentage remains "used" for mascot motion, but the
// readout deliberately inverts it so the bar and the number answer "how much
// can I still use?" without mental subtraction.
- (void)drawCell:(NSString *)label pct:(int)pct x:(CGFloat)x width:(CGFloat)w dim:(CGFloat)dim
           effect:(CGFloat)effect resetLabel:(NSString *)resetLabel {
    BOOL unavailable = pct < 0;
    int remaining = UsageRemainingPercent(pct);
    UsageRemainingLevel level = UsageRemainingLevelForUsedPercent(pct);
    NSColor *ink;
    if (level == UsageRemainingLevelCritical)
        ink = [NSColor colorWithSRGBRed:0.902 green:0.208 blue:0.180 alpha:1.0];  // ≤10% left
    else if (level == UsageRemainingLevelWarning)
        ink = [NSColor colorWithSRGBRed:0.949 green:0.706 blue:0.161 alpha:1.0];  // ≤50% left
    else
        ink = [NSColor colorWithSRGBRed:0.173 green:0.533 blue:0.945 alpha:1.0];

    BOOL compact = w < 82;
    CGFloat labelSize = effect > 0 ? 8.0 : (compact ? 7.0 : 10.0);
    // A window with no reading is deliberately quieter than a live gauge: it
    // should read as "nothing to report here", not as a loading bar that broke.
    CGFloat quiet = unavailable ? 0.55 : 1.0;
    NSDictionary *lb = @{ NSFontAttributeName: [NSFont systemFontOfSize:labelSize weight:NSFontWeightSemibold],
                          NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:(0.70 + effect * 0.30) * dim * quiet] };
    [resetLabel drawAtPoint:NSMakePoint(x, TEXT_Y) withAttributes:lb];

    NSString *num = unavailable ? @"—" : UsageRemainingDisplay(pct);
    NSDictionary *nu = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:(compact ? 8 : 12)
                                                                                weight:NSFontWeightBold],
                          NSForegroundColorAttributeName: unavailable
                              ? [NSColor colorWithWhite:1.0 alpha:0.40 * dim]
                              : [ink colorWithAlphaComponent:dim] };
    if (!compact) DrawRight(num, x + w, TEXT_Y - 1, nu);

    // The selected cell briefly grows upward and gains a soft halo. It is
    // feedback for a fingertip, not a persistent fifth visual state.
    CGFloat barH = BAR_H + effect * 3.0;
    CGFloat barY = BAR_Y;
    if (effect > 0) {
        [[ink colorWithAlphaComponent:0.15 * effect] set];
        NSRectFill(NSInsetRect(NSMakeRect(x, barY, w, barH), -2.0, -1.2));
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

    CGFloat fillW = unavailable ? 0 : w * remaining / 100.0;
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
        [NSGraphicsContext restoreGraphicsState];
    }

    // Ticks at 50 and 90 turn the remaining-allowance bar into a scale.
    [[NSColor colorWithWhite:1.0 alpha:0.3 * dim] set];
    for (NSNumber *frac in unavailable ? @[] : @[@0.5, @0.9]) {
        CGFloat tx = w * frac.doubleValue;
        if (tx > fillW) NSRectFill(NSMakeRect(x + tx, barY, 1, barH));
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
                self.pet.ageSec = claude.ageSec;
                self.pet.state = claude.state;
            }
            if (codex) {
                self.pet.codexP5 = codex.p5;
                self.pet.codexP7 = codex.p7;
                self.pet.codexResetMin = codex.resetMin;
                self.pet.codexReset7dMin = codex.reset7dMin;
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
        @"13-null-5h": @[@-1, @41, @-1, @"ok", @0, @"", @-1, @0, @-1, @"ok"],
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
    v.p5 = 62; v.p7 = 61; v.resetMin = 93; v.scopedPct = 61; v.scopedName = @"Fable";
    v.state = @"ok"; v.haveData = YES; v.x = 60;
    // Film output is illustrative sample data, but it must exercise both
    // provider readouts so the README accurately demonstrates the widget.
    v.codexP5 = 48; v.codexP7 = 57; v.codexResetMin = 126; v.codexAgeSec = 0;
    v.codexState = @"ok"; v.codexHaveData = YES;
    v.reset7dMin = 2 * 24 * 60 + 180; v.codexReset7dMin = 4 * 24 * 60 + 120;

    double fps = lensFilm ? 60 : kFPS;
    int n = (int)(secs * fps);
    for (int i = 0; i < n; i++) {
        // The README film demonstrates the same bar press used in the live
        // view, including the Codex five-hour countdown at the 7s mark.
        if (!lensFilm && i == (int)(7 * kFPS)) {
            v.activeUsageCell = 2;
            v.usageTapT = 2.5;
        }
        if (lensFilm) {
            // The same entry points as real fingers: tap, hold, scrub, release.
            if (i == 36) [v beginLensAt:READ_X + 26];
            if (i == 45) [v.lens end];
            if (i == 138) [v beginLensAt:READ_X + 189];
            if (i == 240) [v.lens end];
            if (i == 300) [v beginLensAt:READ_X + 83];
            if (i >= 306 && i <= 420) {
                double t = (i - 306) / 114.0;
                [v.lens moveTo:READ_X + 83 + (0.5 - 0.5 * cos(t * M_PI * 3)) * 57];
            }
            if (i == 421) [v.lens end];
            if (i == 480) { v.p5 = 94; v.resetMin = 12; [v beginLensAt:READ_X + 28]; }
            if (i == 564) [v.lens end];
            [v advanceLens:1.0 / fps];
            if (i % 4 == 0) [v advance:1.0 / kFPS];
        } else [v advance:1.0 / kFPS];
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

