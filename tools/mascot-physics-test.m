#import <Foundation/Foundation.h>
#import "../mascot_physics.h"

static int failures = 0;

static void Check(BOOL condition, NSString *message) {
    if (condition) {
        printf("  ok    %s\n", message.UTF8String);
    } else {
        printf("  FAIL  %s\n", message.UTF8String);
        failures++;
    }
}

int main(void) {
    @autoreleasepool {
        MascotPair pair = {100, 40, 118, -28};
        BOOL collided = ResolveMascotCollision(&pair, 30);
        Check(collided, @"detects overlapping mascots");
        Check(fabs(pair.claudeX - pair.gptX) >= 30, @"separates mascot centres");
        Check(pair.claudeVelocity < 0 && pair.gptVelocity > 0,
              @"sends both mascots away after collision");

        MascotPair apart = {20, 30, 100, -30};
        Check(!ResolveMascotCollision(&apart, 30), @"leaves separated mascots alone");

        Check(MascotTargetAtPoint(45, 40, 150, 24) == MascotTargetClaude,
              @"selects Claude inside its touch target");
        Check(MascotTargetAtPoint(145, 40, 150, 24) == MascotTargetGPT,
              @"selects GPT inside its touch target");
        Check(MascotTargetAtPoint(95, 40, 150, 20) == MascotTargetNone,
              @"ignores touches between mascots");

        Check([GPTMascotResourceForDirection(-1) isEqualToString:@"GPTMascot"],
              @"uses the original GPT sprite before mirroring it left");
        Check([GPTMascotResourceForDirection(1) isEqualToString:@"GPTMascot"],
              @"keeps the existing GPT sprite when walking right");

        GPTActivity activity = {NO, 0, 2.0};
        Check(!AdvanceGPTActivity(&activity, 1.5) && !activity.resting,
              @"keeps GPT walking before its activity interval ends");
        Check(AdvanceGPTActivity(&activity, 0.6) && activity.resting,
              @"moves GPT into an idle rest interval");
        activity.duration = 1.0;
        Check(AdvanceGPTActivity(&activity, 1.0) && !activity.resting,
              @"resumes GPT walking after resting");
    }
    printf("mascot physics: %s\n", failures ? "failed" : "ok");
    return failures ? 1 : 0;
}
