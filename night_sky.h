// A night sky behind the runway: parallax star layers that drift with the
// mascots, slow twinkling, and the occasional meteor. Pure state and numbers
// (no AppKit) so the motion can be tested; main.m draws it.
#import <Foundation/Foundation.h>

#define SKY_STARS 84

typedef struct {
    float x, y;          // home position in sky space; x wraps around the width
    float size;          // pt
    float depth;         // 0 far (dim, slow) .. 1 near (bright, drifts most)
    float phase, speed;  // twinkle
    float warmth;        // 0 blue-white .. 1 warm white
} SkyStar;

typedef struct {
    SkyStar stars[SKY_STARS];
    double width, height;
    double scroll;       // camera offset; each star moves scroll * its parallax
    double clock;
    double nextMeteorAt;
    BOOL meteorActive;
    double mx, my, mvx, mvy, mLife, mMaxLife;
    uint32_t seed;
} NightSky;

void NightSkyInit(NightSky *sky, double width, double height, uint32_t seed);
// drift: how fast the scene is moving under the camera, pt/s, signed. The
// stars slide the other way, nearer ones faster, so the mascots' walk reads as
// travel. Meteors are scheduled and flown here as well.
void NightSkyAdvance(NightSky *sky, double dt, double drift);
// Screen x of a star after parallax and wrap-around.
double NightSkyStarX(const NightSky *sky, int index);
// 0..1 twinkle, slow and mostly steady with a rare sharp glint.
double NightSkyStarBrightness(const NightSky *sky, int index);
// Head and tail of the meteor plus its fade (1 fresh .. 0 gone). NO if none.
BOOL NightSkyMeteor(const NightSky *sky, double *headX, double *headY,
                    double *tailX, double *tailY, double *fade);
