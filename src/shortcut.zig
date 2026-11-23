const std = @import("std");

pub const Modifiers = struct {
    meta: bool = false,
    shift: bool = false,
};

// Enum order is load bearing: a..z, then d0..d9, then f1..f24, then named keys.
pub const KeyName = enum {
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    d0,
    d1,
    d2,
    d3,
    d4,
    d5,
    d6,
    d7,
    d8,
    d9,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    space,
    enter,
    tab,
    esc,
    backspace,
    delete,
    insert,
    home,
    end,
    pageup,
    pagedown,
    left,
    right,
    up,
    down,
    minus,
    equal,
    comma,
    period,
    slash,
    backslash,
    semicolon,
    quote,
    bracketleft,
    bracketright,
    grave,

    pub fn canonicalName(self: KeyName) []const u8 {
        return switch (self) {
            .a => "a",
            .b => "b",
            .c => "c",
            .d => "d",
            .e => "e",
            .f => "f",
            .g => "g",
            .h => "h",
            .i => "i",
            .j => "j",
            .k => "k",
            .l => "l",
            .m => "m",
            .n => "n",
            .o => "o",
            .p => "p",
            .q => "q",
            .r => "r",
            .s => "s",
            .t => "t",
            .u => "u",
            .v => "v",
            .w => "w",
            .x => "x",
            .y => "y",
            .z => "z",
            .d0 => "0",
            .d1 => "1",
            .d2 => "2",
            .d3 => "3",
            .d4 => "4",
            .d5 => "5",
            .d6 => "6",
            .d7 => "7",
            .d8 => "8",
            .d9 => "9",
            .f1 => "f1",
            .f2 => "f2",
            .f3 => "f3",
            .f4 => "f4",
            .f5 => "f5",
            .f6 => "f6",
            .f7 => "f7",
            .f8 => "f8",
            .f9 => "f9",
            .f10 => "f10",
            .f11 => "f11",
            .f12 => "f12",
            .f13 => "f13",
            .f14 => "f14",
            .f15 => "f15",
            .f16 => "f16",
            .f17 => "f17",
            .f18 => "f18",
            .f19 => "f19",
            .f20 => "f20",
            .f21 => "f21",
            .f22 => "f22",
            .f23 => "f23",
            .f24 => "f24",
            .space => "space",
            .enter => "enter",
            .tab => "tab",
            .esc => "esc",
            .backspace => "backspace",
            .delete => "delete",
            .insert => "insert",
            .home => "home",
            .end => "end",
            .pageup => "pageup",
            .pagedown => "pagedown",
            .left => "left",
            .right => "right",
            .up => "up",
            .down => "down",
            .minus => "minus",
            .equal => "equal",
            .comma => "comma",
            .period => "period",
            .slash => "slash",
            .backslash => "backslash",
            .semicolon => "semicolon",
            .quote => "quote",
            .bracketleft => "bracketleft",
            .bracketright => "bracketright",
            .grave => "grave",
        };
    }
};

fn appendByte(buf: []u8, pos: usize, byte: u8) error{NoSpaceLeft}!usize {
    if (pos >= buf.len) return error.NoSpaceLeft;
    buf[pos] = byte;
    return pos + 1;
}

fn appendSlice(buf: []u8, pos: usize, slice: []const u8) error{NoSpaceLeft}!usize {
    if (pos + slice.len > buf.len) return error.NoSpaceLeft;
    @memcpy(buf[pos..][0..slice.len], slice);
    return pos + slice.len;
}

