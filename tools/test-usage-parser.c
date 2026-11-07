/* Exercise the actual native parser without Cocoa, credentials or networking. */
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "../usage_parser.h"

static unsigned checks;

static void expect_reading(const UsageOutput *out, UsageProviderID provider,
                           int p5, int p7, int reset, int reset7, int age,
                           const char *state) {
    const UsageReading *r = &out->reading[provider];
    assert(out->valid[provider] == 1);
    assert(r->p5 == p5);
    assert(r->p7 == p7);
    assert(r->resetMin == reset);
    assert(r->reset7dMin == reset7);
    assert(r->ageSec == age);
    assert(strcmp(r->state, state) == 0);
    checks++;
}

/* Parses `text`, requiring exactly `found` providers. */
static UsageOutput parse(const char *text, size_t length, int found) {
    UsageOutput out;
    memset(&out, 0xa5, sizeof(out));
    assert(ParseUsageOutput(text, length, &out) == found);
    checks++;
    return out;
}

static void invalid_bytes(const char *text, size_t length) {
    UsageOutput out, before;
    memset(&out, 0xa5, sizeof(out));
    memcpy(&before, &out, sizeof(out));
    assert(ParseUsageOutput(text, length, &out) == 0);
    assert(memcmp(&out, &before, sizeof(out)) == 0);   /* all-or-nothing */
    checks++;
}

static void bad(const char *text) { invalid_bytes(text, strlen(text)); }

static void good_claude(const char *text, int p5, int p7, int r5, int r7, int age,
                        const char *state) {
    UsageOutput out = parse(text, strlen(text), 1);
    assert(!out.valid[UsageProviderCodex]);
    expect_reading(&out, UsageProviderClaude, p5, p7, r5, r7, age, state);
}

