// Motion for the widget's "juice": particles, hops and tweens. Pure numbers —
// no AppKit — so the behaviour can be tested without a Touch Bar. main.m owns
// all drawing.
#import <Foundation/Foundation.h>

typedef NS_ENUM(uint8_t, FXKind) {
    FXKindPixel,    // square pixel chip, matches the sprite art
    FXKindSpark,    // short bright streak along its velocity
    FXKindHeart,    // tiny pixel heart that floats up
    FXKindStar,     // four-point twinkle
    FXKindRing,     // expanding shock ring; size is the final radius
};

typedef struct {
    double x, y, vx, vy;
    double life, maxLife;      // seconds left / total
    double size;
    double gravity, drag;      // pt/s^2 (down is negative y), per-second velocity decay 0..1
    float r, g, b;
    FXKind kind;
} FXParticle;

// Fixed capacity: a burst can never grow memory or frame time without bound.
#define FX_CAPACITY 192

typedef struct {
    FXParticle particles[FX_CAPACITY];
    int count;
    uint32_t seed;
} FXSystem;

void FXInit(FXSystem *system, uint32_t seed);
// Deterministic 0..1 random for reproducible tests and films.
double FXRandom(FXSystem *system);
// Adds a particle; when full, the one closest to dying is replaced so a fresh
// burst always shows. Returns NO only for a particle that is already dead.
BOOL FXEmit(FXSystem *system, FXParticle particle);
// n particles radiating from (x, y) within [angleLow, angleHigh] radians.
void FXBurst(FXSystem *system, double x, double y, int n,
             double speedLow, double speedHigh, double angleLow, double angleHigh,
             double life, double size, double gravity,
             float r, float g, float b, FXKind kind);
// Integrates and removes dead particles. Returns the number still alive.
int FXAdvance(FXSystem *system, double dt);

// A hop with squash-and-stretch. y is height above the ground; squash is the
// vertical scale (>1 stretched, <1 squashed), the horizontal scale is 1/squash.
typedef struct {
    double y, vy;
    double squash, squashVelocity;
    int combo;                 // consecutive taps landed within the combo window
    double comboTimer;         // seconds left to extend the combo
} FXHop;

void FXHopInit(FXHop *hop);
// Launch (or re-launch mid-air). Rapid repeats build a combo that jumps higher.
// Returns the combo count after this kick (1 for a fresh tap).
int FXHopKick(FXHop *hop, double strength);
// Returns YES on the frame the hop lands.
BOOL FXHopAdvance(FXHop *hop, double dt);
BOOL FXHopIsActive(const FXHop *hop);

// Frame-rate independent exponential approach toward a target.
double FXApproach(double current, double target, double rate, double dt);
