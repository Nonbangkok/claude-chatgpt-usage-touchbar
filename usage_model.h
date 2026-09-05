#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface UsageProvider : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) int p5;
@property (nonatomic) int p7;
@property (nonatomic) int resetMin;
@property (nonatomic) int reset7dMin;
@property (nonatomic) int ageSec;
@property (nonatomic, copy) NSString *state;
@property (nonatomic) BOOL available;
@end

FOUNDATION_EXPORT UsageProvider * _Nullable ParseUsageRecord(NSString *line);
FOUNDATION_EXPORT NSArray<NSString *> *VisibleUsageProviderNames(UsageProvider *claude,
                                                                  UsageProvider *codex);
FOUNDATION_EXPORT UsageProvider *DemoUsageProvider(NSString *name);
FOUNDATION_EXPORT NSString *UsageResetDisplay(int resetMin);

typedef NS_ENUM(NSInteger, UsageRemainingLevel) {
    UsageRemainingLevelNormal,
    UsageRemainingLevelWarning,
    UsageRemainingLevelCritical,
};
FOUNDATION_EXPORT int UsageRemainingPercent(int usedPercent);
FOUNDATION_EXPORT NSString *UsageRemainingDisplay(int usedPercent);
FOUNDATION_EXPORT UsageRemainingLevel UsageRemainingLevelForUsedPercent(int usedPercent);

NS_ASSUME_NONNULL_END
