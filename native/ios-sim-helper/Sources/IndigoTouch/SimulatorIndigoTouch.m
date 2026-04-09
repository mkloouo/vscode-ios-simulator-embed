/**
 * Touch injection via SimulatorKit Indigo HID (private Apple SPI).
 * Message construction adapted from Meta idb FBSimulatorIndigoHID.m (MIT).
 */

#import "SimulatorIndigoTouch.h"
#import "Indigo.h"

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <malloc/malloc.h>
#import <string.h>

static const unsigned long long kSimDeviceStateBooted = 3;

static IndigoMessage *IndigoHIDMessageForMouseNSEvent(
  CGPoint *point0, CGPoint *point1, int target, int eventType, BOOL flag) {
  IndigoMessage *(*fn)(CGPoint *, CGPoint *, int, int, BOOL) =
    (void *)dlsym(RTLD_DEFAULT, "IndigoHIDMessageForMouseNSEvent");
  if (!fn) {
    return NULL;
  }
  return fn(point0, point1, target, eventType, flag);
}

static IndigoMessage *BuildTouchMessage(IndigoTouch *payload, size_t *messageSizeOut) {
  size_t messageSize = sizeof(IndigoMessage) + sizeof(IndigoPayload);
  size_t stride = sizeof(IndigoPayload);

  IndigoMessage *message = calloc(1, messageSize);
  if (!message) {
    return NULL;
  }
  message->innerSize = sizeof(IndigoPayload);
  message->eventType = IndigoEventTypeTouch;
  message->payload.field1 = 0x0000000b;
  message->payload.timestamp = mach_absolute_time();

  void *destination = &(message->payload.event.button);
  void *source = payload;
  memcpy(destination, source, sizeof(IndigoTouch));

  source = &(message->payload);
  destination = (char *)source + stride;
  IndigoPayload *second = (IndigoPayload *)destination;
  memcpy(destination, source, stride);
  second->event.touch.field1 = 0x00000001;
  second->event.touch.field2 = 0x00000002;

  if (messageSizeOut) {
    *messageSizeOut = messageSize;
  }
  return message;
}

// NSEventType (AppKit): LeftMouseDown=1, LeftMouseUp=2, LeftMouseDragged=6.
// Phase 0 means "touch move during drag" — passing 0 to IndigoHIDMessageForMouseNSEvent returns NULL (invalid type).
static const int kNSEventLeftMouseDragged = 6;
static const int kNSEventMouseMoved = 5;

static IndigoMessage *BuildTouchAtRatios(double xRatio, double yRatio, int direction, size_t *outSize) {
  CGPoint point = CGPointMake(xRatio, yRatio);
  int mouseType = direction;
  if (direction == 0) {
    mouseType = kNSEventLeftMouseDragged;
  }
  IndigoMessage *partial = IndigoHIDMessageForMouseNSEvent(&point, NULL, 0x32, mouseType, NO);
  if (!partial && direction == 0) {
    partial = IndigoHIDMessageForMouseNSEvent(&point, NULL, 0x32, kNSEventMouseMoved, NO);
  }
  if (!partial) {
    return NULL;
  }
  partial->payload.event.touch.xRatio = xRatio;
  partial->payload.event.touch.yRatio = yRatio;
  IndigoTouch t = partial->payload.event.touch;
  free(partial);
  return BuildTouchMessage(&t, outSize);
}

static void StrErr(char *buf, size_t len, NSString *msg) {
  if (!buf || len == 0) {
    return;
  }
  const char *utf8 = msg.UTF8String ?: "error";
  strncpy(buf, utf8, len - 1);
  buf[len - 1] = '\0';
}

BOOL IOSEmbedLoadSimulatorFrameworks(void) {
  NSBundle *cs = [NSBundle bundleWithPath:@"/Library/Developer/PrivateFrameworks/CoreSimulator.framework"];
  if (![cs load]) {
    return NO;
  }
  NSString *dev = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
  if (dev.length == 0) {
    dev = @"/Applications/Xcode.app/Contents/Developer";
  }
  NSString *skPath =
    [[dev stringByAppendingPathComponent:@"Library/PrivateFrameworks"] stringByAppendingPathComponent:@"SimulatorKit.framework"];
  NSBundle *sk = [NSBundle bundleWithPath:skPath];
  if (![sk load]) {
    return NO;
  }
  return YES;
}

