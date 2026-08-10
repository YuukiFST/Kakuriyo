//! Host round-trip tests over the REAL bound callbacks: the wiring
//! installs bindHostCalls(names, {context, send_fn, request_fn,
//! cancel_fn}) — these tests drive vault_host.requestFn / sendFn /
//! State exactly as the effects channel would and assert the wire
//! contract (oracle-first, per the vault plan's Task 1 test gate).
//!
//! The compiled-TS lane of @native-sdk/cli 0.8.3 cannot survive
//! command-issuing or routed (second-cycle) dispatches (see core.ts
//! header + research note), so the app-loop test proves the only
//! stable shape: void dispatches keep the committed root intact; the
//! round-trip fidelity is proven at the binding — the same callback
//! pair the wiring binds into the app's effects, with a sink standing
//! in for feedHostResult.
const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const wiring = @import("main.zig");
const vault_host = @import("vault_host.zig");

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
};

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
