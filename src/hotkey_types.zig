const std = @import("std");
const shortcut = @import("shortcut.zig");

/// Single vocabulary for both directions: the hotkey listener reports a
/// KeyEvent, the typer consumes one. Pure Zig, no OS headers — safe on all
/// targets, including test builds.
///
/// The explicit u8 tag is required because EventRing stores KeyEvent inside
/// std.atomic.Value, which is an extern struct and therefore needs a
/// fixed-size tag type.
pub const KeyEvent = enum(u8) { hotkey_pressed, hotkey_released, cancel_pressed, clipboard_pressed, clipboard_released, search_pressed, search_released };
pub const Mode = enum { hold, toggle };

pub const HotkeyConfig = struct {
    shortcut: shortcut.Binding,
    cancel: shortcut.Binding,
    clipboard: ?shortcut.Binding = null,
    search: ?shortcut.Binding = null,
    mode: Mode = .hold,
    evdev: []const u8 = "",
    evdev_name: []const u8 = "",
};

/// Native code for a legacy binding. Returns null for a chord or for the
/// 0-means-disabled placeholder so listeners can keep their existing guards.
pub fn rawCode(b: shortcut.Binding) ?u16 {
    return switch (b) {
        .chord => null,
        .raw_code => |code| if (code == 0) null else code,
    };
}

/// One config action and the binding resolved for it. `name` is the config
/// field, so a startup error can name the line the user has to edit.
pub const Action = struct {
    name: []const u8,
    binding: ?shortcut.Binding,
};

/// Two actions that fight over one key press, named as they appear in the
/// config.
pub const Collision = struct {
    a: []const u8,
    b: []const u8,
};

/// The four bindings a listener serves. Record and cancel are always bound;
/// clipboard and search carry null when they are switched off.
pub fn actions(cfg: HotkeyConfig) [4]Action {
    return .{
        .{ .name = "shortcut", .binding = cfg.shortcut },
        .{ .name = "cancel", .binding = cfg.cancel },
        .{ .name = "clipboard", .binding = cfg.clipboard },
        .{ .name = "search", .binding = cfg.search },
    };
}

/// The two actions that fire on the same physical key press, or null.
///
/// WHY: a chord and a raw code are different shapes, so comparing bindings
/// never reports them equal even when they name one key. Harmless while every
/// chord required meta; a chord with no modifier fires on the same bare press a
/// raw code does, and the listener stops at its first match, leaving the other
/// action silently dead.
///
/// `codeFor` is the OS key table: portable name to native code, null when this
/// OS cannot report that key.
pub fn mixedKindCollision(cfg: HotkeyConfig, codeFor: *const fn (shortcut.KeyName) ?u16) ?Collision {
    const all = actions(cfg);
    for (all, 0..) |a, i| {
        const code_a = bareCode(a.binding, codeFor) orelse continue;
        for (all[i + 1 ..]) |b| {
            const code_b = bareCode(b.binding, codeFor) orelse continue;
            if (code_a == code_b) return .{ .a = a.name, .b = b.name };
        }
    }
    return null;
}

/// The native code a modifier-free press of this binding reports, or null when
/// it cannot fire bare: it needs a modifier, or it is disabled or unbound.
fn bareCode(binding: ?shortcut.Binding, codeFor: *const fn (shortcut.KeyName) ?u16) ?u16 {
    const b = binding orelse return null;
    switch (b) {
        .raw_code => return rawCode(b),
        .chord => |ch| return if (ch.modifiers.meta or ch.modifiers.shift) null else codeFor(ch.key),
    }
}

