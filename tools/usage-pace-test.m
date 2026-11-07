#import <Foundation/Foundation.h>
#import "../usage_pace.h"

static int failures = 0;
static void Check(BOOL condition, NSString *message) {
    if (condition) printf("  ok    %s\n", message.UTF8String);
    else { printf("  FAIL  %s\n", message.UTF8String); failures++; }
}
static BOOL Near(double a, double b) { return fabs(a - b) < 0.01; }

int main(void) {
    @autoreleasepool {
        // 5h window, 2h in (180 min left), 40% used: 0.2%/min.
        UsagePace p = UsagePaceCompute(40, 180, 300);
        Check(p.valid && Near(p.elapsedMin, 120) && Near(p.ratePerMin, 40.0 / 120),
              @"elapsed time and burn rate follow from used% and reset");
        Check(Near(p.expectedUsedPct, 40), @"an even burn would also be at 40% two fifths in");
        Check(p.exhaustInMin < 0 && UsagePaceVerdictFor(p) == UsagePaceVerdictLasts,
              @"an even pace lasts until the reset");
        Check(Near(UsagePaceProject(p, 60), 40), @"an hour ahead at 0.2%/min leaves 40%");
        Check(Near(UsagePaceProject(p, 0), 60), @"projecting zero minutes ahead is the current remaining");
        Check(Near(UsagePaceProject(p, 180), 100), @"at the reset the window is full again");
        Check(Near(UsagePaceProject(p, 900), 100), @"…and stays full past it");

        // Same point in time, 80% used: 0.667%/min, 20% left -> 30 min.
        UsagePace fast = UsagePaceCompute(80, 180, 300);
        Check(Near(fast.exhaustInMin, 30) && UsagePaceVerdictFor(fast) == UsagePaceVerdictExhausts,
              @"burning twice the even pace runs out 30 minutes from now, well before reset");
        Check(Near(UsagePaceProject(fast, 30), 0) && Near(UsagePaceProject(fast, 60), 0),
              @"a projection never goes below zero");

        // At a constant rate, anything over the even pace runs out first.
        UsagePace over = UsagePaceCompute(41, 180, 300);
        Check(UsagePaceVerdictFor(over) == UsagePaceVerdictExhausts && over.exhaustInMin > 170,
              @"one point over even pace exhausts, but only just before the reset");
        Check(Near(p.spareAtResetPct, 0) && Near(UsagePaceCompute(20, 180, 300).spareAtResetPct, 50),
              @"a lasting window reports how much will be left to spare at the reset");
        Check(Near(fast.spareAtResetPct, 0), @"an exhausting window has nothing to spare");

        Check(!UsagePaceCompute(40, -1, 300).valid, @"an unknown reset time gives no pace");
        Check(!UsagePaceCompute(-1, 180, 300).valid, @"an unknown percentage gives no pace");
        Check(!UsagePaceCompute(40, 180, 0).valid, @"a zero-length window gives no pace");
        Check(UsagePaceProject(UsagePaceCompute(40, -1, 300), 10) < 0, @"an invalid pace projects nothing");

        UsagePace fresh = UsagePaceCompute(0, 300, 300);
        Check(fresh.valid && fresh.ratePerMin == 0 && fresh.exhaustInMin < 0 && Near(fresh.spareAtResetPct, 100),
              @"an untouched window has no burn, lasts, and keeps everything to spare");
        UsagePace early = UsagePaceCompute(30, 300, 300);
        Check(early.valid && early.ratePerMin == 0 && UsagePaceVerdictFor(early) != UsagePaceVerdictExhausts,
              @"under a minute in, usage is not extrapolated into a rate");
        UsagePace odd = UsagePaceCompute(10, 900, 300);
        Check(Near(odd.elapsedMin, 0) && Near(odd.remainingMin, 300),
              @"a reset beyond the window length is clamped, never negative elapsed");
        UsagePace empty = UsagePaceCompute(100, 100, 300);
        Check(Near(empty.exhaustInMin, 0) && UsagePaceVerdictFor(empty) == UsagePaceVerdictExhausts,
              @"fully used is exhausted now");

        // 7d window, 2 days in, 10% used -> lasts easily.
        UsagePace week = UsagePaceCompute(10, 5 * 1440, 7 * 1440);
        Check(week.valid && week.exhaustInMin < 0 && Near(UsagePaceProject(week, 1440), 85),
              @"a weekly window projects per day");

        Check([UsageDurationDisplay(45) isEqualToString:@"45m"] &&
              [UsageDurationDisplay(80) isEqualToString:@"1h 20m"] &&
              [UsageDurationDisplay(65) isEqualToString:@"1h 05m"] &&
              [UsageDurationDisplay(3000) isEqualToString:@"2d 2h"] &&
              [UsageDurationDisplay(-1) isEqualToString:@"—"],
              @"durations read as m, h m, d h");
    }
    if (failures == 0) printf("usage pace: ok\n");
    return failures == 0 ? 0 : 1;
}
