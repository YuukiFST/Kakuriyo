//! Keyboard routing — classic keys only. Vim Motion is not a product language.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const core = @import("core.zig");
const app_dispatch = @import("app_dispatch.zig");
const app_controller = @import("app_controller.zig");

pub fn handleKeyEvent(keyboard: canvas.WidgetKeyboardEvent) ?core.Msg {
    const ctrl = app_dispatch.controller() orelse return null;
    if (@as(app_controller.Phase, @enumFromInt(ctrl.slots.phase)) != .unlocked) {
        return null;
    }
    return mainKey(ctrl, keyboard);
}

fn mainKey(ctrl: *app_controller.AppController, keyboard: canvas.WidgetKeyboardEvent) ?core.Msg {
    var key_buf: [64]u8 = undefined;
    const key = lowerKey(keyboard.key, &key_buf);
    const tree_focus = ctrl.slots.focus_region == 0;
    const mods = keyboard.modifiers;

    if (mods.control and mods.shift and eql(key, "l")) {
        return .lock_press;
    }
    if (mods.control and eql(key, "f")) {
        return .filter_toggle;
    }
    if (eql(key, "escape")) {
        if (ctrl.slots.show_delete_modal != 0) return .dismiss_delete;
        if (ctrl.slots.show_import_modal != 0) return .dismiss_import;
        if (ctrl.slots.show_import_password_modal != 0) return .dismiss_import_password;
        if (ctrl.slots.show_merge_modal != 0) return .dismiss_merge;
        if (ctrl.slots.show_settings_modal != 0) return .dismiss_settings;
        if (ctrl.slots.show_change_password_modal != 0) return .dismiss_change_password;
        return .tree_focus;
    }
    if (eql(key, "tab")) {
        return .focus_cycle;
    }

    if (!tree_focus) return null;

    if (ctrl.slots.show_delete_modal != 0) {
        if (eql(key, "y") or eql(key, "enter")) return .confirm_delete;
        return null;
    }
    if (ctrl.slots.show_import_modal != 0) {
        if (eql(key, "r")) return .import_replace;
        if (eql(key, "m")) return .import_merge;
        return null;
    }
    if (ctrl.slots.show_import_password_modal != 0) {
        return null;
    }
    if (ctrl.slots.show_merge_modal != 0) {
        if (eql(key, "l")) return .merge_keep_local;
        if (eql(key, "i")) return .merge_keep_imported;
        if (eql(key, "b")) return .merge_keep_both;
        return null;
    }

    if (mods.control and eql(key, "enter")) {
        return .open_url;
    }
    if (eql(key, "f2")) {
        return .editor_focus;
    }
    if (eql(key, "delete")) {
        return .delete_press;
    }
    if (mods.control and eql(key, "n")) {
        return .add_collection;
    }

    if (eql(key, "arrowdown")) return .{ .move_tree = 1 };
    if (eql(key, "arrowup")) return .{ .move_tree = -1 };
    if (eql(key, "arrowleft")) return .{ .tree_horiz = -1 };
    if (eql(key, "arrowright")) return .{ .tree_horiz = 1 };
    if (eql(key, "enter")) {
        return .editor_focus;
    }

    return null;
}

fn lowerKey(key: []const u8, buf: *[64]u8) []const u8 {
    const len = @min(key.len, buf.len);
    for (key[0..len], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..len];
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn testKey(key: []const u8) canvas.WidgetKeyboardEvent {
    return .{ .phase = .key_down, .key = key, .modifiers = .{} };
}

fn unlockedController(path: []const u8) !app_controller.AppController {
    var ctrl = try app_controller.AppController.init(std.testing.io, std.testing.allocator, path);
    ctrl.slots.phase = @intFromEnum(app_controller.Phase.unlocked);
    return ctrl;
}

test "bare digits and letters do not steal when tree focused" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
    defer alloc.free(path);

    var ctrl = try unlockedController(path);
    defer ctrl.deinit();
    app_dispatch.setController(&ctrl);

    try std.testing.expect(handleKeyEvent(testKey("1")) == null);
    try std.testing.expect(handleKeyEvent(testKey("2")) == null);
    try std.testing.expect(handleKeyEvent(testKey("a")) == null);
    try std.testing.expect(handleKeyEvent(testKey("j")) == null);
}

test "editor focus ignores tree motion keys" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
    defer alloc.free(path);

    var ctrl = try unlockedController(path);
    defer ctrl.deinit();
    app_dispatch.setController(&ctrl);
    ctrl.slots.focus_region = 1;

    try std.testing.expect(handleKeyEvent(testKey("j")) == null);
    try std.testing.expect(handleKeyEvent(testKey("a")) == null);
    try std.testing.expect(handleKeyEvent(testKey("arrowdown")) == null);
    try std.testing.expect(handleKeyEvent(testKey("delete")) == null);
}

test "entry select keeps tree keyboard; arrowup is move_tree" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
    defer alloc.free(path);

    var ctrl = try unlockedController(path);
    defer ctrl.deinit();
    app_dispatch.setController(&ctrl);
    ctrl.setPasswordText("test-password-123");
    ctrl.slots.confirm_password_mode = 1;
    ctrl.setConfirmText("test-password-123");
    ctrl.createVault();

    ctrl.addCollection();
    const first_id = ctrl.selected_id orelse return error.TestUnexpectedResult;
    ctrl.selected_id = null;
    ctrl.addCollection();
    const second_id = ctrl.selected_id orelse return error.TestUnexpectedResult;
    ctrl.selected_id = null;
    ctrl.addCollection();
    const third_id = ctrl.selected_id orelse return error.TestUnexpectedResult;

    ctrl.selectNode(third_id);
    ctrl.addEntry();
    ctrl.selectEntryAt(0);
    try std.testing.expectEqual(@as(u8, 0), ctrl.slots.focus_region);

    const msg = handleKeyEvent(testKey("arrowup"));
    try std.testing.expect(msg != null);
    try std.testing.expect(msg.? == .move_tree);
    try std.testing.expect(app_dispatch.handle(msg.?));
    try std.testing.expectEqualSlices(u8, &second_id, &(ctrl.selected_id orelse return error.TestUnexpectedResult));
    try std.testing.expect(ctrl.hasSelectedCollection());
    try std.testing.expect(!std.mem.eql(u8, &first_id, &second_id));
}

test "tab cycles focus from tree or editor" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
    defer alloc.free(path);

    var ctrl = try unlockedController(path);
    defer ctrl.deinit();
    app_dispatch.setController(&ctrl);
    ctrl.slots.focus_region = 0;
    var msg = handleKeyEvent(testKey("tab"));
    try std.testing.expect(msg != null);
    try std.testing.expect(msg.? == .focus_cycle);

    ctrl.slots.focus_region = 1;
    msg = handleKeyEvent(testKey("tab"));
    try std.testing.expect(msg != null);
    try std.testing.expect(msg.? == .focus_cycle);
}

test "arrowdown moves tree" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
    defer alloc.free(path);

    var ctrl = try unlockedController(path);
    defer ctrl.deinit();
    app_dispatch.setController(&ctrl);

    const msg = handleKeyEvent(testKey("arrowdown"));
    try std.testing.expect(msg != null);
    try std.testing.expect(msg.? == .move_tree);
}
