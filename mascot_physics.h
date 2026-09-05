#import <Foundation/Foundation.h>

typedef struct {
    double claudeX, claudeVelocity;
    double gptX, gptVelocity;
} MascotPair;

typedef NS_ENUM(NSInteger, MascotTarget) {
    MascotTargetNone,
    MascotTargetClaude,
    MascotTargetGPT,
};

// Separates two overlapping mascot centres and returns them travelling apart.
BOOL ResolveMascotCollision(MascotPair *pair, double minimumDistance);

// Chooses the closest mascot inside the finger-sized hit target.
MascotTarget MascotTargetAtPoint(double touchX, double claudeX, double gptX,
                                 double hitRadius);

// A small independent clock for GPT's walk/rest rhythm. The caller chooses a
// fresh duration after each transition so its behaviour remains irregular.
typedef struct {
    BOOL resting;
    double elapsed, duration;
} GPTActivity;
BOOL AdvanceGPTActivity(GPTActivity *activity, double dt);

// Returns the bundled raster asset matching GPT's horizontal travel direction.
NSString *GPTMascotResourceForDirection(double direction);
