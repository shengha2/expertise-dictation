// Renders the FnDictate app icon (rounded gradient tile with a microphone glyph)
// into an .iconset and converts it to AppIcon.icns.
//   clang -fobjc-arc -framework AppKit scripts/make-icon.m -o build/make-icon && build/make-icon Resources/AppIcon.icns
#import <AppKit/AppKit.h>

static NSImage *renderIcon(CGFloat size) {
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
    [img lockFocus];
    CGFloat inset = size * 0.05;
    NSRect r = NSMakeRect(inset, inset, size - 2 * inset, size - 2 * inset);
    NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:r xRadius:size * 0.22 yRadius:size * 0.22];
    NSGradient *g = [[NSGradient alloc] initWithColorsAndLocations:
                     [NSColor colorWithSRGBRed:0.00 green:0.62 blue:0.53 alpha:1], 0.0,
                     [NSColor colorWithSRGBRed:0.02 green:0.36 blue:0.31 alpha:1], 1.0, nil];
    [g drawInBezierPath:tile angle:-90];
    // subtle inner highlight
    NSBezierPath *hl = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, size * 0.012, size * 0.012) xRadius:size * 0.21 yRadius:size * 0.21];
    [[NSColor colorWithWhite:1 alpha:0.10] setStroke];
    hl.lineWidth = size * 0.012;
    [hl stroke];
    // microphone glyph
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:size * 0.52 weight:NSFontWeightSemibold];
    NSImage *mic = [[NSImage imageWithSystemSymbolName:@"mic.fill" accessibilityDescription:nil] imageWithSymbolConfiguration:cfg];
    NSImage *white = [NSImage imageWithSize:mic.size flipped:NO drawingHandler:^BOOL(NSRect dst) {
        [mic drawInRect:dst];
        [[NSColor whiteColor] set];
        NSRectFillUsingOperation(dst, NSCompositingOperationSourceAtop);
        return YES;
    }];
    NSSize ms = white.size;
    CGFloat scale = (size * 0.50) / MAX(ms.width, ms.height);
    NSRect mr = NSMakeRect((size - ms.width * scale) / 2, (size - ms.height * scale) / 2 - size * 0.01, ms.width * scale, ms.height * scale);
    NSShadow *sh = [NSShadow new];
    sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.25];
    sh.shadowBlurRadius = size * 0.02;
    sh.shadowOffset = NSMakeSize(0, -size * 0.01);
    [sh set];
    [white drawInRect:mr fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    // small "fn" tag at the bottom right
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:size * 0.13 weight:NSFontWeightBold],
                            NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.92]};
    NSAttributedString *tag = [[NSAttributedString alloc] initWithString:@"fn" attributes:attrs];
    NSSize ts = tag.size;
    NSRect tagRect = NSMakeRect(r.origin.x + r.size.width - ts.width - size * 0.14, r.origin.y + size * 0.10, ts.width + size * 0.06, ts.height + size * 0.02);
    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:tagRect xRadius:tagRect.size.height / 2 yRadius:tagRect.size.height / 2];
    [[NSColor colorWithWhite:0 alpha:0.28] setFill];
    [pill fill];
    [tag drawAtPoint:NSMakePoint(tagRect.origin.x + size * 0.03, tagRect.origin.y + size * 0.01)];
    [img unlockFocus];
    return img;
}

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
        NSImage *master = renderIcon(1024);
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
