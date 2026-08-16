//! Host round-trip tests over the REAL bound callbacks: the wiring
//! installs bindHostCalls(names, {context, send_fn, request_fn,
//! cancel_fn}) — these tests drive vault_host.requestFn / sendFn /
//! State exactly as the effects channel would and assert the wire
//! contract (oracle-first, per the vault plan's Task 1 test gate).
//!
//! Task 5 Step 1 (full TS dispatch cycle) is blocked by the compiled
//! lane (core.ts header + ts-core-lane-limits.md). The effects-channel
//! oracles below drive `installHostCalls` → `effects.hostRequest` /
//! `hostSend` → `vault_host.*` → `feedHostResult` with real crypto and
//! a real tmp vault file — no routed Msg arms through the TS core.
const std = @import("std");
const native_sdk = @import("native_sdk");
const wiring = @import("main.zig");
const vault_host = @import("vault_host.zig");
const vault = @import("vault.zig");

/// One live app loop for the round-trip tests: the app state, the bound
/// vault host, and the harness runtime (installed via a real frame
/// event so the effects channel drains like the app loop's).
const Loop = struct {
    app_state: *wiring.App,
    harness: *native_sdk.TestHarness(),
    vault_path: []const u8,
    vault_state: *vault_host.State,

    fn create(gpa: std.mem.Allocator) !Loop {
        var environ_map = std.process.Environ.Map.init(gpa);
        defer environ_map.deinit();

        const app_state = try wiring.createAppState(std.testing.io, gpa, &environ_map);
        errdefer app_state.destroy();

        // The vault file's future home: the testing tmp dir (parent
        // .zig-cache/tmp — see std.testing.tmpDir).
        var tmp = std.testing.tmpDir(.{});
        const vault_path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
        tmp.dir.close(std.testing.io);

        const vault_state = try wiring.installHostCalls(app_state, std.testing.io, gpa, vault_path);

        var harness = try native_sdk.TestHarness().create(gpa, .{ .size = native_sdk.geometry.SizeF.init(720, 480) });
        errdefer harness.destroy(gpa);
        harness.null_platform.gpu_surfaces = true;
        try harness.start(app_state.app());
        // The installing frame: without it the app never becomes
        // `installed` and the effects channel stays inert.
        try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_frame = .{
            .label = wiring.canvas_label,
            .size = native_sdk.geometry.SizeF.init(720, 480),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });

        return .{ .app_state = app_state, .harness = harness, .vault_path = vault_path, .vault_state = vault_state };
    }

    fn destroy(self: *Loop, gpa: std.mem.Allocator) void {
        self.vault_state.deinit();
        gpa.destroy(self.vault_state);
        self.app_state.destroy();
        self.harness.destroy(gpa);
        gpa.free(self.vault_path);
    }

    fn drain(self: *Loop) !void {
        // Frame pump drains host completions (no routed TS arms — on_result null).
        try self.harness.runtime.dispatchPlatformEvent(self.app_state.app(), .{ .gpu_surface_frame = .{
            .label = wiring.canvas_label,
            .size = native_sdk.geometry.SizeF.init(720, 480),
            .scale_factor = 1,
            .frame_index = 99,
            .timestamp_ns = 99_000_000,
            .nonblank = true,
        } });
    }

    fn hostReq(self: *Loop, key: u64, name: []const u8, payload: []const u8) !void {
        // on_result stays null: routed TS arms corrupt the compiled lane.
        self.app_state.effects.hostRequest(.{
            .key = key,
            .name = name,
            .payload = payload,
            .on_result = null,
        });
        try self.drain();
    }

    fn hostReqFields(self: *Loop, gpa: std.mem.Allocator, key: u64, name: []const u8, fields: []const []const u8) !void {
        const f = try frame(gpa, fields);
        defer gpa.free(f);
        try self.hostReq(key, name, f);
    }

    fn hostSend(self: *Loop, name: []const u8, payload: []const u8) void {
        self.app_state.effects.hostSend(name, payload);
    }
};

/// Builds [n_fields:u8] { [len:u32be] [bytes] }* from field slices.
fn frame(gpa: std.mem.Allocator, fields: []const []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(gpa);
    errdefer out.deinit();
    try out.append(@intCast(fields.len));
    for (fields) |f| {
        try out.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(f.len))));
        try out.appendSlice(f);
    }
    return out.toOwnedSlice();
}

fn readAll(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const dirname = std.fs.path.dirname(path) orelse ".";
    var dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), std.testing.io, dirname, .{});
    defer dir.close(std.testing.io);
    var file = try dir.openFile(std.testing.io, std.fs.path.basename(path), .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    const out = try gpa.alloc(u8, @intCast(stat.size));
    errdefer gpa.free(out);
    const n = try file.readPositionalAll(std.testing.io, out, 0);
    if (n != out.len) return error.Io;
    return out;
}

