#import "gpt_sprite.h"
#import <string.h>

const unsigned char kGPTPalette[GPTInkCount][3] = {
    {0, 0, 0},
    {116, 150, 232},    // body: the soft periwinkle of the original
    {44, 58, 110},      // visor
    {176, 244, 244},    // glowing symbol
    {82, 109, 183},     // shade under the head, arms
};

// '.' empty  '1' body  '2' visor  '3' glow  '4' shade.
// The visor (rows 8-10, cols 5-13) is drawn blank here; faces paint into it.
static const char *kBase[GPT_N] = {
    "....................",
    "....................",
    "....................",
    ".....1111.1111......",   // 3  cloud top, two bumps
    "....11111111111.....",   // 4
    "...1111111111111....",   // 5
    "..111111111111111...",   // 6
    "..111222222222111...",   // 7  visor rim
    ".11112222222221111..",   // 8
    ".11112222222221111..",   // 9
    ".11112222222221111..",   // 10
    "..111222222222111...",   // 11
    "..144444444444441...",   // 12 shade under the head
    "....4.1111111.4.....",   // 13 arms + body
    "....4.1113111.4.....",   // 14 chest light
    "......1111111.......",   // 15
    "......11...11.......",   // 16 legs
    "......11...11.......",   // 17
    "....................",
    "....................",
};

static void Put(unsigned char *g, int r, int c, unsigned char v) {
    if (r >= 0 && r < GPT_N && c >= 0 && c < GPT_N) g[r * GPT_N + c] = v;
}

static void PaintFace(unsigned char *g, GPTFace face) {
    switch (face) {
        case GPTFaceNormal:                      // >  _
            Put(g, 8, 6, 3); Put(g, 9, 7, 3); Put(g, 10, 6, 3);
            Put(g, 10, 10, 3); Put(g, 10, 11, 3);
            break;
        case GPTFaceLook:                        // the same, one cell toward the right
            Put(g, 8, 7, 3); Put(g, 9, 8, 3); Put(g, 10, 7, 3);
            Put(g, 10, 11, 3); Put(g, 10, 12, 3);
            break;
        case GPTFaceBlink:                       // -  -
            Put(g, 9, 6, 3); Put(g, 9, 7, 3); Put(g, 9, 10, 3); Put(g, 9, 11, 3);
            break;
        case GPTFaceHappy:                       // ^  ^
            Put(g, 8, 6, 3); Put(g, 9, 5, 3); Put(g, 9, 7, 3);
            Put(g, 8, 11, 3); Put(g, 9, 10, 3); Put(g, 9, 12, 3);
            break;
        case GPTFaceSurprised:                   // o  o  (wide)
            Put(g, 8, 6, 3); Put(g, 8, 7, 3); Put(g, 9, 6, 3); Put(g, 9, 7, 3);
            Put(g, 8, 10, 3); Put(g, 8, 11, 3); Put(g, 9, 10, 3); Put(g, 9, 11, 3);
            break;
        case GPTFaceSleepy:                      // half-closed, dimmer
            Put(g, 9, 6, 4); Put(g, 9, 7, 4); Put(g, 9, 10, 4); Put(g, 9, 11, 4);
            break;
    }
}

void GPTSpriteFrame(GPTFace face, int step, unsigned char out[GPT_N * GPT_N]) {
    for (int r = 0; r < GPT_N; r++)
        for (int c = 0; c < GPT_N; c++) {
            char ch = kBase[r][c];
            out[r * GPT_N + c] = (ch >= '1' && ch <= '4') ? (unsigned char)(ch - '0') : 0;
        }
    PaintFace(out, face);
    if (step < 0) return;

    // Walk: the two legs swing in counter-phase; a swinging leg is lifted
    // (drawn one row shorter). Same four-beat gait as Clawd so they keep time.
    static const int kLegC[2] = {6, 11};                 // left column of each 2-wide leg
    static const int kSwing[4][2] = {{-1, +1}, {0, 0}, {+1, -1}, {0, 0}};
    static const int kLift[4][2]  = {{1, 0}, {0, 0}, {0, 1}, {0, 0}};
    for (int r = 16; r <= 17; r++)
        for (int c = 0; c < GPT_N; c++) out[r * GPT_N + c] = 0;
    int ph = step & 3;
    for (int leg = 0; leg < 2; leg++) {
        int c0 = kLegC[leg] + kSwing[ph][leg];
        int bottom = kLift[ph][leg] ? 16 : 17;
        for (int r = 16; r <= bottom; r++)
            for (int c = c0; c < c0 + 2; c++) Put(out, r, c, 1);
    }
}
