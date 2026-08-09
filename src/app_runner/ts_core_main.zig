//! The Kakuriyo app wiring — app-owned copy of the Native SDK's
//! generated TypeScript-core wiring (`src/app_runner/ts_core_main.zig`
//! from @native-sdk/cli 0.8.3, commit 30c1410, Apache-2.0), extended
//! with the vault host-service binding.
//!
//! Upstream diff (re-vendor with
//! `diff -u <cli>/src/app_runner/ts_core_main.zig src/app_runner/ts_core_main.zig`):
//!   D1  ownership header (this comment)
//!   D2  imports vault/vault_host (staged beside this file by P3 of
//!       build/kak_app.zig)
//!   D3  main() split into createAppState() + runApp(): the options and
//!       launch buffers move to module scope so TESTS can build the same
//!       app state without duplicating the wiring (single-threaded use;
//!       buffers live for the app's whole lifetime, mirroring main()'s
//!       stack)
//!   D4  installHostCalls(): binds the vault HostCallBinding onto the
//!       app's effects channel (request_fn answers via feedHostResult)
//!   D5  vault path resolved from app_dirs .config, and test seam
//!       `test { _ = @import("host_roundtrip_tests.zig"); }`

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const manifest = @import("app_manifest_zon");
pub const core = @import("core.zig");
pub const vault = @import("vault.zig");
pub const vault_host = @import("vault_host.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

/// Re-exported so the model-contract step (and any test) reflects the
/// core's real surface: `native check` verifies app.native against it.
pub const Model = core.Model;
pub const Msg = core.Msg;

const Adapter = native_sdk.TsUiApp(core);
pub const App = Adapter.App;

const shell_scene = native_sdk.app_manifest.shellConfigFrom(manifest);
pub const canvas_label = native_sdk.app_manifest.firstGpuSurfaceLabel(shell_scene);
pub const app_markup = @embedFile("app.native");

const app_permissions = manifestStringList(manifest, "permissions");
const allowed_origins = manifestAllowedOrigins();

/// The vault file name inside the resolved config directory.
pub const vault_file_name = "vault.kakuriyo";

// Launch buffers at module scope (D3): their contents (audio cache dir,
// boot images, env values) are referenced by the app struct for its whole
// lifetime, exactly as main()'s stack kept them alive upstream. Module
// scope keeps createAppState() returning an app state that stays valid;
// single-threaded by design (one app per process; the test runner also
// drives them sequentially).
var cache_dir_buffer: [512]u8 = undefined;
var boot_images_buffer: [manifestImages().len]Adapter.BootImage = undefined;
var env_values_buffer: [envMsgsLen()]Adapter.EnvValue = undefined;

/// Build the app state (D3): same construction the generated wiring's
/// main() performed, exposed so tests drive the identical path.
pub fn createAppState(io: std.Io, allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) !*App {
    var options: Adapter.Options = .{
        .name = manifest.name,
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = io },
        // app.zon's theme pack; unthemed manifests get the house register.
        // The stock tokens compose the pack with the LIVE system
        // appearance, so TS apps follow the OS light/dark flip with no
        // core code. `theme_accent` is the manifest's one-accent brand
        // override, layered over the pack by the runtime (skipped under
        // high contrast — accessibility beats brand).
        .theme = comptime runner.manifestThemePack(),
        .theme_accent = comptime runner.manifestThemeAccent(),
    };
    if (comptime @hasDecl(core, "commandMsg")) {
        // Menus, shortcuts, and chrome tabs dispatch through the core's
        // exported command mapper.
        options.on_command = core.commandMsg;
    }
    // The platform caches directory for this app: when the core's
    // `Cmd.audioPlay` names a URL with no cachePath, the bridge derives
    // the conventional content-addressed path under this directory —
    // resolved once at launch (never inside update), so replay's
    // deterministic-init contract holds. Resolution failure just disables
    // the cache: streams still play, they re-download.
    const audio_cache_dir = native_sdk.app_dirs.resolveOne(
        .{ .name = manifest.name },
        native_sdk.app_dirs.currentPlatform(),
        native_sdk.debug.envFromMap(environ_map),
        .cache,
        &cache_dir_buffer,
    ) catch "";
    // app.zon-declared images, read once at launch (bounded; a missing or
    // over-bound file skips its entry and the views keep their fallback)
    // and registered by the adapter on the installing frame.
    var boot_image_count: usize = 0;
    inline for (comptime manifestImages()) |asset| {
        if (runner.app_assets.readFileAlloc(io, asset.path, std.heap.page_allocator, .limited(max_boot_image_bytes))) |bytes| {
            boot_images_buffer[boot_image_count] = .{ .id = asset.id, .bytes = bytes };
            boot_image_count += 1;
        } else |_| {}
    }

    // The core's launch-time environment channel (`envMsgs`): read each
    // named variable once, here at the boundary — never inside update —
    // and hand the present values to the adapter, which dispatches them
    // as ordinary journaled Msgs right after the boot command.
    var env_value_count: usize = 0;
    if (comptime @hasDecl(core, "envMsgs")) {
        inline for (core.envMsgs) |entry| {
            if (environ_map.get(entry.env)) |value| {
                env_values_buffer[env_value_count] = .{ .msg = entry.msg, .value = value };
                env_value_count += 1;
            }
        }
    }

    // The app struct (and any real model) is multi-MB: `create`
    // heap-allocates and constructs in place, so neither rides the stack.
    return try Adapter.create(allocator, .{
        .audio_cache_dir = audio_cache_dir,
        // Image loads share the same launch-resolved caches directory:
        // the bridge keys the two caches into their own segments
        // (audio/ and images/), so one directory serves both.
        .image_cache_dir = audio_cache_dir,
        .boot_images = boot_images_buffer[0..boot_image_count],
        .env_values = env_values_buffer[0..env_value_count],
    }, options);
}

