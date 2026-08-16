//! Bridge canvas text-input events into core Msg arms.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const core = @import("core.zig");
const app_controller = @import("app_controller.zig");

fn mapCaretDirection(dir: canvas.TextCaretDirection) core.TextCaretDirection {
    return switch (dir) {
        .previous => .previous,
        .next => .next,
        .previous_word => .previous_word,
        .next_word => .next_word,
        .start => .start,
        .end => .end,
    };
}

/// Saturating widen: select-all sends `focus = maxInt(usize)`, which does
/// not fit i64. `@intCast` panics; `lossyCast` keeps sentinel past any
/// real length (same rule as Native SDK `translatedInputMsg`).
fn toCoreOffset(value: usize) i64 {
    return std.math.lossyCast(i64, value);
}

pub fn toCoreEvent(edit: canvas.TextInputEvent) core.TextInputEvent {
    return switch (edit) {
        .insert_text => |t| .{ .insert_text = t },
        .delete_backward => .delete_backward,
        .delete_forward => .delete_forward,
        .delete_word_backward => .delete_word_backward,
        .delete_word_forward => .delete_word_forward,
        .clear => .clear,
        .move_caret => |m| .{ .move_caret = .{
            .direction = mapCaretDirection(m.direction),
            .extend = m.extend,
        } },
        .set_selection => |s| .{ .set_selection = .{
            .anchor = toCoreOffset(s.anchor),
            .focus = toCoreOffset(s.focus),
        } },
        .set_composition => |c| .{ .set_composition = .{
            .text = c.text,
            .cursor = if (c.cursor) |cur| toCoreOffset(cur) else null,
        } },
        .commit_composition => .commit_composition,
        .cancel_composition => .cancel_composition,
    };
}

fn toControllerEvent(edit: canvas.TextInputEvent) ?app_controller.TextInputEvent {
    return switch (edit) {
        .insert_text => |t| .{ .insert_text = t },
        .delete_backward => .delete_backward,
        .delete_forward => .delete_forward,
        .clear => .clear,
        else => null,
    };
}

pub fn passwordInput(edit: canvas.TextInputEvent) core.Msg {
    return .{ .password_input = toCoreEvent(edit) };
}

pub fn confirmInput(edit: canvas.TextInputEvent) core.Msg {
    return .{ .confirm_input = toCoreEvent(edit) };
}

pub fn entryTitleInput(edit: canvas.TextInputEvent) core.Msg {
    return .{ .entry_title_input = toCoreEvent(edit) };
}

pub fn entryUrlInput(edit: canvas.TextInputEvent) core.Msg {
    return .{ .entry_url_input = toCoreEvent(edit) };
}

pub fn entryUserInput(edit: canvas.TextInputEvent) core.Msg {
    return .{ .entry_user_input = toCoreEvent(edit) };
}

pub fn entryPassInput(edit: canvas.TextInputEvent) core.Msg {
    return .{ .entry_pass_input = toCoreEvent(edit) };
}

pub fn entryBodyInput(edit: canvas.TextInputEvent) core.Msg {
    return .{ .entry_body_input = toCoreEvent(edit) };
}

pub fn pasteInput(edit: canvas.TextInputEvent) core.Msg {
    return .{ .paste_input = toCoreEvent(edit) };
}

pub fn groupInput(edit: canvas.TextInputEvent) core.Msg {
    return .{ .group_input = toCoreEvent(edit) };
}

pub fn filterInput(edit: canvas.TextInputEvent) core.Msg {
    return .{ .filter_input = toCoreEvent(edit) };
}

pub fn applyToController(ctrl: *app_controller.AppController, field: app_controller.EditorField, edit: canvas.TextInputEvent) void {
    if (toControllerEvent(edit)) |mapped| ctrl.applyEditorEdit(field, mapped);
}

pub fn applyFilter(ctrl: *app_controller.AppController, edit: canvas.TextInputEvent) void {
    if (toControllerEvent(edit)) |mapped| ctrl.applyFilterEdit(mapped);
}

test "select-all sentinel set_selection does not panic" {
    // Paste / Ctrl+A path: events.zig synthesizes focus = maxInt(usize).
    const edit: canvas.TextInputEvent = .{
        .set_selection = .{ .anchor = 0, .focus = std.math.maxInt(usize) },
    };
    const mapped = toCoreEvent(edit);
    try std.testing.expectEqual(@as(i64, 0), mapped.set_selection.anchor);
    try std.testing.expectEqual(std.math.maxInt(i64), mapped.set_selection.focus);
}

test "ordinary selection offsets stay exact" {
    const edit: canvas.TextInputEvent = .{
        .set_selection = .{ .anchor = 3, .focus = 12 },
    };
    const mapped = toCoreEvent(edit);
    try std.testing.expectEqual(@as(i64, 3), mapped.set_selection.anchor);
    try std.testing.expectEqual(@as(i64, 12), mapped.set_selection.focus);
}

test "multi-link paste insert_text survives bridge" {
    const pasted =
        \\https://example.com/a
        \\https://example.com/b
        \\https://example.com/c
    ;
    const edit: canvas.TextInputEvent = .{ .insert_text = pasted };
    const mapped = toCoreEvent(edit);
    try std.testing.expectEqualStrings(pasted, mapped.insert_text);
}
