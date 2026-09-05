#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface UsageProvider : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) int p5;
@property (nonatomic) int p7;
@property (nonatomic) int resetMin;
@property (nonatomic) int ageSec;
@property (nonatomic, copy) NSString *state;
@property (nonatomic) BOOL available;
@end

FOUNDATION_EXPORT UsageProvider * _Nullable ParseUsageRecord(NSString *line);
FOUNDATION_EXPORT NSArray<NSString *> *VisibleUsageProviderNames(UsageProvider *claude,
                                                                  UsageProvider *codex);
FOUNDATION_EXPORT UsageProvider *DemoUsageProvider(NSString *name);

NS_ASSUME_NONNULL_END
