const std = @import("std");

// Prefix only. The percent-encoded query is appended, so the value must end
// where the query belongs. `?q=` is Google's parameter for it.
pub const default_search_base_url = "https://www.google.com/search?q=";

// Windows URL handlers truncate long URLs. A query that exceeds this bound
// came from an accidental long dictation, not from speech meant as a search.
pub const max_url_len: usize = 2048;

// RFC 3986 unreserved characters survive percent-encoding unchanged. Every
// other byte is escaped, so a query cannot inject extra parameters into the
// base URL's own query string.
fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

// Returns an owned slice. The caller frees it.
pub fn buildSearchUrl(gpa: std.mem.Allocator, base_url: []const u8, query: []const u8) ![]u8 {
    // Each query byte becomes at most three characters (`%XX`). Check the
    // worst case first so an oversized query allocates nothing.
    if (base_url.len > max_url_len) return error.UrlTooLong;
    if (query.len > (max_url_len - base_url.len) / 3) return error.UrlTooLong;

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll(base_url);
    try std.Uri.Component.percentEncode(&out.writer, query, isUnreserved);
    return out.toOwnedSlice();
}

test "buildSearchUrl appends the encoded query to the default prefix" {
    const gpa = std.testing.allocator;
    const url = try buildSearchUrl(gpa, default_search_base_url, "pizza near me");
    defer gpa.free(url);
    try std.testing.expectEqualStrings("https://www.google.com/search?q=pizza%20near%20me", url);
}

test "buildSearchUrl escapes query syntax so it cannot add parameters" {
    const gpa = std.testing.allocator;
    const url = try buildSearchUrl(gpa, default_search_base_url, "a&b=c?d#e%f+g");
    defer gpa.free(url);
    try std.testing.expectEqualStrings("https://www.google.com/search?q=a%26b%3Dc%3Fd%23e%25f%2Bg", url);
}

test "buildSearchUrl leaves unreserved characters unchanged" {
    const gpa = std.testing.allocator;
    const url = try buildSearchUrl(gpa, default_search_base_url, "AZaz09-._~");
    defer gpa.free(url);
    try std.testing.expectEqualStrings("https://www.google.com/search?q=AZaz09-._~", url);
}

test "buildSearchUrl encodes UTF-8 one byte at a time" {
    const gpa = std.testing.allocator;
    const url = try buildSearchUrl(gpa, default_search_base_url, "é");
    defer gpa.free(url);
    try std.testing.expectEqualStrings("https://www.google.com/search?q=%C3%A9", url);
}

test "buildSearchUrl keeps a base URL that already has parameters" {
    const gpa = std.testing.allocator;
    const url = try buildSearchUrl(gpa, "https://example.test/s?lang=en&q=", "a b");
    defer gpa.free(url);
    try std.testing.expectEqualStrings("https://example.test/s?lang=en&q=a%20b", url);
}

test "buildSearchUrl rejects a result over max_url_len" {
    const gpa = std.testing.allocator;
    var query: [max_url_len]u8 = undefined;
    @memset(&query, 'a');
    try std.testing.expectError(error.UrlTooLong, buildSearchUrl(gpa, default_search_base_url, &query));
}
