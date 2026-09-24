// Tiny UI driver for testing: posts real mouse clicks and key presses.
//   uiclick click X Y          left click at screen point (top-left origin, points)
//   uiclick move X Y           move the cursor
//   uiclick key KEYCODE [cmd|shift|alt|ctrl ...]
#import <ApplicationServices/ApplicationServices.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: uiclick click|move X Y | key CODE [mods]\n"); return 1; }
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    if (!strcmp(argv[1], "click") || !strcmp(argv[1], "move")) {
        CGPoint p = CGPointMake(atof(argv[2]), atof(argv[3]));
        CGEventRef mv = CGEventCreateMouseEvent(src, kCGEventMouseMoved, p, kCGMouseButtonLeft);
        CGEventPost(kCGHIDEventTap, mv); CFRelease(mv);
        usleep(60000);
        if (!strcmp(argv[1], "click")) {
            CGEventRef d = CGEventCreateMouseEvent(src, kCGEventLeftMouseDown, p, kCGMouseButtonLeft);
            CGEventRef u = CGEventCreateMouseEvent(src, kCGEventLeftMouseUp, p, kCGMouseButtonLeft);
            CGEventPost(kCGHIDEventTap, d); usleep(40000); CGEventPost(kCGHIDEventTap, u);
            CFRelease(d); CFRelease(u);
        }
    } else if (!strcmp(argv[1], "key")) {
        CGKeyCode code = (CGKeyCode)atoi(argv[2]);
        CGEventFlags flags = 0;
        for (int i = 3; i < argc; i++) {
            if (!strcmp(argv[i], "cmd")) flags |= kCGEventFlagMaskCommand;
            if (!strcmp(argv[i], "shift")) flags |= kCGEventFlagMaskShift;
            if (!strcmp(argv[i], "alt")) flags |= kCGEventFlagMaskAlternate;
            if (!strcmp(argv[i], "ctrl")) flags |= kCGEventFlagMaskControl;
        }
        CGEventRef d = CGEventCreateKeyboardEvent(src, code, true);
        CGEventRef u = CGEventCreateKeyboardEvent(src, code, false);
        CGEventSetFlags(d, flags); CGEventSetFlags(u, flags);
        CGEventPost(kCGHIDEventTap, d); usleep(30000); CGEventPost(kCGHIDEventTap, u);
        CFRelease(d); CFRelease(u);
    }
    CFRelease(src);
    return 0;
}
