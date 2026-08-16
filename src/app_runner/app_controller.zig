//! Kakuriyo app controller — owns vault session, domain store, and UI
//! state. All vault mutations and CRUD run here (synchronously), not
//! through the compiled TS lane. The TS core carries number slots only;
//! this module syncs them after every handled action.

const std = @import("std");
const vault = @import("vault.zig");
const domain = @import("domain.zig");
const preview = @import("preview.zig");

pub const EditorField = enum(u8) {
    title,
    url,
    user,
    pass,
    body,
};

pub const TextInputEvent = union(enum) {
    insert_text: []const u8,
    delete_backward,
    delete_forward,
    clear,
};

pub const Phase = enum(u8) {
    fresh = 0,
    locked = 1,
    unlocked = 2,
};

pub const ErrorCode = enum(u32) {
    none = 0,
    wrong_password = 1,
    password_too_short = 2,
    password_mismatch = 3,
    blank_password = 4,
    io_failed = 5,
    corrupt = 6,
    locked = 7,
    domain_error = 8,
    lockout = 9,
    senhas_weak = 10,
    senhas_wrong = 11,
};

pub const Activity = enum(u8) {
    links = 0,
    senhas = 1,
};

pub const ModelSlots = struct {
    phase: u8 = 0,
    error_code: u32 = 0,
    selected_hi: u32 = 0,
    selected_lo: u32 = 0,
    tree_epoch: u32 = 0,
    reveal_secrets: u8 = 0,
    vim_motion: u8 = 0,
    activity: u8 = 0,
    show_delete_modal: u8 = 0,
    show_import_modal: u8 = 0,
    show_import_password_modal: u8 = 0,
    show_settings_modal: u8 = 0,
    show_change_password_modal: u8 = 0,
    change_password_step: u8 = 0, // 0 current, 1 new+confirm
    show_merge_modal: u8 = 0,
    merge_conflict_index: u32 = 0,
    merge_conflict_count: u32 = 0,
    filter_active: u8 = 0,
    idle_preset: u8 = 1, // 5 min default index
    lockout_until_ms: u64 = 0,
    dirty: u8 = 0,
    confirm_password_mode: u8 = 0,
    focus_region: u8 = 0, // 0 tree, 1 editor
    senhas_gate_state: u8 = 0, // 0 unset, 1 locked, 2 unlocked
    senhas_error: u32 = 0,
    secret_index: u32 = 0,
};

pub const TreeRow = struct {
    id: domain.Uuid,
    parent_id: domain.Uuid,
    depth: u8,
    kind: u8, // 0 collection, 1 entry
    expanded: bool,
    secret_badge: bool,
    title: []const u8,
};

const max_tree_rows = 256;
pub const max_tree_rows_pub = max_tree_rows;
const max_entry_rows = 128;
pub const max_entry_rows_pub = max_entry_rows;
const max_password_len = 1024;
const min_master_password_len = 8;
const lockout_fail_limit = 5;
const lockout_duration_ms: u64 = 5 * 60 * 1000;
const idle_preset_ms = [_]u64{ 60_000, 300_000, 900_000, 1_800_000, 0 }; // 1/5/15/30 min, never

