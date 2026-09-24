// Deterministic native typography and layout for the Finder installer background.
// The application and Applications icons are real Finder items, not pictures.
#import <AppKit/AppKit.h>

static void text(NSString *value, CGFloat size, CGFloat weight, NSColor *color, NSRect rect) {
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    [value drawInRect:rect withAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:size weight:weight],
        NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: paragraph}];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2 || argc > 3) { fprintf(stderr, "usage: render-installer background.png [2]\n"); return 2; }
        NSInteger scale = argc == 3 ? atoi(argv[2]) : 1;
        if (scale != 1 && scale != 2) return 2;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
            pixelsWide:720 * scale pixelsHigh:540 * scale bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
            isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        rep.size = NSMakeSize(720, 540);
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
        NSColor *cream = [NSColor colorWithSRGBRed:0.974 green:0.970 blue:0.955 alpha:1];
        NSColor *ink = [NSColor colorWithSRGBRed:0.08 green:0.17 blue:0.15 alpha:1];
        NSColor *muted = [NSColor colorWithSRGBRed:0.36 green:0.43 blue:0.41 alpha:1];
        [cream setFill]; NSRectFill(NSMakeRect(0, 0, 720, 540));
        text(@"EXPERTISE TYPER", 12, NSFontWeightSemibold, muted, NSMakeRect(40, 487, 640, 22));
        text(@"Speak naturally. Write clearly.", 31, NSFontWeightSemibold, ink, NSMakeRect(24, 430, 672, 44));
        text(@"Your voice, ready for any text field.", 15, NSFontWeightRegular, muted, NSMakeRect(40, 403, 640, 26));
        // Finder positions the two live icons at (220, 220) and (500, 220).
        NSBezierPath *arrow = [NSBezierPath bezierPath];
        [arrow moveToPoint:NSMakePoint(324, 320)]; [arrow lineToPoint:NSMakePoint(396, 320)];
        [arrow moveToPoint:NSMakePoint(387, 329)]; [arrow lineToPoint:NSMakePoint(396, 320)];
        [arrow lineToPoint:NSMakePoint(387, 311)]; arrow.lineWidth = 2;
        arrow.lineCapStyle = NSLineCapStyleRound; arrow.lineJoinStyle = NSLineJoinStyleRound;
        [[NSColor colorWithSRGBRed:0.40 green:0.63 blue:0.57 alpha:1] setStroke]; [arrow stroke];
        text(@"Drag Expertise Typer to Applications", 17, NSFontWeightMedium, ink, NSMakeRect(40, 195, 640, 28));
        text(@"Then open the app and follow the short setup.", 13, NSFontWeightRegular, muted, NSMakeRect(40, 167, 640, 24));
        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (![png writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES]) return 1;
        return 0;
    }
}
