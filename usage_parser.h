// Strict, portable parser for claude-touchbar.sh --raw output.
// The line-oriented approach builds on @xmihal03's PR #1. Scan backwards
// so both login banners and trailing shell diagnostics can be ignored.
//
// Protocol: one record per provider, six fields after the provider name:
//   "<claude|codex> <5h%> <7d%> <5hResetMin> <7dResetMin> <ageSec> <state> [longDays] [plan]"
// longDays (1...3650, default 7) is the length of the long window, e.g. 30 for
// a free ChatGPT plan. plan is the subscription level (max_20x, pro, free...)
// in [A-Za-z0-9_.-], at most 24 chars; "-" or absent means unknown. Either
// optional token may be omitted, but not reordered: longDays is numeric and
// plan always starts with a letter, so a lone token is unambiguous. The newest
// valid record of each provider wins; anything else is noise.
#pragma once
#include <limits.h>
#include <stddef.h>
#include <string.h>

typedef enum { UsageProviderClaude = 0, UsageProviderCodex = 1 } UsageProviderID;

typedef struct {
    int p5, p7, resetMin, reset7dMin, ageSec, longDays;
    char state[8];
    char plan[25];                      // "" when unknown
} UsageReading;

typedef struct {
    UsageReading reading[2];
    int valid[2];                       // indexed by UsageProviderID
} UsageOutput;

typedef struct { const char *text; size_t length; } UsageToken;

static inline int UsageTokenEquals(UsageToken token, const char *value) {
    return token.length == strlen(value) &&
           memcmp(token.text, value, token.length) == 0;
}

static inline int UsageInteger(UsageToken token, int maximum, int *result) {
    // Only the protocol's unknown sentinel may be negative. No signs,
    // decimals, suffixes or locale-dependent conversion; decimal zeros are OK.
    if (UsageTokenEquals(token, "-1")) { *result = -1; return 1; }
    if (token.length == 0 || token.length > 10) return 0;
    int value = 0;
    for (size_t i = 0; i < token.length; ++i) {
        unsigned char c = (unsigned char)token.text[i];
        if (c < '0' || c > '9') return 0;
        int digit = c - '0';
        if (value > maximum / 10 ||
            (value == maximum / 10 && digit > maximum % 10)) return 0;
        value = value * 10 + digit;
    }
    *result = value;
    return 1;
}

// Parses exactly one record. On success returns 1, stores the provider and
// reading; on failure returns 0 and leaves both outputs untouched.
static inline int ParseUsageLine(const char *text, size_t length,
                          UsageProviderID *provider, UsageReading *out) {
    if (!text || !provider || !out || length == 0 || length > 512) return 0;
    UsageToken fields[10];
    size_t count = 0, i = 0;
    while (i < length) {
        while (i < length && (text[i] == ' ' || text[i] == '\t')) ++i;
        if (i == length) break;
        if (count == 10) return 0;
        size_t start = i;
        while (i < length && text[i] != ' ' && text[i] != '\t') ++i;
        fields[count++] = (UsageToken){text + start, i - start};
    }
    if (count < 7 || count > 9) return 0;

    UsageProviderID id;
    if (UsageTokenEquals(fields[0], "claude")) id = UsageProviderClaude;
    else if (UsageTokenEquals(fields[0], "codex")) id = UsageProviderCodex;
    else return 0;

    UsageReading candidate = {0};
    candidate.longDays = 7;
    if (!UsageInteger(fields[1], 100, &candidate.p5) ||
        !UsageInteger(fields[2], 100, &candidate.p7) ||
        !UsageInteger(fields[3], 525600, &candidate.resetMin) ||
        !UsageInteger(fields[4], 525600, &candidate.reset7dMin) ||
        !UsageInteger(fields[5], INT_MAX, &candidate.ageSec)) return 0;
    // -1 means "this window is not reported" (e.g. no active five-hour window:
    // the API sends `five_hour: null`). The view draws it as an em dash, so it
    // must not discard the other window's valid reading.
    if (!(UsageTokenEquals(fields[6], "ok") || UsageTokenEquals(fields[6], "stale") ||
          UsageTokenEquals(fields[6], "expired") || UsageTokenEquals(fields[6], "none"))) return 0;
    memcpy(candidate.state, fields[6].text, fields[6].length);
    size_t next = 7;
    if (next < count && fields[next].length && fields[next].text[0] >= '0' &&
        fields[next].text[0] <= '9') {
        if (!UsageInteger(fields[next], 3650, &candidate.longDays) ||
            candidate.longDays < 1) return 0;
        ++next;
    }
    if (next < count) {
        UsageToken plan = fields[next];
        if (next + 1 != count) return 0;           /* nothing may follow the plan */
        if (!UsageTokenEquals(plan, "-")) {
            if (plan.length == 0 || plan.length > 24) return 0;
            for (size_t j = 0; j < plan.length; ++j) {
                unsigned char c = (unsigned char)plan.text[j];
                int alpha = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
                if (j == 0 ? !alpha
                           : !(alpha || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-'))
                    return 0;
            }
            memcpy(candidate.plan, plan.text, plan.length);
        }
    }
    *provider = id;
    *out = candidate;
    return 1;
}

// Scans backwards so the newest record per provider wins and trailing noise
// is ignored. Returns the number of providers found (0 leaves `out` untouched).
static inline int ParseUsageOutput(const char *text, size_t length, UsageOutput *out) {
    if (!text || !out || length == 0 || length > 65536) return 0;
    // Reject embedded NUL rather than allowing callers to disagree on length.
    if (memchr(text, '\0', length)) return 0;
    UsageOutput found;
    memset(&found, 0, sizeof(found));
    int count = 0;
    size_t end = length;
    while (end > 0 && count < 2) {
        while (end > 0 && (text[end - 1] == '\n' || text[end - 1] == '\r')) --end;
        if (end == 0) break;
        size_t start = end;
        while (start > 0 && text[start - 1] != '\n' && text[start - 1] != '\r') --start;
        UsageProviderID provider;
        UsageReading reading;
        if (ParseUsageLine(text + start, end - start, &provider, &reading) &&
            !found.valid[provider]) {
            found.reading[provider] = reading;
            found.valid[provider] = 1;
            ++count;
        }
        end = start;
    }
    if (count) *out = found;
    return count;
}