pub const AppController = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    session: vault.Session,
    store: domain.Store,
    slots: ModelSlots = .{},
    password_buf: [max_password_len]u8 = undefined,
    password_len: usize = 0,
    confirm_buf: [max_password_len]u8 = undefined,
    confirm_len: usize = 0,
    change_current_buf: [max_password_len]u8 = undefined,
    change_current_len: usize = 0,
    password_mask_buf: [max_password_len]u8 = undefined,
    confirm_mask_buf: [max_password_len]u8 = undefined,
    show_password: bool = false,
    unlock_fail_count: u8 = 0,
    tree_rows: [max_tree_rows]TreeRow = undefined,
    tree_row_count: usize = 0,
    entry_rows: [max_entry_rows]TreeRow = undefined,
    entry_row_count: usize = 0,
    group_buf: [256]u8 = undefined,
    group_len: usize = 0,
    expanded: std.AutoHashMapUnmanaged(u64, void) = .empty,
    editor_title: []u8 = undefined,
    editor_title_len: usize = 0,
    editor_url: []u8 = undefined,
    editor_url_len: usize = 0,
    editor_user: []u8 = undefined,
    editor_user_len: usize = 0,
    editor_pass: []u8 = undefined,
    editor_pass_len: usize = 0,
    editor_body: []u8 = undefined,
    editor_body_len: usize = 0,
    filter_buf: [256]u8 = undefined,
    filter_len: usize = 0,
    last_activity_ms: u64 = 0,
    selected_id: ?domain.Uuid = null,
    clipboard_node: ?domain.Uuid = null,
    vault_exists_on_disk: bool = false,
    merge_import: ?domain.Store = null,
    merge_conflicts: std.ArrayListUnmanaged(domain.Store.MergeConflict) = .empty,
    merge_resolutions: std.ArrayListUnmanaged(domain.Store.MergeResolution) = .empty,
    paste_buf: [65536]u8 = undefined,
    paste_len: usize = 0,
    senhas_gate_unlocked: bool = false,
    preview_fetch_count: u32 = 0,
    selected_secret: ?domain.Uuid = null,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !AppController {
        var ctrl: AppController = .{
            .io = io,
            .allocator = allocator,
            .session = try vault.Session.init(io, allocator, path),
            .store = domain.Store.init(allocator),
            .editor_title = try allocator.alloc(u8, 4096),
            .editor_url = try allocator.alloc(u8, 4096),
            .editor_user = try allocator.alloc(u8, 4096),
            .editor_pass = try allocator.alloc(u8, 4096),
            .editor_body = try allocator.alloc(u8, 65536),
        };
        ctrl.vault_exists_on_disk = fileExists(io, path);
        if (ctrl.vault_exists_on_disk) {
            ctrl.slots.phase = @intFromEnum(Phase.locked);
        } else {
            ctrl.slots.phase = @intFromEnum(Phase.fresh);
        }
        ctrl.touchActivity();
        return ctrl;
    }

    pub fn deinit(self: *AppController) void {
        self.clearMergePending();
        self.store.deinit();
        self.session.deinit();
        self.expanded.deinit(self.allocator);
        self.allocator.free(self.editor_title);
        self.allocator.free(self.editor_url);
        self.allocator.free(self.editor_user);
        self.allocator.free(self.editor_pass);
        self.allocator.free(self.editor_body);
        self.* = undefined;
    }

    pub fn syncSlots(self: *const AppController, out: *ModelSlots) void {
        out.* = self.slots;
        if (self.selected_id) |id| {
            out.selected_hi = std.mem.readInt(u32, id[0..4], .little);
            out.selected_lo = std.mem.readInt(u32, id[4..8], .little);
        } else {
            out.selected_hi = 0;
            out.selected_lo = 0;
        }
    }

    pub fn applySlots(self: *AppController, slots: ModelSlots) void {
        self.slots = slots;
    }

    pub fn clearPassword(self: *AppController) void {
        std.crypto.secureZero(u8, self.password_buf[0..self.password_len]);
        self.password_len = 0;
        std.crypto.secureZero(u8, self.confirm_buf[0..self.confirm_len]);
        self.confirm_len = 0;
    }

    fn clearChangePasswordBuffers(self: *AppController) void {
        std.crypto.secureZero(u8, self.change_current_buf[0..self.change_current_len]);
        self.change_current_len = 0;
        self.clearPassword();
    }

    pub fn beginChangePassword(self: *AppController) void {
        self.clearChangePasswordBuffers();
        self.slots.show_change_password_modal = 1;
        self.slots.change_password_step = 0;
        self.clearError();
    }

    pub fn dismissChangePassword(self: *AppController) void {
        self.slots.show_change_password_modal = 0;
        self.slots.change_password_step = 0;
        self.clearChangePasswordBuffers();
        self.clearError();
    }

    pub fn changePasswordNext(self: *AppController) void {
        self.clearError();
        if (@as(Phase, @enumFromInt(self.slots.phase)) != .unlocked) {
            self.setError(.locked);
            return;
        }
        if (self.password_len == 0) {
            self.setError(.blank_password);
            return;
        }
        const len = @min(self.password_len, max_password_len);
        @memcpy(self.change_current_buf[0..len], self.password_buf[0..len]);
        self.change_current_len = len;
        std.crypto.secureZero(u8, self.password_buf[0..self.password_len]);
        self.password_len = 0;
        self.slots.change_password_step = 1;
    }

    pub fn submitChangePassword(self: *AppController) void {
        self.clearError();
        if (@as(Phase, @enumFromInt(self.slots.phase)) != .unlocked) {
            self.setError(.locked);
            return;
        }
        if (self.password_len < min_master_password_len) {
            self.setError(.password_too_short);
            return;
        }
        if (self.confirm_len != self.password_len or
            !std.mem.eql(u8, self.passwordSlice(), self.confirmSlice()))
        {
            self.setError(.password_mismatch);
            return;
        }
        const current = self.change_current_buf[0..self.change_current_len];
        const next = self.passwordSlice();
        self.session.changePassword(current, next) catch |err| {
            self.setError(switch (err) {
                error.WrongPassword => .wrong_password,
                error.Locked => .locked,
                else => .io_failed,
            });
            return;
        };
        self.dismissChangePassword();
        self.touchActivity();
    }

    pub fn setPasswordText(self: *AppController, text: []const u8) void {
        const len = @min(text.len, max_password_len);
        @memcpy(self.password_buf[0..len], text[0..len]);
        self.password_len = len;
    }

    pub fn setConfirmText(self: *AppController, text: []const u8) void {
        const len = @min(text.len, max_password_len);
        @memcpy(self.confirm_buf[0..len], text[0..len]);
        self.confirm_len = len;
    }

    pub fn toggleShowPassword(self: *AppController) void {
        self.show_password = !self.show_password;
    }

    pub fn passwordSlice(self: *const AppController) []const u8 {
        return self.password_buf[0..self.password_len];
    }

    pub fn confirmSlice(self: *const AppController) []const u8 {
        return self.confirm_buf[0..self.confirm_len];
    }

    /// Visible text for password fields: plaintext when revealed, `*` per byte when hidden.
    pub fn passwordDisplay(self: *AppController) []const u8 {
        return maskedOrPlain(self.show_password, self.passwordSlice(), self.password_mask_buf[0..]);
    }

    pub fn confirmDisplay(self: *AppController) []const u8 {
        return maskedOrPlain(self.show_password, self.confirmSlice(), self.confirm_mask_buf[0..]);
    }

    pub fn setError(self: *AppController, code: ErrorCode) void {
        self.slots.error_code = @intFromEnum(code);
    }

    pub fn clearError(self: *AppController) void {
        self.slots.error_code = @intFromEnum(ErrorCode.none);
    }

    pub fn isLockoutActive(self: *const AppController) bool {
        if (self.slots.lockout_until_ms == 0) return false;
        return nowMs(self) < self.slots.lockout_until_ms;
    }

    pub fn touchActivity(self: *AppController) void {
        self.last_activity_ms = nowMs(self);
    }

    pub fn idleLimitMs(self: *const AppController) u64 {
        const idx = @min(self.slots.idle_preset, idle_preset_ms.len - 1);
        return idle_preset_ms[idx];
    }

    pub fn checkIdleLock(self: *AppController) void {
        if (@as(Phase, @enumFromInt(self.slots.phase)) != .unlocked) return;
        const limit = self.idleLimitMs();
        if (limit == 0) return;
        const elapsed = nowMs(self) - self.last_activity_ms;
        if (elapsed >= limit) self.lock();
    }

    pub fn vaultPath(self: *const AppController) []const u8 {
        return self.session.path;
    }

    pub fn unlock(self: *AppController) void {
        self.clearError();
        if (self.isLockoutActive()) {
            self.setError(.lockout);
            return;
        }
        if (self.password_len == 0) {
            self.setError(.blank_password);
            return;
        }
        const pw = self.passwordSlice();
        const payload = self.session.unlock(pw) catch |err| {
            self.unlock_fail_count += 1;
            if (self.unlock_fail_count >= lockout_fail_limit) {
                self.slots.lockout_until_ms = nowMs(self) + lockout_duration_ms;
                self.setError(.lockout);
                return;
            }
            self.setError(switch (err) {
                error.WrongPassword => .wrong_password,
                error.NotFound => .io_failed,
                error.Corrupt => .corrupt,
                else => .io_failed,
            });
            return;
        };
        self.loadStoreFromPayload(payload) catch {
            self.setError(.corrupt);
            self.session.lock();
            return;
        };
        self.unlock_fail_count = 0;
        self.slots.lockout_until_ms = 0;
        self.slots.phase = @intFromEnum(Phase.unlocked);
        self.senhas_gate_unlocked = false;
        self.syncSenhasGateSlot();
        self.rebuildTree();
        self.clearPassword();
        self.touchActivity();
    }

    pub fn createVault(self: *AppController) void {
        self.clearError();
        if (self.password_len < min_master_password_len) {
            self.setError(.password_too_short);
            return;
        }
        if (self.confirm_len != self.password_len or
            !std.mem.eql(u8, self.passwordSlice(), self.confirmSlice()))
        {
            self.setError(.password_mismatch);
            return;
        }
        const pw = self.passwordSlice();
        self.session.create(pw, vault.defaultParams()) catch {
            self.setError(.io_failed);
            return;
        };
        self.store.deinit();
        self.store = domain.Store.init(self.allocator);
        self.persistDomain() catch {
            self.setError(.io_failed);
            return;
        };
        self.vault_exists_on_disk = true;
        self.slots.phase = @intFromEnum(Phase.unlocked);
        self.slots.confirm_password_mode = 0;
        self.rebuildTree();
        self.clearPassword();
        self.touchActivity();
    }

    pub fn addEntry(self: *AppController) void {
        self.clearError();
        const parent = self.parentForNewEntry();
        const id = self.newUuid();
        const now = nowMs(self);
        var suffix: u32 = 0;
        while (true) {
            var title_buf: [64]u8 = undefined;
            const title = if (suffix == 0)
                "New Entry"
            else
                std.fmt.bufPrint(&title_buf, "New Entry {d}", .{suffix}) catch {
                    self.setError(.domain_error);
                    return;
                };
            self.store.addEntry(id, parent, title, "", "", now, now) catch |err| {
                if (err == error.DuplicateName and suffix < 128) {
                    suffix += 1;
                    continue;
                }
                self.setError(.domain_error);
                return;
            };
            break;
        }
        self.persistDomain() catch {
            self.setError(.io_failed);
            return;
        };
        self.rebuildTree();
        self.selectNode(id);
        self.slots.dirty = 0;
        self.touchActivity();
    }

    pub fn addCollection(self: *AppController) void {
        self.clearError();
        const parent = self.parentForNewCollection();
        const id = self.newUuid();
        var suffix: u32 = 0;
        while (true) {
            var name_buf: [64]u8 = undefined;
            const name = if (suffix == 0)
                "New Collection"
            else
                std.fmt.bufPrint(&name_buf, "New Collection {d}", .{suffix}) catch {
                    self.setError(.domain_error);
                    return;
                };
            self.store.addCollection(id, parent, name) catch |err| {
                if (err == error.DuplicateName and suffix < 128) {
                    suffix += 1;
                    continue;
                }
                self.setError(.domain_error);
                return;
            };
            break;
        }
        self.persistDomain() catch {
            self.setError(.io_failed);
            return;
        };
        const key = uuidKey(id);
        self.expanded.put(self.allocator, key, {}) catch {};
        self.rebuildTree();
        self.selectNode(id);
        self.touchActivity();
    }

    pub fn saveEditor(self: *AppController) void {
        self.clearError();
        const id = self.selected_id orelse return;
        const title = self.editor_title[0..self.editor_title_len];
        if (title.len == 0 or std.mem.trim(u8, title, " \t\r\n").len == 0) {
            self.setError(.domain_error);
            return;
        }
        if (self.findCollection(id)) |c| {
            self.store.updateCollection(id, c.parent_id, title) catch {
                self.setError(.domain_error);
                return;
            };
            self.persistDomain() catch {
                self.setError(.io_failed);
                return;
            };
            self.slots.dirty = 0;
            self.rebuildTree();
            self.touchActivity();
            return;
        }
        if (self.findEntry(id) == null) return;

        const body = self.composeBodyAlloc() catch {
            self.setError(.io_failed);
            return;
        };
        defer self.allocator.free(body);
        const now = nowMs(self);
        self.store.updateEntry(
            id,
            title,
            self.editor_url[0..self.editor_url_len],
            body,
            now,
        ) catch {
            self.setError(.domain_error);
            return;
        };
        self.persistDomain() catch {
            self.setError(.io_failed);
            return;
        };
        self.slots.dirty = 0;
        self.rebuildTree();
        self.touchActivity();
    }

    pub fn refreshPreviewForSelected(self: *AppController) void {
        const id = self.selected_id orelse return;
        const url = self.editor_url[0..self.editor_url_len];
        if (url.len == 0) return;
        // Network budget (800ms): select path never calls this; Save/Refresh may.
        // TimedOut / NetworkFailed leave prior Vault cache untouched.
        var fetched = preview.fetchPreview(self.io, self.allocator, url) catch return;
        defer fetched.deinit(self.allocator);
        self.preview_fetch_count += 1;
        self.store.setPreview(id, fetched.title, fetched.description, fetched.image) catch return;
        self.persistDomain() catch {};
    }

    pub fn openSelectedUrl(self: *AppController) void {
        const url = self.editor_url[0..self.editor_url_len];
        if (url.len == 0) return;
        openUrlExternal(self.io, url) catch {};
        self.touchActivity();
    }

    pub fn cutSelectedNode(self: *AppController) void {
        self.clipboard_node = self.selected_id;
        self.touchActivity();
    }

    pub fn pasteClipboardNode(self: *AppController) void {
        const node_id = self.clipboard_node orelse return;
        const target_parent = self.parentForNewEntry();
        const idx = self.store.findIndex(node_id) orelse return;
        switch (self.store.nodes.items[idx]) {
            .entry => self.store.moveEntry(node_id, target_parent) catch {
                self.setError(.domain_error);
                return;
            },
            .collection => self.store.moveCollection(node_id, target_parent) catch {
                self.setError(.domain_error);
                return;
            },
        }
        self.persistDomain() catch {
            self.setError(.io_failed);
            return;
        };
        self.rebuildTree();
        self.selectNode(node_id);
        self.touchActivity();
    }

    pub fn cycleIdlePreset(self: *AppController) void {
        self.slots.idle_preset = @intCast((@as(usize, self.slots.idle_preset) + 1) % idle_preset_ms.len);
        self.touchActivity();
    }

    pub fn idlePresetLabel(self: *const AppController) []const u8 {
        return switch (self.slots.idle_preset) {
            0 => "1 min",
            1 => "5 min",
            2 => "15 min",
            3 => "30 min",
            else => "Never",
        };
    }

    pub fn previewTitle(self: *const AppController) []const u8 {
        if (self.selected_id) |id| {
            if (self.findEntry(id)) |e| {
                if (e.preview_title.len > 0) return e.preview_title;
            }
        }
        return "";
    }

    pub fn previewDescription(self: *const AppController) []const u8 {
        if (self.selected_id) |id| {
            if (self.findEntry(id)) |e| {
                if (e.preview_description.len > 0) return e.preview_description;
            }
        }
        return "";
    }

    pub fn previewImage(self: *const AppController) []const u8 {
        if (self.selected_id) |id| {
            if (self.findEntry(id)) |e| {
                return e.preview_image;
            }
        }
        return "";
    }

    pub fn beginImport(self: *AppController) void {
        self.slots.show_import_modal = 1;
    }

    pub fn importReplace(self: *AppController) void {
        self.slots.show_import_modal = 0;
        self.importVaultReplace();
    }

    pub fn importMerge(self: *AppController) void {
        self.clearError();
        const dst = self.session.path;
        var src_buf: [4096]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "{s}.import", .{dst}) catch {
            self.setError(.io_failed);
            return;
        };
        if (!fileExists(self.io, src)) {
            self.setError(.io_failed);
            return;
        }
        self.slots.show_import_modal = 0;
        self.slots.show_import_password_modal = 1;
        self.clearPassword();
    }

    pub fn dismissImportPassword(self: *AppController) void {
        self.slots.show_import_password_modal = 0;
        self.clearPassword();
        self.clearError();
    }

    pub fn submitImportPassword(self: *AppController) void {
        self.clearError();
        if (self.isLockoutActive()) {
            self.setError(.lockout);
            return;
        }
        if (self.password_len == 0) {
            self.setError(.blank_password);
            return;
        }
        const dst = self.session.path;
        var src_buf: [4096]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "{s}.import", .{dst}) catch {
            self.setError(.io_failed);
            return;
        };
        const pw = self.passwordSlice();
        const payload = vault.decryptPayloadFile(self.io, self.allocator, src, pw) catch |err| {
            self.unlock_fail_count += 1;
            if (self.unlock_fail_count >= lockout_fail_limit) {
                self.slots.lockout_until_ms = nowMs(self) + lockout_duration_ms;
                self.setError(.lockout);
                return;
            }
            self.setError(switch (err) {
                error.WrongPassword => .wrong_password,
                error.NotFound => .io_failed,
                error.Corrupt => .corrupt,
                else => .io_failed,
            });
            return;
        };
        defer self.allocator.free(payload);
        self.unlock_fail_count = 0;
        self.slots.lockout_until_ms = 0;
        self.slots.show_import_password_modal = 0;
        self.clearPassword();
        self.importVaultMergeFromPayload(payload);
    }

    fn importVaultReplace(self: *AppController) void {
        self.clearError();
        if (self.isLockoutActive()) {
            self.setError(.lockout);
            return;
        }
        const dst = self.session.path;
        var src_buf: [4096]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "{s}.import", .{dst}) catch {
            self.setError(.io_failed);
            return;
        };
        if (!fileExists(self.io, src)) {
            self.setError(.io_failed);
            return;
        }
        var bak_buf: [4096]u8 = undefined;
        const bak = std.fmt.bufPrint(&bak_buf, "{s}.bak", .{dst}) catch {
            self.setError(.io_failed);
            return;
        };
        if (fileExists(self.io, dst)) {
            copyFile(self.io, dst, bak) catch {
                self.setError(.io_failed);
                return;
            };
        }
        copyFile(self.io, src, dst) catch {
            self.setError(.io_failed);
            return;
        };
        self.lock();
        self.vault_exists_on_disk = true;
        self.slots.phase = @intFromEnum(Phase.locked);
        self.touchActivity();
    }

    fn importVaultMergeFromPayload(self: *AppController, payload: []const u8) void {
        self.clearError();
        var imported = domain.Store.decode(self.allocator, payload) catch {
            self.setError(.corrupt);
            return;
        };

        self.clearMergePending();
        self.store.scanMergeConflicts(&imported, &self.merge_conflicts) catch {
            imported.deinit();
            self.setError(.domain_error);
            return;
        };

        if (self.merge_conflicts.items.len == 0) {
            self.store.mergeFrom(&imported) catch {
                imported.deinit();
                self.setError(.domain_error);
                return;
            };
            imported.deinit();
            self.persistDomain() catch {
                self.setError(.io_failed);
                return;
            };
            self.rebuildTree();
            self.touchActivity();
            return;
        }

        self.merge_import = imported;
        self.slots.show_merge_modal = 1;
        self.slots.merge_conflict_index = 0;
        self.slots.merge_conflict_count = @intCast(self.merge_conflicts.items.len);
        self.touchActivity();
    }

    pub fn dismissMerge(self: *AppController) void {
        self.clearMergePending();
        self.slots.show_merge_modal = 0;
        self.slots.merge_conflict_index = 0;
        self.slots.merge_conflict_count = 0;
    }

    pub fn pickMergeResolution(self: *AppController, resolution: domain.Store.MergeResolution) void {
        if (self.merge_import == null) return;
        self.merge_resolutions.append(self.allocator, resolution) catch {
            self.setError(.domain_error);
            return;
        };
        self.slots.merge_conflict_index += 1;
        if (self.slots.merge_conflict_index >= self.slots.merge_conflict_count) {
            self.applyPendingMerge();
        }
    }

    fn applyPendingMerge(self: *AppController) void {
        const imported = self.merge_import orelse return;
        if (self.merge_resolutions.items.len != self.merge_conflicts.items.len) {
            self.setError(.domain_error);
            return;
        }
        self.store.mergeFromWithResolutions(
            &imported,
            self.merge_conflicts.items,
            self.merge_resolutions.items,
        ) catch {
            self.setError(.domain_error);
            return;
        };
        self.dismissMerge();
        self.persistDomain() catch {
            self.setError(.io_failed);
            return;
        };
        self.rebuildTree();
        self.touchActivity();
    }

    fn clearMergePending(self: *AppController) void {
        if (self.merge_import) |*st| {
            st.deinit();
            self.merge_import = null;
        }
        self.merge_conflicts.deinit(self.allocator);
        self.merge_conflicts = .empty;
        self.merge_resolutions.deinit(self.allocator);
        self.merge_resolutions = .empty;
    }

    pub fn mergeConflictLabel(self: *const AppController) []const u8 {
        const idx: usize = @intCast(self.slots.merge_conflict_index);
        if (self.merge_import == null or idx >= self.merge_conflicts.items.len) return "";
        const conflict = self.merge_conflicts.items[idx];
        const imported = self.merge_import.?;
        const node = imported.nodes.items[conflict.other_node_index];
        return switch (node) {
            .collection => |c| c.name,
            .entry => |e| e.title,
        };
    }

    pub fn mergeConflictKindLabel(self: *const AppController) []const u8 {
        const idx: usize = @intCast(self.slots.merge_conflict_index);
        if (idx >= self.merge_conflicts.items.len) return "";
        return switch (self.merge_conflicts.items[idx].kind) {
            .uuid_exists => "same UUID",
            .name_collision => "name collision",
        };
    }

    pub fn deleteSelected(self: *AppController) void {
        self.clearError();
        const id = self.selected_id orelse return;
        const idx = self.store.findIndex(id) orelse return;
        switch (self.store.nodes.items[idx]) {
            .collection => self.store.deleteCollection(id) catch {
                self.setError(.domain_error);
                return;
            },
            .entry => self.store.deleteEntry(id) catch {
                self.setError(.domain_error);
                return;
            },
        }
        self.persistDomain() catch {
            self.setError(.io_failed);
            return;
        };
        self.selected_id = null;
        self.clearEditor();
        self.rebuildTree();
        self.touchActivity();
    }

    pub fn exportVault(self: *AppController) void {
        self.clearError();
        if (@as(Phase, @enumFromInt(self.slots.phase)) != .unlocked) {
            self.setError(.locked);
            return;
        }
        const src = self.session.path;
        var dst_buf: [4096]u8 = undefined;
        const dst = std.fmt.bufPrint(&dst_buf, "{s}.export", .{src}) catch {
            self.setError(.io_failed);
            return;
        };
        copyFile(self.io, src, dst) catch {
            self.setError(.io_failed);
            return;
        };
        var kdat_buf: [4096]u8 = undefined;
        const kdat_dst = std.fmt.bufPrint(&kdat_buf, "{s}.export.kdat", .{src}) catch {
            self.setError(.io_failed);
            return;
        };
        const encoded = self.store.encode(self.allocator) catch {
            self.setError(.io_failed);
            return;
        };
        defer self.allocator.free(encoded);
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = kdat_dst, .data = encoded }) catch {
            self.setError(.io_failed);
            return;
        };
        self.touchActivity();
    }

    pub fn importVault(self: *AppController) void {
        self.beginImport();
    }

    pub fn moveTreeSelection(self: *AppController, delta: i32) void {
        if (self.tree_row_count == 0) return;
        const cur = if (self.selected_id) |sid| self.findTreeIndex(sid) orelse 0 else 0;
        var next: i32 = @as(i32, @intCast(cur)) + delta;
        if (next < 0) next = 0;
        if (next >= self.tree_row_count) next = @intCast(self.tree_row_count - 1);
        self.selectNode(self.tree_rows[@intCast(next)].id);
        self.touchActivity();
    }

    pub fn applyEditorEdit(self: *AppController, field: EditorField, ev: TextInputEvent) void {
        var buf: []u8 = undefined;
        var len: *usize = undefined;
        switch (field) {
            .title => {
                buf = self.editor_title;
                len = &self.editor_title_len;
            },
            .url => {
                buf = self.editor_url;
                len = &self.editor_url_len;
            },
            .user => {
                buf = self.editor_user;
                len = &self.editor_user_len;
            },
            .pass => {
                buf = self.editor_pass;
                len = &self.editor_pass_len;
            },
            .body => {
                buf = self.editor_body;
                len = &self.editor_body_len;
            },
        }
        applyTextEdit(buf, len, ev);
        self.slots.dirty = 1;
        self.touchActivity();
    }

    pub fn applyFilterEdit(self: *AppController, ev: TextInputEvent) void {
        applyTextEdit(self.filter_buf[0..], &self.filter_len, ev);
        self.rebuildEntryList();
        self.touchActivity();
    }

    pub fn filterText(self: *const AppController) []const u8 {
        return self.filter_buf[0..self.filter_len];
    }

    pub fn rowMatchesFilter(self: *const AppController, title: []const u8) bool {
        if (self.slots.filter_active == 0 and self.filter_len == 0) return true;
        const q = self.filter_buf[0..self.filter_len];
        if (q.len == 0) return true;
        var lower_title: [512]u8 = undefined;
        var lower_q: [256]u8 = undefined;
        const tlen = @min(title.len, lower_title.len);
        const qlen = @min(q.len, lower_q.len);
        for (title[0..tlen], 0..) |ch, i| lower_title[i] = std.ascii.toLower(ch);
        for (q[0..qlen], 0..) |ch, i| lower_q[i] = std.ascii.toLower(ch);
        return std.mem.indexOf(u8, lower_title[0..tlen], lower_q[0..qlen]) != null;
    }

    pub fn lock(self: *AppController) void {
        if (self.slots.dirty != 0 and self.hasSelectedEntry()) {
            self.saveEditor();
        }
        self.session.lock();
        self.store.deinit();
        self.store = domain.Store.init(self.allocator);
        self.slots.phase = @intFromEnum(Phase.locked);
        self.slots.dirty = 0;
        self.selected_id = null;
        self.selected_secret = null;
        self.senhas_gate_unlocked = false;
        self.syncSenhasGateSlot();
        self.tree_row_count = 0;
        self.clearPassword();
        self.clearChangePasswordBuffers();
        self.slots.show_change_password_modal = 0;
        self.slots.change_password_step = 0;
        self.dismissMerge();
        self.clearError();
    }

    pub fn syncSenhasGateSlot(self: *AppController) void {
        if (self.store.secrets_gate == .unset) {
            self.slots.senhas_gate_state = 0;
        } else if (self.senhas_gate_unlocked) {
            self.slots.senhas_gate_state = 2;
        } else {
            self.slots.senhas_gate_state = 1;
        }
        self.slots.senhas_error = 0;
    }

    pub fn setActivity(self: *AppController, tab: u8) void {
        if (tab > 1) return;
        self.slots.activity = tab;
        if (tab == @intFromEnum(Activity.senhas)) {
            self.syncSenhasGateSlot();
        }
    }

    pub fn pasteText(self: *const AppController) []const u8 {
        return self.paste_buf[0..self.paste_len];
    }

    pub fn groupText(self: *const AppController) []const u8 {
        return self.group_buf[0..self.group_len];
    }

    pub fn applyGroupEdit(self: *AppController, ev: TextInputEvent) void {
        applyTextEdit(self.group_buf[0..], &self.group_len, ev);
    }

    pub fn applyPasteEdit(self: *AppController, ev: TextInputEvent) void {
        const pasted_urls = switch (ev) {
            .insert_text => |t| containsHttpScheme(t),
            else => false,
        };
        applyTextEdit(self.paste_buf[0..], &self.paste_len, ev);
        if (!pasted_urls) return;
        var extracted: [65536]u8 = undefined;
        const n = domain.formatExtractedUrls(self.paste_buf[0..self.paste_len], extracted[0..]);
        if (n == 0) return;
        @memcpy(self.paste_buf[0..n], extracted[0..n]);
        if (n < self.paste_len) {
            std.crypto.secureZero(u8, self.paste_buf[n..self.paste_len]);
        }
        self.paste_len = n;
    }

    pub fn ingestPaste(self: *AppController) void {
        if (@as(Phase, @enumFromInt(self.slots.phase)) != .unlocked) return;
        const dest = self.destinationForIngest() orelse {
            self.setError(.domain_error);
            return;
        };
        _ = self.store.ingestUrls(self.paste_buf[0..self.paste_len], nowMs(self), dest) catch {
            self.setError(.domain_error);
            return;
        };
        self.expanded.put(self.allocator, uuidKey(dest), {}) catch {};
        self.persistDomain() catch {
            self.setError(.io_failed);
            return;
        };
        std.crypto.secureZero(u8, self.paste_buf[0..self.paste_len]);
        self.paste_len = 0;
        self.group_len = 0;
        self.rebuildTree();
        self.selectNode(dest);
        self.touchActivity();
    }

    fn destinationForIngest(self: *AppController) ?domain.Uuid {
        const group = trimAscii(self.group_buf[0..self.group_len]);
        if (group.len > 0) {
            const parent = self.parentForNewCollection();
            return self.store.ensureNamedCollection(parent, group) catch null;
        }
        const current = self.parentForNewEntry();
        if (!std.mem.eql(u8, &current, &domain.root_parent)) return current;
        return self.store.ensureNamedCollection(domain.root_parent, domain.inbox_name) catch null;
    }

    pub fn createSenhasGate(self: *AppController) void {
        self.slots.senhas_error = 0;
        self.clearError();
        if (!domain.passwordMeetsSenhasPolicy(self.passwordSlice())) {
            self.setError(.senhas_weak);
            self.slots.senhas_error = @intFromEnum(ErrorCode.senhas_weak);
            return;
        }
        if (self.confirm_len != self.password_len or
            !std.mem.eql(u8, self.passwordSlice(), self.confirmSlice()))
        {
            self.setError(.password_mismatch);
            return;
        }
        self.store.setSecretsGateFromPassword(self.io, self.passwordSlice()) catch |err| switch (err) {
            error.WeakPassword => {
                self.setError(.senhas_weak);
                return;
            },
            else => {
                self.setError(.io_failed);
                return;
            },
        };
        self.persistDomain() catch {
            self.setError(.io_failed);
            return;
        };
        self.senhas_gate_unlocked = true;
        self.syncSenhasGateSlot();
        self.clearPassword();
    }

    pub fn unlockSenhasGate(self: *AppController) void {
        self.slots.senhas_error = 0;
        self.clearError();
        if (!self.store.verifySecretsGate(self.io, self.passwordSlice())) {
            self.setError(.senhas_wrong);
            self.slots.senhas_error = @intFromEnum(ErrorCode.senhas_wrong);
            return;
        }
        self.senhas_gate_unlocked = true;
        self.syncSenhasGateSlot();
        self.clearPassword();
    }

    pub fn addSecret(self: *AppController) void {
        if (!self.senhas_gate_unlocked) return;
        const id = self.store.addSecret("New secret", "", "", "", nowMs(self)) catch {
            self.setError(.domain_error);
            return;
        };
        self.persistDomain() catch {
            self.setError(.io_failed);
            return;
        };
        self.selectSecret(id);
    }

    pub fn selectSecret(self: *AppController, id: domain.Uuid) void {
        const secret = self.store.getSecret(id) orelse return;
        self.selected_secret = id;
        self.loadEditorFromSecret(secret);
        if (self.secretIndexOf(id)) |idx| self.slots.secret_index = @intCast(idx);
    }

    fn secretIndexOf(self: *const AppController, id: domain.Uuid) ?usize {
        for (self.store.secrets.items, 0..) |s, i| {
            if (std.mem.eql(u8, &s.id, &id)) return i;
        }
        return null;
    }

    fn loadEditorFromSecret(self: *AppController, secret: *const domain.Secret) void {
        self.editor_title_len = @min(secret.label.len, self.editor_title.len);
        @memcpy(self.editor_title[0..self.editor_title_len], secret.label[0..self.editor_title_len]);
        self.editor_url_len = 0;
        self.editor_user_len = @min(secret.username.len, self.editor_user.len);
        @memcpy(self.editor_user[0..self.editor_user_len], secret.username[0..self.editor_user_len]);
        self.editor_pass_len = @min(secret.password.len, self.editor_pass.len);
        @memcpy(self.editor_pass[0..self.editor_pass_len], secret.password[0..self.editor_pass_len]);
        self.editor_body_len = @min(secret.notes.len, self.editor_body.len);
        @memcpy(self.editor_body[0..self.editor_body_len], secret.notes[0..self.editor_body_len]);
        self.slots.dirty = 0;
    }

    pub fn saveSecret(self: *AppController) void {
        const id = self.selected_secret orelse return;
        self.store.updateSecret(
            id,
            self.editor_title[0..self.editor_title_len],
            self.editor_user[0..self.editor_user_len],
            self.editor_pass[0..self.editor_pass_len],
            self.editor_body[0..self.editor_body_len],
            nowMs(self),
        ) catch {
            self.setError(.domain_error);
            return;
        };
        self.persistDomain() catch {
            self.setError(.io_failed);
            return;
        };
        self.slots.dirty = 0;
    }

    pub fn deleteSelectedSecret(self: *AppController) void {
        const id = self.selected_secret orelse return;
        self.store.deleteSecret(id) catch {
            self.setError(.domain_error);
            return;
        };
        self.selected_secret = null;
        self.persistDomain() catch {
            self.setError(.io_failed);
            return;
        };
    }

    pub fn persistDomain(self: *AppController) !void {
        const encoded = try self.store.encode(self.allocator);
        defer self.allocator.free(encoded);
        try self.session.save(encoded);
        self.slots.dirty = 0;
    }

    fn loadStoreFromPayload(self: *AppController, payload: []const u8) !void {
        self.store.deinit();
        self.store = if (payload.len == 0)
            domain.Store.init(self.allocator)
        else
            try domain.Store.decode(self.allocator, payload);
    }

    pub fn rebuildTree(self: *AppController) void {
        self.tree_row_count = 0;
        self.appendTreeChildren(domain.root_parent, 0);
        self.rebuildEntryList();
        self.slots.tree_epoch +%= 1;
    }

    fn appendTreeChildren(self: *AppController, parent_id: domain.Uuid, depth: u8) void {
        for (self.store.nodes.items) |node| {
            if (self.tree_row_count >= max_tree_rows) return;
            const c = switch (node) {
                .collection => |col| col,
                .entry => continue,
            };
            if (!std.mem.eql(u8, &c.parent_id, &parent_id)) continue;
            const id_key = uuidKey(c.id);
            const expanded = self.expanded.contains(id_key);
            self.tree_rows[self.tree_row_count] = .{
                .id = c.id,
                .parent_id = c.parent_id,
                .depth = depth,
                .kind = 0,
                .expanded = expanded,
                .secret_badge = false,
                .title = c.name,
            };
            self.tree_row_count += 1;
            if (expanded) {
                self.appendTreeChildren(c.id, depth +| 1);
            }
        }
    }

    pub fn listingCollectionId(self: *const AppController) ?domain.Uuid {
        const id = self.selected_id orelse return null;
        if (self.findCollection(id) != null) return id;
        if (self.findEntry(id)) |e| return e.parent_id;
        return null;
    }

    pub fn rebuildEntryList(self: *AppController) void {
        self.entry_row_count = 0;
        const parent_id = self.listingCollectionId() orelse return;
        const filter = self.filter_buf[0..self.filter_len];
        for (self.store.nodes.items) |node| {
            if (self.entry_row_count >= max_entry_rows) return;
            const e = switch (node) {
                .entry => |en| en,
                .collection => continue,
            };
            if (!std.mem.eql(u8, &e.parent_id, &parent_id)) continue;
            if (filter.len > 0) {
                if (std.ascii.indexOfIgnoreCase(e.title, filter) == null and
                    std.ascii.indexOfIgnoreCase(e.url, filter) == null)
                {
                    continue;
                }
            }
            self.entry_rows[self.entry_row_count] = .{
                .id = e.id,
                .parent_id = e.parent_id,
                .depth = 0,
                .kind = 1,
                .expanded = false,
                .secret_badge = false,
                .title = e.title,
            };
            self.entry_row_count += 1;
        }
    }

    pub fn selectEntryAt(self: *AppController, index: usize) void {
        if (index >= self.entry_row_count) return;
        self.selectNode(self.entry_rows[index].id);
        self.slots.focus_region = 1;
    }

    pub fn toggleExpanded(self: *AppController, id: domain.Uuid) void {
        const key = uuidKey(id);
        if (self.expanded.contains(key)) {
            _ = self.expanded.remove(key);
        } else {
            self.expanded.put(self.allocator, key, {}) catch return;
        }
        self.rebuildTree();
    }

    pub fn selectNode(self: *AppController, id: domain.Uuid) void {
        self.selected_id = id;
        if (self.findEntry(id)) |entry| {
            self.loadEditorFromEntry(entry);
        } else if (self.findCollection(id)) |c| {
            self.loadEditorFromCollection(c);
        } else {
            self.clearEditor();
        }
        self.rebuildEntryList();
    }

    pub fn hasSelectedEntry(self: *const AppController) bool {
        if (self.selected_id) |id| return self.findEntry(id) != null;
        return false;
    }

    pub fn hasSelectedCollection(self: *const AppController) bool {
        if (self.selected_id) |id| return self.findCollection(id) != null;
        return false;
    }

    pub fn findEntry(self: *const AppController, id: domain.Uuid) ?domain.Entry {
        const idx = self.store.findIndex(id) orelse return null;
        return switch (self.store.nodes.items[idx]) {
            .entry => |e| e,
            .collection => return null,
        };
    }

    pub fn findCollection(self: *const AppController, id: domain.Uuid) ?domain.Collection {
        const idx = self.store.findIndex(id) orelse return null;
        return switch (self.store.nodes.items[idx]) {
            .collection => |c| c,
            .entry => return null,
        };
    }

    fn loadEditorFromCollection(self: *AppController, collection: domain.Collection) void {
        self.editor_title_len = @min(collection.name.len, self.editor_title.len);
        @memcpy(self.editor_title[0..self.editor_title_len], collection.name[0..self.editor_title_len]);
        self.editor_url_len = 0;
        self.editor_user_len = 0;
        self.editor_pass_len = 0;
        self.editor_body_len = 0;
        self.slots.dirty = 0;
    }

    fn loadEditorFromEntry(self: *AppController, entry: domain.Entry) void {
        self.editor_title_len = @min(entry.title.len, self.editor_title.len);
        @memcpy(self.editor_title[0..self.editor_title_len], entry.title[0..self.editor_title_len]);
        self.editor_url_len = @min(entry.url.len, self.editor_url.len);
        @memcpy(self.editor_url[0..self.editor_url_len], entry.url[0..self.editor_url_len]);
        self.editor_user_len = 0;
        self.editor_pass_len = 0;
        self.editor_body_len = 0;

        var offset: usize = 0;
        var notes: std.ArrayListUnmanaged(u8) = .empty;
        errdefer notes.deinit(self.allocator);

        while (offset < entry.body.len) {
            const line_end = std.mem.indexOfScalarPos(u8, entry.body, offset, '\n') orelse entry.body.len;
            const line = entry.body[offset..line_end];
            if (std.ascii.startsWithIgnoreCase(line, "user:")) {
                const val = std.mem.trim(u8, line["user:".len..], " \t");
                self.editor_user_len = @min(val.len, self.editor_user.len);
                @memcpy(self.editor_user[0..self.editor_user_len], val[0..self.editor_user_len]);
            } else if (std.ascii.startsWithIgnoreCase(line, "password:")) {
                const val = std.mem.trim(u8, line["password:".len..], " \t");
                self.editor_pass_len = @min(val.len, self.editor_pass.len);
                @memcpy(self.editor_pass[0..self.editor_pass_len], val[0..self.editor_pass_len]);
            } else {
                notes.appendSlice(self.allocator, line) catch break;
                if (line_end < entry.body.len) notes.append(self.allocator, '\n') catch break;
            }
            offset = if (line_end < entry.body.len) line_end + 1 else entry.body.len;
        }
        self.editor_body_len = @min(notes.items.len, self.editor_body.len);
        @memcpy(self.editor_body[0..self.editor_body_len], notes.items[0..self.editor_body_len]);
        notes.deinit(self.allocator);
        self.slots.dirty = 0;
    }

    fn clearEditor(self: *AppController) void {
        self.editor_title_len = 0;
        self.editor_url_len = 0;
        self.editor_user_len = 0;
        self.editor_pass_len = 0;
        self.editor_body_len = 0;
    }

    fn parentForNewEntry(self: *const AppController) domain.Uuid {
        if (self.selected_id) |id| {
            if (self.store.findIndex(id)) |idx| {
                return switch (self.store.nodes.items[idx]) {
                    .collection => |c| c.id,
                    .entry => |e| e.parent_id,
                };
            }
        }
        return domain.root_parent;
    }

    fn parentForNewCollection(self: *const AppController) domain.Uuid {
        if (self.selected_id) |id| {
            if (self.store.findIndex(id)) |idx| {
                if (self.store.nodes.items[idx] == .collection) return id;
            }
        }
        return domain.root_parent;
    }

    pub fn findTreeIndex(self: *const AppController, id: domain.Uuid) ?usize {
        for (0..self.tree_row_count) |i| {
            if (std.mem.eql(u8, &self.tree_rows[i].id, &id)) return i;
        }
        return null;
    }

    fn newUuid(self: *AppController) domain.Uuid {
        var id: domain.Uuid = undefined;
        self.io.random(&id);
        return id;
    }

    fn composeBodyAlloc(self: *AppController) ![]const u8 {
        if (self.editor_user_len == 0 and self.editor_pass_len == 0) {
            return try self.allocator.dupe(u8, self.editor_body[0..self.editor_body_len]);
        }
        var list: std.ArrayListUnmanaged(u8) = .empty;
        errdefer list.deinit(self.allocator);
        if (self.editor_user_len > 0) {
            try list.appendSlice(self.allocator, "user: ");
            try list.appendSlice(self.allocator, self.editor_user[0..self.editor_user_len]);
            try list.append(self.allocator, '\n');
        }
        if (self.editor_pass_len > 0) {
            try list.appendSlice(self.allocator, "password: ");
            try list.appendSlice(self.allocator, self.editor_pass[0..self.editor_pass_len]);
            try list.append(self.allocator, '\n');
        }
        if (self.editor_body_len > 0) {
            try list.appendSlice(self.allocator, self.editor_body[0..self.editor_body_len]);
        }
        return try list.toOwnedSlice(self.allocator);
    }

    pub fn editorTitle(self: *const AppController) []const u8 {
        return self.editor_title[0..self.editor_title_len];
    }
    pub fn editorUrl(self: *const AppController) []const u8 {
        return self.editor_url[0..self.editor_url_len];
    }
    pub fn editorUser(self: *const AppController) []const u8 {
        return self.editor_user[0..self.editor_user_len];
    }
    pub fn editorPass(self: *const AppController) []const u8 {
        return self.editor_pass[0..self.editor_pass_len];
    }
    pub fn editorBody(self: *const AppController) []const u8 {
        return self.editor_body[0..self.editor_body_len];
    }

    pub fn errorText(self: *const AppController) []const u8 {
        return switch (@as(ErrorCode, @enumFromInt(self.slots.error_code))) {
            .none => "",
            .wrong_password => "Wrong Master Password",
            .password_too_short => "Password must be at least 8 characters",
            .password_mismatch => "Passwords do not match",
            .blank_password => "Enter a Master Password",
            .io_failed => "Could not read or write the Vault file",
            .corrupt => "Vault data is corrupt",
            .locked => "Vault is locked",
            .domain_error => "Invalid Entry or Collection",
            .lockout => "Too many attempts — try again in 5 minutes",
            .senhas_weak => "Passwords gate needs uppercase, lowercase, digit, and special",
            .senhas_wrong => "Wrong gate password",
        };
    }

    pub fn phase(self: *const AppController) Phase {
        return @enumFromInt(self.slots.phase);
    }
};

