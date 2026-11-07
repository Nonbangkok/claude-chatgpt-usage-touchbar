// Pace: how fast a usage window is being consumed, and what that implies.
// Pure arithmetic over the two numbers the API gives (used %, minutes until
// reset) plus the window's length, so it can be tested without a Touch Bar.
#import <Foundation/Foundation.h>

typedef struct {
    BOOL valid;               // enough information to say anything at all
    double windowMin;         // length of the window in minutes
    double elapsedMin;        // minutes since the window started (0..window)
    double remainingMin;      // minutes until it resets
    double usedPct;           // 0..100
    double ratePerMin;        // observed average burn, % per minute
    double expectedUsedPct;   // what a perfectly even burn would have used by now
    double exhaustInMin;      // minutes from now until 0% left at this rate;
                              // < 0 means the allowance lasts until the reset
    double spareAtResetPct;   // % still unused when the window resets, at this rate
} UsagePace;

// usedPct 0..100, resetMin minutes until reset (-1 unknown), windowMin > 0.
UsagePace UsagePaceCompute(int usedPct, int resetMin, int windowMin);

// Remaining % expected `aheadMin` minutes from now at the observed rate,
// clamped to 0..100. Past the reset the window is full again (100).
double UsagePaceProject(UsagePace pace, double aheadMin);

// Shared verdict for colour and copy. At a constant rate, burning faster than
// even pace always means running out before the reset, so there are only two
// outcomes: the allowance lasts (with some to spare) or it exhausts first.
typedef NS_ENUM(NSInteger, UsagePaceVerdict) {
    UsagePaceVerdictUnknown,
    UsagePaceVerdictLasts,
    UsagePaceVerdictExhausts,
};
UsagePaceVerdict UsagePaceVerdictFor(UsagePace pace);

// "45m", "1h 20m", "2d 3h"; "—" for a negative value.
NSString *UsageDurationDisplay(int minutes);
