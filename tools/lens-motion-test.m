#import "../lens_motion.h"
#import <math.h>
#include <assert.h>
int main(void) {
    @autoreleasepool {
        UsageLens *lens = [UsageLens new];
        assert(!lens.visible);
        [lens beginAt:20 minimum:0 maximum:100];
        [lens advance:0.25]; [lens advance:0.20];
        assert(lens.holding);
        [lens moveTo:95];
        assert(lens.scrubbing && !lens.holding && lens.checkpoint == 100);
        [lens advance:1.0/60];
        assert(lens.x > 20 && lens.x < 95); // follows with inertia, not a jump
        [lens moveTo:500];
        for (int i = 0; i < 120; i++) [lens advance:1.0/60];
        assert(isfinite(lens.x) && lens.x <= 100 && lens.amount <= 1.06);
        [lens end];
        for (int i = 0; i < 180; i++) [lens advance:1.0/60];
        assert(!lens.visible);
        [lens beginAt:50 minimum:0 maximum:100]; [lens advance:0.1]; [lens end];
        for (int i = 0; i < 177; i++) [lens advance:1.0/60];
        assert(lens.visible && lens.releaseTime < 0); // a tap holds the lens for 3 seconds
        for (int i = 0; i < 6; i++) [lens advance:1.0/60];
        assert(lens.releaseTime >= 0); // then the normal spring-out begins
        [lens cancel];
        for (int i = 0; i < 20; i++) [lens advance:0.25];
        assert(!lens.visible);
        puts("lens gestures and spring: ok");
    }
}
