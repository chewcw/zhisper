const std = @import("std");
const types = @import("tray_types.zig");
const config = @import("config.zig");
const hotkey_types = @import("hotkey_types.zig");

pub const Submenu = types.Submenu;
pub const Action = types.Action;
pub const ProviderKeys = types.ProviderKeys;

pub const Item = struct {
    label: []const u8,
    action: Action,
    checked: bool = false,
    enabled: bool = true,
    opens_submenu: bool = false,
};

pub const Row = union(enum) {
    separator,
    status: []const u8,
    item: Item,
};

pub const Menu = struct { rows: []const Row };

pub const row_height: i32 = 22;
pub const pad_x: i32 = 8;
pub const min_width: i32 = 120;
pub const max_width: i32 = 320;

fn valueRow(arena: std.mem.Allocator, name: []const u8, value: []const u8, which: Submenu) !Row {
    return .{ .item = .{
        .label = try std.fmt.allocPrint(arena, "{s}: {s}", .{ name, value }),
        .action = .{ .open_submenu = which },
        .opens_submenu = true,
    } };
}

pub fn rootMenu(arena: std.mem.Allocator, state: types.State, cfg: config.Config) !Menu {
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    try rows.append(arena, .{ .status = types.tooltip(state) });
    try rows.append(arena, .separator);
    try rows.append(arena, try valueRow(arena, "Hotkey mode", cfg.hotkey.mode, .hotkey_mode));
    try rows.append(arena, try valueRow(arena, "Normalize", if (cfg.normalize.enabled) "on" else "off", .normalize));
    try rows.append(arena, try valueRow(arena, "Styling", cfg.normalize.styling, .styling));
    try rows.append(arena, try valueRow(arena, "Structure", cfg.normalize.structure, .structure));
    try rows.append(arena, try valueRow(arena, "Context", cfg.normalize.context, .context));
    try rows.append(arena, try valueRow(arena, "Provider", cfg.transcribe.provider, .provider));
    try rows.append(arena, try valueRow(arena, "Overlay", if (cfg.daemon.overlay) "on" else "off", .overlay));
    try rows.append(arena, .separator);
    try rows.append(arena, .{ .item = .{ .label = "Quit", .action = .quit } });
    return .{ .rows = try rows.toOwnedSlice(arena) };
}

pub fn height(menu: Menu) i32 {
    return @as(i32, @intCast(menu.rows.len)) * row_height;
}

pub fn width(menu: Menu, advance: i32) i32 {
    var longest: usize = 0;
    for (menu.rows) |row| switch (row) {
        .item => |item| longest = @max(longest, item.label.len),
        .status => |text| longest = @max(longest, text.len),
        .separator => {},
    };
    // Two columns of glyphs next to the label: the check mark and the submenu
    // marker. Both are drawn as shapes, so they are reserved as advance-wide.
    const chars: i32 = @intCast(longest + 4);
    return std.math.clamp(chars * advance + 2 * pad_x, min_width, max_width);
}

pub fn rowAt(menu: Menu, y: i32) ?usize {
    if (y < 0) return null;
    const index: usize = @intCast(@divTrunc(y, row_height));
    if (index >= menu.rows.len) return null;
    return index;
}

pub const Position = struct { x: i32, y: i32 };
pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// Shifts the menu left or up so it fits on the screen. On a screen smaller
/// than the menu the result is 0, never negative.
pub fn clampPos(x: i32, y: i32, w: i32, h: i32, screen_w: i32, screen_h: i32) Position {
    return .{
        .x = @max(0, @min(x, screen_w - w)),
        .y = @max(0, @min(y, screen_h - h)),
    };
}

