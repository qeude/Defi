// Test-only: holds one extra virtual display in the VM until killed, for the two-display tests.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)w height:(NSUInteger)h refreshRate:(double)r;
@end
@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (retain, nonatomic) NSArray *modes;
@end
@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide, maxPixelsHigh, vendorID, productID, serialNum;
@property (nonatomic) CGSize sizeInMillimeters;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)d;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)s;
@property (readonly, nonatomic) unsigned int displayID;
@end
int main(void) { @autoreleasepool {
  [NSApplication sharedApplication];
  CGVirtualDisplayDescriptor *d = [CGVirtualDisplayDescriptor new];
  d.queue = dispatch_get_main_queue(); d.name = @"Defi Test Display";
  d.maxPixelsWide = 1280; d.maxPixelsHigh = 800; d.sizeInMillimeters = CGSizeMake(340, 210);
  d.vendorID = 0xDEF1; d.productID = 1; d.serialNum = 1;
  CGVirtualDisplay *v = [[CGVirtualDisplay alloc] initWithDescriptor:d];
  CGVirtualDisplaySettings *s = [CGVirtualDisplaySettings new];
  s.hiDPI = 0; s.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:1280 height:800 refreshRate:60]];
  if (![v applySettings:s]) return 1;
  [[NSRunLoop mainRunLoop] run];
} return 0; }
