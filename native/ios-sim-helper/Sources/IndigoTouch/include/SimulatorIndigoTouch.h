#import <Foundation/Foundation.h>

/// Loads CoreSimulator + SimulatorKit from standard install locations. Call once before other APIs.
FOUNDATION_EXPORT BOOL IOSEmbedLoadSimulatorFrameworks(void);

/// `direction`: 1 = touch down, 2 = touch up (idb FBSimulatorHIDDirection values).
/// `xRatio` / `yRatio`: 0…1 from top-left of the simulated display (Indigo convention).
/// `udid`: optional; if nil, uses the first booted device.
FOUNDATION_EXPORT BOOL IOSEmbedHIDSendTouch(
  NSString *_Nullable udid,
  double xRatio,
  double yRatio,
  int direction,
  char *_Nonnull errBuf,
  size_t errLen);
