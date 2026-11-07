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
// Chibi proportions: a small round cloud of a head on a chubby body with
// stubby legs. The visor (rows 6-9, cols 6-12) is blank here; faces paint
// the original's >_ terminal prompt into it. The chest wears it too. A short
// antenna rises from the back of the head with a glowing ball on top; the
// walking mirror keeps it at the back whichever way it faces.
static const char *kBase[GPT_N] = {
    "....................",
    "....................",
    "....3...............",   // 2  antenna ball, glowing
    "....4..11111........",   // 3  antenna stem, two cells, at the back of the head
    "....4111111111......",   // 4
    "....11111111111.....",   // 5
    "....11222222211.....",   // 6  visor
    "...1112222222111....",   // 7  side bumps
    "...1112222222111....",   // 8
    "....11222222211.....",   // 9
    ".....111111111......",   // 10 chin
    "......4444444.......",   // 11 shade under the head
    "....44111111144.....",   // 12 arms: 2x2 blocks sticking out
    "....44111111144.....",   // 13
    "......1111111.......",   // 14
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
        case GPTFaceNormal:                      // >_
            Put(g, 6, 7, 3); Put(g, 7, 8, 3); Put(g, 8, 7, 3);
            Put(g, 8, 10, 3); Put(g, 8, 11, 3);
            break;
        case GPTFaceLook:                        // the same, one cell toward the right
            Put(g, 6, 8, 3); Put(g, 7, 9, 3); Put(g, 8, 8, 3);
            Put(g, 8, 11, 3); Put(g, 8, 12, 3);
            break;
        case GPTFaceBlink:                       // -  -
            Put(g, 7, 7, 3); Put(g, 7, 8, 3); Put(g, 7, 10, 3); Put(g, 7, 11, 3);
            break;
        case GPTFaceHappy:                       // ^ ^ and a smile
            Put(g, 6, 7, 3); Put(g, 7, 6, 3); Put(g, 7, 8, 3);
            Put(g, 6, 11, 3); Put(g, 7, 10, 3); Put(g, 7, 12, 3);
            Put(g, 9, 8, 3); Put(g, 9, 9, 3); Put(g, 9, 10, 3);
            break;
        case GPTFaceSurprised:                   // o o and a little o mouth
            Put(g, 6, 7, 3); Put(g, 6, 8, 3); Put(g, 7, 7, 3); Put(g, 7, 8, 3);
            Put(g, 6, 10, 3); Put(g, 6, 11, 3); Put(g, 7, 10, 3); Put(g, 7, 11, 3);
            Put(g, 9, 9, 3);
            break;
        case GPTFaceSleepy:                      // half-closed, dimmer
            Put(g, 7, 7, 4); Put(g, 7, 8, 4); Put(g, 7, 10, 4); Put(g, 7, 11, 4);
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
    Put(out, 12, 7, 3); Put(out, 13, 8, 3); Put(out, 14, 7, 3);     // >
    Put(out, 14, 10, 3); Put(out, 14, 11, 3);                        // _
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
