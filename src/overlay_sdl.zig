const std = @import("std");
const types = @import("overlay_types.zig");
const sdl3 = @import("sdl3");

// SDL3 backend (non-test builds only): 240x72 borderless transparent
// always-on-top non-focusable tool window. Idle draws a breathing orb at
// the left; recording/working draw a full-window capsule (pill) with a
// fake waveform / stable spinner. Left-anchored: saved Position is the
// top-left corner, so existing overlay.pos files keep working.
// Main thread only — the worker thread never touches these.
var window: ?sdl3.video.Window = null;
var renderer: ?sdl3.render.Renderer = null;
var tint: types.Rgba = types.stateTint(.idle);
var cur_state: types.State = .idle;
var prev_state: types.State = .idle;
var state_start_ms: u64 = 0;
var last_tick_ms: u64 = 0;
var last_present_ms: ?u64 = null;
var dragging: bool = false;
var drag_moved: bool = false;
var inited: bool = false;

fn redraw() void {
    const r = renderer orelse return;
    r.setDrawBlendMode(.blend) catch return;
    r.setDrawColor(.{ .r = 0, .g = 0, .b = 0, .a = 0 }) catch return;
    r.clear() catch return;
    const t = tint;
    r.setDrawColor(.{ .r = t.r, .g = t.g, .b = t.b, .a = t.a }) catch return;
    // Midpoint scanline fill of the orb (center 36,36, r 36) on the left
    // side of the 240x72 window; the rest stays transparent.
    var y: i32 = -types.ball_radius;
    while (y <= types.ball_radius) : (y += 1) {
        const half: f32 = @sqrt(@as(f32, @floatFromInt(types.ball_radius * types.ball_radius - y * y)));
        const cy: f32 = @as(f32, @floatFromInt(types.ball_radius + y));
        const cx: f32 = @as(f32, @floatFromInt(types.ball_radius));
        r.renderLine(.{ .x = cx - half, .y = cy }, .{ .x = cx + half, .y = cy }) catch return;
    }
    r.present() catch return;
}

/// Scanline orb at (36,36) with float radius (breathing).
fn drawOrb(r: sdl3.render.Renderer, radius_f: f32) void {
    const cx: f32 = 36.0;
    const cy: f32 = 36.0;
    const ri: i32 = @intFromFloat(@round(radius_f));
    var dy: i32 = -ri;
    while (dy <= ri) : (dy += 1) {
        const half: f32 = @sqrt(@as(f32, @floatFromInt(ri * ri - dy * dy)));
        const y: f32 = cy + @as(f32, @floatFromInt(dy));
        r.renderLine(.{ .x = cx - half, .y = y }, .{ .x = cx + half, .y = y }) catch return;
    }
}

/// Stadium fill for the morph: left end circle fixed at cx=36, right end
/// circle slides 36 -> 204 with `morph` (0 = orb, 1 = full capsule).
/// Rows use the circle equation so top/bottom rows inset into round caps.
fn drawStadium(r: sdl3.render.Renderer, morph: f32) void {
    const right_cx: f32 = 36.0 + (204.0 - 36.0) * morph;
    var y: i32 = 0;
    while (y < types.window_h) : (y += 1) {
        const dy: f32 = @as(f32, @floatFromInt(y)) + 0.5 - 36.0;
        if (@abs(dy) > 36.0) continue;
        const half: f32 = @sqrt(36.0 * 36.0 - dy * dy);
        const x0: f32 = 36.0 - half;
        const x1: f32 = right_cx + half;
        r.renderLine(.{ .x = x0, .y = @as(f32, @floatFromInt(y)) }, .{ .x = x1, .y = @as(f32, @floatFromInt(y)) }) catch return;
    }
}

