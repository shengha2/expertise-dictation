// Mechanically resizes the approved Expertise Typer master artwork into the
// standard macOS ICNS sizes. No styling or generated artwork is changed here.
#import <AppKit/AppKit.h>

static void writePNG(NSImage *img, CGFloat px, NSString *path) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:px pixelsHigh:px bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = NSMakeSize(px, px);
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
    [[NSColor clearColor] set];
    NSRectFill(NSMakeRect(0, 0, px, px));
    [img drawInRect:NSMakeRect(0, 0, px, px) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *out = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"AppIcon.icns";
        NSString *iconset = [[out stringByDeletingPathExtension] stringByAppendingPathExtension:@"iconset"];
        [[NSFileManager defaultManager] removeItemAtPath:iconset error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:iconset withIntermediateDirectories:YES attributes:nil error:nil];
        if (argc < 3) { fprintf(stderr, "usage: make-icon output.icns master.png\n"); return 2; }
        NSImage *master = [[NSImage alloc] initWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]];
        if (!master || master.size.width <= 0 || master.size.height <= 0) { fprintf(stderr, "invalid master artwork\n"); return 2; }
        int sizes[] = {16, 32, 128, 256, 512};
        for (int i = 0; i < 5; i++) {
            int s = sizes[i];
            writePNG(master, s, [iconset stringByAppendingPathComponent:[NSString stringWithFormat:@"icon_%dx%d.png", s, s]]);
            writePNG(master, s * 2, [iconset stringByAppendingPathComponent:[NSString stringWithFormat:@"icon_%dx%d@2x.png", s, s]]);
        }
        NSTask *t = [NSTask new];
        t.launchPath = @"/usr/bin/iconutil";
        t.arguments = @[@"-c", @"icns", iconset, @"-o", out];
        [t launch]; [t waitUntilExit];
        [[NSFileManager defaultManager] removeItemAtPath:iconset error:nil];
        printf("wrote %s (status %d)\n", out.UTF8String, t.terminationStatus);
        return t.terminationStatus;
    }
}
