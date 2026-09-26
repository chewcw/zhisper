const std = @import("std");
const types = @import("tray_types.zig");
const zstbi = @import("zstbi");

const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xatom.h");
    @cInclude("X11/Xutil.h");
});

const icon_size: c_int = 22;
const xembed_version: c_long = 1;
const system_tray_request_dock: c_long = 0;
const xembed_info_flags_mapped: c_long = 1;

const TrayError = error{
    NoDisplay,
    NoTrayManager,
    UnsupportedVisual,
    ImageDecodeFailed,
    NotSetup,
    XError,
};

var display: ?*c.Display = null;
var client_window: c.Window = 0;
var client_colormap: c.Colormap = 0;
var client_visual: ?*c.Visual = null;
var client_depth: c_int = 0;
var selection_atom: c.Atom = 0;
var manager_owner: c.Window = 0;
var state_pixmaps: [3]c.Pixmap = .{ 0, 0, 0 };
var current_state: types.State = .idle;
var zstbi_ready = false;

fn stateIndex(state: types.State) usize {
    return @intFromEnum(state);
}

fn cleanupResources() void {
    if (display) |d| {
        if (client_window != 0) {
            _ = c.XUnmapWindow(d, client_window);
            _ = c.XDestroyWindow(d, client_window);
            client_window = 0;
        }
        for (state_pixmaps) |pixmap| {
            if (pixmap != 0) _ = c.XFreePixmap(d, pixmap);
        }
        state_pixmaps = .{ 0, 0, 0 };
        if (client_colormap != 0) {
            _ = c.XFreeColormap(d, client_colormap);
            client_colormap = 0;
        }
        _ = c.XCloseDisplay(d);
    }
    display = null;
    client_visual = null;
    client_depth = 0;
    selection_atom = 0;
    manager_owner = 0;
    current_state = .idle;
    if (zstbi_ready) {
        zstbi.deinit();
        zstbi_ready = false;
    }
}

fn createStatePixmap(d: *c.Display, drawable: c.Drawable, visual: *c.Visual, depth: c_int, png: []const u8) TrayError!c.Pixmap {
    var image = zstbi.Image.loadFromMemory(png, 4) catch return error.ImageDecodeFailed;
    defer image.deinit();

    if (image.width != icon_size or image.height != icon_size or image.num_components != 4) {
        return error.ImageDecodeFailed;
    }

    var pixels: [icon_size * icon_size]u32 = undefined;
    for (&pixels, 0..) |*pixel, i| {
        const r: u32 = image.data[i * 4 + 0];
        const g: u32 = image.data[i * 4 + 1];
        const b: u32 = image.data[i * 4 + 2];
        const a: u32 = image.data[i * 4 + 3];
        // X11's usual 32-bit TrueColor layout is BGRA in memory, ARGB
        // numerically. Alpha is required by the tray manager to composite
        // the icon without a black square around it.
        pixel.* = (a << 24) | (r << 16) | (g << 8) | b;
    }

    const ximage = c.XCreateImage(
        d,
        visual,
        @intCast(depth),
        c.ZPixmap,
        0,
        @ptrCast(&pixels),
        icon_size,
        icon_size,
        32,
        icon_size * 4,
    ) orelse return error.ImageDecodeFailed;
    // XCreateImage does not own the pixel buffer. Clear the pointer before
    // releasing the XImage wrapper so XDestroyImage does not free stack data.
    defer if (ximage.*.f.destroy_image) |destroy_image| {
        ximage.*.data = null;
        _ = destroy_image(ximage);
    };

    const pixmap = c.XCreatePixmap(d, drawable, icon_size, icon_size, @intCast(depth));
    if (pixmap == 0) return error.XError;
    const gc = c.XCreateGC(d, pixmap, 0, null) orelse {
        _ = c.XFreePixmap(d, pixmap);
        return error.XError;
    };
    defer _ = c.XFreeGC(d, gc);
    // XPutImage returns 0 on both success and failure in libX11; the request
    // is flushed and server-side errors are reported through Xlib's handler.
    _ = c.XPutImage(d, pixmap, gc, ximage, 0, 0, 0, 0, icon_size, icon_size);
    _ = c.XSync(d, 0);
    return pixmap;
}

