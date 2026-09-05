#import "../usage_model.h"

static void require(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        UsageProvider *usage = ParseUsageRecord(@"codex 18 42 44 0 ok");
        require(usage != nil,
                @"valid Codex record is accepted");
        require([usage.name isEqualToString:@"codex"], @"Codex provider name is preserved");
        require(usage.p5 == 18 && usage.p7 == 42, @"Codex window percentages are parsed");
        require(usage.resetMin == 44 && usage.ageSec == 0, @"Codex reset and age are parsed");
        require(usage.available, @"ok record is available");

        require(ParseUsageRecord(@"unknown 99 99 0 0 ok") == nil,
                @"unknown providers are rejected");
        require(usage.p5 == 18 && usage.p7 == 42,
                @"rejected record cannot overwrite a healthy provider");

        usage = ParseUsageRecord(@"claude 0 0 -1 -1 expired");
        require(usage != nil,
                @"expired Claude record is accepted");
        require([usage.name isEqualToString:@"claude"], @"Claude provider name is preserved");
        require(!usage.available && [usage.state isEqualToString:@"expired"],
                @"expired record is unavailable and actionable");

        UsageProvider *claude = ParseUsageRecord(@"claude 0 0 -1 -1 expired");
        UsageProvider *codex = ParseUsageRecord(@"codex 18 42 44 0 ok");
        require([VisibleUsageProviderNames(claude, codex) isEqualToArray:@[@"codex"]],
                @"hides an expired provider when its peer is available");

        codex = ParseUsageRecord(@"codex 0 0 -1 -1 expired");
        require([VisibleUsageProviderNames(claude, codex) isEqualToArray:@[@"claude", @"codex"]],
                @"keeps both providers visible when both expired");

        UsageProvider *demoClaude = DemoUsageProvider(@"claude");
        UsageProvider *demoCodex = DemoUsageProvider(@"codex");
        require(demoClaude.available && demoClaude.p5 == 24 && demoClaude.p7 == 62,
                @"Claude Pro demo has a live-looking allowance");
        require(demoCodex.available && demoCodex.p5 == 18 && demoCodex.p7 == 44,
                @"ChatGPT Pro demo has a live-looking allowance");
    }
    puts("usage model: ok");
    return 0;
}