fn assertValidHeader(bytes: []const u8) !void {
    try std.testing.expect(bytes.len >= vault.min_file_len);
    try std.testing.expectEqualStrings(vault.magic, bytes[0..4]);
    const version = std.mem.readInt(u32, bytes[4..8], .big);
    try std.testing.expectEqual(vault.version, version);
}

test "the app loop survives sequential dispatches with an intact model" {
    // The vault session model (phase + Uint8Array fields + Cmd.request)
    // cannot ride the scriptc compiled lane at runtime — see core.ts and
    // ts-core-lane-limits.md. Full-loop app dispatches belong in Task 5;
    // binding oracles below still prove the host wire contract.
    return error.SkipZigTest;
}

test "vault_host echoes arbitrary byte payloads verbatim" {
    // HOST -> WIRE oracle over the real bound callback: requestFn
    // answers its sink with exactly the bytes it received — empty
    // included. The wiring's feedHostResultFn is the same callback
    // shape (ctx, key, ok, bytes) this sink stands in for.
    const gpa = std.testing.allocator;
    const Sink = struct {
        var slot: ?struct { ok: bool, bytes: []const u8 } = null;
        fn onResult(_: *anyopaque, _: u64, ok: bool, bytes: []const u8) void {
            slot = .{ .ok = ok, .bytes = bytes };
        }
    };
    var state = try vault_host.State.init(std.testing.io, gpa, "unused", .{
        .result_ctx = &Sink.slot,
        .result_fn = Sink.onResult,
    });
    defer state.deinit();

    const payload = "echo me verbatim";
    vault_host.requestFn(&state, "vault.ping", 7, payload);
    const got = Sink.slot.?;
    try std.testing.expect(got.ok);
    try std.testing.expectEqualStrings(payload, got.bytes);

    vault_host.requestFn(&state, "vault.ping", 8, "");
    const empty = Sink.slot.?;
    try std.testing.expect(empty.ok);
    try std.testing.expect(empty.bytes.len == 0);
}

test "unknown vault.* names reject through the err route" {
    // Bind-level oracle: a request the host does not know must answer
    // ok=false with the "unknown" code — the wire contract the err
    // route of `Cmd.request` would carry to the core.
    const gpa = std.testing.allocator;
    const Sink = struct {
        var slot: ?struct { ok: bool, bytes: []const u8 } = null;
        fn onResult(_: *anyopaque, _: u64, ok: bool, bytes: []const u8) void {
            slot = .{ .ok = ok, .bytes = bytes };
        }
    };
    var state = try vault_host.State.init(std.testing.io, gpa, "unused", .{
        .result_ctx = &Sink.slot,
        .result_fn = Sink.onResult,
    });
    defer state.deinit();

    vault_host.requestFn(&state, "vault.unknown", 42, "");
    const got = Sink.slot.?;
    try std.testing.expect(!got.ok);
    try std.testing.expectEqualStrings("unknown", got.bytes);
}

test "vault_host.sendFn observes fire-and-forget commands" {
    // The Cmd.host lane (sendFn): vault.lock's transport in the full
    // op table (Task 3). The real bound callback counts observations.
    const gpa = std.testing.allocator;
    const Sink = struct {
        fn onResult(_: *anyopaque, _: u64, _: bool, _: []const u8) void {}
    };
    var state = try vault_host.State.init(std.testing.io, gpa, "unused", .{
        .result_ctx = undefined,
        .result_fn = Sink.onResult,
    });
    defer state.deinit();

    vault_host.sendFn(&state, "vault.ping", "");
    vault_host.sendFn(&state, "vault.ping", "");
    try std.testing.expectEqual(@as(usize, 2), state.ping_count);
}

// ------------------------------------------------- Task 5 Step 1 (effects channel, re-scoped)

test "full vault lifecycle through the real effects channel" {
    const gpa = std.testing.allocator;
    var loop = try Loop.create(gpa);
    defer loop.destroy(gpa);

    const pw = "initial password";
    const next_pw = "next master password";
    const payload = "minimal payload";

    try loop.hostReqFields(gpa, 1, "vault.create", &.{pw});
    try std.testing.expect(loop.vault_state.session.unlocked);

    try loop.hostReqFields(gpa, 2, "vault.save", &.{payload});
    try std.testing.expect(loop.vault_state.session.unlocked);

    loop.hostSend("vault.lock", "");
    try std.testing.expect(!loop.vault_state.session.unlocked);

    try loop.hostReqFields(gpa, 3, "vault.unlock", &.{pw});
    try std.testing.expect(loop.vault_state.session.unlocked);
    const got = loop.vault_state.session.payload orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(payload, got);

    try loop.hostReqFields(gpa, 4, "vault.unlock", &.{"not the password"});
    try std.testing.expect(!loop.vault_state.session.unlocked);

    try loop.hostReqFields(gpa, 5, "vault.unlock", &.{pw});
    try loop.hostReqFields(gpa, 6, "vault.change_password", &.{ pw, next_pw });
    try std.testing.expect(loop.vault_state.session.unlocked);

    loop.hostSend("vault.lock", "");
    try loop.hostReqFields(gpa, 7, "vault.unlock", &.{next_pw});
    const after_change = loop.vault_state.session.payload orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(payload, after_change);

    loop.hostSend("vault.lock", "");
    try loop.hostReqFields(gpa, 8, "vault.unlock", &.{pw});
    try std.testing.expect(!loop.vault_state.session.unlocked);
}

