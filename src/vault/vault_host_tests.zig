//! Task 3 oracles: the full `vault.*` protocol over framed payloads.
//! Written before the dispatch existed (plan Task 3 Step 1); the
//! baseline failure state was recorded in the plan.
//!
//! Protocol pinned here:
//!   request payload = field list  [n_fields:u8] { [len:u32be] [bytes] }*
//!   ok route        = op result bytes (vault.unlock -> plaintext payload)
//!   err route       = ASCII error code
//!   vault.lock rides sendFn (Cmd.host, fire-and-forget).

const std = @import("std");
const testing = std.testing;
const vault_host = @import("vault_host.zig");

/// Recording sink: copies every (key, ok, bytes) answer into a fixed
/// buffer — the sink contract only guarantees `bytes` for the duration
/// of the call, and each request must produce exactly one answer.
const Recorder = struct {
    buf: [32][512]u8 = undefined,
    keys: [32]u64 = undefined,
    oks: [32]bool = undefined,
    lens: [32]usize = undefined,
    count: usize = 0,

    fn resultFn(ctx: *anyopaque, key: u64, ok: bool, bytes: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        const i = self.count;
        self.keys[i] = key;
        self.oks[i] = ok;
        self.lens[i] = @min(bytes.len, 512);
        @memcpy(self.buf[i][0..self.lens[i]], bytes[0..self.lens[i]]);
        self.count += 1;
    }

    fn last(self: *const Recorder) struct { ok: bool, bytes: []const u8 } {
        testing.expect(self.count > 0) catch unreachable;
        const i = self.count - 1;
        return .{ .ok = self.oks[i], .bytes = self.buf[i][0..self.lens[i]] };
    }

    fn countFor(self: *const Recorder, key: u64) usize {
        var n: usize = 0;
        for (self.keys[0..self.count]) |k| {
            if (k == key) {
                n += 1;
            }
        }
        return n;
    }
};

fn request(rec: *Recorder, state: *vault_host.State, name: []const u8, key: u64, payload: []const u8) void {
    _ = rec; // the recorder is asserted through `state`'s sink
    vault_host.requestFn(state, name, key, payload);
}

/// One framed request with a frame owned for exactly the call.
fn reqFrame(gpa: std.mem.Allocator, rec: *Recorder, state: *vault_host.State, name: []const u8, key: u64, fields: []const []const u8) !void {
    const f = try frame(gpa, fields);
    defer gpa.free(f);
    request(rec, state, name, key, f);
}

fn send(rec: *Recorder, state: *vault_host.State, name: []const u8, payload: []const u8) void {
    _ = rec;
    vault_host.sendFn(state, name, payload);
}

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

const TestDir = struct {
    tmp: testing.TmpDir,
    path: []u8,

    fn create(gpa: std.mem.Allocator) !TestDir {
        const tmp = testing.tmpDir(.{});
        // tmpDir's sub_path is the random LEAF; the dir physically
        // lives under .zig-cache/tmp/ (cwd-relative).
        const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *TestDir, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        self.tmp.dir.close(testing.io);
    }
};

fn makeState(gpa: std.mem.Allocator, rec: *Recorder, td: *TestDir) !vault_host.State {
    return vault_host.State.init(testing.io, gpa, td.path, .{
        .result_ctx = rec,
        .result_fn = Recorder.resultFn,
    });
}