/// Resolve the default vault path (config dir + vault.kakuriyo) into
/// `output`; returns "" on resolution failure (the host then reports
/// io_failed on first use instead of crashing).
pub fn defaultVaultPath(_: std.Io, environ_map: *std.process.Environ.Map, output: []u8) []const u8 {
    const dir = native_sdk.app_dirs.resolveOne(
        .{ .name = manifest.name },
        native_sdk.app_dirs.currentPlatform(),
        native_sdk.debug.envFromMap(environ_map),
        .config,
        output,
    ) catch return "";
    if (dir.len == 0 or dir.len + vault_file_name.len > output.len) return "";
    @memcpy(output[dir.len..][0..vault_file_name.len], vault_file_name);
    return output[0 .. dir.len + vault_file_name.len];
}

/// Feed a host answer back into the effects channel (D4): the vault
/// host answers every request exactly once through this adapter.
fn feedHostResultFn(ctx: *anyopaque, key: u64, ok: bool, bytes: []const u8) void {
    const fx: *App.Effects = @ptrCast(@alignCast(ctx));
    // A late/cancelled result reports EffectNotFound; the channel drops
    // it — nothing to answer into.
    fx.feedHostResult(key, ok, bytes) catch {};
}

/// Bind the vault host service onto the app's effects channel (D4):
/// `Cmd.request("vault.*", ...)` from the TS core rides
/// `hostRequest` into vault_host.requestFn, whose answers arrive back
/// as ok/err Msg arms. Call once, after createAppState, on the loop
/// thread before the runner starts.
pub fn installHostCalls(app_state: *App, io: std.Io, allocator: std.mem.Allocator, vault_path: []const u8) !*vault_host.State {
    const vault_state = try allocator.create(vault_host.State);
    vault_state.* = try vault_host.State.init(io, allocator, vault_path, .{
        .result_ctx = &app_state.effects,
        .result_fn = feedHostResultFn,
    });
    app_state.effects.bindHostCalls(.{
        .context = vault_state,
        .send_fn = vault_host.sendFn,
        .request_fn = vault_host.requestFn,
    });
    return vault_state;
}