/// Places the menu beside the anchor: above it when the anchor sits in the
/// lower half of the screen, below it otherwise. The double comparison keeps
/// the tie on the lower-half side without integer division rounding.
pub fn placeMenu(anchor: Rect, menu_w: i32, menu_h: i32, screen_w: i32, screen_h: i32) Position {
    const centre_y = anchor.y + @divTrunc(anchor.h, 2);
    const preferred_y = if (centre_y * 2 <= screen_h) anchor.y + anchor.h else anchor.y - menu_h;
    const preferred_x = if (anchor.x + menu_w > screen_w) anchor.x + anchor.w - menu_w else anchor.x;
    return .{
        .x = @max(0, @min(preferred_x, screen_w - menu_w)),
        .y = @max(0, @min(preferred_y, screen_h - menu_h)),
    };
}

fn choice(label: []const u8, action: Action, checked: bool, enabled: bool) Row {
    return .{ .item = .{
        .label = label,
        .action = action,
        .checked = checked,
        .enabled = enabled,
    } };
}

fn envSet(name: [*:0]const u8) bool {
    const raw = std.c.getenv(name) orelse return false;
    return raw[0] != 0;
}

/// The menu cannot ask for a key, and the environment is read once at daemon
/// start, so a provider without a key here can never work this session.
pub fn providerKeysFromEnv() ProviderKeys {
    return .{
        .groq = envSet("GROQ_API_KEY"),
        .openai = envSet("OPENAI_API_KEY"),
        .deepgram = envSet("DEEPGRAM_API_KEY"),
    };
}

pub fn submenu(arena: std.mem.Allocator, which: Submenu, cfg: config.Config, keys: ProviderKeys) !Menu {
    var rows: std.ArrayListUnmanaged(Row) = .empty;
    try rows.append(arena, choice("< back", .back, false, true));
    switch (which) {
        .hotkey_mode => {
            try rows.append(arena, choice("hold", .{ .set_hotkey_mode = .hold }, std.mem.eql(u8, cfg.hotkey.mode, "hold"), true));
            try rows.append(arena, choice("toggle", .{ .set_hotkey_mode = .toggle }, std.mem.eql(u8, cfg.hotkey.mode, "toggle"), true));
        },
        .normalize => {
            try rows.append(arena, choice("off", .{ .set_normalize_enabled = false }, !cfg.normalize.enabled, true));
            try rows.append(arena, choice("on", .{ .set_normalize_enabled = true }, cfg.normalize.enabled, true));
        },
        .styling => {
            for ([_][]const u8{ "casual", "semi-casual", "semi-formal", "formal" }) |value| {
                try rows.append(arena, choice(value, .{ .set_styling = value }, std.mem.eql(u8, cfg.normalize.styling, value), true));
            }
        },
        .structure => {
            for ([_][]const u8{ "prose", "lists" }) |value| {
                try rows.append(arena, choice(value, .{ .set_structure = value }, std.mem.eql(u8, cfg.normalize.structure, value), true));
            }
        },
        .context => {
            for ([_][]const u8{ "general", "email" }) |value| {
                try rows.append(arena, choice(value, .{ .set_context = value }, std.mem.eql(u8, cfg.normalize.context, value), true));
            }
        },
        .provider => {
            const entries = [_]struct { name: []const u8, enabled: bool }{
                .{ .name = "groq", .enabled = keys.groq },
                .{ .name = "openai", .enabled = keys.openai },
                .{ .name = "deepgram", .enabled = keys.deepgram },
            };
            for (entries) |entry| {
                try rows.append(arena, choice(entry.name, .{ .set_provider = entry.name }, std.mem.eql(u8, cfg.transcribe.provider, entry.name), entry.enabled));
            }
        },
        .overlay => {
            try rows.append(arena, choice("on", .{ .set_overlay = true }, cfg.daemon.overlay, true));
            try rows.append(arena, choice("off", .{ .set_overlay = false }, !cfg.daemon.overlay, true));
        },
    }
    return .{ .rows = try rows.toOwnedSlice(arena) };
}

fn testMenu(arena: std.mem.Allocator, cfg: config.Config) !Menu {
    return rootMenu(arena, .idle, cfg);
}

fn itemAt(menu: Menu, index: usize) Item {
    return switch (menu.rows[index]) {
        .item => |it| it,
        else => unreachable,
    };
}

