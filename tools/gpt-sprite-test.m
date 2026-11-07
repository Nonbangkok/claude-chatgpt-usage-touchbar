#import <Foundation/Foundation.h>
#import "../gpt_sprite.h"

static int failures = 0;
static void Check(BOOL condition, NSString *message) {
    if (condition) printf("  ok    %s\n", message.UTF8String);
    else { printf("  FAIL  %s\n", message.UTF8String); failures++; }
}
static int Count(const unsigned char *g, int r0, int r1, int c0, int c1, int ink) {
    int n = 0;
    for (int r = r0; r <= r1; r++) for (int c = c0; c <= c1; c++) n += g[r * GPT_N + c] == ink;
    return n;
}
static int Differ(const unsigned char *a, const unsigned char *b) {
    int n = 0; for (int i = 0; i < GPT_N * GPT_N; i++) n += a[i] != b[i]; return n;
}

int main(void) {
    @autoreleasepool {
        unsigned char stand[GPT_N * GPT_N], other[GPT_N * GPT_N];
        GPTSpriteFrame(GPTFaceNormal, -1, stand);
        BOOL inks = YES, rows = YES;
        for (int i = 0; i < GPT_N * GPT_N; i++) inks &= stand[i] < GPTInkCount;
        for (int r = 0; r < GPT_N; r++)
            for (int c = 0; c < GPT_N; c++)
                if (stand[r * GPT_N + c] && (r < GPT_TOP || r > GPT_BOT)) rows = NO;
        Check(inks, @"every cell uses a palette index");
        Check(rows, @"nothing is drawn outside the declared row window");
        Check(Count(stand, GPT_TOP, GPT_BOT, 0, GPT_N - 1, GPTInkBody) > 60, @"a solid body");
        Check(Count(stand, 6, 9, 6, 12, GPTInkGlow) == 5, @"the resting face is the five-cell >_ prompt");
        Check(Count(stand, 12, 14, 6, 12, GPTInkGlow) == 5, @"the chest wears the >_ glyph");
        Check(stand[4 * GPT_N + 4] == GPTInkShade && stand[3 * GPT_N + 4] == GPTInkShade &&
              stand[2 * GPT_N + 4] == GPTInkGlow && Count(stand, 2, 2, 0, GPT_N - 1, GPTInkGlow) == 1,
              @"a two-cell antenna at the back of the head with a glowing ball on top");
        Check(Count(stand, 12, 13, 4, 5, GPTInkShade) == 4 && Count(stand, 12, 13, 13, 14, GPTInkShade) == 4 &&
              Count(stand, 14, 14, 4, 5, GPTInkShade) == 0,
              @"two 2x2 arms stick out from the sides of the body");
        Check(Count(stand, 16, 17, 6, 7, GPTInkBody) == 4 && Count(stand, 16, 17, 11, 12, GPTInkBody) == 4,
              @"standing: two full legs");
        // Symmetry of the body outside the face keeps the mirror flip honest.
        BOOL symmetric = YES;
        for (int r = GPT_TOP; r <= GPT_BOT; r++)
            for (int c = 0; c < GPT_N; c++) {
                if (r >= 6 && r <= 9 && c >= 6 && c <= 12) continue;   // face region
                if (r <= 4 && (c == 4 || c == 14)) continue;             // the antenna
                unsigned char a = stand[r * GPT_N + c], b = stand[r * GPT_N + (18 - c)];
                if (a == GPTInkGlow || b == GPTInkGlow) continue;       // the chest glyph
                if (c <= 18 && a != b) symmetric = NO;
            }
        Check(symmetric, @"the body is left-right symmetric about column 9");

        for (GPTFace f = GPTFaceNormal; f <= GPTFaceLook; f++) {
            GPTSpriteFrame(f, -1, other);
            BOOL onlyFace = YES;
            for (int r = 0; r < GPT_N; r++)
                for (int c = 0; c < GPT_N; c++)
                    if (other[r * GPT_N + c] != stand[r * GPT_N + c] && !(r >= 6 && r <= 9 && c >= 6 && c <= 12))
                        onlyFace = NO;
            Check(onlyFace, [NSString stringWithFormat:@"face %ld changes only the visor", (long)f]);
            Check(Count(other, 6, 9, 6, 12, GPTInkGlow) + Count(other, 6, 9, 6, 12, GPTInkShade) >= 4,
                  [NSString stringWithFormat:@"face %ld is visible", (long)f]);
        }
        GPTSpriteFrame(GPTFaceSleepy, -1, other);
        Check(Count(other, 6, 9, 6, 12, GPTInkGlow) == 0, @"sleepy eyes are dim, not glowing");

        unsigned char steps[4][GPT_N * GPT_N];
        for (int s = 0; s < 4; s++) GPTSpriteFrame(GPTFaceNormal, s, steps[s]);
        Check(Differ(steps[0], steps[2]) > 0 && Differ(steps[0], steps[1]) > 0, @"walk steps differ");
        Check(Count(steps[0], 17, 17, 0, GPT_N - 1, GPTInkBody) == 2 &&
              Count(steps[2], 17, 17, 0, GPT_N - 1, GPTInkBody) == 2,
              @"one leg is lifted on each swing beat");
        Check(Count(steps[1], 17, 17, 0, GPT_N - 1, GPTInkBody) == 4, @"both feet are planted between swings");
        BOOL legsOnly = YES;
        for (int s = 0; s < 4; s++)
            for (int r = 0; r < 16; r++)
                for (int c = 0; c < GPT_N; c++)
                    if (steps[s][r * GPT_N + c] != stand[r * GPT_N + c]) legsOnly = NO;
        Check(legsOnly, @"walking moves only the legs");
        Check(kGPTPalette[GPTInkBody][2] > kGPTPalette[GPTInkBody][0], @"the body is blue");
    }
    if (failures == 0) printf("gpt sprite: ok\n");
    return failures == 0 ? 0 : 1;
}