pub fn main(init: std.process.Init) !void {
    const app_state = try createAppState(init.io, std.heap.page_allocator, init.environ_map);
    defer app_state.destroy();

    var vault_path_buffer: [4096]u8 = undefined;
    const vault_path = defaultVaultPath(init.io, init.environ_map, &vault_path_buffer);
    const vault_state = try std.heap.page_allocator.create(vault_host.State);
    vault_state.* = try vault_host.State.init(init.io, std.heap.page_allocator, vault_path, .{
        .result_ctx = &app_state.effects,
        .result_fn = feedHostResultFn,
    });
    defer {
        vault_state.deinit();
        std.heap.page_allocator.destroy(vault_state);
    }
    app_state.effects.bindHostCalls(.{
        .context = vault_state,
        .send_fn = vault_host.sendFn,
        .request_fn = vault_host.requestFn,
    });

    try runner.runWithOptions(app_state.app(), .{
        .app_name = manifest.name,
        .window_title = comptime windowTitle(),
        .bundle_id = manifest.id,
        .icon_path = "assets/icon.png",
        .default_frame = comptime defaultFrame(),
        .restore_state = comptime startupRestoreState(),
        .js_window_api = false,
        .security = .{
            .permissions = app_permissions,
            .navigation = .{ .allowed_origins = allowed_origins },
        },
    }, init);
}

// Full-loop tests over the real effects channel with the bound vault
// host (see host_roundtrip_tests.zig).
test {
    _ = @import("host_roundtrip_tests.zig");
}

/// The startup window title: the scene's first window title, else the
/// manifest display name, else the app name.
fn windowTitle() []const u8 {
    if (shell_scene.windows.len > 0) {
        if (shell_scene.windows[0].title) |title| return title;
    }
    if (@hasField(@TypeOf(manifest), "display_name")) return manifest.display_name;
    return manifest.name;
}

fn defaultFrame() native_sdk.geometry.RectF {
    if (shell_scene.windows.len > 0) {
        const window = shell_scene.windows[0];
        return native_sdk.geometry.RectF.init(window.x orelse 0, window.y orelse 0, window.width, window.height);
    }
    return native_sdk.geometry.RectF.init(0, 0, 720, 480);
}

fn startupRestoreState() bool {
    if (shell_scene.windows.len > 0) return shell_scene.windows[0].restore_state;
    return true;
}

/// One app.zon `.assets.images` entry: the encoded file the wiring reads
/// at launch and the `ImageId` markup avatar bindings reference.
const ImageAsset = struct {
    id: u64,
    path: []const u8,
};

/// Encoded-size bound for one boot image: over-bound files skip their
/// entry (the views keep the initials fallback) instead of holding the
/// launch path hostage to a mis-sized asset.
const max_boot_image_bytes: usize = 4 * 1024 * 1024;

fn manifestImages() []const ImageAsset {
    comptime {
        if (!@hasField(@TypeOf(manifest), "assets")) return &.{};
        if (!@hasField(@TypeOf(manifest.assets), "images")) return &.{};
        var out: []const ImageAsset = &.{};
        for (manifest.assets.images) |entry| {
            out = out ++ &[_]ImageAsset{.{ .id = entry.id, .path = entry.path }};
        }
        return out;
    }
}

fn envMsgsLen() usize {
    comptime {
        if (!@hasDecl(core, "envMsgs")) return 0;
        return core.envMsgs.len;
    }
}

fn manifestStringList(comptime m: anytype, comptime field: []const u8) []const []const u8 {
    comptime {
        if (!@hasField(@TypeOf(m), field)) return &.{};
        var out: []const []const u8 = &.{};
        for (@field(m, field)) |entry| {
            const name: []const u8 = entry;
            out = out ++ &[_][]const u8{name};
        }
        return out;
    }
}

fn manifestAllowedOrigins() []const []const u8 {
    comptime {
        if (!@hasField(@TypeOf(manifest), "security")) return &.{};
        if (!@hasField(@TypeOf(manifest.security), "navigation")) return &.{};
        return manifestStringList(manifest.security.navigation, "allowed_origins");
    }
}
