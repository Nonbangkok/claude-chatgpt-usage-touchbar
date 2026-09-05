#import <Foundation/Foundation.h>

typedef struct {
    double claudeX, claudeVelocity;
    double gptX, gptVelocity;
} MascotPair;

// Separates two overlapping mascot centres and returns them travelling apart.
BOOL ResolveMascotCollision(MascotPair *pair, double minimumDistance);