/// Fixed-capacity single-producer / single-consumer queue of hotkey events.
///
/// WHY this exists: main.zig calls pollEvent() exactly once per loop iteration
/// and the seam returns a single ?KeyEvent. Linux tolerates that because the
/// kernel buffers evdev events between reads. The macOS event tap and the
/// Windows keyboard hook deliver callbacks on their own background thread with
/// no kernel buffer behind them, so a press and release landing between two
/// iterations would collapse into one reported event and hold-to-talk would
/// never start.
///
/// Fixed capacity keeps push() allocation-free and non-blocking, which is
/// mandatory inside a foreign-thread callback. On overflow the oldest event is
/// discarded: losing stale events beats blocking or allocating in a callback
/// the operating system is waiting on.
pub const EventRing = struct {
    pub const capacity = 16;

    /// Slots are read only after a matching push has published `tail`, so the
    /// undefined default is never observed.
    slots: [capacity]std.atomic.Value(KeyEvent) = undefined,
    /// Consumer position. Advanced by pop(), and by push() when it drops.
    head: std.atomic.Value(usize) = .init(0),
    /// Producer position. Written only by push().
    tail: std.atomic.Value(usize) = .init(0),

    pub fn init() EventRing {
        return .{};
    }

    pub fn push(self: *EventRing, ev: KeyEvent) void {
        const t = self.tail.load(.monotonic);
        // Store the payload before publishing `tail`; the release-store below
        // is what makes this slot visible to the consumer.
        self.slots[t % capacity].store(ev, .unordered);
        self.tail.store(t + 1, .release);
        // If the consumer is a full lap behind, this store just overwrote the
        // oldest unread slot. Advance head so pop() cannot hand it back.
        const h = self.head.load(.acquire);
        if (t + 1 - h > capacity) self.head.store(h + 1, .release);
    }

    pub fn pop(self: *EventRing) ?KeyEvent {
        const h = self.head.load(.acquire);
        const t = self.tail.load(.acquire);
        if (h == t) return null;
        const ev = self.slots[h % capacity].load(.unordered);
        self.head.store(h + 1, .release);
        return ev;
    }

    pub fn reset(self: *EventRing) void {
        self.head.store(0, .monotonic);
        self.tail.store(0, .monotonic);
    }
};

test "default mode is hold" {
    const cfg = HotkeyConfig{ .shortcut = .{ .raw_code = 16 }, .cancel = .{ .raw_code = 46 } };
    try std.testing.expectEqual(Mode.hold, cfg.mode);
}

test "clipboard and search bindings default to null, which never fires" {
    const t = @import("hotkey_types.zig");
    const cfg: t.HotkeyConfig = .{ .shortcut = .{ .raw_code = 30 }, .cancel = .{ .raw_code = 46 } };
    try std.testing.expect(cfg.clipboard == null);
    try std.testing.expect(cfg.search == null);
}

test "rawCode reads legacy codes and refuses chords" {
    const t = @import("hotkey_types.zig");
    const sc = @import("shortcut.zig");
    try std.testing.expectEqual(@as(?u16, 30), t.rawCode(.{ .raw_code = 30 }));
    // 0 is the "never fires" placeholder used by an unset module-level config.
    try std.testing.expect(t.rawCode(.{ .raw_code = 0 }) == null);
    try std.testing.expect(t.rawCode(.{ .chord = try sc.parse("meta+8") }) == null);
}

test "actions names the four bindings in config order" {
    const t = @import("hotkey_types.zig");
    const sc = @import("shortcut.zig");
    const f9 = sc.Binding{ .chord = try sc.parse("f9") };
    const list = t.actions(.{
        .shortcut = f9,
        .cancel = .{ .raw_code = 66 },
        .clipboard = .{ .raw_code = 68 },
        .search = null,
    });
    try std.testing.expectEqualStrings("shortcut", list[0].name);
    try std.testing.expectEqualStrings("cancel", list[1].name);
    try std.testing.expectEqualStrings("clipboard", list[2].name);
    try std.testing.expectEqualStrings("search", list[3].name);
    try std.testing.expect(list[0].binding.?.eql(f9));
    try std.testing.expect(list[1].binding.?.eql(.{ .raw_code = 66 }));
    // An action that is switched off has no binding to claim a key.
    try std.testing.expect(list[3].binding == null);
}

// A stand-in for an OS key table: two function keys with codes, everything else
// unmappable. The helper is judged on the codes it is given, not on a real
// platform, so this runs on every target.
fn codeForTwoFunctionKeys(name: shortcut.KeyName) ?u16 {
    return switch (name) {
        .f9 => 67,
        .f8 => 66,
        else => null,
    };
}

test "a bare chord and a raw code naming the same key collide" {
    const t = @import("hotkey_types.zig");
    const sc = @import("shortcut.zig");
    const cfg: t.HotkeyConfig = .{
        .shortcut = .{ .chord = try sc.parse("f9") },
        .cancel = .{ .raw_code = 67 },
    };
    const pair = t.mixedKindCollision(cfg, codeForTwoFunctionKeys).?;
    try std.testing.expectEqualStrings("shortcut", pair.a);
    try std.testing.expectEqualStrings("cancel", pair.b);
}

