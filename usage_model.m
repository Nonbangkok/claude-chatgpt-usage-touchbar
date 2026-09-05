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
    if (parts.count != 6) return nil;

    NSString *name = parts[0];
    NSString *state = parts[5];
    if (!([name isEqualToString:@"claude"] || [name isEqualToString:@"codex"])) return nil;
    if (!([state isEqualToString:@"ok"] || [state isEqualToString:@"stale"] ||
          [state isEqualToString:@"expired"] || [state isEqualToString:@"none"])) return nil;

    int p5, p7, resetMin, ageSec;
    if (!ParseInt(parts[1], &p5) || !ParseInt(parts[2], &p7) ||
        !ParseInt(parts[3], &resetMin) || !ParseInt(parts[4], &ageSec)) return nil;
    if (p5 < 0 || p5 > 100 || p7 < 0 || p7 > 100 || resetMin < -1 || ageSec < -1) return nil;

    UsageProvider *usage = [UsageProvider new];
    usage.name = name;
    usage.p5 = p5;
    usage.p7 = p7;
    usage.resetMin = resetMin;
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
        usage.p5 = 24; usage.p7 = 62; usage.resetMin = 147;
    } else {
        usage.p5 = 18; usage.p7 = 44; usage.resetMin = 203;
    }
    usage.ageSec = 0;
    return usage;
}
