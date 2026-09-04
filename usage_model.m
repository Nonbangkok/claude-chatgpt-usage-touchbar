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