static id SimServiceContextShared(NSString *developerDir, NSError **error) {
  Class cls = objc_getClass("SimServiceContext");
  if (!cls) {
    if (error) {
      *error = [NSError errorWithDomain:@"IOSEmbed" code:1 userInfo:@{NSLocalizedDescriptionKey: @"SimServiceContext class missing"}];
    }
    return nil;
  }
  return ((id (*)(Class, SEL, NSString *, NSError **))objc_msgSend)(
    cls, sel_registerName("sharedServiceContextForDeveloperDir:error:"), developerDir, error);
}

static id DefaultDeviceSet(id serviceContext, NSError **error) {
  return ((id (*)(id, SEL, NSError **))objc_msgSend)(
    serviceContext, sel_registerName("defaultDeviceSetWithError:"), error);
}

static NSArray *DeviceSetDevices(id deviceSet) {
  return ((NSArray * (*)(id, SEL))objc_msgSend)(deviceSet, sel_registerName("devices"));
}

static unsigned long long SimDeviceState(id device) {
  return ((unsigned long long (*)(id, SEL))objc_msgSend)(device, sel_registerName("state"));
}

static NSString *SimDeviceUDIDString(id device) {
  NSUUID *uuid = ((NSUUID * (*)(id, SEL))objc_msgSend)(device, sel_registerName("UDID"));
  return uuid.UUIDString;
}

static id BootedSimDevice(NSString *udidFilter, NSError **error) {
  NSString *dev = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
  if (dev.length == 0) {
    dev = @"/Applications/Xcode.app/Contents/Developer";
  }
  NSError *e2 = nil;
  id ctx = SimServiceContextShared(dev, &e2);
  if (!ctx) {
    if (error) {
      *error = e2;
    }
    return nil;
  }
  id set = DefaultDeviceSet(ctx, &e2);
  if (!set) {
    if (error) {
      *error = e2 ?: [NSError errorWithDomain:@"IOSEmbed" code:2 userInfo:@{NSLocalizedDescriptionKey: @"No device set"}];
    }
    return nil;
  }
  NSArray *devices = DeviceSetDevices(set);
  for (id d in devices) {
    if (SimDeviceState(d) != kSimDeviceStateBooted) {
      continue;
    }
    if (udidFilter.length > 0) {
      NSString *u = SimDeviceUDIDString(d);
      if (![u.lowercaseString isEqualToString:udidFilter.lowercaseString]) {
        continue;
      }
    }
    return d;
  }
  if (error) {
    *error = [NSError
      errorWithDomain:@"IOSEmbed"
                 code:3
             userInfo:@{
               NSLocalizedDescriptionKey : @"No booted simulator. Boot one in Xcode or `simctl boot`, or set IOS_SIM_UDID.",
             }];
  }
  return nil;
}

static Class SimDeviceLegacyHIDClientClass(void) {
  Class c = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient");
  if (c) {
    return c;
  }
  c = NSClassFromString(@"SimDeviceLegacyHIDClient");
  if (c) {
    return c;
  }
  return objc_lookUpClass("SimDeviceLegacyHIDClient");
}

static BOOL HIDClientSendIndigoTouch(id client, double xRatio, double yRatio, int phase, char *errBuf, size_t errLen) {
  if (xRatio < 0 || xRatio > 1 || yRatio < 0 || yRatio > 1) {
    StrErr(errBuf, errLen, @"x/y ratios must be in [0,1]");
    return NO;
  }
  if (phase != 0 && phase != 1 && phase != 2) {
    StrErr(errBuf, errLen, @"phase must be 0 (move), 1 (down), or 2 (up)");
    return NO;
  }

  size_t msgSize = 0;
  IndigoMessage *message = BuildTouchAtRatios(xRatio, yRatio, phase, &msgSize);
  if (!message || msgSize == 0) {
    StrErr(errBuf, errLen, @"IndigoHIDMessageForMouseNSEvent unavailable or allocation failed");
    return NO;
  }

  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block NSError *sendErr = nil;

  typedef void (^Completion)(NSError *);
  SEL sendSel = sel_registerName("sendWithMessage:freeWhenDone:completionQueue:completion:");
  Method meth = class_getInstanceMethod([client class], sendSel);
  if (!meth) {
    free(message);
    StrErr(errBuf, errLen, @"sendWithMessage:freeWhenDone:completionQueue:completion: not found");
    return NO;
  }
  IMP imp = method_getImplementation(meth);
  void (*send)(id, SEL, IndigoMessage *, BOOL, dispatch_queue_t, Completion) = (void *)imp;
  send(client, sendSel, message, YES, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(NSError *e) {
    sendErr = e;
    dispatch_semaphore_signal(sem);
  });

  dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

  if (sendErr) {
    StrErr(errBuf, errLen, sendErr.localizedDescription);
    return NO;
  }
  return YES;
}