fn statusAt(menu: Menu) []const u8 {
    return switch (menu.rows[0]) {
        .status => |text| text,
        else => unreachable,
    };
}

fn isSeparator(menu: Menu, index: usize) bool {
    return menu.rows[index] == .separator;
}

test "root menu starts with the status line and ends with quit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const menu = try testMenu(arena_state.allocator(), config.defaultConfig());

    try std.testing.expectEqualStrings("zhisper: idle", statusAt(menu));
    try std.testing.expect(isSeparator(menu, 1));
    const last = itemAt(menu, menu.rows.len - 1);
    try std.testing.expectEqualStrings("Quit", last.label);
    try std.testing.expect(last.action == .quit);
}

test "root menu shows the current value of every row" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var cfg = config.defaultConfig();
    cfg.hotkey.mode = "toggle";
    cfg.normalize.enabled = true;
    cfg.normalize.styling = "formal";
    cfg.normalize.structure = "lists";
    cfg.normalize.context = "email";
    cfg.transcribe.provider = "deepgram";
    cfg.daemon.overlay = false;
    const menu = try testMenu(arena_state.allocator(), cfg);

    const labels = [_][]const u8{
        "Hotkey mode: toggle",
        "Normalize: on",
        "Styling: formal",
        "Structure: lists",
        "Context: email",
        "Provider: deepgram",
        "Overlay: off",
    };
    for (labels, 0..) |want, i| {
        try std.testing.expectEqualStrings(want, itemAt(menu, i + 2).label);
        try std.testing.expect(itemAt(menu, i + 2).opens_submenu);
    }
}

test "width grows with the longest label and clamps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const menu = try testMenu(arena_state.allocator(), config.defaultConfig());
    // "Styling: semi-formal" is 20 characters; 20 + 2 check + 2 marker = 24.
    try std.testing.expectEqual(@as(i32, 24 * 6 + 2 * pad_x), width(menu, 6));
    try std.testing.expectEqual(min_width, width(menu, 1));
    try std.testing.expectEqual(max_width, width(menu, 40));
}

test "rowAt maps y to a row and rejects points outside the menu" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const menu = try testMenu(arena_state.allocator(), config.defaultConfig());
    try std.testing.expectEqual(@as(usize, 0), rowAt(menu, 0).?);
    try std.testing.expectEqual(@as(usize, 0), rowAt(menu, row_height - 1).?);
    try std.testing.expectEqual(@as(usize, 1), rowAt(menu, row_height).?);
    try std.testing.expect(rowAt(menu, -1) == null);
    try std.testing.expect(rowAt(menu, height(menu)) == null);
}

test "root menu status follows the tray state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const menu = try rootMenu(arena_state.allocator(), .recording, config.defaultConfig());
    try std.testing.expectEqualStrings("zhisper: recording", statusAt(menu));
}

test "every submenu starts with a back row" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]Submenu{ .hotkey_mode, .normalize, .styling, .structure, .context, .provider, .overlay }) |which| {
        const menu = try submenu(arena, which, config.defaultConfig(), .{});
        const back = itemAt(menu, 0);
        try std.testing.expectEqualStrings("< back", back.label);
        try std.testing.expect(back.action == .back);
    }
}

test "hotkey submenu marks the configured mode" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var cfg = config.defaultConfig();
    cfg.hotkey.mode = "toggle";
    const menu = try submenu(arena_state.allocator(), .hotkey_mode, cfg, .{});
    try std.testing.expectEqual(@as(usize, 3), menu.rows.len);
    try std.testing.expect(!itemAt(menu, 1).checked);
    try std.testing.expect(itemAt(menu, 2).checked);
    try std.testing.expectEqual(hotkey_types.Mode.toggle, itemAt(menu, 2).action.set_hotkey_mode);
}

