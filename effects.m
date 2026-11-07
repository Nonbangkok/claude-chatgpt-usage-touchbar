#import "effects.h"
#import <math.h>

void FXInit(FXSystem *system, uint32_t seed) {
    system->count = 0;
    system->seed = seed ? seed : 0x9e3779b9u;
}

double FXRandom(FXSystem *system) {
    uint32_t s = system->seed;
    s ^= s << 13; s ^= s >> 17; s ^= s << 5;
    system->seed = s;
    return (s >> 8) / (double)(1u << 24);
}

BOOL FXEmit(FXSystem *system, FXParticle particle) {
    if (!(particle.life > 0) || !(particle.maxLife > 0)) return NO;
    if (system->count < FX_CAPACITY) {
        system->particles[system->count++] = particle;
        return YES;
    }
    int oldest = 0;
    for (int i = 1; i < system->count; i++)
        if (system->particles[i].life < system->particles[oldest].life) oldest = i;
    system->particles[oldest] = particle;
    return YES;
}

void FXBurst(FXSystem *system, double x, double y, int n,
             double speedLow, double speedHigh, double angleLow, double angleHigh,
             double life, double size, double gravity,
             float r, float g, float b, FXKind kind) {
    for (int i = 0; i < n; i++) {
        double angle = angleLow + (angleHigh - angleLow) * FXRandom(system);
        double speed = speedLow + (speedHigh - speedLow) * FXRandom(system);
        double l = life * (0.7 + 0.6 * FXRandom(system));
        FXParticle p = {
            .x = x, .y = y, .vx = cos(angle) * speed, .vy = sin(angle) * speed,
            .life = l, .maxLife = l, .size = size * (0.75 + 0.5 * FXRandom(system)),
            .gravity = gravity, .drag = 0.85, .r = r, .g = g, .b = b, .kind = kind,
        };
        FXEmit(system, p);
    }
}

int FXAdvance(FXSystem *system, double dt) {
    if (dt <= 0) return system->count;
    int alive = 0;
    for (int i = 0; i < system->count; i++) {
        FXParticle p = system->particles[i];
        p.life -= dt;
        if (p.life <= 0) continue;
        double keep = pow(1.0 - fmin(fmax(p.drag, 0.0), 0.999), dt);
        p.vx *= keep;
        p.vy = p.vy * keep - p.gravity * dt;
        p.x += p.vx * dt;
        p.y += p.vy * dt;
        system->particles[alive++] = p;
    }
    system->count = alive;
    return alive;
}

static const double kHopGravity = 420.0;     // pt/s^2 — snappy at 30pt tall
static const double kComboWindow = 0.7;      // seconds between taps to chain

void FXHopInit(FXHop *hop) {
    *hop = (FXHop){0};
    hop->squash = 1.0;
}

int FXHopKick(FXHop *hop, double strength) {
    hop->combo = hop->comboTimer > 0 ? hop->combo + 1 : 1;
    hop->comboTimer = kComboWindow;
    int extra = MIN(hop->combo - 1, 4);
    // The bar is only 30pt tall and the sprites nearly fill it, so a combo adds
    // a little height and the rest of the drama comes from squash and confetti.
    hop->vy = strength * (1.0 + 0.08 * extra);
    hop->squash = 0.84;                      // anticipation: crouch, then spring up
    hop->squashVelocity = 0;
    return hop->combo;
}

BOOL FXHopAdvance(FXHop *hop, double dt) {
    if (dt <= 0) return NO;
    BOOL landed = NO;
    BOOL airborne = hop->y > 0 || hop->vy > 0;
    if (airborne) {
        hop->vy -= kHopGravity * dt;
        hop->y += hop->vy * dt;
        if (hop->y <= 0 && hop->vy < 0) {
            double impact = fabs(hop->vy);
            hop->y = 0; hop->vy = 0;
            hop->squash = fmin(hop->squash, 1.0 - fmin(0.22, impact / 380.0));
            hop->squashVelocity = 0;
            landed = YES;
            airborne = NO;
        }
    }
    // Stretch along the motion while rising/falling, settle to 1 on the ground.
    double target = airborne ? 1.0 + fmax(-0.03, fmin(0.035, hop->vy / 1500.0)) : 1.0;
    double accel = -600.0 * (hop->squash - target) - 18.0 * hop->squashVelocity;
    hop->squashVelocity += accel * dt;
    hop->squash += hop->squashVelocity * dt;
    hop->squash = fmax(0.7, fmin(1.25, hop->squash));

    if (hop->comboTimer > 0) {
        hop->comboTimer -= dt;
        if (hop->comboTimer <= 0 && !airborne) { hop->comboTimer = 0; hop->combo = 0; }
    }
    return landed;
}

BOOL FXHopIsActive(const FXHop *hop) {
    return hop->y > 0 || hop->vy != 0 || fabs(hop->squash - 1.0) > 0.004 ||
           fabs(hop->squashVelocity) > 0.01;
}

double FXApproach(double current, double target, double rate, double dt) {
    if (dt <= 0 || rate <= 0) return current;
    double next = target + (current - target) * exp(-rate * dt);
    return fabs(next - target) < 0.01 ? target : next;
}
