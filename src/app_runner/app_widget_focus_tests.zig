//! Widget-runtime oracle: click a link, then ArrowUp must move the folder.
//! Msg-only `handleKeyEvent` is a false green if Title/Filter swallows keys.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const wiring = @import("main.zig");
const app_dispatch = @import("app_dispatch.zig");

fn pump(harness: *native_sdk.TestHarness(), app_state: *wiring.App, frame_index: u64) !void {
    // handleFrame rebuilds after install only on size/scale/font change.
    const height = 720 + @as(f32, @floatFromInt(frame_index));
    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_frame = .{
        .label = wiring.canvas_label,
        .size = native_sdk.geometry.SizeF.init(1200, height),
        .scale_factor = 1,
        .frame_index = frame_index,
        .timestamp_ns = frame_index * 1_000_000,
        .nonblank = true,
    } });
}

fn findListItemWithText(layout: canvas.WidgetLayoutTree, needle: []const u8) ?canvas.ObjectId {
    for (layout.nodes) |node| {
        if (node.widget.kind != .list_item) continue;
        if (std.mem.indexOf(u8, node.widget.text, needle) != null) return node.widget.id;
    }
    return null;
}

fn canvasViewIndex(harness: *native_sdk.TestHarness()) !usize {
    for (harness.runtime.views[0..harness.runtime.view_count], 0..) |view, index| {
        if (std.mem.eql(u8, view.label, wiring.canvas_label)) return index;
    }
    return error.TestUnexpectedResult;
}

test "widget click entry then arrowup moves listing folder" {
    const gpa = std.testing.allocator;
    var environ_map = std.process.Environ.Map.init(gpa);
    defer environ_map.deinit();

    const app_state = try wiring.createAppState(std.testing.io, gpa, &environ_map);
    defer app_state.destroy();

    var tmp = std.testing.tmpDir(.{});
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
    defer gpa.free(path);
    tmp.dir.close(std.testing.io);

    try wiring.installAppController(app_state, std.testing.io, gpa, path);
    defer wiring.uninstallAppController(gpa);
    // TestHarness enables automation, which otherwise loads app.native
    // markup and skips the Zig vault shell.
    app_state.options.markup = null;

    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = native_sdk.geometry.SizeF.init(1200, 720) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app_state.app());
    try pump(harness, app_state, 1);

    const ctrl = app_dispatch.controller() orelse return error.TestUnexpectedResult;
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
    try std.testing.expectEqual(@as(u8, 2), ctrl.slots.phase);
    try std.testing.expect(ctrl.entry_row_count >= 1);
    try std.testing.expect(ctrl.tree_row_count >= 3);

    app_dispatch.syncModel(ctrl, &app_state.model);
    try std.testing.expectEqual(@as(u8, 2), app_state.model.phase);
    try pump(harness, app_state, 2);

    try std.testing.expect(app_state.installed);

    const view_index = try canvasViewIndex(harness);
    harness.runtime.views[view_index].focused = true;

    const layout = harness.runtime.views[view_index].widgetLayoutTree();
    try std.testing.expect(layout.nodes.len > 0);
    var list_item_count: usize = 0;
    for (layout.nodes) |node| {
        if (node.widget.kind == .list_item) list_item_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), list_item_count);
    const entry_id = findListItemWithText(layout, "New Entry") orelse return error.TestUnexpectedResult;

    var command_buffer: [128]u8 = undefined;
    const click = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ wiring.canvas_label, entry_id });
    try harness.runtime.dispatchAutomationCommand(app_state.app(), click);

    const after_click = try harness.runtime.canvasWidgetLayout(1, wiring.canvas_label);
    const focused_id = harness.runtime.views[view_index].canvas_widget_focused_id;
    try std.testing.expect(focused_id != 0);
    const focused = after_click.findById(focused_id) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!canvas.isWidgetTextEntry(focused.widget));
    // Quiet list-row fallthrough is a false green for live GTK: click can
    // keep the link focused while Title never steals. Autofocus must pin
    // the listing folder so ArrowUp walks treeitems after the link click.
    try std.testing.expectEqual(canvas.WidgetRole.treeitem, focused.widget.semantics.role);
    try std.testing.expect(std.mem.indexOf(u8, focused.widget.text, "New Collection 2") != null);

    try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = wiring.canvas_label,
        .kind = .key_down,
        .key = "arrowup",
    } });

    try std.testing.expectEqualSlices(u8, &second_id, &(ctrl.selected_id orelse return error.TestUnexpectedResult));
    try std.testing.expect(ctrl.hasSelectedCollection());
    try std.testing.expect(!std.mem.eql(u8, &first_id, &second_id));
}
