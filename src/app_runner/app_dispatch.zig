//! Dispatches UI messages into AppController before the compiled TS
//! update runs. Password fields accumulate via text-input events here.

const std = @import("std");
const app_controller = @import("app_controller.zig");
const domain = @import("domain.zig");
const text_input_bridge = @import("text_input_bridge.zig");
const core = @import("core.zig");

const Ctrl = app_controller.AppController;

/// Global controller pointer — set once at app install (single-threaded).
var active: ?*Ctrl = null;

pub fn setController(ctrl: *Ctrl) void {
    active = ctrl;
}

pub fn controller() ?*Ctrl {
    return active;
}

pub fn syncModel(ctrl: *Ctrl, model: *core.Model) void {
    var slots: app_controller.ModelSlots = .{};
    ctrl.syncSlots(&slots);
    model.phase = @intCast(slots.phase);
    model.errorCode = @intCast(slots.error_code);
    model.selectedHi = @intCast(slots.selected_hi);
    model.selectedLo = @intCast(slots.selected_lo);
    model.treeEpoch = @intCast(slots.tree_epoch);
    model.revealSecrets = @intCast(slots.reveal_secrets);
    model.vimMotion = @intCast(slots.vim_motion);
    model.activity = @intCast(slots.activity);
    model.showDeleteModal = @intCast(slots.show_delete_modal);
    model.showImportModal = @intCast(slots.show_import_modal);
    model.showImportPasswordModal = @intCast(slots.show_import_password_modal);
    model.showSettingsModal = @intCast(slots.show_settings_modal);
    model.showChangePasswordModal = @intCast(slots.show_change_password_modal);
    model.changePasswordStep = @intCast(slots.change_password_step);
    model.showMergeModal = @intCast(slots.show_merge_modal);
    model.mergeConflictIndex = @intCast(slots.merge_conflict_index);
    model.mergeConflictCount = @intCast(slots.merge_conflict_count);
    model.filterActive = @intCast(slots.filter_active);
    model.idlePreset = @intCast(slots.idle_preset);
    model.lockoutUntilMs = @intCast(slots.lockout_until_ms);
    model.dirty = @intCast(slots.dirty);
    model.confirmPasswordMode = @intCast(slots.confirm_password_mode);
    model.focusRegion = @intCast(slots.focus_region);
    model.senhasGateState = @intCast(slots.senhas_gate_state);
    model.senhasError = @intCast(slots.senhas_error);
    model.secretIndex = @intCast(slots.secret_index);
}

