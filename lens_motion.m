#import "lens_motion.h"
#import <math.h>

@implementation UsageLens
- (BOOL)holding { return self.touching && !self.scrubbing && self.heldTime >= 0.45; }
- (BOOL)visible { return self.touching || self.amount > 0.002 || self.releaseTime < 0.65; }
- (instancetype)init {
    if ((self = [super init])) { _releaseTime = 10; _rippleTime = 10; _checkpoint = -1; }
    return self;
}
- (void)beginAt:(double)x minimum:(double)minimum maximum:(double)maximum {
    BOOL wasVisible = self.visible;
    self.minimumX = minimum; self.maximumX = MAX(minimum, maximum);
    self.targetX = MIN(self.maximumX, MAX(minimum, x));
    if (!wasVisible) { self.x = self.targetX; self.velocity = 0; }
    self.startX = self.targetX;
    self.touching = YES; self.scrubbing = NO; self.heldTime = 0;
    self.rippleTime = 0; self.releaseTime = 10; self.checkpoint = -1;
}
- (void)moveTo:(double)x {
    if (!self.touching || !isfinite(x)) return;
    self.targetX = MIN(self.maximumX, MAX(self.minimumX, x));
    if (fabs(self.targetX - self.startX) > 4) self.scrubbing = YES;
    if (!self.scrubbing) return;
    double fraction = (self.targetX - self.minimumX) / MAX(1, self.maximumX - self.minimumX);
    NSInteger next = fraction < 0.30 ? 10 : fraction < 0.75 ? 50 : 100;
    if (next != self.checkpoint) { self.checkpointPulse = 1; self.checkpoint = next; }
}
- (void)end {
    if (!self.touching) return;
    // A quick tap keeps its readout legible for three full seconds; a drag or
    // hold intentionally releases immediately so it feels direct.
    self.releaseTime = (!self.scrubbing && self.heldTime < 0.45) ? -3.0 : 0;
    self.touching = NO;
}
- (void)cancel { self.touching = NO; self.releaseTime = 0; self.scrubbing = NO; }
- (void)advance:(double)dt {
    if (!isfinite(dt) || dt <= 0) return;
    dt = MIN(dt, 0.25);
    self.clock += dt; self.rippleTime += dt;
    if (self.touching) self.heldTime += dt; else self.releaseTime += dt;
    self.checkpointPulse = MAX(0, self.checkpointPulse - dt * 3);
    double target = (self.touching || self.releaseTime < 0) ? 1 : 0;
    // Small substeps keep the damped spring stable across stalls/slow renders.
    int steps = MAX(1, (int)ceil(dt * 240));
    double h = dt / steps;
    for (int i = 0; i < steps; i++) {
        self.velocity += ((self.targetX - self.x) * 210 - self.velocity * 25) * h;
        self.x += self.velocity * h;
        self.amountVelocity += ((target - self.amount) * 190 - self.amountVelocity * 22) * h;
        self.amount += self.amountVelocity * h;
    }
    self.x = MIN(self.maximumX, MAX(self.minimumX, self.x));
    self.amount = MAX(0, MIN(1.06, self.amount));
}
@end