pub fn tick(t_ms: u64) void {
    const r = renderer orelse return;
    if (window == null) return;
    last_tick_ms = t_ms;
    if (last_present_ms) |lp| {
        // 30fps throttle + clock-jump guard (time going backwards = redraw).
        if (t_ms >= lp and t_ms - lp < 33) return;
    }
    last_present_ms = t_ms;
    var elapsed: u64 = 0;
    if (t_ms >= state_start_ms) {
        elapsed = t_ms - state_start_ms;
        if (elapsed > 5000) elapsed = 5000;
    }
    const raw_morph = types.morphProgress(elapsed);
    // Growing into the pill for recording/working; shrinking back to the
    // orb when settling to idle. Once shrunk, latch prev=cur (idle steady).
    var morph = raw_morph;
    var settling_idle = false;
    if (cur_state == .idle and prev_state != .idle) {
        settling_idle = true;
        morph = 1.0 - raw_morph;
        if (raw_morph >= 1.0) {
            prev_state = .idle;
            settling_idle = false;
        }
    }
    r.setDrawBlendMode(.blend) catch return;
    r.setDrawColor(.{ .r = 0, .g = 0, .b = 0, .a = 0 }) catch return;
    r.clear() catch return;
    if (cur_state == .idle and !settling_idle) {
        r.setDrawColor(.{ .r = tint.r, .g = tint.g, .b = tint.b, .a = 230 }) catch return;
        drawOrb(r, types.breatheRadius(t_ms));
    } else {
        // Growing capsule; content appears once mostly grown.
        r.setDrawColor(.{ .r = tint.r, .g = tint.g, .b = tint.b, .a = tint.a }) catch return;
        drawStadium(r, morph);
        if (morph > 0.9) {
            if (cur_state == .recording) {
                var i: usize = 0;
                while (i < 5) : (i += 1) {
                    const h = types.waveBar(t_ms, i) * 40.0 + 4.0;
                    const x: f32 = 108.0 + @as(f32, @floatFromInt(i)) * 20.0;
                    r.setDrawColor(.{ .r = 255, .g = 255, .b = 255, .a = 217 }) catch return;
                    r.renderLine(.{ .x = x, .y = 36.0 - h / 2.0 }, .{ .x = x, .y = 36.0 + h / 2.0 }) catch return;
                }
            } else if (cur_state == .working) {
                // Fixed center (150,36), radius 14: layout never jumps mid-cycle.
                const ang = types.spinnerAngle(t_ms);
                var i: usize = 0;
                while (i < 8) : (i += 1) {
                    const a = ang + @as(f32, @floatFromInt(i)) * 2.0 * std.math.pi;
                    const x: f32 = 150.0 + 14.0 * @cos(a);
                    const yy: f32 = 36.0 + 14.0 * @sin(a);
                    const alpha: u8 = if (i == 0) 255 else 140;
                    r.setDrawColor(.{ .r = 255, .g = 255, .b = 255, .a = alpha }) catch return;
                    r.renderLine(.{ .x = x, .y = yy }, .{ .x = x + 1.0, .y = yy }) catch return;
                }
            } else {
                // Settling back to idle: shrinking stadium only, no content.
            }
        }
    }
    r.present() catch return;
}

/// Monitor enumeration in global desktop coordinates. Runs per call but
/// only on drag motions, startup, and display-change events — never in
/// the render path — so unplug/replug is always current.
fn collectDisplays(buf: []types.Display) usize {
    const ds = sdl3.video.getDisplays() catch return 0;
    defer sdl3.free(ds);
    var n: usize = 0;
    for (ds) |d| {
        if (n >= buf.len) break;
        const b = d.getBounds() catch continue;
        buf[n] = .{ .x = @intCast(b.x), .y = @intCast(b.y), .w = @intCast(b.w), .h = @intCast(b.h) };
        n += 1;
    }
    return n;
}

/// Display containing the ball center for a window at `pos`, or the first
/// enumerated display when off-screen (drives clamping during
/// cross-monitor drags and after unplug).
fn containingDisplay(pos: types.Position, scratch: []types.Display) ?types.Display {
    const n = collectDisplays(scratch);
    if (n == 0) return null;
    const list = scratch[0..n];
    // Prefer the display under the ball center so cross-monitor drags
    // stick to the monitor holding most of the ball…
    if (types.findDisplayFor(pos, list)) |idx| return list[idx];
    // …otherwise pin to the first display, e.g. after unplug.
    return list[0];
}

fn clampToCurrent(pos: types.Position) types.Position {
    var scratch: [16]types.Display = undefined;
    const d = containingDisplay(pos, &scratch) orelse return pos;
    return types.clampToDisplay(pos, d);
}

fn windowPos(w: sdl3.video.Window) types.Position {
    const xy = w.getPosition() catch return .{ .x = 0, .y = 0 };
    return .{ .x = @intCast(xy[0]), .y = @intCast(xy[1]) };
}

pub fn setup(_: types.OverlayConfig) !void {
    if (window != null) return;
    // UTILITY + NOT_FOCUSABLE: the portable parentless combo for a
    // non-activating tool window (no taskbar entry, no keyboard focus on
    // Win/X11/macOS). TOOLTIP was tried and rejected: SDL3 hard-requires a
    // parent window for tooltips ("must specify a parent window") and we
    // have none. Caveat: without override-redirect, tiling WMs (i3 retiled
    // ours to 100x100) manage the window; floating WMs show it as specced.
    // True override-redirect belongs to the deferred native X11 backend
    // (spec §4). If the manual checklist shows focus theft on any OS, that
    // OS gets a native hint as a follow-up — not here.
    sdl3.init(.{ .video = true }) catch return error.SdlFailed;
    errdefer sdl3.quit(.{ .video = true });
    const w = sdl3.video.Window.init("zhisper", types.window_w, types.window_h, .{
        .borderless = true,
        .transparent = true,
        .always_on_top = true,
        .utility = true,
        .not_focusable = true,
    }) catch return error.SdlFailed;
    errdefer w.deinit();
    const r = sdl3.render.Renderer.init(w, null) catch return error.SdlFailed;
    window = w;
    renderer = r;
    inited = true;
    cur_state = .idle;
    prev_state = .idle;
    state_start_ms = 0;
    last_tick_ms = 0;
    last_present_ms = null;
    tint = types.stateTint(.idle);
    redraw();
}

