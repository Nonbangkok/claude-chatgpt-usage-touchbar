#import "usage_model.h"
#import <string.h>

@implementation UsageProvider
@end

UsageProvider *UsageProviderFromReading(UsageProviderID provider, const UsageReading *reading) {
    UsageProvider *usage = [UsageProvider new];
    usage.name = provider == UsageProviderClaude ? @"claude" : @"codex";
    usage.p5 = reading->p5;
    usage.p7 = reading->p7;
    usage.resetMin = reading->resetMin;
    usage.reset7dMin = reading->reset7dMin;
    usage.ageSec = reading->ageSec;
    usage.state = [NSString stringWithUTF8String:reading->state];
    usage.available = strcmp(reading->state, "none") != 0 && strcmp(reading->state, "expired") != 0;
    return usage;
}

UsageProvider *ParseUsageRecord(NSString *line) {
    // One validation path for the app and the tests: the strict C parser.
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    UsageProviderID provider;
    UsageReading reading;
    if (!ParseUsageLine(data.bytes, data.length, &provider, &reading)) return nil;
    return UsageProviderFromReading(provider, &reading);
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