test "provider submenu disables a provider without a key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var cfg = config.defaultConfig();
    cfg.transcribe.provider = "openai";
    const menu = try submenu(arena_state.allocator(), .provider, cfg, .{ .groq = true, .openai = true });
    try std.testing.expectEqual(@as(usize, 4), menu.rows.len);
    try std.testing.expectEqualStrings("groq", itemAt(menu, 1).label);
    try std.testing.expectEqualStrings("openai", itemAt(menu, 2).label);
    try std.testing.expectEqualStrings("deepgram", itemAt(menu, 3).label);
    try std.testing.expect(itemAt(menu, 1).enabled);
    try std.testing.expect(itemAt(menu, 2).checked);
    try std.testing.expect(!itemAt(menu, 3).enabled);
}

test "styling and structure submenus list their allowed values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const styling = try submenu(arena, .styling, config.defaultConfig(), .{});
    try std.testing.expectEqual(@as(usize, 5), styling.rows.len);
    try std.testing.expectEqualStrings("semi-formal", itemAt(styling, 3).label);
    try std.testing.expect(itemAt(styling, 3).checked);
    const structure = try submenu(arena, .structure, config.defaultConfig(), .{});
    try std.testing.expectEqualStrings("lists", itemAt(structure, 2).label);
}

test "normalize and overlay submenus carry booleans" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cfg = config.defaultConfig();
    cfg.daemon.overlay = false;
    const overlay = try submenu(arena, .overlay, cfg, .{});
    try std.testing.expect(itemAt(overlay, 1).action.set_overlay);
    try std.testing.expect(!itemAt(overlay, 2).action.set_overlay);
    try std.testing.expect(itemAt(overlay, 2).checked);
    const normalize = try submenu(arena, .normalize, cfg, .{});
    try std.testing.expect(!itemAt(normalize, 1).action.set_normalize_enabled);
    try std.testing.expect(itemAt(normalize, 1).checked);
}

test "clampPos keeps the menu inside the screen and off the top-left edge" {
    const Pos = Position;
    try std.testing.expectEqual(Pos{ .x = 100, .y = 100 }, clampPos(100, 100, 200, 150, 1920, 1080));
    try std.testing.expectEqual(Pos{ .x = 1720, .y = 930 }, clampPos(1900, 1070, 200, 150, 1920, 1080));
    try std.testing.expectEqual(Pos{ .x = 0, .y = 0 }, clampPos(0, 0, 200, 150, 1920, 1080));
}

test "clampPos never returns a negative offset on a tiny screen" {
    const Pos = Position;
    try std.testing.expectEqual(Pos{ .x = 0, .y = 0 }, clampPos(50, 50, 400, 300, 320, 200));
}

test "placeMenu opens upward when the icon sits in the lower half" {
    const anchor = Rect{ .x = 100, .y = 1050, .w = 22, .h = 22 };
    try std.testing.expectEqual(Position{ .x = 100, .y = 788 }, placeMenu(anchor, 200, 262, 1920, 1080));
}

test "placeMenu opens downward when the icon sits in the upper half" {
    const anchor = Rect{ .x = 100, .y = 0, .w = 22, .h = 22 };
    try std.testing.expectEqual(Position{ .x = 100, .y = 22 }, placeMenu(anchor, 200, 262, 1920, 1080));
}

test "placeMenu flips left when the icon is near the right edge" {
    const anchor = Rect{ .x = 1900, .y = 1050, .w = 22, .h = 22 };
    try std.testing.expectEqual(Position{ .x = 1720, .y = 788 }, placeMenu(anchor, 200, 262, 1920, 1080));
}

test "placeMenu clamps a menu taller than the space above the icon" {
    const anchor = Rect{ .x = 100, .y = 1050, .w = 22, .h = 22 };
    try std.testing.expectEqual(Position{ .x = 100, .y = 0 }, placeMenu(anchor, 200, 1200, 1920, 1080));
}

test "placeMenu clamps a menu larger than the screen to the origin" {
    const anchor = Rect{ .x = 500, .y = 500, .w = 22, .h = 22 };
    try std.testing.expectEqual(Position{ .x = 0, .y = 0 }, placeMenu(anchor, 2000, 1200, 1920, 1080));
}
