const std = @import("std");

/// Single vocabulary for both directions: the hotkey listener reports a
/// KeyEvent, the typer consumes one. Pure Zig, no OS headers — safe on all
/// targets, including test builds.
///
/// The explicit u8 tag is required because EventRing stores KeyEvent inside
/// std.atomic.Value, which is an extern struct and therefore needs a
/// fixed-size tag type.
pub const KeyEvent = enum(u8) { hotkey_pressed, hotkey_released, cancel_pressed, clipboard_pressed, clipboard_released };
pub const Mode = enum { hold, toggle };
// WHY clipboard_key_code defaults to 0: evdev key 0 is KEY_RESERVED and is
// never emitted, so 0 is a real disable rather than a real binding. macOS
// key code 0 is a genuine key (kVK_ANSI_A), which main.zig resolves the same
// way it already resolves cancel_key_code.
pub const HotkeyConfig = struct { key_code: u16, mode: Mode = .hold, evdev: []const u8 = "", evdev_name: []const u8 = "", cancel_key_code: u16 = 46, clipboard_key_code: u16 = 0 };

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
    const cfg = HotkeyConfig{ .key_code = 16 };
    try std.testing.expectEqual(Mode.hold, cfg.mode);
}

test "cancel key defaults to KEY_C and is disableable with 0" {
    const cfg = HotkeyConfig{ .key_code = 16 };
    try std.testing.expectEqual(@as(u16, 46), cfg.cancel_key_code);
    const off = HotkeyConfig{ .key_code = 16, .cancel_key_code = 0 };
    try std.testing.expectEqual(@as(u16, 0), off.cancel_key_code);
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

test "clipboard key code defaults to 0, which never fires" {
    const cfg = HotkeyConfig{ .key_code = 16 };
    try std.testing.expectEqual(@as(u16, 0), cfg.clipboard_key_code);
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
