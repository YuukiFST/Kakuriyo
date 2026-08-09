const std = @import("std");
const kak_sdk_app = @import("build/kak_app.zig");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("native_sdk", .{});
    kak_sdk_app.addApp(b, dep, .{ .name = "kakuriyo" });

    // The fast vault gate: pure std module (no GTK, no scriptc), the
    // same oracles `zig test src/vault/vault.zig` runs.
    const vault_tests = b.addTest(.{
        .name = "test-vault",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vault/tests.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const vault_test_step = b.step("test-vault", "Run vault envelope unit tests (std-only, no GTK)");
    vault_test_step.dependOn(&b.addRunArtifact(vault_tests).step);

    // The smoke driver: real Session ops against a real file, driven
    // by tools/smoke/run.sh.
    const smoke_exe = b.addExecutable(.{
        .name = "kakuriyo-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vault/smoke.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    // 0.16 does not auto-forward `--` args to run steps; build.zig
    // must. `zig build smoke-driver -- <path> [m_cost]` works.
    const run_smoke = b.addRunArtifact(smoke_exe);
    if (b.args) |args| run_smoke.addArgs(args);
    const smoke_step = b.step("smoke-driver", "Run the vault smoke sequence against a tmp vault file");
    smoke_step.dependOn(&run_smoke.step);
}
