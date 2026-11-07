#import "night_sky.h"
#import <math.h>

static double Rand(NightSky *sky) {
    uint32_t s = sky->seed;
    s ^= s << 13; s ^= s >> 17; s ^= s << 5;
    sky->seed = s;
    return (s >> 8) / (double)(1u << 24);
}

static void ScheduleMeteor(NightSky *sky) {
    sky->nextMeteorAt = sky->clock + 9.0 + Rand(sky) * 13.0;    // every 9-22s
}

void NightSkyInit(NightSky *sky, double width, double height, uint32_t seed) {
    memset(sky, 0, sizeof(*sky));
    sky->width = width; sky->height = height;
    sky->seed = seed ? seed : 0x5ca1ab1eu;
    for (int i = 0; i < SKY_STARS; i++) {
        SkyStar *s = &sky->stars[i];
        double depth = Rand(sky);
        depth = depth * depth;                                  // most stars are far
        s->depth = (float)depth;
        s->x = (float)(Rand(sky) * width);
        // Keep the sky above the ground line and below the very top edge; near
        // stars sit a little higher so they do not crowd the mascots' heads.
        s->y = (float)(7.0 + Rand(sky) * (height - 9.0));
        s->size = (float)(0.7 + depth * 1.1 + Rand(sky) * 0.3);
        s->phase = (float)(Rand(sky) * M_PI * 2);
        s->speed = (float)(0.25 + Rand(sky) * 0.6);             // radians/s: slow
        s->warmth = (float)(Rand(sky) < 0.2 ? 0.8 : Rand(sky) * 0.3);
    }
    ScheduleMeteor(sky);
}

void NightSkyAdvance(NightSky *sky, double dt, double drift) {
    if (!(dt > 0)) return;
    dt = fmin(dt, 0.25);
    sky->clock += dt;
    sky->scroll += drift * dt;
    if (sky->meteorActive) {
        sky->mLife -= dt;
        sky->mx += sky->mvx * dt;
        sky->my += sky->mvy * dt;
        if (sky->mLife <= 0 || sky->my < 2 || sky->mx < -30 || sky->mx > sky->width + 30) {
            sky->meteorActive = NO;
            ScheduleMeteor(sky);
        }
    } else if (sky->clock >= sky->nextMeteorAt) {
        sky->meteorActive = YES;
        // Born on the side it flies away from, so the streak always crosses
        // the visible sky instead of leaving through the nearest edge.
        double leftward = Rand(sky) < 0.5 ? -1 : 1;
        double along = 0.08 + Rand(sky) * 0.34;                 // 8-42% in from that edge
        sky->mx = sky->width * (leftward < 0 ? 1.0 - along : along);
        sky->my = sky->height - 2 - Rand(sky) * 6;
        double speed = 150 + Rand(sky) * 90;
        sky->mvx = leftward * speed * 0.86;
        sky->mvy = -speed * 0.42;
        sky->mMaxLife = sky->mLife = 0.42 + Rand(sky) * 0.25;
    }
}

double NightSkyStarX(const NightSky *sky, int index) {
    const SkyStar *s = &sky->stars[index];
    double parallax = 0.12 + 0.88 * s->depth;
    double x = fmod(s->x - sky->scroll * parallax, sky->width);
    if (x < 0) x += sky->width;
    return x;
}

double NightSkyStarBrightness(const NightSky *sky, int index) {
    const SkyStar *s = &sky->stars[index];
    double t = sky->clock * s->speed + s->phase;
    double slow = 0.72 + 0.28 * sin(t);                         // gentle breathing
    double glint = pow(fmax(0, sin(t * 2.3 + 1.1)), 24) * 0.6;  // rare sharp flash
    double base = 0.35 + 0.65 * s->depth;
    return fmin(1.0, base * slow + glint);
}

BOOL NightSkyMeteor(const NightSky *sky, double *headX, double *headY,
                    double *tailX, double *tailY, double *fade) {
    if (!sky->meteorActive) return NO;
    double life = sky->mLife / sky->mMaxLife;                   // 1 .. 0
    double tail = 0.09 * (0.5 + 0.5 * (1 - life));              // tail grows as it burns
    *headX = sky->mx; *headY = sky->my;
    *tailX = sky->mx - sky->mvx * tail; *tailY = sky->my - sky->mvy * tail;
    *fade = life < 0.3 ? life / 0.3 : 1.0;
    return YES;
}