pub fn uuidKey(id: domain.Uuid) u64 {
    return std.mem.readInt(u64, id[0..8], .little);
}

fn nowMs(ctrl: *const AppController) u64 {
    const ts = std.Io.Timestamp.now(ctrl.io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, 1_000_000));
}

fn containsHttpScheme(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "https://") != null or std.mem.indexOf(u8, text, "http://") != null;
}

fn maskedOrPlain(show: bool, plain: []const u8, mask_buf: []u8) []const u8 {
    if (show) return plain;
    const len = @min(plain.len, mask_buf.len);
    @memset(mask_buf[0..len], '*');
    return mask_buf[0..len];
}

fn trimAscii(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and std.ascii.isWhitespace(s[start])) start += 1;
    var end = s.len;
    while (end > start and std.ascii.isWhitespace(s[end - 1])) end -= 1;
    return s[start..end];
}

fn applyTextEdit(buf: []u8, len: *usize, ev: TextInputEvent) void {
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
        .delete_forward => {},
    }
}

fn openUrlExternal(io: std.Io, url: []const u8) CopyError!void {
    const argv = [_][]const u8{ "xdg-open", url };
    var child = std.process.spawn(io, .{ .argv = &argv }) catch return error.IoFailed;
    _ = child.wait(io) catch return error.IoFailed;
}

fn copyFile(io: std.Io, src: []const u8, dst: []const u8) CopyError!void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, src, std.heap.page_allocator, .unlimited) catch return error.IoFailed;
    defer std.heap.page_allocator.free(bytes);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = bytes }) catch return error.IoFailed;
}

const CopyError = error{IoFailed};

fn fileExists(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}
