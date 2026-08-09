//! The vault host service: dispatch for `vault.*` names arriving from
//! the TS core over the effects channel (HostCallBinding). Pure std —
//! the wiring builds the binding type; this module only declares the
//! fn-pointer-shaped callbacks and the State the wiring allocates.
//!
//! Protocol (pinned in docs/superpowers/plans/2026-08-09-vault-v1-envelope.md):
//!   request payload = field list  [n_fields:u8] { [len:u32be] [bytes] }*
//!   ok route   = op result bytes (vault.unlock: plaintext payload)
//!   err route  = ASCII error code ("wrong_password", "not_found", ...)
//!   vault.lock rides Cmd.host (sendFn, fire-and-forget).
//!
//! Task 1 lands the seam with a single echo op (vault.ping); the full
//! op table (create/unlock/save/change_password/lock) lands in Task 3.

const std = @import("std");
const vault = @import("vault.zig");

/// How the wiring answers a request: points at the effects channel's
/// feedHostResult. `bytes` is only valid for the duration of the call.
pub const ResultFn = *const fn (ctx: *anyopaque, key: u64, ok: bool, bytes: []const u8) void;

pub const ResultSink = struct {
    result_ctx: *anyopaque,
    result_fn: ResultFn,
};

/// Host-side vault session state; lives as long as the app (allocated by
/// the wiring, deinit on shutdown).
pub const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8, // owned copy
    sink: ResultSink,
    /// Fire-and-forget ping observations (sendFn), for the round-trip
    /// oracle: the TS core's Cmd.host must reach this State.
    ping_count: usize = 0,
    /// Routed request observations (requestFn), same oracle role.
    request_count: usize = 0,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, path: []const u8, sink: ResultSink) error{OutOfMemory}!State {
        return .{
            .io = io,
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .sink = sink,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.path);
        self.* = undefined;
    }

    fn answer(self: *State, key: u64, ok: bool, bytes: []const u8) void {
        self.sink.result_fn(self.sink.result_ctx, key, ok, bytes);
    }
};

/// Fire-and-forget host commands (Cmd.host): only `vault.ping` is
/// observed (the round-trip oracle); anything else is a silent no-op
/// (no result route to reject into).
pub fn sendFn(context: *anyopaque, name: []const u8, payload: []const u8) void {
    _ = payload;
    const state: *State = @ptrCast(@alignCast(context));
    if (std.mem.eql(u8, name, "vault.ping")) state.ping_count += 1;
}

/// Keyed routed host commands (Cmd.request): answer exactly once via
/// the State's sink. Unknown names reject with "unknown".
pub fn requestFn(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
    const state: *State = @ptrCast(@alignCast(context));
    if (std.mem.eql(u8, name, "vault.ping")) {
        state.request_count += 1;
        state.answer(key, true, payload);
        return;
    }
    state.answer(key, false, "unknown");
}
