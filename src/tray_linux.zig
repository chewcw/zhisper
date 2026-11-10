const std = @import("std");
const types = @import("tray_types.zig");
const zstbi = @import("zstbi");
const tray_menu = @import("tray_menu.zig");

const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xatom.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/extensions/shape.h");
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
var state_masks: [3]c.Pixmap = .{ 0, 0, 0 };
var current_state: types.State = .idle;
var zstbi_ready = false;

const xk_escape: c.KeySym = 0xFF1B;
const menu_bg: c_ulong = 0x2b2b2b;
const menu_border: c_ulong = 0x505050;

var host: ?types.MenuHost = null;
var menu_font: ?*c.XFontStruct = null;
var menu_window: c.Window = 0;
var menu_gc: c.GC = @ptrFromInt(0);

fn stateIndex(state: types.State) usize {
    return @intFromEnum(state);
}

fn cleanupResources() void {
    if (menu_font) |font| {
        if (display) |d| _ = c.XFreeFont(d, font);
        menu_font = null;
    }
    host = null;
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
        for (state_masks) |mask| {
            if (mask != 0) _ = c.XFreePixmap(d, mask);
        }
        state_masks = .{ 0, 0, 0 };
        if (client_colormap != 0) {
            _ = c.XUninstallColormap(d, client_colormap);
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

fn createStateMask(d: *c.Display, drawable: c.Drawable, png: []const u8) TrayError!c.Pixmap {
    var image = zstbi.Image.loadFromMemory(png, 4) catch return error.ImageDecodeFailed;
    defer image.deinit();

    var mask_data: [((icon_size + 7) / 8) * icon_size]u8 = [_]u8{0} ** (((icon_size + 7) / 8) * icon_size);
    for (0..icon_size) |y| {
        for (0..icon_size) |x| {
            const alpha = image.data[(y * icon_size + x) * 4 + 3];
            if (alpha != 0) {
                mask_data[y * ((icon_size + 7) / 8) + x / 8] |= @as(u8, 1) << @intCast(x % 8);
            }
        }
    }
    const mask = c.XCreateBitmapFromData(d, drawable, @ptrCast(&mask_data), icon_size, icon_size);
    if (mask == 0) return error.XError;
    return mask;
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

fn clientIsEmbedded() bool {
    const d = display orelse return false;
    var root: c.Window = 0;
    var parent: c.Window = 0;
    var children: [*c]c.Window = null;
    var child_count: c_uint = 0;
    if (c.XQueryTree(d, client_window, &root, &parent, &children, &child_count) == 0) return false;
    if (children != null) _ = c.XFree(@ptrCast(children));
    return parent != root;
}

pub fn setup(io: std.Io, menu_host: types.MenuHost) !void {
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
    _ = c.XInstallColormap(d, client_colormap);

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
        state_masks[i] = try createStateMask(d, client_window, png);
    }

    _ = c.XMapWindow(d, client_window);
    _ = c.XSelectInput(d, client_window, c.ButtonPressMask);
    host = menu_host;
    // A missing core font disables only the menu: the icon must keep working.
    menu_font = c.XLoadQueryFont(d, "fixed");
    if (menu_font == null) {
        std.log.scoped(.tray).debug("core font \"fixed\" missing; right-click menu disabled", .{});
    }
    embedWithOwner(manager_owner);
    setState(io, .idle) catch {};
    _ = c.XSync(d, 0);
}

pub fn setState(_: std.Io, state: types.State) !void {
    const d = display orelse return error.NotSetup;
    if (client_window == 0) return error.NotSetup;
    const pixmap = state_pixmaps[stateIndex(state)];
    const mask = state_masks[stateIndex(state)];
    if (pixmap == 0 or mask == 0) return error.NotSetup;
    c.XShapeCombineMask(d, client_window, c.ShapeBounding, 0, 0, mask, c.ShapeSet);
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
        if (event.type == c.ButtonPress and event.xbutton.button == 3) openMenu(d);
    }

    // i3bar and other tray managers can restart without the daemon. Their
    // selection owner changes, so re-send XEMBED to the new owner instead of
    // allocating another client window.
    const owner = c.XGetSelectionOwner(d, selection_atom);
    if (owner != 0) {
        if (owner != manager_owner) {
            manager_owner = owner;
            embedWithOwner(owner);
        } else if (!clientIsEmbedded()) {
            // i3bar reload can keep the same selection window while
            // returning the client to the root window.
            embedWithOwner(owner);
        }
    }
}

fn openMenu(d: *c.Display) void {
    const menu_host = host orelse return;
    if (menu_font == null) return;

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const menu = tray_menu.rootMenu(arena_state.allocator(), current_state, menu_host.snapshot()) catch |err| {
        std.log.scoped(.tray).debug("menu build failed: {s}", .{@errorName(err)});
        return;
    };

    const screen = c.XDefaultScreen(d);
    const root = c.XRootWindow(d, screen);
    const advance: i32 = menu_font.?.max_bounds.width;
    const w = tray_menu.width(menu, advance);
    const h = tray_menu.height(menu);

    var root_return: c.Window = 0;
    var child: c.Window = 0;
    var px: c_int = 0;
    var py: c_int = 0;
    var win_x: c_int = 0;
    var win_y: c_int = 0;
    var mask: c_uint = 0;
    if (c.XQueryPointer(d, root, &root_return, &child, &px, &py, &win_x, &win_y, &mask) == 0) return;
    const pos = tray_menu.clampPos(px, py, w, h, c.XDisplayWidth(d, screen), c.XDisplayHeight(d, screen));

    menu_window = c.XCreateSimpleWindow(d, root, pos.x, pos.y, @intCast(w), @intCast(h), 1, menu_border, menu_bg);
    if (menu_window == 0) return;
    var attributes: c.XSetWindowAttributes = std.mem.zeroes(c.XSetWindowAttributes);
    attributes.override_redirect = 1;
    _ = c.XChangeWindowAttributes(d, menu_window, c.CWOverrideRedirect, &attributes);
    _ = c.XSelectInput(d, menu_window, c.ExposureMask | c.ButtonPressMask | c.ButtonReleaseMask | c.PointerMotionMask);
    menu_gc = c.XCreateGC(d, menu_window, 0, null);
    if (@intFromPtr(menu_gc) == 0) {
        closeMenuWindow(d);
        return;
    }
    _ = c.XSetFont(d, menu_gc, menu_font.?.fid);
    _ = c.XMapRaised(d, menu_window);

    const grab_mask = c.ButtonPressMask | c.ButtonReleaseMask | c.PointerMotionMask;
    if (c.XGrabPointer(d, menu_window, 0, grab_mask, c.GrabModeAsync, c.GrabModeAsync, 0, 0, c.CurrentTime) != c.GrabSuccess) {
        std.log.scoped(.tray).debug("menu pointer grab refused", .{});
        closeMenuWindow(d);
        return;
    }
    const keyboard_grabbed = c.XGrabKeyboard(d, menu_window, 0, c.GrabModeAsync, c.GrabModeAsync, c.CurrentTime) == c.GrabSuccess;

    runMenuLoop(d);

    if (keyboard_grabbed) _ = c.XUngrabKeyboard(d, c.CurrentTime);
    _ = c.XUngrabPointer(d, c.CurrentTime);
    closeMenuWindow(d);
}

fn closeMenuWindow(d: *c.Display) void {
    if (@intFromPtr(menu_gc) != 0) {
        _ = c.XFreeGC(d, menu_gc);
        menu_gc = @ptrFromInt(0);
    }
    if (menu_window != 0) {
        _ = c.XDestroyWindow(d, menu_window);
        menu_window = 0;
    }
}

fn runMenuLoop(d: *c.Display) void {
    while (true) {
        var event: c.XEvent = undefined;
        _ = c.XNextEvent(d, &event);
        switch (event.type) {
            c.Expose => _ = c.XClearWindow(d, menu_window),
            c.ButtonPress => return,
            c.KeyPress => if (c.XLookupKeysym(&event.xkey, 0) == xk_escape) return,
            else => {},
        }
    }
}

pub fn destroy(_: std.Io) void {
    cleanupResources();
}
