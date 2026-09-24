// Posts a synthetic Fn (Globe) key press: flagsChanged down, hold, flagsChanged up.
// Used to exercise the event tap without touching the keyboard.
//   clang -framework ApplicationServices scripts/fnpress.m -o build/fnpress && build/fnpress 2.0
#import <ApplicationServices/ApplicationServices.h>
#import <unistd.h>
#import <stdlib.h>
int main(int argc, char **argv) {
    double hold = argc > 1 ? atof(argv[1]) : 1.5;
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    CGEventRef down = CGEventCreate(src);
    CGEventSetType(down, kCGEventFlagsChanged);
    CGEventSetIntegerValueField(down, kCGKeyboardEventKeycode, 63);
    CGEventSetFlags(down, kCGEventFlagMaskSecondaryFn);
    CGEventPost(kCGSessionEventTap, down);
    usleep((useconds_t)(hold * 1000000));
    CGEventRef up = CGEventCreate(src);
    CGEventSetType(up, kCGEventFlagsChanged);
    CGEventSetIntegerValueField(up, kCGKeyboardEventKeycode, 63);
    CGEventSetFlags(up, 0);
    CGEventPost(kCGSessionEventTap, up);
    CFRelease(down); CFRelease(up); CFRelease(src);
    return 0;
}