pub const Shortcut = struct {
    modifiers: Modifiers,
    key: KeyName,

    pub fn eql(a: Shortcut, b: Shortcut) bool {
        return a.modifiers.meta == b.modifiers.meta and
            a.modifiers.shift == b.modifiers.shift and
            a.key == b.key;
    }

    pub fn format(self: Shortcut, buf: []u8) ![]const u8 {
        var pos: usize = 0;
        if (self.modifiers.meta) {
            pos = try appendSlice(buf, pos, "Meta");
        }
        if (self.modifiers.shift) {
            if (self.modifiers.meta) pos = try appendSlice(buf, pos, "+");
            pos = try appendSlice(buf, pos, "Shift");
        }
        if (self.modifiers.meta or self.modifiers.shift) {
            pos = try appendSlice(buf, pos, "+");
        }
        const name = self.key.canonicalName();
        if (name.len > 0) {
            pos = try appendByte(buf, pos, std.ascii.toUpper(name[0]));
            if (name.len > 1) pos = try appendSlice(buf, pos, name[1..]);
        }
        return buf[0..pos];
    }
};

pub const Binding = union(enum) {
    chord: Shortcut,
    raw_code: u16,

    pub fn eql(a: Binding, b: Binding) bool {
        return switch (a) {
            .chord => |ac| switch (b) {
                .chord => |bc| Shortcut.eql(ac, bc),
                .raw_code => false,
            },
            .raw_code => |ar| switch (b) {
                .chord => false,
                .raw_code => |br| ar == br,
            },
        };
    }

    pub fn format(self: Binding, buf: []u8) ![]const u8 {
        return switch (self) {
            .chord => |c| c.format(buf),
            .raw_code => |code| std.fmt.bufPrint(buf, "code {d}", .{code}),
        };
    }
};

pub const ParseError = error{
    EmptyShortcut,
    UnknownModifier,
    UnsupportedModifier,
    MissingMetaModifier,
    DuplicateModifier,
    MissingKey,
    TooManyParts,
    UnknownKey,
};

// src/shortcut.zig — exact values, do not renumber
const named = std.StaticStringMap(KeyName).initComptime(.{
    .{ "space", .space },               .{ "enter", .enter },       .{ "return", .enter },
    .{ "tab", .tab },                   .{ "esc", .esc },           .{ "escape", .esc },
    .{ "backspace", .backspace },       .{ "delete", .delete },     .{ "del", .delete },
    .{ "insert", .insert },             .{ "home", .home },         .{ "end", .end },
    .{ "pageup", .pageup },             .{ "pagedown", .pagedown }, .{ "left", .left },
    .{ "right", .right },               .{ "up", .up },             .{ "down", .down },
    .{ "minus", .minus },               .{ "equal", .equal },       .{ "comma", .comma },
    .{ "period", .period },             .{ "slash", .slash },       .{ "backslash", .backslash },
    .{ "semicolon", .semicolon },       .{ "quote", .quote },       .{ "bracketleft", .bracketleft },
    .{ "bracketright", .bracketright }, .{ "grave", .grave },
});

const unsupported_modifiers = std.StaticStringMap(void).initComptime(.{
    .{ "ctrl", {} },  .{ "control", {} }, .{ "alt", {} },
    .{ "super", {} }, .{ "cmd", {} },     .{ "command", {} },
    .{ "win", {} },   .{ "option", {} },  .{ "opt", {} },
});

