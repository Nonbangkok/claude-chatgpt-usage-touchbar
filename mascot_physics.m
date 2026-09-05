#import "mascot_physics.h"
#import <math.h>

BOOL ResolveMascotCollision(MascotPair *pair, double minimumDistance) {
    if (!pair || minimumDistance <= 0) return NO;

    double delta = pair->gptX - pair->claudeX;
    if (fabs(delta) >= minimumDistance) return NO;

    // Treat touching exactly on top as a right-side impact so every collision
    // has a deterministic, visible outcome rather than leaving the sprites
    // layered on one another.
    double direction = delta < 0 ? -1.0 : 1.0;
    double midpoint = (pair->claudeX + pair->gptX) / 2.0;
    double halfDistance = minimumDistance / 2.0;
    pair->claudeX = midpoint - direction * halfDistance;
    pair->gptX = midpoint + direction * halfDistance;

    // An elastic-looking kick is clearer than exchanging their possibly slow
    // walking speeds: both immediately head away even if one was standing.
    double kick = MAX(18.0, (fabs(pair->claudeVelocity) + fabs(pair->gptVelocity)) / 2.0);
    pair->claudeVelocity = -direction * kick;
    pair->gptVelocity = direction * kick;
    return YES;
}

MascotTarget MascotTargetAtPoint(double touchX, double claudeX, double gptX,
                                 double hitRadius) {
    if (hitRadius <= 0) return MascotTargetNone;
    double claudeDistance = fabs(touchX - claudeX);
    double gptDistance = fabs(touchX - gptX);
    if (claudeDistance > hitRadius && gptDistance > hitRadius) return MascotTargetNone;
    return claudeDistance <= gptDistance ? MascotTargetClaude : MascotTargetGPT;
}

BOOL AdvanceGPTActivity(GPTActivity *activity, double dt) {
    if (!activity || dt <= 0 || activity->duration <= 0) return NO;
    activity->elapsed += dt;
    if (activity->elapsed < activity->duration) return NO;
    activity->elapsed = 0;
    activity->resting = !activity->resting;
    return YES;
}

NSString *GPTMascotResourceForDirection(double direction) {
    return @"GPTMascot";
}
