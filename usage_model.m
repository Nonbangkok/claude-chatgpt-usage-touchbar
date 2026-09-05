#import "usage_model.h"

@implementation UsageProvider
@end

static BOOL ParseInt(NSString *value, int *result) {
    NSScanner *scanner = [NSScanner scannerWithString:value];
    int parsed = 0;
    if (![scanner scanInt:&parsed] || !scanner.isAtEnd) return NO;
    *result = parsed;
    return YES;
}

UsageProvider *ParseUsageRecord(NSString *line) {
    NSArray<NSString *> *parts = [[line
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        componentsSeparatedByString:@" "];
    if (parts.count != 7) return nil;

    NSString *name = parts[0];
    NSString *state = parts[6];
    if (!([name isEqualToString:@"claude"] || [name isEqualToString:@"codex"])) return nil;
    if (!([state isEqualToString:@"ok"] || [state isEqualToString:@"stale"] ||
          [state isEqualToString:@"expired"] || [state isEqualToString:@"none"])) return nil;

    int p5, p7, resetMin, reset7dMin, ageSec;
    if (!ParseInt(parts[1], &p5) || !ParseInt(parts[2], &p7) ||
        !ParseInt(parts[3], &resetMin) || !ParseInt(parts[4], &reset7dMin) ||
        !ParseInt(parts[5], &ageSec)) return nil;
    if (p5 < 0 || p5 > 100 || p7 < 0 || p7 > 100 || resetMin < -1 ||
        reset7dMin < -1 || ageSec < -1) return nil;

    UsageProvider *usage = [UsageProvider new];
    usage.name = name;
    usage.p5 = p5;
    usage.p7 = p7;
    usage.resetMin = resetMin;
    usage.reset7dMin = reset7dMin;
    usage.ageSec = ageSec;
    usage.state = state;
    usage.available = ![state isEqualToString:@"none"] && ![state isEqualToString:@"expired"];
    return usage;
}

NSArray<NSString *> *VisibleUsageProviderNames(UsageProvider *claude, UsageProvider *codex) {
    BOOL claudeExpired = [claude.state isEqualToString:@"expired"];
    BOOL codexExpired = [codex.state isEqualToString:@"expired"];
    // When every provider needs authentication, keep both labels visible so
    // the user knows to repair both accounts. Otherwise an expired provider
    // only takes valuable Touch Bar space from a live one.
    if (claudeExpired && codexExpired) return @[@"claude", @"codex"];

    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:2];
    if (!claudeExpired) [names addObject:@"claude"];
    if (!codexExpired) [names addObject:@"codex"];
    return names;
}

UsageProvider *DemoUsageProvider(NSString *name) {
    UsageProvider *usage = [UsageProvider new];
    usage.name = name;
    usage.state = @"ok";
    usage.available = YES;
    if ([name isEqualToString:@"claude"]) {
        usage.p5 = 12 + (int)arc4random_uniform(35);   // 12-46%
        usage.p7 = 38 + (int)arc4random_uniform(42);   // 38-79%
        usage.resetMin = 45 + (int)arc4random_uniform(220);
    } else {
        usage.p5 = 8 + (int)arc4random_uniform(38);    // 8-45%
        usage.p7 = 28 + (int)arc4random_uniform(48);   // 28-75%
        usage.resetMin = 45 + (int)arc4random_uniform(220);
    }
    usage.reset7dMin = 2 * 24 * 60 + (int)arc4random_uniform(5 * 24 * 60);
    usage.ageSec = 0;
    return usage;
}

NSString *UsageResetDisplay(int resetMin) {
    if (resetMin < 0) return @"↻ —";
    if (resetMin < 60) return [NSString stringWithFormat:@"↻ %dm", resetMin];
    if (resetMin < 24 * 60)
        return [NSString stringWithFormat:@"↻ %dh %dm", resetMin / 60, resetMin % 60];
    return [NSString stringWithFormat:@"↻ %dd %dh", resetMin / (24 * 60), (resetMin / 60) % 24];
}

int UsageRemainingPercent(int usedPercent) {
    if (usedPercent < 0 || usedPercent > 100) return -1;
    return 100 - usedPercent;
}

NSString *UsageRemainingDisplay(int usedPercent) {
    int remaining = UsageRemainingPercent(usedPercent);
    return remaining < 0 ? @"—" : [NSString stringWithFormat:@"%d%% left", remaining];
}

UsageRemainingLevel UsageRemainingLevelForUsedPercent(int usedPercent) {
    int remaining = UsageRemainingPercent(usedPercent);
    if (remaining >= 0 && remaining <= 10) return UsageRemainingLevelCritical;
    if (remaining >= 0 && remaining <= 50) return UsageRemainingLevelWarning;
    return UsageRemainingLevelNormal;
}