fn trimAsciiWhitespace(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn isUnsupportedModifier(token: []const u8) bool {
    var buf: [16]u8 = undefined;
    const n = @min(token.len, buf.len);
    for (token[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return unsupported_modifiers.has(buf[0..n]);
}

fn resolveKeyName(token: []const u8) ParseError!KeyName {
    if (token.len == 0) return error.UnknownKey;

    if (token.len == 1) {
        const c = std.ascii.toLower(token[0]);
        if (c >= 'a' and c <= 'z') {
            const off: u8 = c - 'a';
            return @enumFromInt(@intFromEnum(KeyName.a) + off);
        }
        if (c >= '0' and c <= '9') {
            const off: u8 = c - '0';
            return @enumFromInt(@intFromEnum(KeyName.d0) + off);
        }
    }

    if (std.ascii.toLower(token[0]) == 'f' and token.len >= 2 and token.len <= 3) {
        var all_digits = true;
        for (token[1..]) |c| {
            if (!std.ascii.isDigit(c)) {
                all_digits = false;
                break;
            }
        }
        if (all_digits) {
            const n = std.fmt.parseInt(u8, token[1..], 10) catch return error.UnknownKey;
            if (n >= 1 and n <= 24) {
                return @enumFromInt(@intFromEnum(KeyName.f1) + (n - 1));
            }
        }
    }

    var lower_buf: [32]u8 = undefined;
    if (token.len <= lower_buf.len) {
        for (token, 0..) |c, i| lower_buf[i] = std.ascii.toLower(c);
        if (named.get(lower_buf[0..token.len])) |k| return k;
    }

    return error.UnknownKey;
}

pub fn parse(text: []const u8) ParseError!Shortcut {
    const trimmed = trimAsciiWhitespace(text);
    if (trimmed.len == 0) return error.EmptyShortcut;

    var parts: [4][]const u8 = undefined;
    var part_count: usize = 0;
    var it = std.mem.splitScalar(u8, trimmed, '+');
    while (it.next()) |raw_part| {
        if (part_count >= parts.len) return error.TooManyParts;
        parts[part_count] = trimAsciiWhitespace(raw_part);
        part_count += 1;
    }

    if (part_count > 3) return error.TooManyParts;

    // Empty token other than a trailing one is UnknownKey.
    for (parts[0..part_count], 0..) |p, i| {
        if (p.len == 0) {
            if (i == part_count - 1) return error.MissingKey;
            return error.UnknownKey;
        }
    }

    var modifiers: Modifiers = .{};
    var key_token: ?[]const u8 = null;

    for (parts[0..part_count], 0..) |token, i| {
        const is_last = i == part_count - 1;
        if (is_last) {
            key_token = token;
            break;
        }

        // Non-final position: must be a modifier.
        if (std.ascii.eqlIgnoreCase(token, "meta")) {
            if (modifiers.meta) return error.DuplicateModifier;
            modifiers.meta = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(token, "shift")) {
            if (modifiers.shift) return error.DuplicateModifier;
            modifiers.shift = true;
            continue;
        }
        if (isUnsupportedModifier(token)) return error.UnsupportedModifier;

        // Anything else in a non-final position: if it's a key name, TooManyParts;
        // otherwise UnknownModifier.
        if (resolveKeyName(token)) |_| {
            return error.TooManyParts;
        } else |_| {}
        return error.UnknownModifier;
    }

    const key_tok = key_token orelse return error.MissingKey;
    const key = try resolveKeyName(key_tok);

    if (!modifiers.meta) return error.MissingMetaModifier;

    return .{ .modifiers = modifiers, .key = key };
}

test "parse accepts a modifier and a key in any letter case" {
    const t = @import("shortcut.zig");
    const s = try t.parse("Meta+F9");
    try std.testing.expect(s.modifiers.meta);
    try std.testing.expect(!s.modifiers.shift);
    try std.testing.expectEqual(t.KeyName.f9, s.key);
}

test "parse accepts both modifier orders and trims spaces" {
    const t = @import("shortcut.zig");
    const a = try t.parse("meta+shift+z");
    const b = try t.parse("  SHIFT + Meta + Z  ");
    try std.testing.expect(t.Shortcut.eql(a, b));
    try std.testing.expect(a.modifiers.meta and a.modifiers.shift);
}

test "parse covers letters, digits and every function key" {
    const t = @import("shortcut.zig");
    try std.testing.expectEqual(t.KeyName.a, (try t.parse("meta+a")).key);
    try std.testing.expectEqual(t.KeyName.z, (try t.parse("meta+z")).key);
    try std.testing.expectEqual(t.KeyName.d0, (try t.parse("meta+0")).key);
    try std.testing.expectEqual(t.KeyName.d9, (try t.parse("meta+9")).key);
    try std.testing.expectEqual(t.KeyName.f1, (try t.parse("meta+f1")).key);
    try std.testing.expectEqual(t.KeyName.f24, (try t.parse("meta+f24")).key);
}

test "parse accepts aliases for the named keys" {
    const t = @import("shortcut.zig");
    try std.testing.expectEqual(t.KeyName.enter, (try t.parse("meta+return")).key);
    try std.testing.expectEqual(t.KeyName.esc, (try t.parse("meta+escape")).key);
    try std.testing.expectEqual(t.KeyName.delete, (try t.parse("meta+del")).key);
}

test "parse rejects every malformed shape with its own error" {
    const t = @import("shortcut.zig");
    try std.testing.expectError(t.ParseError.EmptyShortcut, t.parse(""));
    try std.testing.expectError(t.ParseError.EmptyShortcut, t.parse("   "));
    try std.testing.expectError(t.ParseError.MissingMetaModifier, t.parse("shift+z"));
    try std.testing.expectError(t.ParseError.MissingMetaModifier, t.parse("z"));
    try std.testing.expectError(t.ParseError.UnsupportedModifier, t.parse("ctrl+8"));
    try std.testing.expectError(t.ParseError.UnsupportedModifier, t.parse("meta+alt+n"));
    try std.testing.expectError(t.ParseError.DuplicateModifier, t.parse("meta+meta+8"));
    try std.testing.expectError(t.ParseError.MissingKey, t.parse("meta+"));
    try std.testing.expectError(t.ParseError.UnknownKey, t.parse("meta+f99"));
    try std.testing.expectError(t.ParseError.UnknownKey, t.parse("meta++8"));
    try std.testing.expectError(t.ParseError.TooManyParts, t.parse("meta+a+b"));
    try std.testing.expectError(t.ParseError.TooManyParts, t.parse("a+meta+b"));
}

test "format prints the canonical spelling" {
    const t = @import("shortcut.zig");
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Meta+F9", try (try t.parse("meta+f9")).format(&buf));
    try std.testing.expectEqualStrings("Meta+Shift+Z", try (try t.parse("shift+meta+z")).format(&buf));
    try std.testing.expectEqualStrings("Meta+0", try (try t.parse("meta+0")).format(&buf));
    try std.testing.expectEqualStrings("Meta+Bracketleft", try (try t.parse("meta+bracketleft")).format(&buf));
}

test "format round-trips through parse for every key name" {
    const t = @import("shortcut.zig");
    var buf: [32]u8 = undefined;
    inline for (@typeInfo(t.KeyName).@"enum".fields) |field| {
        const s = t.Shortcut{ .modifiers = .{ .meta = true }, .key = @field(t.KeyName, field.name) };
        try std.testing.expect(t.Shortcut.eql(s, try t.parse(try s.format(&buf))));
    }
}

test "bindings compare equal only inside their own kind" {
    const t = @import("shortcut.zig");
    const chord: t.Binding = .{ .chord = try t.parse("meta+8") };
    const same: t.Binding = .{ .chord = try t.parse("meta+8") };
    const shifted: t.Binding = .{ .chord = try t.parse("meta+shift+8") };
    const raw: t.Binding = .{ .raw_code = 9 };
    try std.testing.expect(t.Binding.eql(chord, same));
    try std.testing.expect(!t.Binding.eql(chord, shifted));
    try std.testing.expect(!t.Binding.eql(chord, raw));
    try std.testing.expect(t.Binding.eql(raw, .{ .raw_code = 9 }));
}

test "binding format marks legacy codes as codes" {
    const t = @import("shortcut.zig");
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("code 9", try (t.Binding{ .raw_code = 9 }).format(&buf));
}

test "Shortcut.format returns error.NoSpaceLeft for a too-small buffer" {
    const s = try parse("meta+f9");
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, s.format(&buf));
}
