//! The vault host service: dispatch for `vault.*` names arriving from
//! the TS core over the effects channel (HostCallBinding). Pure std —
//! the wiring builds the binding type; this module only declares the
//! fn-pointer-shaped callbacks and the State the wiring allocates.
//!
//! Protocol (pinned in docs/superpowers/plans/2026-08-09-vault-v1-envelope.md):
//!   request payload = field list  [n_fields:u8] { [len:u32be] [bytes] }*
//!   ok route   = op result bytes (vault.unlock: plaintext payload,
//!                every other op: empty)
//!   err route  = ASCII error code:
//!       unknown | bad_request | wrong_password | not_found |
//!       already_exists | locked | corrupt | unsupported_version |
//!       password_invalid | params_invalid | payload_too_large |
//!       io | oom | internal
//!   vault.lock rides Cmd.host (sendFn, fire-and-forget).
//!   vault.ping is the Task 1 seam oracle: echoed verbatim, unframed.
//!
//! Answering discipline: every requestFn path answers exactly once —
//! the `answered` flag + defer guard turns any missed answer into
//! ok=false "internal" rather than a hung request.

const std = @import("std");
const vault = @import("vault.zig");

/// How the wiring answers a request: points at the effects channel's
/// feedHostResult. `bytes` is only valid for the duration of the call.
pub const ResultFn = *const fn (ctx: *anyopaque, key: u64, ok: bool, bytes: []const u8) void;

pub const ResultSink = struct {
    result_ctx: *anyopaque,
    result_fn: ResultFn,
};

/// Max fields a framed op may carry (create=1, unlock=1, save=1,
/// change_password=2); anything larger is malformed.
const max_fields = 8;

/// Bounds-checked field-list reader; returns null for any malformed
/// frame (empty, truncated len, length overrun, n_fields garbage).
/// Fields are slices INTO the request payload — valid only for the
/// duration of the call, which is all the ops need.
const Frame = struct {
    fields: [max_fields][]const u8,
    n: u8,

    fn parse(payload: []const u8) ?Frame {
        if (payload.len == 0 or payload[0] > max_fields) return null;
        const n = payload[0];
        var out: Frame = .{ .fields = undefined, .n = n };
        var off: usize = 1;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (off + 4 > payload.len) return null;
            const len: usize = std.mem.readInt(u32, payload[off..][0..4], .big);
            off += 4;
            if (len > payload.len - off) return null;
            out.fields[i] = payload[off .. off + len];
            off += len;
        }
        return out;
    }
};

/// Host-side vault session state; lives as long as the app (allocated by
/// the wiring, deinit on shutdown). Owns the Session, which owns the
/// vault path copy and all key material.
pub const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    session: vault.Session,
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
            .session = try vault.Session.init(io, allocator, path),
            .sink = sink,
        };
    }

    pub fn deinit(self: *State) void {
        // Session.deinit locks first: the DEK and plaintext never
        // outlive the state.
        self.session.deinit();
        self.* = undefined;
    }

    fn answer(self: *State, key: u64, ok: bool, bytes: []const u8) void {
        self.sink.result_fn(self.sink.result_ctx, key, ok, bytes);
    }
};

/// Maps every Session error to its wire code. Errors NOT in any
/// Session error set (programmer bugs) become "internal".
fn codeFor(err: anyerror) []const u8 {
    return switch (err) {
        error.WrongPassword => "wrong_password",
        error.NotFound => "not_found",
        error.AlreadyExists => "already_exists",
        error.Locked => "locked",
        error.Corrupt => "corrupt",
        error.UnsupportedVersion => "unsupported_version",
        error.PasswordInvalid => "password_invalid",
        error.ParamsInvalid => "params_invalid",
        error.PayloadTooLarge => "payload_too_large",
        error.OutOfMemory => "oom",
        error.Io => "io",
        else => "internal",
    };
}

/// Fire-and-forget host commands (Cmd.host): `vault.lock` locks the
/// session (no result route to answer into), `vault.ping` feeds the
/// round-trip oracle, anything else is a silent no-op.
pub fn sendFn(context: *anyopaque, name: []const u8, payload: []const u8) void {
    _ = payload;
    const state: *State = @ptrCast(@alignCast(context));
    if (std.mem.eql(u8, name, "vault.lock")) {
        state.session.lock();
    } else if (std.mem.eql(u8, name, "vault.ping")) {
        state.ping_count += 1;
    }
}

/// Keyed routed host commands (Cmd.request): answer exactly once.
pub fn requestFn(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
    const state: *State = @ptrCast(@alignCast(context));

    var answered = false;
    defer if (!answered) state.answer(key, false, "internal");

    // Task 1 seam oracle: the ping payload is raw (unframed) bytes.
    if (std.mem.eql(u8, name, "vault.ping")) {
        state.request_count += 1;
        state.answer(key, true, payload);
        answered = true;
        return;
    }

    if (!isKnownOp(name)) {
        state.answer(key, false, "unknown");
        answered = true;
        return;
    }

    const f = Frame.parse(payload) orelse {
        state.answer(key, false, "bad_request");
        answered = true;
        return;
    };

    if (std.mem.eql(u8, name, "vault.create")) {
        if (f.n != 1) {
            state.answer(key, false, "bad_request");
            answered = true;
            return;
        }
        state.session.create(f.fields[0], vault.defaultParams()) catch |err| {
            state.answer(key, false, codeFor(err));
            answered = true;
            return;
        };
        state.answer(key, true, "");
        answered = true;
    } else if (std.mem.eql(u8, name, "vault.unlock")) {
        if (f.n != 1) {
            state.answer(key, false, "bad_request");
            answered = true;
            return;
        }
        const plaintext = state.session.unlock(f.fields[0]) catch |err| {
            state.answer(key, false, codeFor(err));
            answered = true;
            return;
        };
        state.answer(key, true, plaintext);
        answered = true;
    } else if (std.mem.eql(u8, name, "vault.save")) {
        if (f.n != 1) {
            state.answer(key, false, "bad_request");
            answered = true;
            return;
        }
        state.session.save(f.fields[0]) catch |err| {
            state.answer(key, false, codeFor(err));
            answered = true;
            return;
        };
        state.answer(key, true, "");
        answered = true;
    } else if (std.mem.eql(u8, name, "vault.change_password")) {
        if (f.n != 2) {
            state.answer(key, false, "bad_request");
            answered = true;
            return;
        }
        state.session.changePassword(f.fields[0], f.fields[1]) catch |err| {
            state.answer(key, false, codeFor(err));
            answered = true;
            return;
        };
        state.answer(key, true, "");
        answered = true;
    } else {
        // Unreachable: isKnownOp() rejected everything else. The
        // answered-guard turns any future drift into "internal".
        state.answer(key, false, "internal");
        answered = true;
    }
}

fn isKnownOp(name: []const u8) bool {
    return std.mem.eql(u8, name, "vault.create") or
        std.mem.eql(u8, name, "vault.unlock") or
        std.mem.eql(u8, name, "vault.save") or
        std.mem.eql(u8, name, "vault.change_password") or
        std.mem.eql(u8, name, "vault.ping");
}
