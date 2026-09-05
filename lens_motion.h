#import <Foundation/Foundation.h>

// Gesture and spring state, independent of drawing and real usage data.
@interface UsageLens : NSObject
@property double x, velocity, targetX, startX, amount, amountVelocity;
@property double heldTime, releaseTime, rippleTime, clock, checkpointPulse;
@property double minimumX, maximumX;
@property BOOL touching, scrubbing;
@property NSInteger checkpoint;
@property (readonly) BOOL holding;
@property (readonly) BOOL visible;
- (void)beginAt:(double)x minimum:(double)minimum maximum:(double)maximum;
- (void)moveTo:(double)x;
- (void)end;
- (void)cancel;
- (void)advance:(double)dt;
@end