pub fn destroy() void {
    if (renderer) |*r| {
        r.deinit();
        renderer = null;
    }
    if (window) |w| {
        w.deinit();
        window = null;
    }
    if (inited) {
        sdl3.quit(.{ .video = true });
        sdl3.shutdown();
        inited = false;
    }
    cur_state = .idle;
    prev_state = .idle;
    last_present_ms = null;
    dragging = false;
}

pub fn show() !void {
    const w = window orelse return error.NotSetup;
    w.show() catch return error.SdlFailed;
    redraw();
}

pub fn hide() void {
    if (window) |w| w.hide() catch {};
}

pub fn move(pos: types.Position) void {
    const w = window orelse return;
    const p = clampToCurrent(pos);
    w.setPosition(.{ .absolute = p.x }, .{ .absolute = p.y }) catch {};
}

/// Monitor list in global desktop coordinates for startup restore,
/// primary first (SDL enum order is unspecified, so the primary is pinned
/// to the front). Caller owns the slice. Empty when SDL reports no displays.
pub fn displayList(gpa: std.mem.Allocator) ![]types.Display {
    const ds = sdl3.video.getDisplays() catch return try gpa.alloc(types.Display, 0);
    defer sdl3.free(ds);
    const primary: ?sdl3.video.Display = sdl3.video.Display.getPrimaryDisplay() catch null;
    var scratch: [16]types.Display = undefined;
    var n: usize = 0;
    // Pass 1: primary first, so restore/default prefer it.
    for (ds) |d| {
        if (n >= scratch.len) break;
        if (primary) |pd| {
            if (d != pd) continue;
        } else continue;
        const b = d.getBounds() catch continue;
        scratch[n] = .{ .x = @intCast(b.x), .y = @intCast(b.y), .w = @intCast(b.w), .h = @intCast(b.h) };
        n += 1;
    }
    // Pass 2: the rest in SDL order.
    for (ds) |d| {
        if (n >= scratch.len) break;
        if (primary) |pd| {
            if (d == pd) continue;
        }
        const b = d.getBounds() catch continue;
        scratch[n] = .{ .x = @intCast(b.x), .y = @intCast(b.y), .w = @intCast(b.w), .h = @intCast(b.h) };
        n += 1;
    }
    const out = try gpa.alloc(types.Display, n);
    @memcpy(out, scratch[0..n]);
    return out;
}

pub fn setState(s: types.State) void {
    if (s == cur_state) return;
    prev_state = cur_state;
    cur_state = s;
    state_start_ms = last_tick_ms;
    tint = types.stateTint(s);
    // Draw is deferred to tick (30fps throttle); nothing to do here.
}

pub fn pollEvent() ?types.Event {
    const w = window orelse return null;
    while (sdl3.events.poll()) |sev| {
        switch (sev) {
            .mouse_button_down => |mb| {
                if (mb.button != .left) continue;
                // Window-local coords; presses outside the pill never
                // start a drag (corners stay click-through-tolerant).
                if (!types.hitTestPill(@intFromFloat(mb.x), @intFromFloat(mb.y))) continue;
                dragging = true;
                drag_moved = false;
                return .{ .drag_start = windowPos(w) };
            },
            .mouse_motion => |mm| {
                if (!dragging) continue;
                drag_moved = true;
                const cur = windowPos(w);
                // Clamped to the display under the ball, so drags glide
                // across monitor bezels instead of sticking at the primary.
                const p = clampToCurrent(.{
                    .x = cur.x + @as(i32, @intFromFloat(mm.x_rel)),
                    .y = cur.y + @as(i32, @intFromFloat(mm.y_rel)),
                });
                w.setPosition(.{ .absolute = p.x }, .{ .absolute = p.y }) catch {};
                return .{ .drag_moved = p };
            },
            .mouse_button_up => |mu| {
                if (mu.button != .left or !dragging) continue;
                dragging = false;
                // Press + release without motion is ignored (no click event).
                if (!drag_moved) continue;
                return .{ .drag_end = windowPos(w) };
            },
            // Monitor plugged/unplugged/moved mid-session: re-pin the ball
            // onto a live display instead of stranding it off-screen.
            .display_added, .display_removed, .display_moved, .display_desktop_mode_changed, .display_current_mode_changed, .display_content_scale_changed, .display_usable_bounds_changed, .display_orientation => {
                const p = clampToCurrent(windowPos(w));
                w.setPosition(.{ .absolute = p.x }, .{ .absolute = p.y }) catch {};
            },
            else => {},
        }
    }
    return null;
}
