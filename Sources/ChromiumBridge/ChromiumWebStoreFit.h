#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ArdiaCoreTab;

typedef void (^ARCWebStoreFitEvaluator)(ArdiaCoreTab *tab, NSString *script,
                                        void (^completion)(NSString * _Nullable json));

/// Zooms Chrome Web Store tabs out just enough to fit the store's fixed body minimum width,
/// and back to 100% once the page card is wide enough. A manual zoom holds until the next navigation.
@interface ARCWebStoreFit : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithTesting:(BOOL)testing evaluator:(ARCWebStoreFitEvaluator)evaluator;
- (void)tabDidNavigate:(ArdiaCoreTab *)tab;
- (void)tabDidChangeLoading:(ArdiaCoreTab *)tab;
- (void)tabDidChangeZoom:(ArdiaCoreTab *)tab;
- (void)tabWillClose:(ArdiaCoreTab *)tab;
@end

NS_ASSUME_NONNULL_END
