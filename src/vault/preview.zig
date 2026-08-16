//! Link preview — parse OG/Twitter/HTML title from fetched HTML.
//! Privacy: no Referer, short UA, capped body read.
//! Fetch returns allocator-owned strings; network budget defaults to 800ms.

const std = @import("std");

pub const Preview = struct {
    title: []const u8 = "",
    description: []const u8 = "",
    image_url: []const u8 = "",
};

/// Heap-owned preview strings. Caller must `deinit`.
pub const OwnedPreview = struct {
    title: []u8,
    description: []u8,
    image_url: []u8,
    image: []u8,

    pub fn deinit(self: *OwnedPreview, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.image_url);
        if (self.image.len > 0) allocator.free(self.image);
        self.* = undefined;
    }
};

pub const max_body_bytes: usize = 512 * 1024;
pub const max_image_bytes: usize = 128 * 1024;
pub const user_agent = "Kakuriyo/0.1";
/// Hard budget for network Preview fetch (Save / Refresh). Select path never fetches.
pub const fetch_budget_ms: u32 = 800;

pub fn acceptImageBytes(len: usize) bool {
    return len > 0 and len <= max_image_bytes;
}

pub fn parseHtml(html: []const u8) Preview {
    var out: Preview = .{};
    if (extractMetaContent(html, "og:title")) |t| out.title = t;
    if (extractMetaContent(html, "og:description")) |d| out.description = d;
    if (out.title.len == 0) {
        if (extractMetaContent(html, "twitter:title")) |t| out.title = t;
    }
    if (out.description.len == 0) {
        if (extractMetaContent(html, "twitter:description")) |d| out.description = d;
    }
    if (out.title.len == 0) {
        if (extractTagText(html, "title")) |t| out.title = t;
    }
    if (out.description.len == 0) {
        if (extractMetaName(html, "description")) |d| out.description = d;
    }
    if (extractMetaContent(html, "og:image")) |img| {
        out.image_url = img;
    } else if (extractMetaContent(html, "twitter:image")) |img| {
        out.image_url = img;
    }
    return out;
}

fn extractMetaContent(html: []const u8, property: []const u8) ?[]const u8 {
    var offset: usize = 0;
    while (offset < html.len) {
        const tag_start = std.mem.indexOfScalarPos(u8, html, offset, '<') orelse break;
        const tag_end = std.mem.indexOfScalarPos(u8, html, tag_start, '>') orelse break;
        const tag = html[tag_start + 1 .. tag_end];
        if (!startsWithIgnoreCase(tag, "meta")) {
            offset = tag_end + 1;
            continue;
        }
        if (!tagHasAttr(tag, "property", property) and !tagHasAttr(tag, "name", property)) {
            offset = tag_end + 1;
            continue;
        }
        if (attrValue(tag, "content")) |val| return trimQuotes(val);
        offset = tag_end + 1;
    }
    return null;
}

fn extractMetaName(html: []const u8, name: []const u8) ?[]const u8 {
    return extractMetaContent(html, name);
}

fn extractTagText(html: []const u8, tag: []const u8) ?[]const u8 {
    var search_buf: [32]u8 = undefined;
    const open = std.fmt.bufPrint(&search_buf, "<{s}", .{tag}) catch return null;
    const start = std.mem.indexOf(u8, html, open) orelse return null;
    const content_start = std.mem.indexOfScalarPos(u8, html, start, '>') orelse return null;
    var close_buf: [32]u8 = undefined;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;
    const end = std.mem.indexOfPos(u8, html, content_start + 1, close) orelse return null;
    return trimAscii(html[content_start + 1 .. end]);
}

fn tagHasAttr(tag: []const u8, attr: []const u8, value: []const u8) bool {
    if (attrValue(tag, attr)) |v| {
        return std.ascii.eqlIgnoreCase(trimQuotes(v), value);
    }
    return false;
}

