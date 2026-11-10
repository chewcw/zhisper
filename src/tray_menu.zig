const std = @import("std");
const types = @import("tray_types.zig");
const config = @import("config.zig");

pub const Submenu = types.Submenu;
pub const Action = types.Action;

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