test "create, unlock, save, lock lifecycle through dispatch" {
    const gpa = testing.allocator;
    var td = try TestDir.create(gpa);
    defer td.deinit(gpa);

    var rec = Recorder{};
    var state = try makeState(gpa, &rec, &td);
    defer state.deinit();

    // create(pw) -> ok, empty result
    try reqFrame(gpa, &rec, &state, "vault.create", 1, &.{"pw"});
    var got = rec.last();
    try testing.expect(got.ok);
    try testing.expectEqual(@as(usize, 0), got.bytes.len);

    // save(payload) -> ok
    try reqFrame(gpa, &rec, &state, "vault.save", 2, &.{"first payload"});
    got = rec.last();
    try testing.expect(got.ok);

    // lock via sendFn (fire-and-forget, no result route)
    send(&rec, &state, "vault.lock", "");
    try testing.expect(!state.session.unlocked);

    // unlock(pw) -> ok with the plaintext payload back
    try reqFrame(gpa, &rec, &state, "vault.unlock", 3, &.{"pw"});
    got = rec.last();
    try testing.expect(got.ok);
    try testing.expectEqualStrings("first payload", got.bytes);
}

test "wrong password maps to wrong_password" {
    const gpa = testing.allocator;
    var td = try TestDir.create(gpa);
    defer td.deinit(gpa);

    var rec = Recorder{};
    var state = try makeState(gpa, &rec, &td);
    defer state.deinit();

    try reqFrame(gpa, &rec, &state, "vault.create", 1, &.{"pw"});

    try reqFrame(gpa, &rec, &state, "vault.unlock", 2, &.{"wrong"});
    const got = rec.last();
    try testing.expect(!got.ok);
    try testing.expectEqualStrings("wrong_password", got.bytes);
}

test "unknown host name rejects; unknown sendFn name is a silent no-op" {
    const gpa = testing.allocator;
    var td = try TestDir.create(gpa);
    defer td.deinit(gpa);

    var rec = Recorder{};
    var state = try makeState(gpa, &rec, &td);
    defer state.deinit();

    request(&rec, &state, "vault.nope", 1, "");
    const got = rec.last();
    try testing.expect(!got.ok);
    try testing.expectEqualStrings("unknown", got.bytes);

    // sendFn has no result route: unknown names must not crash or
    // answer; the session must remain untouched.
    send(&rec, &state, "vault.nope", "payload");
    send(&rec, &state, "vault.lock", "ignored payload");
    try testing.expect(!state.session.unlocked);
    try testing.expectEqual(@as(usize, 0), rec.countFor(999));
}

test "malformed frames map to bad_request with exactly one answer" {
    const gpa = testing.allocator;
    var td = try TestDir.create(gpa);
    defer td.deinit(gpa);

    var rec = Recorder{};
    var state = try makeState(gpa, &rec, &td);
    defer state.deinit();

    const cases = [_][]const u8{
        "", // no frame at all
        &.{0}, // zero fields
        &.{ 2, 0, 0, 0, 1, 'a' }, // declared 2, one present
        &.{ 1, 0xff, 0xff, 0xff, 0xff, 'a' }, // len overruns payload
        &.{9}, // n_fields garbage (> 8)
        &.{ 1, 0, 0, 0, 3, 'a', 'b' }, // declared len 3, 2 present
    };
    for (cases, 0..) |c, i| {
        request(&rec, &state, "vault.create", 10 + i, c);
        const got = rec.last();
        try testing.expect(!got.ok);
        try testing.expectEqualStrings("bad_request", got.bytes);
        try testing.expectEqual(@as(usize, 1), rec.countFor(10 + i));
    }
}

test "save while locked maps to locked" {
    const gpa = testing.allocator;
    var td = try TestDir.create(gpa);
    defer td.deinit(gpa);

    var rec = Recorder{};
    var state = try makeState(gpa, &rec, &td);
    defer state.deinit();

    try reqFrame(gpa, &rec, &state, "vault.create", 1, &.{"pw"});

    try reqFrame(gpa, &rec, &state, "vault.save", 2, &.{"data"});
    try testing.expect(rec.last().ok);

    send(&rec, &state, "vault.lock", "");
    try reqFrame(gpa, &rec, &state, "vault.save", 3, &.{"data"});
    const got = rec.last();
    try testing.expect(!got.ok);
    try testing.expectEqualStrings("locked", got.bytes);
}

