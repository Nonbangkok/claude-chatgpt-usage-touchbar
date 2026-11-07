#import "usage_pace.h"
#import <math.h>

UsagePace UsagePaceCompute(int usedPct, int resetMin, int windowMin) {
    UsagePace p = {0};
    p.exhaustInMin = -1;
    if (usedPct < 0 || usedPct > 100 || resetMin < 0 || windowMin <= 0) return p;
    p.valid = YES;
    p.windowMin = windowMin;
    p.remainingMin = MIN(resetMin, windowMin);
    p.elapsedMin = windowMin - p.remainingMin;
    p.usedPct = usedPct;
    p.expectedUsedPct = 100.0 * p.elapsedMin / windowMin;
    p.spareAtResetPct = 100.0 - usedPct;
    // Under a minute in, any rate is noise: treat the window as untouched.
    if (p.elapsedMin >= 1.0 && usedPct > 0) {
        p.ratePerMin = usedPct / p.elapsedMin;
        double toExhaust = (100.0 - usedPct) / p.ratePerMin;
        if (toExhaust < p.remainingMin) {
            p.exhaustInMin = toExhaust;
            p.spareAtResetPct = 0;
        } else {
            p.spareAtResetPct = 100.0 - usedPct - p.ratePerMin * p.remainingMin;
        }
    }
    return p;
}

double UsagePaceProject(UsagePace pace, double aheadMin) {
    if (!pace.valid) return -1;
    if (aheadMin < 0) aheadMin = 0;
    if (aheadMin >= pace.remainingMin && pace.remainingMin > 0) return 100;
    double remaining = 100.0 - pace.usedPct - pace.ratePerMin * aheadMin;
    return MAX(0, MIN(100, remaining));
}

UsagePaceVerdict UsagePaceVerdictFor(UsagePace pace) {
    if (!pace.valid) return UsagePaceVerdictUnknown;
    return pace.exhaustInMin >= 0 ? UsagePaceVerdictExhausts : UsagePaceVerdictLasts;
}

NSString *UsageDurationDisplay(int minutes) {
    if (minutes < 0) return @"—";
    if (minutes < 60) return [NSString stringWithFormat:@"%dm", minutes];
    if (minutes < 24 * 60)
        return [NSString stringWithFormat:@"%dh %02dm", minutes / 60, minutes % 60];
    return [NSString stringWithFormat:@"%dd %dh", minutes / (24 * 60), (minutes / 60) % 24];
}