fn attrValue(tag: []const u8, attr: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < tag.len) {
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) i += 1;
        const name_start = i;
        while (i < tag.len and tag[i] != '=' and !std.ascii.isWhitespace(tag[i])) i += 1;
        const name = tag[name_start..i];
        if (!std.ascii.eqlIgnoreCase(name, attr)) {
            while (i < tag.len and tag[i] != ' ') i += 1;
            continue;
        }
        while (i < tag.len and tag[i] != '=') i += 1;
        if (i >= tag.len) return null;
        i += 1;
        const quote = if (i < tag.len and (tag[i] == '"' or tag[i] == '\'')) tag[i] else 0;
        if (quote != 0) {
            i += 1;
            const val_start = i;
            while (i < tag.len and tag[i] != quote) i += 1;
            return tag[val_start..i];
        }
        const val_start = i;
        while (i < tag.len and !std.ascii.isWhitespace(tag[i])) i += 1;
        return tag[val_start..i];
    }
    return null;
}

fn trimQuotes(s: []const u8) []const u8 {
    return trimAscii(s);
}

fn trimAscii(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn startsWithIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (hay.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(hay[0..needle.len], needle);
}

pub const FetchError = error{
    InvalidUrl,
    NetworkFailed,
    TooLarge,
    Unsupported,
    OutOfMemory,
    TimedOut,
};

fn dupePreview(allocator: std.mem.Allocator, parsed: Preview) FetchError!OwnedPreview {
    const title = allocator.dupe(u8, parsed.title) catch return error.OutOfMemory;
    errdefer allocator.free(title);
    const description = allocator.dupe(u8, parsed.description) catch return error.OutOfMemory;
    errdefer allocator.free(description);
    const image_url = allocator.dupe(u8, parsed.image_url) catch return error.OutOfMemory;
    errdefer allocator.free(image_url);
    return .{ .title = title, .description = description, .image_url = image_url, .image = &.{} };
}

fn fetchGetBody(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    cap: usize,
) FetchError![]u8 {
    if (url.len == 0 or (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://"))) {
        return error.InvalidUrl;
    }
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var request = client.request(.GET, uri, .{
        .keep_alive = false,
        .redirect_behavior = @enumFromInt(3),
        .extra_headers = &.{
            .{ .name = "user-agent", .value = user_agent },
        },
    }) catch return error.NetworkFailed;
    defer request.deinit();
    request.sendBodiless() catch return error.NetworkFailed;
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = request.receiveHead(&redirect_buffer) catch return error.NetworkFailed;
    if (response.head.status != .ok) return error.NetworkFailed;

    const buf = allocator.alloc(u8, cap + 1) catch return error.OutOfMemory;
    errdefer allocator.free(buf);
    var transfer_buffer: [4096]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var body_writer = std.Io.Writer.fixed(buf);
    _ = reader.streamRemaining(&body_writer) catch |err| switch (err) {
        error.WriteFailed => {},
        else => return error.NetworkFailed,
    };
    const n = body_writer.end;
    if (n > cap) {
        allocator.free(buf);
        return error.TooLarge;
    }
    const out = allocator.dupe(u8, buf[0..n]) catch {
        allocator.free(buf);
        return error.OutOfMemory;
    };
    allocator.free(buf);
    return out;
}

fn fetchPreviewUnbudgeted(io: std.Io, allocator: std.mem.Allocator, url: []const u8) FetchError!OwnedPreview {
    const html = fetchGetBody(io, allocator, url, max_body_bytes) catch |err| switch (err) {
        error.TooLarge => return error.TooLarge,
        else => return err,
    };
    defer allocator.free(html);
    const parsed = parseHtml(html);
    var owned = try dupePreview(allocator, parsed);
    errdefer owned.deinit(allocator);

    if (owned.image_url.len == 0) return owned;
    const image = fetchGetBody(io, allocator, owned.image_url, max_image_bytes) catch {
        return owned;
    };
    if (!acceptImageBytes(image.len)) {
        allocator.free(image);
        return owned;
    }
    owned.image = image;
    return owned;
}

/// Fetch with hard wall-clock budget. On timeout returns `error.TimedOut` and
/// cancels the in-flight request (best-effort at next Io cancel point).
pub fn fetchPreviewBudget(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    budget_ms: u32,
) FetchError!OwnedPreview {
    const Slot = struct {
        result: ?FetchError!OwnedPreview = null,

        fn work(self: *@This(), work_io: std.Io, work_allocator: std.mem.Allocator, work_url: []const u8) void {
            self.result = fetchPreviewUnbudgeted(work_io, work_allocator, work_url);
        }
    };
    var slot: Slot = .{};
    var future = io.concurrent(Slot.work, .{ &slot, io, allocator, url }) catch {
        // Single-threaded Io: cannot enforce wall budget; still return owned strings.
        return fetchPreviewUnbudgeted(io, allocator, url);
    };

    var waited_ms: u32 = 0;
    const step_ms: u32 = 25;
    while (waited_ms < budget_ms) {
        if (slot.result != null) {
            future.await(io);
            return slot.result.?;
        }
        io.sleep(.fromMilliseconds(step_ms), .real) catch {
            _ = future.cancel(io);
            if (slot.result) |r| return r;
            return error.TimedOut;
        };
        waited_ms += step_ms;
    }
    if (slot.result != null) {
        future.await(io);
        return slot.result.?;
    }
    _ = future.cancel(io);
    if (slot.result) |r| return r;
    return error.TimedOut;
}

pub fn fetchPreview(io: std.Io, allocator: std.mem.Allocator, url: []const u8) FetchError!OwnedPreview {
    return fetchPreviewBudget(io, allocator, url, fetch_budget_ms);
}

test "parse og title and description" {
    const html =
        \\<html><head>
        \\<meta property="og:title" content="Example Site" />
        \\<meta property="og:description" content="A demo page" />
        \\<title>Ignored</title>
        \\</head></html>
    ;
    const p = parseHtml(html);
    try std.testing.expectEqualStrings("Example Site", p.title);
    try std.testing.expectEqualStrings("A demo page", p.description);
}

test "parseHtml extracts og:image" {
    const html =
        \\<html><head>
        \\<meta property="og:title" content="Example Site" />
        \\<meta property="og:image" content="https://cdn.example/img.jpg" />
        \\</head></html>
    ;
    const p = parseHtml(html);
    try std.testing.expectEqualStrings("https://cdn.example/img.jpg", p.image_url);
}

test "image bytes over 128KiB are discarded" {
    try std.testing.expect(acceptImageBytes(128 * 1024));
    try std.testing.expect(!acceptImageBytes(128 * 1024 + 1));
    try std.testing.expect(!acceptImageBytes(0));
}

test "falls back to title tag" {
    const html = "<html><head><title>Hello</title></head></html>";
    const p = parseHtml(html);
    try std.testing.expectEqualStrings("Hello", p.title);
}

test "twitter fallback" {
    const html = "<meta name=\"twitter:title\" content=\"Tw\" />";
    const p = parseHtml(html);
    try std.testing.expectEqualStrings("Tw", p.title);
}

test "dupePreview owns strings independent of html buffer" {
    var html_buf = "<html><head><title>Owned</title><meta name=\"description\" content=\"Desc\" /></head></html>".*;
    const parsed = parseHtml(&html_buf);
    var owned = try dupePreview(std.testing.allocator, parsed);
    defer owned.deinit(std.testing.allocator);
    @memset(&html_buf, 'x');
    try std.testing.expectEqualStrings("Owned", owned.title);
    try std.testing.expectEqualStrings("Desc", owned.description);
}

test "fetch budget times out against documentation blackhole" {
    // Requires Io concurrency so the wall budget can cancel a hung connect.
    // TEST-NET-1 (192.0.2.0/24) — should not be routed.
    const io = std.testing.io;
    const Nop = struct {
        fn work() void {}
    };
    var probe = io.concurrent(Nop.work, .{}) catch return error.SkipZigTest;
    probe.await(io);

    const start = std.Io.Timestamp.now(io, .real);
    const result = fetchPreviewBudget(io, std.testing.allocator, "http://192.0.2.1:9/", 200);
    const elapsed_ms = start.durationTo(std.Io.Timestamp.now(io, .real)).toMilliseconds();
    if (result) |owned| {
        var o = owned;
        o.deinit(std.testing.allocator);
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.TimedOut, error.NetworkFailed => try std.testing.expect(elapsed_ms < 2000),
        else => return error.TestUnexpectedResult,
    }
}
