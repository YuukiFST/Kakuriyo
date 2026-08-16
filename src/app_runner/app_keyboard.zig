//! Keyboard routing — respects Vim/Classic profile and editor focus rules.
//! Wired as `Options.on_key` (core.ts must not export `keyMsg`).

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const core = @import("core.zig");
const app_dispatch = @import("app_dispatch.zig");
const app_controller = @import("app_controller.zig");

var pending_g: bool = false;

pub fn handleKeyEvent(keyboard: canvas.WidgetKeyboardEvent) ?core.Msg {
    const ctrl = app_dispatch.controller() orelse return null;
    if (@as(app_controller.Phase, @enumFromInt(ctrl.slots.phase)) != .unlocked) {
        return null;
    }
    return mainKey(ctrl, keyboard);
}

fn mainKey(ctrl: *app_controller.AppController, keyboard: canvas.WidgetKeyboardEvent) ?core.Msg {
    const key = lowerKey(keyboard.key);
    const vim = ctrl.slots.vim_motion != 0;

    if (keyboard.modifiers.control and keyboard.modifiers.shift and eql(key, "l")) {
        return .lock_press;
    }
    if (keyboard.modifiers.control and eql(key, "f")) {
        return .filter_toggle;
    }
    if (eql(key, "/")) {
        return .filter_toggle;
    }
    if (eql(key, "escape")) {
        pending_g = false;
        if (ctrl.slots.show_delete_modal != 0) return .dismiss_delete;
        if (ctrl.slots.show_import_modal != 0) return .dismiss_import;
        if (ctrl.slots.show_import_password_modal != 0) return .dismiss_import_password;
        if (ctrl.slots.show_merge_modal != 0) return .dismiss_merge;
        if (ctrl.slots.show_settings_modal != 0) return .dismiss_settings;
        if (ctrl.slots.show_change_password_modal != 0) return .dismiss_change_password;
        return .tree_focus;
    }
    if (ctrl.slots.show_delete_modal != 0) {
        if (eql(key, "y")) return .confirm_delete;
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

    if (keyboard.modifiers.control and eql(key, "enter")) {
        return .open_url;
    }
    if (vim and eql(key, "g")) {
        pending_g = true;
        return null;
    }
    if (vim and pending_g and eql(key, "x")) {
        pending_g = false;
        return .open_url;
    }
    pending_g = false;

    if (vim and eql(key, "x") and !keyboard.modifiers.control and !keyboard.modifiers.shift) {
        return .cut_node;
    }
    if (vim and eql(key, "p") and !keyboard.modifiers.control) {
        return .paste_node;
    }
    if ((vim and eql(key, "r")) or eql(key, "f2")) {
        return .editor_focus;
    }
    if (eql(key, "delete")) {
        return .delete_press;
    }
    if (eql(key, "1")) return .{ .activity_tab = 0 };
    if (eql(key, "2")) return .{ .activity_tab = 1 };
    if (vim and eql(key, "a") and !keyboard.modifiers.shift) {
        return .add_entry;
    }
    if (vim and eql(key, "a") and keyboard.modifiers.shift) {
        return .add_collection;
    }

    if (keyboard.modifiers.control and eql(key, "w")) {
        return .focus_cycle;
    }

    if (vim) {
        if (eql(key, "j")) return .{ .move_tree = 1 };
        if (eql(key, "k")) return .{ .move_tree = -1 };
        if (eql(key, "h")) return .{ .tree_horiz = -1 };
        if (eql(key, "l") and !keyboard.modifiers.control) return .{ .tree_horiz = 1 };
    }

    if (!vim or keyboard.modifiers.control) {
        if (eql(key, "arrowdown")) return .{ .move_tree = 1 };
        if (eql(key, "arrowup")) return .{ .move_tree = -1 };
        if (eql(key, "arrowleft")) return .{ .tree_horiz = -1 };
        if (eql(key, "arrowright")) return .{ .tree_horiz = 1 };
    }
    if (!vim and eql(key, "enter")) {
        return .editor_focus;
    }

    return null;
}

fn lowerKey(key: []const u8) []const u8 {
    var buf: [64]u8 = undefined;
    const len = @min(key.len, buf.len);
    for (key[0..len], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..len];
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "vim j moves tree" {
    const io = std.testing.io_instance;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(alloc, "vault.kakuriyo");
    defer alloc.free(path);

    var ctrl = try app_controller.AppController.init(io, alloc, path);
    defer ctrl.deinit();
    app_dispatch.setController(&ctrl);
    ctrl.slots.vim_motion = 1;
    ctrl.slots.phase = @intFromEnum(app_controller.Phase.unlocked);

    const msg = handleKeyEvent(.{
        .key = "j",
        .modifiers = .{},
    });
    try std.testing.expect(msg != null);
    try std.testing.expect(msg.? == .move_tree);
}
