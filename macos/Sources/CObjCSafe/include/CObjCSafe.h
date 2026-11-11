// 调应用（IMK 客户端）的方法时接住它抛出的 NSException，免得输入法跟着崩。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 执行 block；抛出 NSException 时返回它，正常结束返回 nil。
FOUNDATION_EXPORT NSException *_Nullable WTCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