pub fn handle(msg: core.Msg) bool {
    const ctrl = active orelse return false;
    if (msg != .tick) ctrl.touchActivity();

    switch (msg) {
        .password_input => |ev| {
            applyPasswordEdit(ctrl, ev, false);
            return true;
        },
        .confirm_input => |ev| {
            applyPasswordEdit(ctrl, ev, true);
            return true;
        },
        .unlock_press => {
            ctrl.unlock();
            return true;
        },
        .create_press => {
            ctrl.createVault();
            return true;
        },
        .lock_press => {
            ctrl.lock();
            return true;
        },
        .toggle_show_password => {
            ctrl.toggleShowPassword();
            return true;
        },
        .select_row => |row| {
            const idx: usize = @intFromFloat(row);
            if (ctrl.slots.activity == @intFromEnum(app_controller.Activity.senhas)) {
                if (idx < ctrl.store.secrets.items.len) {
                    ctrl.selectSecret(ctrl.store.secrets.items[idx].id);
                }
            } else if (idx < ctrl.tree_row_count) {
                ctrl.selectNode(ctrl.tree_rows[idx].id);
                ctrl.slots.focus_region = 0;
            }
            return true;
        },
        .select_entry => |row| {
            const idx: usize = @intFromFloat(row);
            ctrl.selectEntryAt(idx);
            return true;
        },
        .toggle_row => |row| {
            const idx: usize = @intFromFloat(row);
            if (idx < ctrl.tree_row_count and ctrl.tree_rows[idx].kind == 0) {
                ctrl.toggleExpanded(ctrl.tree_rows[idx].id);
            }
            return true;
        },
        .activity_tab => |tab| {
            const t: u8 = @intFromFloat(tab);
            ctrl.setActivity(t);
            return true;
        },
        .toggle_reveal => {
            ctrl.slots.reveal_secrets = if (ctrl.slots.reveal_secrets != 0) 0 else 1;
            return true;
        },
        .toggle_vim => {
            ctrl.slots.vim_motion = 0;
            return true;
        },
        .filter_toggle => {
            ctrl.slots.filter_active = if (ctrl.slots.filter_active != 0) 0 else 1;
            return true;
        },
        .delete_press => {
            ctrl.slots.show_delete_modal = 1;
            return true;
        },
        .dismiss_delete => {
            ctrl.slots.show_delete_modal = 0;
            return true;
        },
        .confirm_delete => {
            ctrl.slots.show_delete_modal = 0;
            if (ctrl.slots.activity == @intFromEnum(app_controller.Activity.senhas)) {
                ctrl.deleteSelectedSecret();
            } else {
                ctrl.deleteSelected();
            }
            return true;
        },
        .dismiss_import => {
            ctrl.slots.show_import_modal = 0;
            return true;
        },
        .import_replace => {
            ctrl.importReplace();
            return true;
        },
        .import_merge => {
            ctrl.importMerge();
            return true;
        },
        .dismiss_import_password => {
            ctrl.dismissImportPassword();
            return true;
        },
        .import_password_submit => {
            ctrl.submitImportPassword();
            return true;
        },
        .dismiss_merge => {
            ctrl.dismissMerge();
            return true;
        },
        .merge_keep_local => {
            ctrl.pickMergeResolution(domain.Store.MergeResolution.keep_local);
            return true;
        },
        .merge_keep_imported => {
            ctrl.pickMergeResolution(domain.Store.MergeResolution.keep_imported);
            return true;
        },
        .merge_keep_both => {
            ctrl.pickMergeResolution(domain.Store.MergeResolution.keep_both);
            return true;
        },
        .dismiss_settings => {
            ctrl.slots.show_settings_modal = if (ctrl.slots.show_settings_modal != 0) 0 else 1;
            return true;
        },
        .change_password_open => {
            ctrl.beginChangePassword();
            return true;
        },
        .dismiss_change_password => {
            ctrl.dismissChangePassword();
            return true;
        },
        .change_password_next => {
            ctrl.changePasswordNext();
            return true;
        },
        .change_password_submit => {
            ctrl.submitChangePassword();
            return true;
        },
        .cycle_idle_preset => {
            ctrl.cycleIdlePreset();
            return true;
        },
        .open_url => {
            ctrl.openSelectedUrl();
            return true;
        },
        .cut_node => {
            ctrl.cutSelectedNode();
            return true;
        },
        .paste_node => {
            ctrl.pasteClipboardNode();
            return true;
        },
        .editor_focus => {
            ctrl.slots.focus_region = 1;
            return true;
        },
        .tree_focus => {
            ctrl.slots.focus_region = 0;
            return true;
        },
        .focus_cycle => {
            ctrl.slots.focus_region = if (ctrl.slots.focus_region == 0) 1 else 0;
            return true;
        },
        .refresh_preview => {
            ctrl.refreshPreviewForSelected();
            return true;
        },
        .ingest_press => {
            ctrl.ingestPaste();
            return true;
        },
        .paste_input => |ev| {
            if (mapEvent(ev)) |mapped| ctrl.applyPasteEdit(mapped);
            return true;
        },
        .group_input => |ev| {
            if (mapEvent(ev)) |mapped| ctrl.applyGroupEdit(mapped);
            return true;
        },
        .senhas_gate_create => {
            ctrl.createSenhasGate();
            return true;
        },
        .senhas_gate_unlock => {
            ctrl.unlockSenhasGate();
            return true;
        },
        .secret_add => {
            ctrl.addSecret();
            return true;
        },
        .secret_save => {
            ctrl.saveSecret();
            return true;
        },
        .secret_delete => {
            ctrl.deleteSelectedSecret();
            return true;
        },
        .save_entry => {
            if (ctrl.slots.activity == @intFromEnum(app_controller.Activity.senhas)) {
                ctrl.saveSecret();
            } else {
                ctrl.saveEditor();
            }
            return true;
        },
        .add_entry => {
            if (ctrl.slots.activity == @intFromEnum(app_controller.Activity.senhas)) {
                ctrl.addSecret();
            } else {
                ctrl.addEntry();
            }
            return true;
        },
        .add_collection => {
            ctrl.addCollection();
            return true;
        },
        .export_vault => {
            ctrl.exportVault();
            return true;
        },
        .import_vault => {
            ctrl.importVault();
            return true;
        },
        .entry_title_input => |ev| {
            if (mapEvent(ev)) |mapped| ctrl.applyEditorEdit(.title, mapped);
            ctrl.slots.focus_region = 1;
            return true;
        },
        .entry_url_input => |ev| {
            if (mapEvent(ev)) |mapped| ctrl.applyEditorEdit(.url, mapped);
            ctrl.slots.focus_region = 1;
            return true;
        },
        .entry_user_input => |ev| {
            if (mapEvent(ev)) |mapped| ctrl.applyEditorEdit(.user, mapped);
            ctrl.slots.focus_region = 1;
            return true;
        },
        .entry_pass_input => |ev| {
            if (mapEvent(ev)) |mapped| ctrl.applyEditorEdit(.pass, mapped);
            ctrl.slots.focus_region = 1;
            return true;
        },
        .entry_body_input => |ev| {
            if (mapEvent(ev)) |mapped| ctrl.applyEditorEdit(.body, mapped);
            ctrl.slots.focus_region = 1;
            return true;
        },
        .filter_input => |ev| {
            if (mapEvent(ev)) |mapped| ctrl.applyFilterEdit(mapped);
            return true;
        },
        .move_tree => |delta| {
            ctrl.moveTreeSelection(@intFromFloat(delta));
            return true;
        },
        .tree_horiz => |delta| {
            const id = ctrl.selected_id orelse return true;
            if (ctrl.findTreeIndex(id)) |idx| {
                if (ctrl.tree_rows[idx].kind == 0) {
                    const d: i32 = @as(i32, @intFromFloat(delta));
                    const expanded = ctrl.tree_rows[idx].expanded;
                    if (d > 0 and !expanded) ctrl.toggleExpanded(id);
                    if (d < 0 and expanded) ctrl.toggleExpanded(id);
                }
            }
            return true;
        },
        .tick => {
            ctrl.checkIdleLock();
            return true;
        },
    }
}

