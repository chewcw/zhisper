#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#include <stddef.h>
#include <stdlib.h>

typedef struct ZhisperTray ZhisperTray;

struct ZhisperTray {
    NSStatusItem *item;
    NSImage *images[3];
};

void zhisper_tray_destroy(ZhisperTray *tray);

static NSString *const tooltips[3] = {
    @"zhisper: idle",
    @"zhisper: recording",
    @"zhisper: processing",
};

static NSImage *image_from_bytes(const unsigned char *bytes, size_t length) {
    NSData *data = [NSData dataWithBytes:bytes length:length];
    NSImage *image = [[NSImage alloc] initWithData:data];
    if (image == nil) return nil;
    image.size = NSMakeSize(22.0, 22.0);
    // The generated PNGs carry state colors; do not let AppKit turn them into
    // a monochrome template image.
    image.template = NO;
    return image;
}

ZhisperTray *zhisper_tray_create(
    const unsigned char *idle_png,
    size_t idle_len,
    const unsigned char *recording_png,
    size_t recording_len,
    const unsigned char *working_png,
    size_t working_len) {
    @autoreleasepool {
        ZhisperTray *tray = (ZhisperTray *)calloc(1, sizeof(ZhisperTray));
        if (tray == NULL) return NULL;

        tray->images[0] = image_from_bytes(idle_png, idle_len);
        tray->images[1] = image_from_bytes(recording_png, recording_len);
        tray->images[2] = image_from_bytes(working_png, working_len);
        if (tray->images[0] == nil || tray->images[1] == nil || tray->images[2] == nil) {
            zhisper_tray_destroy(tray);
            return NULL;
        }

        tray->item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
        if (tray->item == nil) {
            zhisper_tray_destroy(tray);
            return NULL;
        }
        tray->item.button.image = tray->images[0];
        tray->item.button.toolTip = tooltips[0];
        // v1 is indicator-only: no NSMenu and no click action.
        tray->item.menu = nil;
        return tray;
    }
}

int zhisper_tray_set_state(ZhisperTray *tray, int state) {
    if (tray == nil || state < 0 || state > 2 || tray->item == nil) return 0;
    @autoreleasepool {
        tray->item.button.image = tray->images[state];
        tray->item.button.toolTip = tooltips[state];
    }
    return 1;
}

void zhisper_tray_poll(ZhisperTray *tray) {
    if (tray == nil) return;
    @autoreleasepool {
        // Service Cocoa events without blocking the daemon's 5ms poll loop.
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, false);
    }
}

void zhisper_tray_destroy(ZhisperTray *tray) {
    if (tray == nil) return;
    @autoreleasepool {
        tray->item = nil;
        for (int i = 0; i < 3; i++) tray->images[i] = nil;
        free(tray);
    }
}