fn embedWithOwner(owner: c.Window) void {
    const d = display orelse return;
    const opcode = c.XInternAtom(d, "_NET_SYSTEM_TRAY_OPCODE", 0);
    var message: c.XClientMessageEvent = std.mem.zeroes(c.XClientMessageEvent);
    message.type = c.ClientMessage;
    message.send_event = 1;
    message.display = d;
    message.window = owner;
    message.message_type = opcode;
    message.format = 32;
    // _NET_SYSTEM_TRAY_OPCODE is (timestamp, request-dock, client-window).
    // i3bar reparents the client only when this exact layout is used.
    message.data.l[0] = 0;
    message.data.l[1] = system_tray_request_dock;
    message.data.l[2] = @intCast(client_window);
    _ = c.XSendEvent(d, owner, 0, c.NoEventMask, @ptrCast(&message));
    _ = c.XFlush(d);
}

pub fn setup(io: std.Io) !void {
    if (display != null) return;

    const d = c.XOpenDisplay(null) orelse return error.NoDisplay;
    display = d;
    errdefer cleanupResources();

    const screen = c.XDefaultScreen(d);
    const root = c.XRootWindow(d, screen);

    var selection_name_buf: [64]u8 = undefined;
    const selection_name = std.fmt.bufPrint(&selection_name_buf, "_NET_SYSTEM_TRAY_S{d}", .{screen}) catch return error.NoTrayManager;
    selection_name_buf[selection_name.len] = 0;
    selection_atom = c.XInternAtom(d, @ptrCast(&selection_name_buf), 0);
    manager_owner = c.XGetSelectionOwner(d, selection_atom);
    if (manager_owner == 0) return error.NoTrayManager;

    // The tray protocol publishes the visual that tray clients must use.
    // i3bar advertises its 24-bit bar visual here; using an arbitrary 32-bit
    // ARGB visual makes the embedded window valid but invisible in i3bar.
    var manager_attributes: c.XWindowAttributes = undefined;
    if (c.XGetWindowAttributes(d, manager_owner, &manager_attributes) == 0) {
        return error.UnsupportedVisual;
    }
    client_visual = manager_attributes.visual;
    client_depth = manager_attributes.depth;
    client_colormap = c.XCreateColormap(d, root, client_visual.?, c.AllocNone);
    if (client_colormap == 0) return error.UnsupportedVisual;

    var attributes: c.XSetWindowAttributes = std.mem.zeroes(c.XSetWindowAttributes);
    attributes.colormap = client_colormap;
    attributes.border_pixel = 0;
    attributes.override_redirect = 1;
    client_window = c.XCreateWindow(
        d,
        root,
        0,
        0,
        icon_size,
        icon_size,
        0,
        client_depth,
        c.InputOutput,
        client_visual.?,
        c.CWColormap | c.CWBorderPixel | c.CWOverrideRedirect,
        &attributes,
    );
    if (client_window == 0) return error.XError;

    const xembed_info_atom = c.XInternAtom(d, "_XEMBED_INFO", 0);
    const xembed_info = [2]c_long{ xembed_version, xembed_info_flags_mapped };
    _ = c.XChangeProperty(
        d,
        client_window,
        xembed_info_atom,
        c.XA_CARDINAL,
        32,
        c.PropModeReplace,
        @ptrCast(&xembed_info),
        2,
    );

    zstbi.init(io, std.heap.page_allocator);
    zstbi_ready = true;
    const assets = [_][]const u8{ types.idle_png, types.recording_png, types.working_png };
    for (assets, 0..) |png, i| {
        state_pixmaps[i] = try createStatePixmap(d, client_window, client_visual.?, client_depth, png);
    }

    _ = c.XMapWindow(d, client_window);
    embedWithOwner(manager_owner);
    setState(io, .idle) catch {};
    _ = c.XSync(d, 0);
}

pub fn setState(_: std.Io, state: types.State) !void {
    const d = display orelse return error.NotSetup;
    if (client_window == 0) return error.NotSetup;
    const pixmap = state_pixmaps[stateIndex(state)];
    if (pixmap == 0) return error.NotSetup;
    if (c.XSetWindowBackgroundPixmap(d, client_window, pixmap) == 0) return error.XError;
    _ = c.XClearWindow(d, client_window);
    _ = c.XFlush(d);
    current_state = state;
}

pub fn poll(_: std.Io) void {
    const d = display orelse return;
    while (c.XPending(d) != 0) {
        var event: c.XEvent = undefined;
        _ = c.XNextEvent(d, &event);
    }

    // i3bar and other tray managers can restart without the daemon. Their
    // selection owner changes, so re-send XEMBED to the new owner instead of
    // allocating another client window.
    const owner = c.XGetSelectionOwner(d, selection_atom);
    if (owner != 0 and owner != manager_owner) {
        manager_owner = owner;
        embedWithOwner(owner);
    }
}

pub fn destroy(_: std.Io) void {
    cleanupResources();
}
