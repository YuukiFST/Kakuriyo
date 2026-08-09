const std = @import("std");
const kak_sdk_app = @import("build/kak_app.zig");

pub fn build(b: *std.Build) void {
    const dep = b.dependency("native_sdk", .{});
    kak_sdk_app.addApp(b, dep, .{ .name = "kakuriyo" });
}