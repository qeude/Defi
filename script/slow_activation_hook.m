// Injected into a tear-probe fixture (DYLD_INSERT_LIBRARIES): blocks the main thread for
// DEFI_ACTIVATION_BUSY_MS after the app becomes active or a window becomes main, like Mail doing activation work.
#import <AppKit/AppKit.h>
#include <stdlib.h>
#include <unistd.h>

__attribute__((constructor)) static void install(void) {
  const char *value = getenv("DEFI_ACTIVATION_BUSY_MS");
  useconds_t busy = value ? (useconds_t)(atof(value) * 1000) : 0;
  if (busy == 0) return;
  // queue:nil runs inside the posting call, so the Accessibility request that caused it waits too.
  for (NSNotificationName name in @[ NSApplicationDidBecomeActiveNotification, NSWindowDidBecomeMainNotification ])
    [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *note) { usleep(busy); }];
}
