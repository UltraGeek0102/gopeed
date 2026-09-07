#import "GopeedTaskEventForwarder.h"

#import <Libgopeed/Libgopeed.h>

#import "Runner-Swift.h"

@interface GopeedTaskEventForwarder () <LibgopeedTaskEventListener>

@property(nonatomic, strong) FlutterMethodChannel *channel;

@end

@implementation GopeedTaskEventForwarder

- (instancetype)initWithChannel:(FlutterMethodChannel *)channel {
  self = [super init];
  if (self) {
    _channel = channel;
  }
  return self;
}

- (void)onTaskEvent:(NSString * _Nullable)payload {
  NSString *arguments = payload ?: @"";

  NSData *data =
      [arguments dataUsingEncoding:NSUTF8StringEncoding];

  NSDictionary *json = nil;

  if (data) {
    json =
        [NSJSONSerialization JSONObjectWithData:data
                                        options:0
                                          error:nil];
  }

  NSString *type = json[@"type"];
  NSString *taskID = json[@"taskId"];

  BOOL continuedProcessingHandlesTask = NO;

  // iOS 26 system continued-processing Live Activity.
  if (@available(iOS 26.0, *)) {
    GopeedContinuedProcessingManager *manager =
        [GopeedContinuedProcessingManager shared];

    [manager handleTaskEventPayload:arguments];

    if (taskID.length > 0) {
      continuedProcessingHandlesTask =
          [manager isHandlingTaskId:taskID];
    }
  }

  // When BGCPT is active, let Apple's system Live Activity
  // represent progress. Otherwise keep using our existing
  // custom Gopeed ActivityKit implementation.
  if (!continuedProcessingHandlesTask) {
    [[GopeedLiveActivityManager shared]
        handleTaskEventPayload:arguments];
  }

  // Flutter currently understands only done/error.
  BOOL flutterEvent =
      [type isEqualToString:@"task.done"] ||
      [type isEqualToString:@"task.error"];

  if (!flutterEvent) {
    return;
  }

  FlutterMethodChannel *channel = self.channel;

  dispatch_async(dispatch_get_main_queue(), ^{
    [channel invokeMethod:@"taskEvent"
                arguments:arguments];
  });
}

@end

void GopeedSubscribeTaskEventsWithForwarder(
    int64_t mask,
    GopeedTaskEventForwarder * _Nullable listener) {
  LibgopeedSubscribeTaskEvents(mask, listener);
}
