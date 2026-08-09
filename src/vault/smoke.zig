//! Vault v1 smoke driver: the goal's smoke sequence executed against a
//! REAL file with real crypto, outside any test framework so the shell
//! runner can drive it and assert on the produced bytes.
//!
//! Usage: smoke <vault-path> [m_cost_kib]
//! Prints one PASS/FAIL line per objective item and exits non-zero on
//! the first failure. The runner then validates the file's header
//! bytes with od/xxd (magic, version, length bounds).
//!
//! The smoke uses CHEAP kdf params (m=8 KiB, t=1) by default: the
//! sequence still exercises real Argon2id + XChaCha20-Poly1305 + the
//! atomic writer, but stays fast enough for CI. Default parameters
//! (19 MiB, t=2) are opt-in via argv[2] for a heavier soak.

const std = @import("std");
const vault = @import("vault.zig");

var io_instance: std.Io.Threaded = undefined;

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;

    var args = try std.process.Args.Iterator.initAllocator(init.args, gpa);
    defer args.deinit();
    _ = args.next(); // argv[0]
    const path = args.next() orelse {
        std.debug.print("usage: smoke <vault-path> [m_cost_kib]\n", .{});
        std.process.exit(1);
    };
    const m_cost: u32 = if (args.next()) |m| try std.fmt.parseInt(u32, m, 10) else 8 * 1024;
    const params = vault.KdfParams{ .m_cost = m_cost, .t_cost = 1, .p_cost = 1 };

    io_instance = std.Io.Threaded.init(gpa, .{});
    const io = io_instance.io();

    const payload = "minimal payload";
    const next_pw = "next master password";

    var s = try vault.Session.init(io, gpa, path);
    defer s.deinit();

    // The driver owns its path: a stale vault from a previous run must
    // not abort the sequence with AlreadyExists.
    if (std.fs.path.dirname(path)) |dirname| {
        var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dirname, .{}) catch null;
        if (dir) |*d| {
            d.deleteFile(io, std.fs.path.basename(path)) catch {};
            d.close(io);
        }
    }

    // 1. create
    try s.create("initial password", params);
    print("PASS create\n", .{});

    // 2. unlock reads the empty vault
    const first = try s.unlock("initial password");
    if (first.len != 0) fail("unlock after create is not empty");
    print("PASS unlock-first\n", .{});

    // 3. save the minimal payload
    try s.save(payload);
    print("PASS save\n", .{});

    // 4. lock
    s.lock();
    if (s.unlocked) fail("lock left the session unlocked");
    print("PASS lock\n", .{});

    // 5. re-unlock reads the same payload byte-identical
    const got = try s.unlock("initial password");
    if (!std.mem.eql(u8, got, payload)) fail("re-unlock payload mismatch");
    print("PASS re-unlock-read\n", .{});

    // 6. wrong password fails cleanly
    const bad = s.unlock("not the password");
    if (bad != error.WrongPassword) fail("wrong password did not fail cleanly");
    if (s.unlocked) fail("wrong password left the session unlocked");
    print("PASS wrong-password\n", .{});

    // 7. change password rewraps the DEK without re-encrypting: the
    // payload region (nonce + ciphertext) is byte-identical on disk.
    // (The failed attempt above left the session locked — by design.)
    _ = try s.unlock("initial password");
    const before = readAll(io, gpa, path) catch fail("read before change");
    defer gpa.free(before);
    try s.changePassword("initial password", next_pw);
    const after = readAll(io, gpa, path) catch fail("read after change");
    defer gpa.free(after);
    if (!std.mem.eql(u8, before[vault.header_len..], after[vault.header_len..])) {
        fail("change password re-encrypted the payload region");
    }
    if (std.mem.eql(u8, before[0..vault.header_len], after[0..vault.header_len])) {
        fail("change password did not touch the header region");
    }
    print("PASS rewrap-no-reencrypt\n", .{});

    // 8. new password opens, old one no longer does
    s.lock();
    const still = try s.unlock(next_pw);
    if (!std.mem.eql(u8, still, payload)) fail("new password read mismatch");
    s.lock();
    const stale = s.unlock("initial password");
    if (stale != error.WrongPassword) fail("old password still opens the vault");
    print("PASS password-rotation\n", .{});
}

fn fail(msg: []const u8) noreturn {
    std.debug.print("FAIL {s}\n", .{msg});
    std.process.exit(1);
}

fn print(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt ++ "\n", args);
}

fn readAll(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const dirname = std.fs.path.dirname(path) orelse ".";
    var dir = try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dirname, .{});
    defer dir.close(io);
    var file = try dir.openFile(io, std.fs.path.basename(path), .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const out = try gpa.alloc(u8, @intCast(stat.size));
    errdefer gpa.free(out);
    const n = try file.readPositionalAll(io, out, 0);
    if (n != out.len) return error.Io;
    return out;
}