int main(void) {
    /* Both providers, in either order, with the newest record winning. */
    {
        const char *both = "claude 26 91 125 6150 0 ok\ncodex 18 42 44 5000 7 stale\n";
        UsageOutput out = parse(both, strlen(both), 2);
        expect_reading(&out, UsageProviderClaude, 26, 91, 125, 6150, 0, "ok");
        expect_reading(&out, UsageProviderCodex, 18, 42, 44, 5000, 7, "stale");
        const char *swapped = "codex 18 42 44 5000 7 stale\nclaude 26 91 125 6150 0 ok\n";
        out = parse(swapped, strlen(swapped), 2);
        expect_reading(&out, UsageProviderClaude, 26, 91, 125, 6150, 0, "ok");
        expect_reading(&out, UsageProviderCodex, 18, 42, 44, 5000, 7, "stale");
        const char *dup = "claude 1 2 3 4 5 ok\nclaude 26 91 125 6150 0 ok\n";
        out = parse(dup, strlen(dup), 1);
        expect_reading(&out, UsageProviderClaude, 26, 91, 125, 6150, 0, "ok");
    }

    good_claude("claude 37 8 20 100 0 ok\n", 37, 8, 20, 100, 0, "ok");
    good_claude("claude 37 8 20 100 0 ok", 37, 8, 20, 100, 0, "ok");
    good_claude("claude 0 0 -1 -1 -1 expired\n", 0, 0, -1, -1, -1, "expired");
    good_claude("claude 0 0 -1 -1 -1 none\n", 0, 0, -1, -1, -1, "none");
    good_claude("claude 0000000008 009 020 030 000 ok\n", 8, 9, 20, 30, 0, "ok");
    good_claude("claude 0 100 525600 525600 0 ok\n", 0, 100, 525600, 525600, 0, "ok");
    good_claude("  \tclaude\t37 8  20\t100 0 ok \t\r\n", 37, 8, 20, 100, 0, "ok");
    good_claude("claude 37 8 20 100 0 ok\nwarning: trailing diagnostic\n", 37, 8, 20, 100, 0, "ok");
    good_claude("debug start\n\nclaude 37 8 20 100 0 ok\n\n", 37, 8, 20, 100, 0, "ok");
    good_claude("claude 1 2 3 4 5 ok\nclaude 37 8 20 100 0 stale\ntrailing noise\n",
                37, 8, 20, 100, 0, "stale");
    /* An invalid newer line must not hide an older valid one. */
    good_claude("claude 1 2 3 4 5 ok\nclaude 101 2 3 4 5 ok\n", 1, 2, 3, 4, 5, "ok");

    bad(""); bad("\n\r\n \t\n"); bad("noise only\n");
    bad("claude 37 8 20 100 0\n");                    /* missing state */
    bad("claude 37 8 20 0 ok\n");                     /* old six-field shape */
    bad("claude 37 8 20 100 0 ok extra\n");
    bad("claude 37 8 20 100 0 okay\n"); bad("claude 37 8 20 100 0 OK\n");
    bad("claude 37 8 20 100 0 unknown\n"); bad("claude 37 8 20 100 0 okkkkkkk\n");
    bad("gemini 37 8 20 100 0 ok\n"); bad("Claude 37 8 20 100 0 ok\n");
    bad("claudex 37 8 20 100 0 ok\n"); bad("37 8 20 100 0 ok\n");
    bad("claude -1 8 20 100 0 ok\n"); bad("claude 37 -1 20 100 0 ok\n");
    bad("claude 37 8 20 100 0 ok\v\n");
    bad("claude 37 8 20 100 0 ok;touch /tmp/x\n");
    bad("claude 37 8 20 100 0 caf\xc3\xa9\n");

    const char *malformed[] = {
        "", "-", "--1", "+1", "-0", "-01", "00000000001", "1x", "0x10", "1.0", "1e2", "NaN", "inf",
        "2147483648", "-2147483649", "999999999999999999999999999999999",
        "a[$(touch${IFS}/tmp/not-executed)]"
    };
    for (size_t i = 0; i < sizeof(malformed)/sizeof(malformed[0]); i++) {
        for (int field = 0; field < 5; field++) {
            const char *v[5] = {"37", "8", "20", "100", "18"};
            v[field] = malformed[i];
            for (int provider = 0; provider < 2; provider++) {
                char line[512];
                snprintf(line, sizeof(line), "%s %s %s %s %s %s ok\n",
                         provider ? "codex" : "claude", v[0], v[1], v[2], v[3], v[4]);
                bad(line);
            }
        }
    }
    const char *ranges[] = {
        "claude 101 8 20 100 0 ok\n", "claude -2 8 20 100 0 ok\n", "claude 37 101 20 100 0 ok\n",
        "claude 37 -2 20 100 0 ok\n", "claude 37 8 -2 100 0 ok\n", "claude 37 8 525601 100 0 ok\n",
        "claude 37 8 20 -2 0 ok\n", "claude 37 8 20 525601 0 ok\n", "claude 37 8 20 100 -2 ok\n",
        "codex 101 8 20 100 0 ok\n", "codex 37 8 20 525601 0 ok\n"
    };
    for (size_t i = 0; i < sizeof(ranges)/sizeof(ranges[0]); i++) bad(ranges[i]);
    char boundary[256];
    snprintf(boundary, sizeof(boundary), "claude 1 2 3 4 %d ok\n", INT_MAX);
    good_claude(boundary, 1, 2, 3, 4, INT_MAX, "ok");

    /* The caller supplies a byte length, not necessarily a NUL-terminated string. */
    const char raw[] = "claude 1 2 3 4 5 ok";
    UsageOutput out = parse(raw, sizeof(raw) - 1, 1);
    expect_reading(&out, UsageProviderClaude, 1, 2, 3, 4, 5, "ok");
    const char embedded[] = "claude 1 2 3 4 5 ok\0hidden\n";
    invalid_bytes(embedded, sizeof(embedded) - 1);
    out = parse(embedded, 19, 1);
    expect_reading(&out, UsageProviderClaude, 1, 2, 3, 4, 5, "ok");

    char longline[600];
    memset(longline, ' ', sizeof(longline));
    memcpy(longline, "claude 1 2 3 4 5 ok", 19);
    longline[sizeof(longline)-1] = '\n';
    invalid_bytes(longline, sizeof(longline));
    out = parse(longline, 512, 1);
    expect_reading(&out, UsageProviderClaude, 1, 2, 3, 4, 5, "ok");
    invalid_bytes(longline, 513);
    char noisy[700];
    const char *valid = "claude 37 8 20 100 0 ok\n";
    size_t validlen = strlen(valid);
    memcpy(noisy, longline, sizeof(longline));
    memcpy(noisy + sizeof(longline), valid, validlen);
    out = parse(noisy, sizeof(longline) + validlen, 1);
    expect_reading(&out, UsageProviderClaude, 37, 8, 20, 100, 0, "ok");

    char *large = malloc(65537);
    assert(large != NULL);
    memset(large, '\n', 65537);
    memcpy(large + 65536 - validlen, valid, validlen);
    out = parse(large, 65536, 1);
    expect_reading(&out, UsageProviderClaude, 37, 8, 20, 100, 0, "ok");
    invalid_bytes(large, 65537);
    free(large);
    invalid_bytes(NULL, 0);
    invalid_bytes(NULL, 10);
    assert(ParseUsageOutput("claude 1 2 3 4 5 ok", 19, NULL) == 0);

    /* Reproducible malformed byte inputs; sanitizers catch overreads/UB while
       these assertions enforce the parser's all-or-nothing output contract. */
    uint32_t seed = UINT32_C(0x21a589f3);
    for (unsigned iteration = 0; iteration < 30000; iteration++) {
        char bytes[600];
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
        size_t length = seed % sizeof(bytes);
        for (size_t i = 0; i < length; i++) {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
            bytes[i] = (char)(seed & 255);
        }
        if (iteration % 2 == 0 && length >= validlen)
            memcpy(bytes + length - validlen, valid, validlen);
        UsageOutput result_out, before;
        memset(&result_out, 0xa5, sizeof(result_out));
        memcpy(&before, &result_out, sizeof(result_out));
        int result = ParseUsageOutput(bytes, length, &result_out);
        assert(result >= 0 && result <= 2);
        if (!result) {
            assert(memcmp(&result_out, &before, sizeof(result_out)) == 0);
        } else {
            for (int provider = 0; provider < 2; provider++) {
                if (!result_out.valid[provider]) continue;
                const UsageReading *r = &result_out.reading[provider];
                assert(r->p5 >= 0 && r->p5 <= 100);
                assert(r->p7 >= 0 && r->p7 <= 100);
                assert(r->resetMin >= -1 && r->resetMin <= 525600);
                assert(r->reset7dMin >= -1 && r->reset7dMin <= 525600);
                assert(r->ageSec >= -1);
                assert(memchr(r->state, 0, sizeof(r->state)) != NULL);
            }
        }
        checks++;
    }
    printf("usage parser: %u checks passed\n", checks);
    return 0;
}