test "create on an existing vault maps to already_exists" {
    const gpa = testing.allocator;
    var td = try TestDir.create(gpa);
    defer td.deinit(gpa);

    var rec = Recorder{};
    var state = try makeState(gpa, &rec, &td);
    defer state.deinit();

    const f = try frame(gpa, &.{"pw"});
    defer gpa.free(f);
    request(&rec, &state, "vault.create", 1, f);
    try testing.expect(rec.last().ok);

    request(&rec, &state, "vault.create", 2, f);
    const got = rec.last();
    try testing.expect(!got.ok);
    try testing.expectEqualStrings("already_exists", got.bytes);
}

test "missing vault maps to not_found" {
    const gpa = testing.allocator;
    var td = try TestDir.create(gpa);
    defer td.deinit(gpa);

    var rec = Recorder{};
    var state = try makeState(gpa, &rec, &td);
    defer state.deinit();

    const f = try frame(gpa, &.{"pw"});
    defer gpa.free(f);
    request(&rec, &state, "vault.unlock", 1, f);
    const got = rec.last();
    try testing.expect(!got.ok);
    try testing.expectEqualStrings("not_found", got.bytes);
}

test "change password via dispatch rewraps" {
    const gpa = testing.allocator;
    var td = try TestDir.create(gpa);
    defer td.deinit(gpa);

    var rec = Recorder{};
    var state = try makeState(gpa, &rec, &td);
    defer state.deinit();

    try reqFrame(gpa, &rec, &state, "vault.create", 1, &.{"pw"});

    try reqFrame(gpa, &rec, &state, "vault.save", 2, &.{"still here"});

    // change_password(current, next) -> ok
    try reqFrame(gpa, &rec, &state, "vault.change_password", 3, &.{ "pw", "pw2" });
    var got = rec.last();
    try testing.expect(got.ok);

    // wrong current -> wrong_password
    try reqFrame(gpa, &rec, &state, "vault.change_password", 4, &.{ "pw", "pw3" });
    got = rec.last();
    try testing.expect(!got.ok);
    try testing.expectEqualStrings("wrong_password", got.bytes);

    // full lifecycle: lock, unlock with the NEW password, read payload
    send(&rec, &state, "vault.lock", "");
    try reqFrame(gpa, &rec, &state, "vault.unlock", 5, &.{"pw2"});
    got = rec.last();
    try testing.expect(got.ok);
    try testing.expectEqualStrings("still here", got.bytes);
}

test "failing ops never leave the session unlocked" {
    const gpa = testing.allocator;
    var td = try TestDir.create(gpa);
    defer td.deinit(gpa);

    var rec = Recorder{};
    var state = try makeState(gpa, &rec, &td);
    defer state.deinit();

    const f = try frame(gpa, &.{"pw"});
    defer gpa.free(f);

    // A failing op from the locked state stays locked and the next
    // correct unlock still works — nothing leaks across ops.
    request(&rec, &state, "vault.create", 1, f); // ok, unlocked
    try testing.expect(state.session.unlocked);
    send(&rec, &state, "vault.lock", "");

    // Wrong-password unlock from the locked state stays locked.
    const bad = try frame(gpa, &.{"wrong"});
    defer gpa.free(bad);
    request(&rec, &state, "vault.unlock", 3, bad);
    try testing.expect(!rec.last().ok);
    try testing.expect(!state.session.unlocked);

    const data = try frame(gpa, &.{"data"});
    defer gpa.free(data);
    request(&rec, &state, "vault.save", 4, data); // still locked
    try testing.expect(!rec.last().ok);

    request(&rec, &state, "vault.change_password", 5, bad); // locked
    try testing.expect(!rec.last().ok);

    // And the correct unlock still works.
    request(&rec, &state, "vault.unlock", 6, f);
    const got = rec.last();
    try testing.expect(got.ok);
    try testing.expectEqual(@as(usize, 0), got.bytes.len);
    try testing.expect(state.session.unlocked);
}
