#import <Foundation/Foundation.h>
#import "../night_sky.h"

static int failures = 0;
static void Check(BOOL condition, NSString *message) {
    if (condition) printf("  ok    %s\n", message.UTF8String);
    else { printf("  FAIL  %s\n", message.UTF8String); failures++; }
}

int main(void) {
    @autoreleasepool {
        static NightSky sky, again;
        NightSkyInit(&sky, 200, 30, 7);
        NightSkyInit(&again, 200, 30, 7);
        BOOL same = YES, inBounds = YES, farMajority = 0;
        int far = 0;
        for (int i = 0; i < SKY_STARS; i++) {
            same &= sky.stars[i].x == again.stars[i].x && sky.stars[i].phase == again.stars[i].phase;
            inBounds &= sky.stars[i].y >= 7 && sky.stars[i].y <= 28 && sky.stars[i].size > 0.5;
            far += sky.stars[i].depth < 0.5;
        }
        farMajority = far > SKY_STARS / 2;
        Check(same, @"a seed reproduces the same sky");
        Check(inBounds, @"stars sit between the ground line and the top edge");
        Check(farMajority, @"most stars are far away");

        double x0 = NightSkyStarX(&sky, 0);
        for (int i = 0; i < 60; i++) NightSkyAdvance(&sky, 1.0 / 60, 40);
        double x1 = NightSkyStarX(&sky, 0);
        Check(x1 != x0, @"drift moves the stars");
        BOOL wrapped = YES;
        for (int i = 0; i < 2000; i++) NightSkyAdvance(&sky, 1.0 / 60, 300);
        for (int i = 0; i < SKY_STARS; i++) {
            double x = NightSkyStarX(&sky, i);
            wrapped &= x >= 0 && x < 200;
        }
        Check(wrapped, @"stars wrap around the sky instead of leaving it");
        int nearIdx = 0, farIdx = 0;
        for (int i = 0; i < SKY_STARS; i++) {
            if (sky.stars[i].depth > sky.stars[nearIdx].depth) nearIdx = i;
            if (sky.stars[i].depth < sky.stars[farIdx].depth) farIdx = i;
        }
        double nearBefore = NightSkyStarX(&sky, nearIdx), farBefore = NightSkyStarX(&sky, farIdx);
        NightSkyAdvance(&sky, 0.1, 20);
        double nearMoved = fabs(NightSkyStarX(&sky, nearIdx) - nearBefore);
        double farMoved = fabs(NightSkyStarX(&sky, farIdx) - farBefore);
        Check(nearMoved > farMoved, @"near stars drift more than far ones (parallax)");

        BOOL bright = YES;
        for (int i = 0; i < SKY_STARS; i++) {
            double b = NightSkyStarBrightness(&sky, i);
            bright &= b > 0 && b <= 1;
        }
        Check(bright, @"brightness stays within 0..1");
        double b0 = NightSkyStarBrightness(&sky, 3);
        NightSkyAdvance(&sky, 1.0, 0);
        Check(NightSkyStarBrightness(&sky, 3) != b0, @"stars twinkle over time");

        NightSkyInit(&sky, 200, 30, 11);
        double hx, hy, tx, ty, fade;
        BOOL seen = NO, started = NO, ended = NO, sane = YES;
        double firstAt = -1;
        for (int i = 0; i < 60 * 60; i++) {
            NightSkyAdvance(&sky, 1.0 / 60, 10);
            if (NightSkyMeteor(&sky, &hx, &hy, &tx, &ty, &fade)) {
                if (!seen) { seen = YES; firstAt = sky.clock; started = YES; }
                sane &= fade > 0 && fade <= 1 && (tx != hx || ty != hy);
            } else if (seen) ended = YES;
        }
        Check(started && firstAt >= 9 && firstAt <= 22.1, @"the first meteor falls between 9 and 22 seconds in");
        Check(ended, @"a meteor burns out");
        Check(sane, @"a meteor has a tail and a fade in 0..1");
        int count = 0; BOOL was = NO;
        NightSkyInit(&sky, 200, 30, 3);
        for (int i = 0; i < 60 * 120; i++) {
            NightSkyAdvance(&sky, 1.0 / 60, 0);
            BOOL now = sky.meteorActive;
            if (now && !was) count++;
            was = now;
        }
        Check(count >= 5 && count <= 14, @"roughly one meteor every 9-22 seconds");
        BOOL crosses = YES; int spawns = 0;
        NightSkyInit(&sky, 200, 30, 5); was = NO;
        for (int i = 0; i < 60 * 300 && spawns < 12; i++) {
            NightSkyAdvance(&sky, 1.0 / 60, 0);
            if (sky.meteorActive && !was) {
                spawns++;
                crosses &= sky.mvx > 0 ? sky.mx < 100 : sky.mx > 100;
            }
            was = sky.meteorActive;
        }
        Check(spawns >= 10 && crosses, @"a meteor is born on the side it flies away from");
    }
    if (failures == 0) printf("night sky: ok\n");
    return failures == 0 ? 0 : 1;
}