fn mapEvent(ev: core.TextInputEvent) ?app_controller.TextInputEvent {
    return switch (ev) {
        .insert_text => |t| .{ .insert_text = t },
        .delete_backward => .delete_backward,
        .delete_forward => .delete_forward,
        .clear => .clear,
        else => null,
    };
}

fn applyPasswordEdit(ctrl: *Ctrl, ev: core.TextInputEvent, confirm: bool) void {
    var buf: []u8 = undefined;
    var len: *usize = undefined;
    if (confirm) {
        buf = ctrl.confirm_buf[0..];
        len = &ctrl.confirm_len;
    } else {
        buf = ctrl.password_buf[0..];
        len = &ctrl.password_len;
    }

    switch (ev) {
        .insert_text => |t| {
            const room = buf.len - len.*;
            const take = @min(t.len, room);
            @memcpy(buf[len.* .. len.* + take], t[0..take]);
            len.* += take;
        },
        .clear => {
            std.crypto.secureZero(u8, buf[0..len.*]);
            len.* = 0;
        },
        .delete_backward => {
            if (len.* > 0) len.* -= 1;
        },
        else => {},
    }
}

test "password insert accumulates" {
    const io = std.testing.io_instance;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(alloc, "vault.kakuriyo");
    defer alloc.free(path);

    var ctrl = try Ctrl.init(io, alloc, path);
    defer ctrl.deinit();
    setController(&ctrl);

    const text = "hello";
    try handle(.{ .password_input = .{ .insert_text = text } });
    try std.testing.expectEqualStrings("hello", ctrl.passwordSlice());
}
