#import <Foundation/Foundation.h>

/// Loads CoreSimulator + SimulatorKit from standard install locations. Call once before other APIs.
FOUNDATION_EXPORT BOOL IOSEmbedLoadSimulatorFrameworks(void);

/// `phase`: 0 = drag/move update (Indigo mouse event type passed through to SimulatorKit),
/// 1 = touch down, 2 = touch up (idb-style directions for down/up).
/// `xRatio` / `yRatio`: 0…1 from top-left of the simulated display (Indigo convention).
/// `udid`: optional; if nil, uses the first booted device.
FOUNDATION_EXPORT BOOL IOSEmbedHIDSendTouch(
  NSString *_Nullable udid,
  double xRatio,
  double yRatio,
  int phase,
  char *_Nonnull errBuf,
  size_t errLen);

/// Logical main-screen size in points for the booted device (`SimDeviceType mainScreenSize`).
/// Returns NO if no booted device, missing type, or zero size.
FOUNDATION_EXPORT BOOL IOSEmbedBootedMainScreenLogicalSize(
  NSString *_Nullable udid,
  double *_Nonnull outWidth,
  double *_Nonnull outHeight,
  char *_Nonnull errBuf,
  size_t errLen);

/// Reuses one `SimDeviceLegacyHIDClient` for down / move / up so drags work across events.
/// Returns an opaque pointer to release with `IOSEmbedHIDSessionClose`, or NULL on failure.
FOUNDATION_EXPORT void *_Nullable IOSEmbedHIDSessionOpen(
  NSString *_Nullable udid,
  char *_Nonnull errBuf,
  size_t errLen);

FOUNDATION_EXPORT BOOL IOSEmbedHIDSessionSend(
  void *_Nonnull session,
  double xRatio,
  double yRatio,
  int phase,
  char *_Nonnull errBuf,
  size_t errLen);

FOUNDATION_EXPORT void IOSEmbedHIDSessionClose(void *_Nullable session);
