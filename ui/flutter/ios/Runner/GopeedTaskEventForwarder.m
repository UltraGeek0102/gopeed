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
  // Send every event to native ActivityKit handling.
  [[GopeedLiveActivityManager shared]
      handleTaskEventPayload:arguments];

  // Flutter currently understands only task.done/task.error.
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

  BOOL flutterEvent =
      [type isEqualToString:@"task.done"] ||
      [type isEqualToString:@"task.error"];

  if (!flutterEvent) {
      return;
  }
  
  FlutterMethodChannel *channel = self.channel;
  dispatch_async(dispatch_get_main_queue(), ^{
    [channel invokeMethod:@"taskEvent" arguments:arguments];
  });
}

@end

void GopeedSubscribeTaskEventsWithForwarder(
    int64_t mask,
    GopeedTaskEventForwarder * _Nullable listener) {
  LibgopeedSubscribeTaskEvents(mask, listener);
}