test "nothing collides without one bare chord and one matching raw code" {
    const t = @import("hotkey_types.zig");
    const sc = @import("shortcut.zig");
    const bare_f9 = sc.Binding{ .chord = try sc.parse("f9") };
    // A chord that needs meta can never fire on the same bare press.
    try std.testing.expect(t.mixedKindCollision(.{
        .shortcut = .{ .chord = try sc.parse("meta+f9") },
        .cancel = .{ .raw_code = 67 },
    }, codeForTwoFunctionKeys) == null);
    // Same shape, different native code.
    try std.testing.expect(t.mixedKindCollision(.{
        .shortcut = bare_f9,
        .cancel = .{ .raw_code = 66 },
    }, codeForTwoFunctionKeys) == null);
    // 0 is the "never fires" placeholder, not a key press.
    try std.testing.expect(t.mixedKindCollision(.{
        .shortcut = bare_f9,
        .cancel = .{ .raw_code = 0 },
    }, codeForTwoFunctionKeys) == null);
    // f10 has no code in this fake table, so nothing can be claimed twice.
    try std.testing.expect(t.mixedKindCollision(.{
        .shortcut = .{ .chord = try sc.parse("f10") },
        .cancel = .{ .raw_code = 67 },
    }, codeForTwoFunctionKeys) == null);
}

test "EventRing preserves push order" {
    const t = @import("hotkey_types.zig");
    var ring = t.EventRing.init();
    defer ring.reset();
    ring.push(.hotkey_pressed);
    ring.push(.hotkey_released);
    ring.push(.cancel_pressed);
    try std.testing.expectEqual(t.KeyEvent.hotkey_pressed, ring.pop().?);
    try std.testing.expectEqual(t.KeyEvent.hotkey_released, ring.pop().?);
    try std.testing.expectEqual(t.KeyEvent.cancel_pressed, ring.pop().?);
    try std.testing.expect(ring.pop() == null);
}

test "EventRing pop on empty ring returns null" {
    const t = @import("hotkey_types.zig");
    var ring = t.EventRing.init();
    defer ring.reset();
    try std.testing.expect(ring.pop() == null);
    try std.testing.expect(ring.pop() == null);
}

test "EventRing drops the oldest event when full" {
    const t = @import("hotkey_types.zig");
    var ring = t.EventRing.init();
    defer ring.reset();
    var i: usize = 0;
    while (i < t.EventRing.capacity + 4) : (i += 1) {
        ring.push(.hotkey_pressed);
    }
    // The ring holds `capacity` entries, all pushed after the overflow began.
    var seen: usize = 0;
    while (ring.pop()) |_| seen += 1;
    try std.testing.expectEqual(t.EventRing.capacity, seen);
}

test "EventRing reset empties it" {
    const t = @import("hotkey_types.zig");
    var ring = t.EventRing.init();
    ring.push(.hotkey_pressed);
    ring.reset();
    try std.testing.expect(ring.pop() == null);
}

test "EventRing preserves search event order" {
    const t = @import("hotkey_types.zig");
    var ring = t.EventRing.init();
    defer ring.reset();
    ring.push(.search_pressed);
    ring.push(.search_released);
    try std.testing.expectEqual(KeyEvent.search_pressed, ring.pop().?);
    try std.testing.expectEqual(KeyEvent.search_released, ring.pop().?);
    try std.testing.expect(ring.pop() == null);
}

test "EventRing preserves clipboard event order" {
    const t = @import("hotkey_types.zig");
    var ring = t.EventRing.init();
    defer ring.reset();
    ring.push(.clipboard_pressed);
    ring.push(.clipboard_released);
    ring.push(.cancel_pressed);
    try std.testing.expectEqual(t.KeyEvent.clipboard_pressed, ring.pop().?);
    try std.testing.expectEqual(t.KeyEvent.clipboard_released, ring.pop().?);
    try std.testing.expectEqual(t.KeyEvent.cancel_pressed, ring.pop().?);
    try std.testing.expect(ring.pop() == null);
}