BOOL IOSEmbedBootedMainScreenLogicalSize(
  NSString *udidFilter,
  double *outW,
  double *outH,
  char *errBuf,
  size_t errLen) {
  if (!outW || !outH) {
    return NO;
  }
  *outW = 0;
  *outH = 0;
  if (!IOSEmbedLoadSimulatorFrameworks()) {
    StrErr(errBuf, errLen, @"Failed to load CoreSimulator / SimulatorKit");
    return NO;
  }
  NSError *err = nil;
  id device = BootedSimDevice(udidFilter, &err);
  if (!device) {
    StrErr(errBuf, errLen, err.localizedDescription);
    return NO;
  }
  id deviceType = ((id (*)(id, SEL))objc_msgSend)(device, sel_registerName("deviceType"));
  if (!deviceType) {
    StrErr(errBuf, errLen, @"SimDevice deviceType is nil");
    return NO;
  }
  CGSize (*getMainScreenSize)(id, SEL) = (CGSize (*)(id, SEL))objc_msgSend;
  CGSize sz = getMainScreenSize(deviceType, sel_registerName("mainScreenSize"));
  if (sz.width <= 0 || sz.height <= 0) {
    StrErr(errBuf, errLen, @"mainScreenSize is invalid");
    return NO;
  }
  *outW = sz.width;
  *outH = sz.height;
  return YES;
}

BOOL IOSEmbedHIDSendTouch(
  NSString *udid,
  double xRatio,
  double yRatio,
  int phase,
  char *errBuf,
  size_t errLen) {
  NSError *err = nil;
  id device = BootedSimDevice(udid, &err);
  if (!device) {
    StrErr(errBuf, errLen, err.localizedDescription);
    return NO;
  }

  Class clientClass = SimDeviceLegacyHIDClientClass();
  if (!clientClass) {
    StrErr(errBuf, errLen, @"SimDeviceLegacyHIDClient class not found (SimulatorKit too new/old?)");
    return NO;
  }

  id clientAlloc = ((id (*)(Class, SEL))objc_msgSend)(clientClass, sel_registerName("alloc"));
  id client = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
    clientAlloc, sel_registerName("initWithDevice:error:"), device, &err);
  if (!client) {
    StrErr(errBuf, errLen, err.localizedDescription ?: @"initWithDevice failed");
    return NO;
  }

  return HIDClientSendIndigoTouch(client, xRatio, yRatio, phase, errBuf, errLen);
}

void *IOSEmbedHIDSessionOpen(NSString *udid, char *errBuf, size_t errLen) {
  if (!IOSEmbedLoadSimulatorFrameworks()) {
    StrErr(errBuf, errLen, @"Failed to load CoreSimulator / SimulatorKit");
    return NULL;
  }
  NSError *err = nil;
  id device = BootedSimDevice(udid, &err);
  if (!device) {
    StrErr(errBuf, errLen, err.localizedDescription);
    return NULL;
  }
  Class clientClass = SimDeviceLegacyHIDClientClass();
  if (!clientClass) {
    StrErr(errBuf, errLen, @"SimDeviceLegacyHIDClient class not found");
    return NULL;
  }
  id clientAlloc = ((id (*)(Class, SEL))objc_msgSend)(clientClass, sel_registerName("alloc"));
  id client = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
    clientAlloc, sel_registerName("initWithDevice:error:"), device, &err);
  if (!client) {
    StrErr(errBuf, errLen, err.localizedDescription ?: @"initWithDevice failed");
    return NULL;
  }
  return (__bridge_retained void *)client;
}

BOOL IOSEmbedHIDSessionSend(void *session, double xRatio, double yRatio, int phase, char *errBuf, size_t errLen) {
  if (!session) {
    StrErr(errBuf, errLen, @"session is null");
    return NO;
  }
  id client = (__bridge id)session;
  return HIDClientSendIndigoTouch(client, xRatio, yRatio, phase, errBuf, errLen);
}

void IOSEmbedHIDSessionClose(void *session) {
  if (!session) {
    return;
  }
  id client = (__bridge_transfer id)session;
  (void)client;
}
