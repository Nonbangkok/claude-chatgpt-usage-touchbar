#import "../usage_model.h"

// Declared here first so this test fails to link until the reset-display
// behaviour is added to the real usage model.
FOUNDATION_EXPORT NSString *UsageResetDisplay(int resetMin);

@interface UsageProvider (WeeklyResetTest)
@property (nonatomic) int reset7dMin;
@end

static void require(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        UsageProvider *usage = ParseUsageRecord(@"codex 18 42 44 6150 0 ok");
        require(usage != nil,
                @"valid Codex record is accepted");
        require([usage.name isEqualToString:@"codex"], @"Codex provider name is preserved");
        require(usage.p5 == 18 && usage.p7 == 42, @"Codex window percentages are parsed");
        require(usage.resetMin == 44 && usage.reset7dMin == 6150 && usage.ageSec == 0,
                @"Codex five-hour, seven-day reset, and age are parsed");
        require(usage.available, @"ok record is available");

        require(ParseUsageRecord(@"unknown 99 99 0 0 ok") == nil,
                @"unknown providers are rejected");
        require(usage.p5 == 18 && usage.p7 == 42,
                @"rejected record cannot overwrite a healthy provider");

        usage = ParseUsageRecord(@"claude 0 0 -1 -1 -1 expired");
        require(usage != nil,
                @"expired Claude record is accepted");
        require([usage.name isEqualToString:@"claude"], @"Claude provider name is preserved");
        require(!usage.available && [usage.state isEqualToString:@"expired"],
                @"expired record is unavailable and actionable");

        UsageProvider *claude = ParseUsageRecord(@"claude 0 0 -1 -1 -1 expired");
        UsageProvider *codex = ParseUsageRecord(@"codex 18 42 44 6150 0 ok");
        require([VisibleUsageProviderNames(claude, codex) isEqualToArray:@[@"codex"]],
                @"hides an expired provider when its peer is available");

        codex = ParseUsageRecord(@"codex 0 0 -1 -1 -1 expired");
        require([VisibleUsageProviderNames(claude, codex) isEqualToArray:@[@"claude", @"codex"]],
                @"keeps both providers visible when both expired");

        UsageProvider *demoClaude = DemoUsageProvider(@"claude");
        UsageProvider *demoCodex = DemoUsageProvider(@"codex");
        require(demoClaude.available && demoClaude.p5 >= 12 && demoClaude.p5 <= 46 &&
                demoClaude.p7 >= 38 && demoClaude.p7 <= 79,
                @"Claude demo has a randomized live-looking allowance");
        require(demoCodex.available && demoCodex.p5 >= 8 && demoCodex.p5 <= 45 &&
                demoCodex.p7 >= 28 && demoCodex.p7 <= 75,
                @"ChatGPT demo has a randomized live-looking allowance");

        require([UsageResetDisplay(92) isEqualToString:@"↻ 1h 32m"],
                @"formats a session reset with hours and minutes");
        require([UsageResetDisplay(6150) isEqualToString:@"↻ 4d 6h"],
                @"formats a weekly reset with days and hours");
        require([UsageResetDisplay(-1) isEqualToString:@"↻ —"],
                @"marks an unavailable reset time");

        require(UsageRemainingPercent(62) == 38,
                @"converts used percentage to remaining percentage");
        require([UsageRemainingDisplay(62) isEqualToString:@"38% left"],
                @"labels the remaining percentage explicitly");
        require(UsageRemainingLevelForUsedPercent(90) == UsageRemainingLevelCritical,
                @"makes ten percent remaining critical");
        require(UsageRemainingLevelForUsedPercent(50) == UsageRemainingLevelWarning,
                @"makes fifty percent remaining a warning");
        require(UsageRemainingLevelForUsedPercent(49) == UsageRemainingLevelNormal,
                @"keeps more than fifty percent remaining normal");
    }
    puts("usage model: ok");
    return 0;
}