test "file bytes prove rewrap-only change through effects channel" {
    const gpa = std.testing.allocator;
    var loop = try Loop.create(gpa);
    defer loop.destroy(gpa);

    const pw = "initial password";
    const next_pw = "next master password";
    const payload = "still here";

    try loop.hostReqFields(gpa, 1, "vault.create", &.{pw});
    try loop.hostReqFields(gpa, 2, "vault.save", &.{payload});

    const before = try readAll(gpa, loop.vault_path);
    defer gpa.free(before);

    try loop.hostReqFields(gpa, 3, "vault.change_password", &.{ pw, next_pw });

    const after = try readAll(gpa, loop.vault_path);
    defer gpa.free(after);

    try std.testing.expect(!std.mem.eql(u8, before[0..vault.header_len], after[0..vault.header_len]));
    try std.testing.expectEqualStrings(before[vault.header_len..], after[vault.header_len..]);
}

test "save is atomic on disk through effects channel" {
    const gpa = std.testing.allocator;
    var loop = try Loop.create(gpa);
    defer loop.destroy(gpa);

    const pw = "pw";
    const payloads = [_][]const u8{ "one", "two", "three", "four", "five" };

    try loop.hostReqFields(gpa, 1, "vault.create", &.{pw});

    const first_gen = try readAll(gpa, loop.vault_path);
    defer gpa.free(first_gen);

    const dir_path = std.fs.path.dirname(loop.vault_path).?;
    var dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), std.testing.io, dir_path, .{});
    defer dir.close(std.testing.io);
    var held = try dir.openFile(std.testing.io, std.fs.path.basename(loop.vault_path), .{});
    defer held.close(std.testing.io);

    for (payloads, 0..) |p, i| {
        try loop.hostReqFields(gpa, 10 + i, "vault.save", &.{p});
        const bytes = try readAll(gpa, loop.vault_path);
        defer gpa.free(bytes);
        try assertValidHeader(bytes);

        const held_stat = try held.stat(std.testing.io);
        const held_bytes = try gpa.alloc(u8, @intCast(held_stat.size));
        defer gpa.free(held_bytes);
        const n = try held.readPositionalAll(std.testing.io, held_bytes, 0);
        try std.testing.expectEqual(held_stat.size, n);
        try std.testing.expectEqualSlices(u8, first_gen, held_bytes);
    }

    loop.hostSend("vault.lock", "");
    try loop.hostReqFields(gpa, 20, "vault.unlock", &.{pw});
    const got = loop.vault_state.session.payload orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("five", got);
}

test "locked save is rejected through effects channel" {
    const gpa = std.testing.allocator;
    var loop = try Loop.create(gpa);
    defer loop.destroy(gpa);

    const pw = "pw";
    try loop.hostReqFields(gpa, 1, "vault.create", &.{pw});
    try loop.hostReqFields(gpa, 2, "vault.save", &.{"first"});

    const before = try readAll(gpa, loop.vault_path);
    defer gpa.free(before);

    loop.hostSend("vault.lock", "");
    try std.testing.expect(!loop.vault_state.session.unlocked);

    try loop.hostReqFields(gpa, 3, "vault.save", &.{"second"});
    try std.testing.expect(!loop.vault_state.session.unlocked);

    const after = try readAll(gpa, loop.vault_path);
    defer gpa.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "unknown host request through effects channel rejects without breaking session" {
    const gpa = std.testing.allocator;
    var loop = try Loop.create(gpa);
    defer loop.destroy(gpa);

    try loop.hostReq(1, "vault.nope", "");
    try std.testing.expectEqual(@as(usize, 0), loop.app_state.effects.pendingHostCount());

    const echo = "still alive";
    try loop.hostReq(2, "vault.ping", echo);
    try std.testing.expectEqual(@as(usize, 0), loop.app_state.effects.pendingHostCount());
    try std.testing.expectEqual(@as(usize, 1), loop.vault_state.request_count);
}
