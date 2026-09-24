// Generate and validate Finder background bookmarks through Foundation, without UI.
#import <Foundation/Foundation.h>

static BOOL validate(NSData *data, NSURL *expected, NSError **error) {
    BOOL stale = NO;
    NSURL *resolved = [NSURL URLByResolvingBookmarkData:data
        options:NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithoutMounting
        relativeToURL:nil bookmarkDataIsStale:&stale error:error];
    if (!resolved) return NO;
    NSString *actual = resolved.URLByResolvingSymlinksInPath.standardizedURL.path;
    NSString *wanted = expected.URLByResolvingSymlinksInPath.standardizedURL.path;
    return [actual isEqualToString:wanted] &&
        [[NSFileManager defaultManager] fileExistsAtPath:actual];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) {
            fprintf(stderr, "usage: native-background-bookmark create BACKGROUND OUTPUT | validate BOOKMARK BACKGROUND\n");
            return 2;
        }
        NSString *mode = [NSString stringWithUTF8String:argv[1]];
        NSURL *input = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
        NSURL *other = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[3]]];
        NSError *error = nil;
        NSData *data = nil;
        if ([mode isEqualToString:@"create"]) {
            data = [input bookmarkDataWithOptions:NSURLBookmarkCreationMinimalBookmark |
                NSURLBookmarkCreationWithoutImplicitSecurityScope
                includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
            if (!data || !validate(data, input, &error) ||
                ![data writeToURL:other options:NSDataWritingAtomic error:&error]) {
                fprintf(stderr, "Could not create a resolvable background bookmark: %s\n",
                    error.localizedDescription.UTF8String ?: "unexpected bookmark target");
                return 1;
            }
        } else if ([mode isEqualToString:@"validate"]) {
            data = [NSData dataWithContentsOfURL:input options:0 error:&error];
            if (!data || !validate(data, other, &error)) {
                fprintf(stderr, "Background bookmark does not resolve to the expected file: %s\n",
                    error.localizedDescription.UTF8String ?: "unexpected bookmark target");
                return 1;
            }
            puts("Native background bookmark resolves to the expected image.");
        } else {
            fprintf(stderr, "unknown bookmark operation\n");
            return 2;
        }
        return 0;
    }
}
