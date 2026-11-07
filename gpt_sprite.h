// The GPT mascot as pixel art on the same 20x20 grid, pixel size and flat
// palette as Clawd, so the two read as one cast. Hand-drawn (not downsampled:
// the face is smaller than one cell of the original and vanishes when
// scaled), with faces and a walk cycle so it behaves like a creature rather
// than a sliding icon. Pure data, no AppKit; main.m draws it.
#import <Foundation/Foundation.h>

#define GPT_N   20
#define GPT_TOP 3          // first occupied row (cloud top)
#define GPT_BOT 17         // last occupied row (feet)

// Palette indices used in the grid. 0 is transparent.
enum { GPTInkNone = 0, GPTInkBody = 1, GPTInkVisor = 2, GPTInkGlow = 3, GPTInkShade = 4, GPTInkCount = 5 };
extern const unsigned char kGPTPalette[GPTInkCount][3];

typedef NS_ENUM(NSInteger, GPTFace) {
    GPTFaceNormal,      // >_
    GPTFaceBlink,       // - -
    GPTFaceHappy,       // ^ ^  (tapped, cheered)
    GPTFaceSurprised,   // o o  (grabbed)
    GPTFaceSleepy,      // half-closed, dim (long rest)
    GPTFaceLook,        // glance to the side (toward the readout)
};

// Fills out[GPT_N*GPT_N], rows top-down, facing right. step is a walk phase
// 0..3 (legs swing and lift, like Clawd's gait) or -1 for standing.
void GPTSpriteFrame(GPTFace face, int step, unsigned char out[GPT_N * GPT_N]);
