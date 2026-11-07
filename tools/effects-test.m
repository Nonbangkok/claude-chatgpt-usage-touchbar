#import <Foundation/Foundation.h>
#import "../effects.h"

static int failures = 0;

static void Check(BOOL condition, NSString *message) {
    if (condition) printf("  ok    %s\n", message.UTF8String);
    else { printf("  FAIL  %s\n", message.UTF8String); failures++; }
}

static double Peak(double strength) {
    FXHop hop; FXHopInit(&hop);
    FXHopKick(&hop, strength);
    double peak = 0;
    for (int i = 0; i < 600; i++) { FXHopAdvance(&hop, 1.0 / 60); peak = fmax(peak, hop.y); }
    return peak;
}

int main(void) {
    @autoreleasepool {
        static FXSystem fx;
        FXInit(&fx, 42);

        FXBurst(&fx, 50, 10, 20, 20, 60, 0, M_PI, 0.5, 2, 100, 1, 0.5, 0.2, FXKindPixel);
        Check(fx.count == 20, @"a burst emits the requested number of particles");
        double startY = fx.particles[0].y;
        FXAdvance(&fx, 0.05);
        Check(fx.particles[0].y != startY, @"particles move when advanced");
        for (int i = 0; i < 120; i++) FXAdvance(&fx, 1.0 / 60);
        Check(fx.count == 0, @"every particle dies once its life runs out");

        for (int i = 0; i < 40; i++)
            FXBurst(&fx, 0, 0, 10, 1, 2, 0, 1, 1, 1, 0, 1, 1, 1, FXKindSpark);
        Check(fx.count == FX_CAPACITY, @"capacity is a hard ceiling, never exceeded");
        FXParticle fresh = { .x = 1, .life = 9, .maxLife = 9, .kind = FXKindStar };
        Check(FXEmit(&fx, fresh), @"a full system still accepts a fresh particle");
        BOOL found = NO;
        for (int i = 0; i < fx.count; i++) found |= fx.particles[i].life == 9;
        Check(found && fx.count == FX_CAPACITY, @"…by replacing the one closest to dying");
        FXParticle dead = { .life = 0, .maxLife = 1 };
        Check(!FXEmit(&fx, dead), @"an already-dead particle is refused");

        FXSystem a, b; FXInit(&a, 7); FXInit(&b, 7);
        BOOL same = YES;
        for (int i = 0; i < 100; i++) same &= FXRandom(&a) == FXRandom(&b);
        Check(same, @"the random stream is reproducible from its seed");
        BOOL inRange = YES;
        for (int i = 0; i < 10000; i++) { double r = FXRandom(&a); inRange &= r >= 0 && r < 1; }
        Check(inRange, @"random values stay within [0, 1)");

        FXHop hop; FXHopInit(&hop);
        Check(!FXHopIsActive(&hop), @"a resting hop is inactive");
        Check(FXHopKick(&hop, 58) == 1, @"the first tap starts a combo of 1");
        Check(hop.squash < 1, @"a kick crouches first (anticipation)");
        BOOL landed = NO, rose = NO;
        for (int i = 0; i < 600 && !landed; i++) { landed = FXHopAdvance(&hop, 1.0 / 60); rose |= hop.y > 1; }
        Check(rose && landed, @"a kick rises and then lands");
        Check(hop.squash < 1, @"landing squashes on impact");
        for (int i = 0; i < 240; i++) FXHopAdvance(&hop, 1.0 / 60);
        Check(!FXHopIsActive(&hop) && fabs(hop.squash - 1) < 0.01, @"the squash springs back to rest");

        double one = Peak(48);
        Check(one > 2.0 && one < 3.5, @"a single tap hops a couple of points, within the 30pt bar");
        FXHop maxed; FXHopInit(&maxed);
        for (int i = 0; i < 5; i++) FXHopKick(&maxed, 48);
        double top = 0;
        for (int i = 0; i < 600; i++) { FXHopAdvance(&maxed, 1.0 / 60); top = fmax(top, maxed.y); }
        Check(top < 5.5, @"even a maxed combo stays low enough not to lose the head off the bar");

        FXHopInit(&hop);
        FXHopKick(&hop, 58); FXHopAdvance(&hop, 0.1);
        FXHopKick(&hop, 58); FXHopAdvance(&hop, 0.1);
        Check(FXHopKick(&hop, 58) == 3, @"rapid taps chain into a combo");
        double comboV = hop.vy;
        Check(comboV > 58, @"a combo kick launches harder than a single tap");
        for (int i = 0; i < 300; i++) FXHopAdvance(&hop, 1.0 / 60);
        Check(FXHopKick(&hop, 58) == 1, @"a pause resets the combo");

        Check(FXHopKick(&hop, 58) && hop.squash >= 0.7 && hop.squash <= 1.25, @"squash stays bounded");
        for (int i = 0; i < 30; i++) FXHopKick(&hop, 58);
        Check(hop.vy <= 58 * (1 + 0.08 * 4) + 1e-9, @"combo strength is capped");

        // Coarse time steps (a 15 fps film, a stalled frame) must not make the
        // spring flap between its clamps.
        FXHop coarse; FXHopInit(&coarse);
        FXHopKick(&coarse, 48);
        for (int i = 0; i < 30; i++) FXHopAdvance(&coarse, 1.0 / 15);
        BOOL settled15 = fabs(coarse.squash - 1) < 0.02 && !FXHopIsActive(&coarse);
        FXHopInit(&coarse); FXHopKick(&coarse, 48);
        for (int i = 0; i < 12; i++) FXHopAdvance(&coarse, 0.25);
        Check(settled15 && fabs(coarse.squash - 1) < 0.02, @"the squash settles even at 15 fps or after a stall");

        FXHop frantic; FXHopInit(&frantic);
        double highest = 0;
        for (int tap = 0; tap < 30; tap++) {
            FXHopKick(&frantic, 48);
            for (int i = 0; i < 6; i++) { FXHopAdvance(&frantic, 1.0 / 60); highest = fmax(highest, frantic.y); }
        }
        Check(highest <= 7.0 + 1e-9, @"tapping mid-air cannot stack hops above the ceiling");

        double v = 0;
        for (int i = 0; i < 120; i++) v = FXApproach(v, 73, 8, 1.0 / 60);
        Check(v == 73, @"a tween settles exactly on its target");
        double half = FXApproach(0, 100, 8, 1.0 / 60);
        Check(half > 0 && half < 100, @"a tween moves part of the way each frame");
        Check(FXApproach(5, 100, 8, 0) == 5, @"a zero time step does not move a tween");
    }
    if (failures == 0) printf("effects: ok\n");
    return failures == 0 ? 0 : 1;
}
