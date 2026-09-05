#import <Foundation/Foundation.h>

typedef struct {
    double claudeX, claudeVelocity;
    double gptX, gptVelocity;
} MascotPair;

BOOL ResolveMascotCollision(MascotPair *pair, double minimumDistance);

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
    }
    printf("mascot physics: %s\n", failures ? "failed" : "ok");
    return failures ? 1 : 0;
}
