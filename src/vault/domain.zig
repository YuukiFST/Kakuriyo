//! Domain model for the vault plaintext payload: Collections + Entries.
//! Serialized as a versioned blob (magic `KDAT`) stored inside the
//! encrypted envelope. Pure std — unit-tested without GTK.

const std = @import("std");

pub const magic = "KDAT";
pub const version: u32 = 3;
pub const version_v2: u32 = 2;
pub const version_v1: u32 = 1;
pub const uuid_len = 16;
pub const root_parent: [uuid_len]u8 = [_]u8{0} ** uuid_len;

pub const Kind = enum(u8) {
    collection = 1,
    entry = 2,
};

pub const DomainError = error{
    BlankTitle,
    DuplicateName,
    NotFound,
    InvalidParent,
    Cycle,
    Corrupt,
    UnsupportedVersion,
    OutOfMemory,
    WeakPassword,
};

pub const Uuid = [uuid_len]u8;

pub const Collection = struct {
    id: Uuid,
    parent_id: Uuid,
    name: []const u8,
};

pub const Entry = struct {
    id: Uuid,
    parent_id: Uuid,
    title: []const u8,
    url: []const u8,
    body: []const u8,
    preview_title: []const u8 = "",
    preview_description: []const u8 = "",
    preview_image: []const u8 = "",
    created_ms: u64,
    updated_ms: u64,
};

pub const Node = union(Kind) {
    collection: Collection,
    entry: Entry,
};

pub const SecretsGate = union(enum) {
    unset,
    set: struct {
        salt: [16]u8,
        t_cost: u32,
        m_cost: u32,
        p_cost: u32,
        hash: [32]u8,
    },
};

pub const Secret = struct {
    id: Uuid,
    label: []const u8,
    username: []const u8,
    password: []const u8,
    notes: []const u8,
    created_ms: u64,
    updated_ms: u64,
};

pub const inbox_name = "Inbox";

pub const senhas_gate_t_cost: u32 = 1;
pub const senhas_gate_m_cost: u32 = 8 * 1024;
pub const senhas_gate_p_cost: u32 = 1;

pub fn passwordMeetsSenhasPolicy(pw: []const u8) bool {
    var has_upper = false;
    var has_lower = false;
    var has_digit = false;
    var has_special = false;
    for (pw) |ch| {
        if (std.ascii.isUpper(ch)) has_upper = true;
        if (std.ascii.isLower(ch)) has_lower = true;
        if (std.ascii.isDigit(ch)) has_digit = true;
        if (!std.ascii.isAlphanumeric(ch)) has_special = true;
    }
    return has_upper and has_lower and has_digit and has_special;
}

pub const IngestResult = struct {
    created: u32 = 0,
    skipped_dup: u32 = 0,
    invalid: u32 = 0,
};

pub fn extractHost(url: []const u8) ?[]const u8 {
    const scheme_sep = std.mem.indexOf(u8, url, "://") orelse return null;
    const rest = url[scheme_sep + 3 ..];
    var end: usize = 0;
    while (end < rest.len) : (end += 1) {
        switch (rest[end]) {
            '/', ':', '?', '#' => break,
            else => {},
        }
    }
    if (end == 0) return null;
    return rest[0..end];
}

pub const UrlSpan = struct { start: usize, end: usize };

fn isTrailingUrlPunct(ch: u8) bool {
    return switch (ch) {
        '.', ',', ';', ')', ']', '>', '\'', '"' => true,
        else => false,
    };
}

/// Next `http://` / `https://` span in `text` at or after `from`.
/// Cuts at whitespace or the next scheme so glued URLs split.
pub fn nextHttpUrlSpan(text: []const u8, from: usize) ?UrlSpan {
    var search = from;
    while (search < text.len) {
        const rest = text[search..];
        const http_i = std.mem.indexOf(u8, rest, "http://");
        const https_i = std.mem.indexOf(u8, rest, "https://");
        const rel: usize = blk: {
            if (http_i == null and https_i == null) return null;
            if (http_i == null) break :blk https_i.?;
            if (https_i == null) break :blk http_i.?;
            break :blk @min(http_i.?, https_i.?);
        };
        const start = search + rel;
        const scheme_len: usize = if (std.mem.startsWith(u8, text[start..], "https://")) 8 else 7;
        var end = start + scheme_len;
        while (end < text.len) {
            if (std.ascii.isWhitespace(text[end])) break;
            if (std.mem.startsWith(u8, text[end..], "https://")) break;
            if (std.mem.startsWith(u8, text[end..], "http://")) break;
            end += 1;
        }
        while (end > start + scheme_len and isTrailingUrlPunct(text[end - 1])) {
            end -= 1;
        }
        if (end > start + scheme_len) {
            return .{ .start = start, .end = end };
        }
        search = start + scheme_len;
    }
    return null;
}

/// Write extracted URLs into `out`, one per line. Returns bytes written.
/// Returns 0 when no URL found (caller keeps original text).
pub fn formatExtractedUrls(text: []const u8, out: []u8) usize {
    var from: usize = 0;
    var o: usize = 0;
    var first = true;
    while (nextHttpUrlSpan(text, from)) |span| {
        from = span.end;
        const url = text[span.start..span.end];
        if (!first) {
            if (o >= out.len) break;
            out[o] = '\n';
            o += 1;
        }
        first = false;
        const take = @min(url.len, out.len - o);
        @memcpy(out[o .. o + take], url[0..take]);
        o += take;
        if (take < url.len) break;
    }
    return o;
}

pub fn normalizeHost(host: []const u8, out: []u8) []const u8 {
    const n = @min(host.len, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        out[i] = std.ascii.toLower(host[i]);
    }
    const lowered = out[0..n];
    if (std.mem.startsWith(u8, lowered, "www.") and lowered.len > 4) {
        return lowered[4..];
    }
    return lowered;
}

fn titleFromUrl(url: []const u8, buf: []u8) []const u8 {
    var path = url;
    if (std.mem.indexOf(u8, url, "://")) |sep| {
        path = url[sep + 3 ..];
        if (std.mem.indexOfScalar(u8, path, '/')) |slash| {
            path = path[slash..];
        } else {
            path = "";
        }
    }
    if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
    if (std.mem.indexOfScalar(u8, path, '#')) |h| path = path[0..h];
    while (path.len > 0 and path[path.len - 1] == '/') {
        path = path[0 .. path.len - 1];
    }
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        const tail = path[slash + 1 ..];
        if (tail.len > 0) return tail;
    }
    const n = @min(url.len, buf.len);
    @memcpy(buf[0..n], url[0..n]);
    return buf[0..n];
}

/// In-memory vault contents. Owns all string storage.
pub const Store = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    secrets_gate: SecretsGate = .unset,
    secrets: std.ArrayListUnmanaged(Secret) = .empty,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.nodes.items) |*node| {
            switch (node.*) {
                .collection => |*c| {
                    self.allocator.free(c.name);
                },
                .entry => |*e| {
                    self.allocator.free(e.title);
                    self.allocator.free(e.url);
                    self.allocator.free(e.body);
                    if (e.preview_title.len > 0) self.allocator.free(e.preview_title);
                    if (e.preview_description.len > 0) self.allocator.free(e.preview_description);
                    if (e.preview_image.len > 0) self.allocator.free(e.preview_image);
                },
            }
        }
        for (self.secrets.items) |*s| {
            self.allocator.free(s.label);
            self.allocator.free(s.username);
            std.crypto.secureZero(u8, @constCast(s.password));
            self.allocator.free(s.password);
            self.allocator.free(s.notes);
        }
        self.secrets.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn findIndex(self: *const Store, id: Uuid) ?usize {
        for (self.nodes.items, 0..) |node, i| {
            const node_id = switch (node) {
                .collection => |c| c.id,
                .entry => |e| e.id,
            };
            if (std.mem.eql(u8, &node_id, &id)) return i;
        }
        return null;
    }

    fn parentExists(self: *const Store, parent_id: Uuid) bool {
        if (std.mem.eql(u8, &parent_id, &root_parent)) return true;
        if (self.findIndex(parent_id)) |idx| {
            return self.nodes.items[idx] == .collection;
        }
        return false;
    }

    fn nameTakenUnderParent(self: *const Store, parent_id: Uuid, name: []const u8, skip_id: ?Uuid) bool {
        for (self.nodes.items) |node| {
            switch (node) {
                .collection => |c| {
                    if (!std.mem.eql(u8, &c.parent_id, &parent_id)) continue;
                    if (skip_id) |sid| {
                        if (std.mem.eql(u8, &c.id, &sid)) continue;
                    }
                    if (std.ascii.eqlIgnoreCase(c.name, name)) return true;
                },
                .entry => |e| {
                    if (!std.mem.eql(u8, &e.parent_id, &parent_id)) continue;
                    if (skip_id) |sid| {
                        if (std.mem.eql(u8, &e.id, &sid)) continue;
                    }
                    if (std.ascii.eqlIgnoreCase(e.title, name)) return true;
                },
            }
        }
        return false;
    }

    fn validateTitle(title: []const u8) DomainError!void {
        if (title.len == 0) return error.BlankTitle;
        if (std.mem.indexOfScalar(u8, title, 0) != null) return error.BlankTitle;
        for (title) |ch| {
            if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r') return;
        }
        return error.BlankTitle;
    }

    pub fn addCollection(self: *Store, id: Uuid, parent_id: Uuid, name: []const u8) DomainError!void {
        if (!self.parentExists(parent_id)) return error.InvalidParent;
        if (self.nameTakenUnderParent(parent_id, name, null)) return error.DuplicateName;
        if (self.findIndex(id) != null) return error.DuplicateName;
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.nodes.append(self.allocator, .{ .collection = .{
            .id = id,
            .parent_id = parent_id,
            .name = owned,
        } });
    }

    pub fn addEntry(
        self: *Store,
        id: Uuid,
        parent_id: Uuid,
        title: []const u8,
        url: []const u8,
        body: []const u8,
        created_ms: u64,
        updated_ms: u64,
    ) DomainError!void {
        try validateTitle(title);
        if (!self.parentExists(parent_id)) return error.InvalidParent;
        if (self.nameTakenUnderParent(parent_id, title, null)) return error.DuplicateName;
        if (self.findIndex(id) != null) return error.DuplicateName;

        const owned_title = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(owned_title);
        const owned_url = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(owned_url);
        const owned_body = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(owned_body);

        try self.nodes.append(self.allocator, .{ .entry = .{
            .id = id,
            .parent_id = parent_id,
            .title = owned_title,
            .url = owned_url,
            .body = owned_body,
            .preview_title = "",
            .preview_description = "",
            .preview_image = "",
            .created_ms = created_ms,
            .updated_ms = updated_ms,
        } });
    }

    pub fn getEntry(self: *const Store, id: Uuid) ?*const Entry {
        const idx = self.findIndex(id) orelse return null;
        return switch (self.nodes.items[idx]) {
            .entry => &self.nodes.items[idx].entry,
            .collection => null,
        };
    }

    pub fn setPreview(
        self: *Store,
        id: Uuid,
        preview_title: []const u8,
        preview_description: []const u8,
        image_bytes: []const u8,
    ) DomainError!void {
        const idx = self.findIndex(id) orelse return error.NotFound;
        const entry = switch (self.nodes.items[idx]) {
            .entry => |*e| e,
            .collection => return error.NotFound,
        };
        if (entry.preview_title.len > 0) self.allocator.free(entry.preview_title);
        if (entry.preview_description.len > 0) self.allocator.free(entry.preview_description);
        if (entry.preview_image.len > 0) self.allocator.free(entry.preview_image);
        entry.preview_title = try self.allocator.dupe(u8, preview_title);
        errdefer {
            self.allocator.free(entry.preview_title);
            entry.preview_title = "";
        }
        entry.preview_description = try self.allocator.dupe(u8, preview_description);
        errdefer {
            self.allocator.free(entry.preview_description);
            entry.preview_description = "";
        }
        entry.preview_image = try self.allocator.dupe(u8, image_bytes);
    }

    pub fn setEntryPreview(
        self: *Store,
        id: Uuid,
        preview_title: []const u8,
        preview_description: []const u8,
    ) DomainError!void {
        const idx = self.findIndex(id) orelse return error.NotFound;
        const entry = switch (self.nodes.items[idx]) {
            .entry => |*e| e,
            .collection => return error.NotFound,
        };
        if (entry.preview_title.len > 0) self.allocator.free(entry.preview_title);
        if (entry.preview_description.len > 0) self.allocator.free(entry.preview_description);
        entry.preview_title = try self.allocator.dupe(u8, preview_title);
        entry.preview_description = try self.allocator.dupe(u8, preview_description);
    }

    pub fn moveEntry(self: *Store, id: Uuid, new_parent: Uuid) DomainError!void {
        const idx = self.findIndex(id) orelse return error.NotFound;
        const entry = switch (self.nodes.items[idx]) {
            .entry => |*e| e,
            .collection => return error.NotFound,
        };
        if (!self.parentExists(new_parent)) return error.InvalidParent;
        if (self.nameTakenUnderParent(new_parent, entry.title, id)) return error.DuplicateName;
        entry.parent_id = new_parent;
    }

    pub fn moveCollection(self: *Store, id: Uuid, new_parent: Uuid) DomainError!void {
        const idx = self.findIndex(id) orelse return error.NotFound;
        const collection = switch (self.nodes.items[idx]) {
            .collection => |*c| c,
            .entry => return error.NotFound,
        };
        if (!self.parentExists(new_parent)) return error.InvalidParent;
        if (std.mem.eql(u8, &id, &new_parent)) return error.Cycle;
        if (self.isDescendant(id, new_parent)) return error.Cycle;
        if (self.nameTakenUnderParent(new_parent, collection.name, id)) return error.DuplicateName;
        collection.parent_id = new_parent;
    }

    fn isDescendant(self: *const Store, ancestor: Uuid, node: Uuid) bool {
        if (std.mem.eql(u8, &ancestor, &node)) return true;
        for (self.nodes.items) |n| {
            switch (n) {
                .collection => |c| {
                    if (!std.mem.eql(u8, &c.parent_id, &ancestor)) continue;
                    if (std.mem.eql(u8, &c.id, &node)) return true;
                    if (self.isDescendant(c.id, node)) return true;
                },
                .entry => |e| {
                    if (std.mem.eql(u8, &e.parent_id, &ancestor) and std.mem.eql(u8, &e.id, &node)) return true;
                },
            }
        }
        return false;
    }

    pub fn mergeFrom(self: *Store, other: *const Store) DomainError!void {
        var conflicts: std.ArrayListUnmanaged(MergeConflict) = .empty;
        defer conflicts.deinit(self.allocator);
        try self.scanMergeConflicts(other, &conflicts);
        if (conflicts.items.len == 0) {
            try self.mergeAuto(other);
            return;
        }
        const resolutions = try self.allocator.alloc(MergeResolution, conflicts.items.len);
        defer self.allocator.free(resolutions);
        for (resolutions) |*r| r.* = .keep_local;
        try self.mergeFromWithResolutions(other, conflicts.items, resolutions);
    }

    pub const MergeResolution = enum(u8) {
        keep_local = 0,
        keep_imported = 1,
        keep_both = 2,
    };

    pub const MergeConflictKind = enum(u8) {
        uuid_exists = 0,
        name_collision = 1,
    };

    pub const MergeConflict = struct {
        kind: MergeConflictKind,
        other_node_index: usize,
    };

    pub fn scanMergeConflicts(
        self: *const Store,
        other: *const Store,
        out: *std.ArrayListUnmanaged(MergeConflict),
    ) DomainError!void {
        for (other.nodes.items, 0..) |node, i| {
            switch (node) {
                .collection => |c| {
                    if (self.findIndex(c.id) != null) {
                        try out.append(self.allocator, .{ .kind = .uuid_exists, .other_node_index = i });
                    } else if (self.nameTakenUnderParent(c.parent_id, c.name, null)) {
                        try out.append(self.allocator, .{ .kind = .name_collision, .other_node_index = i });
                    }
                },
                .entry => |e| {
                    if (self.findIndex(e.id) != null) {
                        try out.append(self.allocator, .{ .kind = .uuid_exists, .other_node_index = i });
                    } else if (self.nameTakenUnderParent(e.parent_id, e.title, null)) {
                        try out.append(self.allocator, .{ .kind = .name_collision, .other_node_index = i });
                    }
                },
            }
        }
    }

    pub fn mergeFromWithResolutions(
        self: *Store,
        other: *const Store,
        conflicts: []const MergeConflict,
        resolutions: []const MergeResolution,
    ) DomainError!void {
        if (conflicts.len != resolutions.len) return error.Corrupt;

        var conflict_indices: std.AutoHashMapUnmanaged(usize, usize) = .empty;
        defer conflict_indices.deinit(self.allocator);
        for (conflicts, 0..) |c, ri| {
            try conflict_indices.put(self.allocator, c.other_node_index, ri);
        }

        for (other.nodes.items, 0..) |_, i| {
            if (conflict_indices.contains(i)) continue;
            const node = other.nodes.items[i];
            switch (node) {
                .collection => |c| try self.addCollection(c.id, c.parent_id, c.name),
                .entry => |e| {
                    try self.addEntry(e.id, e.parent_id, e.title, e.url, e.body, e.created_ms, e.updated_ms);
                    if (e.preview_title.len > 0 or e.preview_description.len > 0 or e.preview_image.len > 0) {
                        try self.setPreview(e.id, e.preview_title, e.preview_description, e.preview_image);
                    }
                },
            }
        }

        for (conflicts, resolutions) |conflict, resolution| {
            const node = other.nodes.items[conflict.other_node_index];
            try self.applyMergeResolution(conflict.kind, resolution, node);
        }
    }

    fn mergeAuto(self: *Store, other: *const Store) DomainError!void {
        for (other.nodes.items) |node| {
            switch (node) {
                .collection => |c| {
                    if (self.findIndex(c.id) == null) {
                        try self.addCollection(c.id, c.parent_id, c.name);
                    }
                },
                .entry => |e| {
                    if (self.findIndex(e.id) == null) {
                        try self.addEntry(e.id, e.parent_id, e.title, e.url, e.body, e.created_ms, e.updated_ms);
                        if (e.preview_title.len > 0 or e.preview_description.len > 0 or e.preview_image.len > 0) {
                            try self.setPreview(e.id, e.preview_title, e.preview_description, e.preview_image);
                        }
                    }
                },
            }
        }
    }

    fn applyMergeResolution(self: *Store, kind: MergeConflictKind, resolution: MergeResolution, node: Node) DomainError!void {
        switch (resolution) {
            .keep_local => {},
            .keep_imported => try self.applyKeepImported(kind, node),
            .keep_both => try self.applyKeepBoth(kind, node),
        }
    }

    fn applyKeepImported(self: *Store, kind: MergeConflictKind, node: Node) DomainError!void {
        switch (node) {
            .collection => |c| {
                if (kind == .uuid_exists) {
                    try self.updateCollection(c.id, c.parent_id, c.name);
                } else {
                    const local_id = self.findCollectionByNameUnderParent(c.parent_id, c.name) orelse return;
                    try self.deleteCollection(local_id);
                    try self.addCollection(c.id, c.parent_id, c.name);
                }
            },
            .entry => |e| {
                if (kind == .uuid_exists) {
                    try self.updateEntry(e.id, e.title, e.url, e.body, e.updated_ms);
                    try self.setPreview(e.id, e.preview_title, e.preview_description, e.preview_image);
                } else {
                    const local_id = self.findEntryByTitleUnderParent(e.parent_id, e.title) orelse return;
                    try self.deleteEntry(local_id);
                    try self.addEntry(e.id, e.parent_id, e.title, e.url, e.body, e.created_ms, e.updated_ms);
                    if (e.preview_title.len > 0 or e.preview_description.len > 0 or e.preview_image.len > 0) {
                        try self.setPreview(e.id, e.preview_title, e.preview_description, e.preview_image);
                    }
                }
            },
        }
    }

    fn applyKeepBoth(self: *Store, kind: MergeConflictKind, node: Node) DomainError!void {
        switch (node) {
            .collection => |c| {
                const new_id = newUuid();
                const owned_name = try self.uniqueLabelUnderParent(c.parent_id, c.name);
                defer self.allocator.free(owned_name);
                try self.addCollection(new_id, c.parent_id, owned_name);
            },
            .entry => |e| {
                const new_id = newUuid();
                const owned_title = try self.uniqueLabelUnderParent(e.parent_id, e.title);
                defer self.allocator.free(owned_title);
                try self.addEntry(new_id, e.parent_id, owned_title, e.url, e.body, e.created_ms, e.updated_ms);
                if (e.preview_title.len > 0 or e.preview_description.len > 0 or e.preview_image.len > 0) {
                    try self.setPreview(new_id, e.preview_title, e.preview_description, e.preview_image);
                }
            },
        }
        _ = kind;
    }

    pub fn updateCollection(self: *Store, id: Uuid, parent_id: Uuid, name: []const u8) DomainError!void {
        const idx = self.findIndex(id) orelse return error.NotFound;
        const collection = switch (self.nodes.items[idx]) {
            .collection => |*c| c,
            .entry => return error.NotFound,
        };
        if (!self.parentExists(parent_id)) return error.InvalidParent;
        if (self.nameTakenUnderParent(parent_id, name, id)) return error.DuplicateName;
        collection.parent_id = parent_id;
        self.allocator.free(collection.name);
        collection.name = try self.allocator.dupe(u8, name);
    }

    pub fn findCollectionByNameUnderParent(self: *const Store, parent_id: Uuid, name: []const u8) ?Uuid {
        for (self.nodes.items) |node| {
            switch (node) {
                .collection => |c| {
                    if (std.mem.eql(u8, &c.parent_id, &parent_id) and std.ascii.eqlIgnoreCase(c.name, name)) {
                        return c.id;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    /// Find or create a Collection named `name` under `parent_id`.
    pub fn ensureNamedCollection(self: *Store, parent_id: Uuid, name: []const u8) DomainError!Uuid {
        if (self.findCollectionByNameUnderParent(parent_id, name)) |id| return id;
        const id = newUuid();
        try self.addCollection(id, parent_id, name);
        return id;
    }

    fn findEntryByTitleUnderParent(self: *const Store, parent_id: Uuid, title: []const u8) ?Uuid {
        for (self.nodes.items) |node| {
            switch (node) {
                .entry => |e| {
                    if (std.mem.eql(u8, &e.parent_id, &parent_id) and std.ascii.eqlIgnoreCase(e.title, title)) {
                        return e.id;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    fn uniqueLabelUnderParent(self: *Store, parent_id: Uuid, base: []const u8) DomainError![]const u8 {
        if (!self.nameTakenUnderParent(parent_id, base, null)) {
            return try self.allocator.dupe(u8, base);
        }
        var suffix: u32 = 2;
        while (suffix < 256) {
            var buf: [256]u8 = undefined;
            const candidate = std.fmt.bufPrint(&buf, "{s} (imported)", .{base}) catch return error.OutOfMemory;
            if (suffix > 2) {
                const alt = std.fmt.bufPrint(&buf, "{s} ({d})", .{ base, suffix }) catch return error.OutOfMemory;
                if (!self.nameTakenUnderParent(parent_id, alt, null)) {
                    return try self.allocator.dupe(u8, alt);
                }
            } else if (!self.nameTakenUnderParent(parent_id, candidate, null)) {
                return try self.allocator.dupe(u8, candidate);
            }
            suffix += 1;
        }
        return error.DuplicateName;
    }

    var merge_uuid_nonce: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

    fn newUuid() Uuid {
        var id: Uuid = undefined;
        const n = merge_uuid_nonce.fetchAdd(1, .monotonic);
        std.mem.writeInt(u64, id[0..8], n, .little);
        std.mem.writeInt(u64, id[8..16], n ^ 0xc0ffee1234567890, .little);
        return id;
    }

    /// Delete a collection: children move to its parent (evacuate, never cascade).
    pub fn deleteCollection(self: *Store, id: Uuid) DomainError!void {
        const idx = self.findIndex(id) orelse return error.NotFound;
        const collection = self.nodes.items[idx].collection;
        const parent_id = collection.parent_id;

        // Reparent direct children before removing the collection.
        for (self.nodes.items) |*node| {
            switch (node.*) {
                .collection => |*c| {
                    if (std.mem.eql(u8, &c.parent_id, &id)) c.parent_id = parent_id;
                },
                .entry => |*e| {
                    if (std.mem.eql(u8, &e.parent_id, &id)) e.parent_id = parent_id;
                },
            }
        }

        self.allocator.free(collection.name);
        _ = self.nodes.swapRemove(idx);
    }

    pub fn deleteEntry(self: *Store, id: Uuid) DomainError!void {
        const idx = self.findIndex(id) orelse return error.NotFound;
        const entry = self.nodes.items[idx].entry;
        self.allocator.free(entry.title);
        self.allocator.free(entry.url);
        self.allocator.free(entry.body);
        if (entry.preview_title.len > 0) self.allocator.free(entry.preview_title);
        if (entry.preview_description.len > 0) self.allocator.free(entry.preview_description);
        if (entry.preview_image.len > 0) self.allocator.free(entry.preview_image);
        _ = self.nodes.swapRemove(idx);
    }

    pub fn updateEntry(
        self: *Store,
        id: Uuid,
        title: []const u8,
        url: []const u8,
        body: []const u8,
        updated_ms: u64,
    ) DomainError!void {
        try validateTitle(title);
        const idx = self.findIndex(id) orelse return error.NotFound;
        const entry = switch (self.nodes.items[idx]) {
            .entry => |*e| e,
            .collection => return error.NotFound,
        };
        const parent_id = entry.parent_id;
        if (self.nameTakenUnderParent(parent_id, title, id)) return error.DuplicateName;

        self.allocator.free(entry.title);
        self.allocator.free(entry.url);
        self.allocator.free(entry.body);
        entry.title = try self.allocator.dupe(u8, title);
        entry.url = try self.allocator.dupe(u8, url);
        entry.body = try self.allocator.dupe(u8, body);
        entry.updated_ms = updated_ms;
    }

    fn hashSenhasGate(
        allocator: std.mem.Allocator,
        io: std.Io,
        password: []const u8,
        salt: *const [16]u8,
        t_cost: u32,
        m_cost: u32,
        p_cost: u32,
        out_hash: *[32]u8,
    ) DomainError!void {
        std.crypto.pwhash.argon2.kdf(
            allocator,
            out_hash,
            password,
            salt,
            std.crypto.pwhash.argon2.Params{ .t = @intCast(t_cost), .m = @intCast(m_cost), .p = @intCast(p_cost) },
            .argon2id,
            io,
        ) catch return error.OutOfMemory;
    }

    pub fn setSecretsGateFromPassword(self: *Store, io: std.Io, password: []const u8) DomainError!void {
        if (!passwordMeetsSenhasPolicy(password)) return error.WeakPassword;
        var salt: [16]u8 = undefined;
        io.random(&salt);
        var hash: [32]u8 = undefined;
        try hashSenhasGate(
            self.allocator,
            io,
            password,
            &salt,
            senhas_gate_t_cost,
            senhas_gate_m_cost,
            senhas_gate_p_cost,
            &hash,
        );
        self.secrets_gate = .{ .set = .{
            .salt = salt,
            .t_cost = senhas_gate_t_cost,
            .m_cost = senhas_gate_m_cost,
            .p_cost = senhas_gate_p_cost,
            .hash = hash,
        } };
    }

    pub fn verifySecretsGate(self: *const Store, io: std.Io, password: []const u8) bool {
        const gate = switch (self.secrets_gate) {
            .unset => return false,
            .set => |g| g,
        };
        var hash: [32]u8 = undefined;
        hashSenhasGate(
            self.allocator,
            io,
            password,
            &gate.salt,
            gate.t_cost,
            gate.m_cost,
            gate.p_cost,
            &hash,
        ) catch return false;
        return std.crypto.timing_safe.eql([32]u8, hash, gate.hash);
    }

    pub fn addSecret(
        self: *Store,
        label: []const u8,
        username: []const u8,
        password: []const u8,
        notes: []const u8,
        now_ms: u64,
    ) DomainError!Uuid {
        const id = newUuid();
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);
        const owned_user = try self.allocator.dupe(u8, username);
        errdefer self.allocator.free(owned_user);
        const owned_pass = try self.allocator.dupe(u8, password);
        errdefer self.allocator.free(owned_pass);
        const owned_notes = try self.allocator.dupe(u8, notes);
        errdefer self.allocator.free(owned_notes);
        try self.secrets.append(self.allocator, .{
            .id = id,
            .label = owned_label,
            .username = owned_user,
            .password = owned_pass,
            .notes = owned_notes,
            .created_ms = now_ms,
            .updated_ms = now_ms,
        });
        return id;
    }

    pub fn getSecret(self: *const Store, id: Uuid) ?*const Secret {
        for (self.secrets.items) |*s| {
            if (std.mem.eql(u8, &s.id, &id)) return s;
        }
        return null;
    }

    pub fn updateSecret(
        self: *Store,
        id: Uuid,
        label: []const u8,
        username: []const u8,
        password: []const u8,
        notes: []const u8,
        now_ms: u64,
    ) DomainError!void {
        const secret = for (self.secrets.items) |*s| {
            if (std.mem.eql(u8, &s.id, &id)) break s;
        } else return error.NotFound;
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);
        const owned_user = try self.allocator.dupe(u8, username);
        errdefer self.allocator.free(owned_user);
        const owned_pass = try self.allocator.dupe(u8, password);
        errdefer self.allocator.free(owned_pass);
        const owned_notes = try self.allocator.dupe(u8, notes);
        errdefer self.allocator.free(owned_notes);
        self.allocator.free(secret.label);
        self.allocator.free(secret.username);
        std.crypto.secureZero(u8, @constCast(secret.password));
        self.allocator.free(secret.password);
        self.allocator.free(secret.notes);
        secret.label = owned_label;
        secret.username = owned_user;
        secret.password = owned_pass;
        secret.notes = owned_notes;
        secret.updated_ms = now_ms;
    }

    pub fn deleteSecret(self: *Store, id: Uuid) DomainError!void {
        for (self.secrets.items, 0..) |s, i| {
            if (!std.mem.eql(u8, &s.id, &id)) continue;
            self.allocator.free(s.label);
            self.allocator.free(s.username);
            std.crypto.secureZero(u8, @constCast(s.password));
            self.allocator.free(s.password);
            self.allocator.free(s.notes);
            _ = self.secrets.swapRemove(i);
            return;
        }
        return error.NotFound;
    }

    fn urlExists(self: *const Store, url: []const u8) bool {
        for (self.nodes.items) |node| {
            switch (node) {
                .entry => |e| {
                    if (std.mem.eql(u8, e.url, url)) return true;
                },
                else => {},
            }
        }
        return false;
    }

    fn ensureHostCollection(self: *Store, host: []const u8) DomainError!Uuid {
        if (self.findCollectionByNameUnderParent(root_parent, host)) |id| return id;
        const id = newUuid();
        try self.addCollection(id, root_parent, host);
        return id;
    }

    fn addEntryUniqueTitle(
        self: *Store,
        parent_id: Uuid,
        title: []const u8,
        url: []const u8,
        now_ms: u64,
    ) DomainError!void {
        const id = newUuid();
        self.addEntry(id, parent_id, title, url, "", now_ms, now_ms) catch |err| switch (err) {
            error.DuplicateName => {
                var suffix: u32 = 2;
                var buf: [256]u8 = undefined;
                while (suffix < 256) : (suffix += 1) {
                    const alt = std.fmt.bufPrint(&buf, "{s} ({d})", .{ title, suffix }) catch return error.OutOfMemory;
                    const alt_id = newUuid();
                    self.addEntry(alt_id, parent_id, alt, url, "", now_ms, now_ms) catch |e2| switch (e2) {
                        error.DuplicateName => continue,
                        else => return e2,
                    };
                    return;
                }
                return error.DuplicateName;
            },
            else => return err,
        };
    }

    /// `dest` null (or omitted by callers as `null`): group by host under root.
    /// `dest` set: every new entry lands in that collection (must exist).
    pub fn ingestUrls(self: *Store, text: []const u8, now_ms: u64, dest: ?Uuid) DomainError!IngestResult {
        if (dest) |d| {
            if (!self.parentExists(d)) return error.InvalidParent;
        }
        var result: IngestResult = .{};
        var from: usize = 0;
        while (nextHttpUrlSpan(text, from)) |span| {
            from = span.end;
            const token = text[span.start..span.end];
            const host_raw = extractHost(token) orelse {
                result.invalid += 1;
                continue;
            };
            var host_buf: [256]u8 = undefined;
            const host = normalizeHost(host_raw, &host_buf);
            if (host.len == 0) {
                result.invalid += 1;
                continue;
            }
            if (self.urlExists(token)) {
                result.skipped_dup += 1;
                continue;
            }
            const parent_id = dest orelse try self.ensureHostCollection(host);
            var title_buf: [256]u8 = undefined;
            const title = titleFromUrl(token, &title_buf);
            try self.addEntryUniqueTitle(parent_id, title, token, now_ms);
            result.created += 1;
        }
        return result;
    }

    pub fn encode(self: *const Store, allocator: std.mem.Allocator) DomainError![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, magic);
        try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, version)));
        try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(self.nodes.items.len))));

        for (self.nodes.items) |node| {
            switch (node) {
                .collection => |c| try writeCollection(allocator, &out, c),
                .entry => |e| try writeEntry(allocator, &out, e),
            }
        }

        switch (self.secrets_gate) {
            .unset => try out.append(allocator, 0),
            .set => |g| {
                try out.append(allocator, 1);
                try out.appendSlice(allocator, &g.salt);
                try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, g.t_cost)));
                try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, g.m_cost)));
                try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, g.p_cost)));
                try out.appendSlice(allocator, &g.hash);
            },
        }
        try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(self.secrets.items.len))));
        for (self.secrets.items) |s| try writeSecret(allocator, &out, s);

        return try out.toOwnedSlice(allocator);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) DomainError!Store {
        if (bytes.len < 12) return error.Corrupt;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.Corrupt;
        const ver = std.mem.readInt(u32, bytes[4..][0..4], .big);
        if (ver != version and ver != version_v2 and ver != version_v1) return error.UnsupportedVersion;
        const count = std.mem.readInt(u32, bytes[8..][0..4], .big);
        var store = Store.init(allocator);
        errdefer store.deinit();

        var off: usize = 12;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (off >= bytes.len) return error.Corrupt;
            const kind: Kind = @enumFromInt(bytes[off]);
            off += 1;
            switch (kind) {
                .collection => off = try readCollection(allocator, &store, bytes, off),
                .entry => off = try readEntry(allocator, &store, bytes, off, ver),
            }
        }
        if (ver < version) {
            if (off != bytes.len) return error.Corrupt;
            return store;
        }
        if (off == bytes.len) return store;
        off = try readSecretsTrailer(allocator, &store, bytes, off);
        if (off != bytes.len) return error.Corrupt;
        return store;
    }
};

fn writeCollection(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), c: Collection) DomainError!void {
    try out.append(allocator, @intFromEnum(Kind.collection));
    try out.appendSlice(allocator, &c.id);
    try out.appendSlice(allocator, &c.parent_id);
    try writeBytes(allocator, out, c.name);
}

fn writeEntry(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), e: Entry) DomainError!void {
    try out.append(allocator, @intFromEnum(Kind.entry));
    try out.appendSlice(allocator, &e.id);
    try out.appendSlice(allocator, &e.parent_id);
    try writeBytes(allocator, out, e.title);
    try writeBytes(allocator, out, e.url);
    try writeBytes(allocator, out, e.body);
    try writeBytes(allocator, out, e.preview_title);
    try writeBytes(allocator, out, e.preview_description);
    try writeBytes(allocator, out, e.preview_image);
    try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u64, e.created_ms)));
    try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u64, e.updated_ms)));
}

fn writeSecret(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: Secret) DomainError!void {
    try out.appendSlice(allocator, &s.id);
    try writeBytes(allocator, out, s.label);
    try writeBytes(allocator, out, s.username);
    try writeBytes(allocator, out, s.password);
    try writeBytes(allocator, out, s.notes);
    try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u64, s.created_ms)));
    try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u64, s.updated_ms)));
}

fn readSecretsTrailer(allocator: std.mem.Allocator, store: *Store, bytes: []const u8, start: usize) DomainError!usize {
    if (start >= bytes.len) return error.Corrupt;
    var off = start;
    const tag = bytes[off];
    off += 1;
    switch (tag) {
        0 => store.secrets_gate = .unset,
        1 => {
            if (off + 16 + 12 + 32 > bytes.len) return error.Corrupt;
            var salt: [16]u8 = undefined;
            @memcpy(&salt, bytes[off .. off + 16]);
            off += 16;
            const t_cost = std.mem.readInt(u32, bytes[off..][0..4], .big);
            off += 4;
            const m_cost = std.mem.readInt(u32, bytes[off..][0..4], .big);
            off += 4;
            const p_cost = std.mem.readInt(u32, bytes[off..][0..4], .big);
            off += 4;
            var hash: [32]u8 = undefined;
            @memcpy(&hash, bytes[off .. off + 32]);
            off += 32;
            store.secrets_gate = .{ .set = .{
                .salt = salt,
                .t_cost = t_cost,
                .m_cost = m_cost,
                .p_cost = p_cost,
                .hash = hash,
            } };
        },
        else => return error.Corrupt,
    }
    if (off + 4 > bytes.len) return error.Corrupt;
    const count = std.mem.readInt(u32, bytes[off..][0..4], .big);
    off += 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (off + uuid_len > bytes.len) return error.Corrupt;
        var id: Uuid = undefined;
        @memcpy(&id, bytes[off .. off + uuid_len]);
        off += uuid_len;
        const label = try readBytes(allocator, bytes, off);
        off = label[1];
        const username = try readBytes(allocator, bytes, off);
        off = username[1];
        const password = try readBytes(allocator, bytes, off);
        off = password[1];
        const notes = try readBytes(allocator, bytes, off);
        off = notes[1];
        if (off + 16 > bytes.len) return error.Corrupt;
        const created_ms = std.mem.readInt(u64, bytes[off..][0..8], .big);
        const updated_ms = std.mem.readInt(u64, bytes[off + 8 ..][0..8], .big);
        off += 16;
        try store.secrets.append(store.allocator, .{
            .id = id,
            .label = label[0],
            .username = username[0],
            .password = password[0],
            .notes = notes[0],
            .created_ms = created_ms,
            .updated_ms = updated_ms,
        });
    }
    return off;
}

fn writeBytes(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), slice: []const u8) DomainError!void {
    if (slice.len > std.math.maxInt(u32)) return error.Corrupt;
    try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(slice.len))));
    try out.appendSlice(allocator, slice);
}

fn readBytes(allocator: std.mem.Allocator, bytes: []const u8, off: usize) DomainError!struct { []const u8, usize } {
    if (off + 4 > bytes.len) return error.Corrupt;
    const len = std.mem.readInt(u32, bytes[off..][0..4], .big);
    const start = off + 4;
    const end = start + len;
    if (end > bytes.len) return error.Corrupt;
    const owned = try allocator.dupe(u8, bytes[start..end]);
    return .{ owned, end };
}

fn readCollection(allocator: std.mem.Allocator, store: *Store, bytes: []const u8, off: usize) DomainError!usize {
    if (off + uuid_len * 2 > bytes.len) return error.Corrupt;
    var id: Uuid = undefined;
    var parent_id: Uuid = undefined;
    @memcpy(&id, bytes[off .. off + uuid_len]);
    @memcpy(&parent_id, bytes[off + uuid_len .. off + uuid_len * 2]);
    const name_result = try readBytes(allocator, bytes, off + uuid_len * 2);
    if (store.findIndex(id) != null) return error.Corrupt;
    try store.nodes.append(store.allocator, .{ .collection = .{
        .id = id,
        .parent_id = parent_id,
        .name = name_result[0],
    } });
    return name_result[1];
}

fn readEntry(allocator: std.mem.Allocator, store: *Store, bytes: []const u8, off: usize, ver: u32) DomainError!usize {
    if (off + uuid_len * 2 > bytes.len) return error.Corrupt;
    var id: Uuid = undefined;
    var parent_id: Uuid = undefined;
    @memcpy(&id, bytes[off .. off + uuid_len]);
    @memcpy(&parent_id, bytes[off + uuid_len .. off + uuid_len * 2]);
    var cursor = off + uuid_len * 2;
    const title_result = try readBytes(allocator, bytes, cursor);
    cursor = title_result[1];
    const url_result = try readBytes(allocator, bytes, cursor);
    cursor = url_result[1];
    const body_result = try readBytes(allocator, bytes, cursor);
    cursor = body_result[1];
    var preview_title: []const u8 = "";
    var preview_description: []const u8 = "";
    var preview_image: []const u8 = "";
    if (ver >= version_v2) {
        const pt = try readBytes(allocator, bytes, cursor);
        cursor = pt[1];
        preview_title = pt[0];
        const pd = try readBytes(allocator, bytes, cursor);
        cursor = pd[1];
        preview_description = pd[0];
    }
    if (ver >= version) {
        const pi = try readBytes(allocator, bytes, cursor);
        cursor = pi[1];
        preview_image = pi[0];
    }
    if (cursor + 16 > bytes.len) return error.Corrupt;
    const created_ms = std.mem.readInt(u64, bytes[cursor..][0..8], .big);
    const updated_ms = std.mem.readInt(u64, bytes[cursor + 8 ..][0..8], .big);
    cursor += 16;
    if (store.findIndex(id) != null) return error.Corrupt;
    try store.nodes.append(store.allocator, .{ .entry = .{
        .id = id,
        .parent_id = parent_id,
        .title = title_result[0],
        .url = url_result[0],
        .body = body_result[0],
        .preview_title = preview_title,
        .preview_description = preview_description,
        .preview_image = preview_image,
        .created_ms = created_ms,
        .updated_ms = updated_ms,
    } });
    return cursor;
}

// --- oracles (prove Task 1) ---

test "empty store roundtrip" {
    const alloc = std.testing.allocator;
    var store = Store.init(alloc);
    defer store.deinit();

    const encoded = try store.encode(alloc);
    defer alloc.free(encoded);

    var decoded = try Store.decode(alloc, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 0), decoded.nodes.items.len);
}

test "collection and entry roundtrip" {
    const alloc = std.testing.allocator;
    var store = Store.init(alloc);
    defer store.deinit();

    var col_id: Uuid = undefined;
    @memset(&col_id, 0x11);
    try store.addCollection(col_id, root_parent, "Work");

    var ent_id: Uuid = undefined;
    @memset(&ent_id, 0x22);
    try store.addEntry(ent_id, col_id, "GitHub", "https://github.com", "note", 1000, 2000);

    const encoded = try store.encode(alloc);
    defer alloc.free(encoded);

    var decoded = try Store.decode(alloc, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 2), decoded.nodes.items.len);
}

test "blank title rejected" {
    const alloc = std.testing.allocator;
    var store = Store.init(alloc);
    defer store.deinit();

    var id: Uuid = undefined;
    @memset(&id, 0x33);
    try std.testing.expectError(error.BlankTitle, store.addEntry(id, root_parent, "   ", "", "", 0, 0));
}

test "delete collection evacuates children" {
    const alloc = std.testing.allocator;
    var store = Store.init(alloc);
    defer store.deinit();

    var parent_id: Uuid = undefined;
    @memset(&parent_id, 0x44);
    try store.addCollection(parent_id, root_parent, "Parent");

    var child_col: Uuid = undefined;
    @memset(&child_col, 0x55);
    try store.addCollection(child_col, parent_id, "Child");

    var entry_id: Uuid = undefined;
    @memset(&entry_id, 0x66);
    try store.addEntry(entry_id, child_col, "Item", "", "", 0, 0);

    try store.deleteCollection(child_col);

    const idx = store.findIndex(entry_id).?;
    try std.testing.expect(std.mem.eql(u8, &store.nodes.items[idx].entry.parent_id, &parent_id));
}

test "update entry preserves id" {
    const alloc = std.testing.allocator;
    var store = Store.init(alloc);
    defer store.deinit();

    var id: Uuid = undefined;
    @memset(&id, 0x99);
    try store.addEntry(id, root_parent, "Old", "", "", 1000, 1000);
    try store.updateEntry(id, "New Title", "https://x.test", "body", 2000);
    const idx = store.findIndex(id).?;
    try std.testing.expectEqualStrings("New Title", store.nodes.items[idx].entry.title);
    try std.testing.expectEqual(@as(u64, 2000), store.nodes.items[idx].entry.updated_ms);
}

test "domain v2 roundtrip with preview fields" {
    const alloc = std.testing.allocator;
    var store = Store.init(alloc);
    defer store.deinit();

    var id: Uuid = undefined;
    @memset(&id, 0xaa);
    try store.addEntry(id, root_parent, "Site", "https://example.com", "", 1, 2);
    try store.setEntryPreview(id, "Example", "A demo");

    const encoded = try store.encode(alloc);
    defer alloc.free(encoded);

    var decoded = try Store.decode(alloc, encoded);
    defer decoded.deinit();
    const idx = decoded.findIndex(id).?;
    try std.testing.expectEqualStrings("Example", decoded.nodes.items[idx].entry.preview_title);
}

test "duplicate name per parent rejected" {
    const alloc = std.testing.allocator;
    var store = Store.init(alloc);
    defer store.deinit();

    var id1: Uuid = undefined;
    @memset(&id1, 0x77);
    try store.addEntry(id1, root_parent, "Same", "", "", 0, 0);

    var id2: Uuid = undefined;
    @memset(&id2, 0x88);
    try std.testing.expectError(error.DuplicateName, store.addEntry(id2, root_parent, "same", "", "", 0, 0));
}

test "merge name collision keep both renames imported" {
    const alloc = std.testing.allocator;
    var local = Store.init(alloc);
    defer local.deinit();
    var imported = Store.init(alloc);
    defer imported.deinit();

    var local_id: Uuid = undefined;
    @memset(&local_id, 0x11);
    try local.addEntry(local_id, root_parent, "Notes", "", "local", 0, 0);

    var import_id: Uuid = undefined;
    @memset(&import_id, 0x22);
    try imported.addEntry(import_id, root_parent, "Notes", "", "imported", 0, 0);

    var conflicts: std.ArrayListUnmanaged(Store.MergeConflict) = .empty;
    defer conflicts.deinit(alloc);
    try local.scanMergeConflicts(&imported, &conflicts);
    try std.testing.expectEqual(@as(usize, 1), conflicts.items.len);

    const resolutions = [_]Store.MergeResolution{.keep_both};
    try local.mergeFromWithResolutions(&imported, conflicts.items, &resolutions);

    var found_local = false;
    var found_imported = false;
    for (local.nodes.items) |node| {
        if (node != .entry) continue;
        if (std.mem.eql(u8, &node.entry.id, &local_id)) {
            found_local = true;
            try std.testing.expectEqualStrings("local", node.entry.body);
        } else if (std.mem.indexOf(u8, node.entry.title, "imported") != null or
            std.mem.indexOf(u8, node.entry.title, "Notes") != null)
        {
            found_imported = true;
            try std.testing.expectEqualStrings("imported", node.entry.body);
        }
    }
    try std.testing.expect(found_local);
    try std.testing.expect(found_imported);
}

test "merge uuid conflict keep imported replaces local" {
    const alloc = std.testing.allocator;
    var local = Store.init(alloc);
    defer local.deinit();
    var imported = Store.init(alloc);
    defer imported.deinit();

    var id: Uuid = undefined;
    @memset(&id, 0x33);
    try local.addEntry(id, root_parent, "Title", "", "old body", 0, 0);
    try imported.addEntry(id, root_parent, "Title", "", "new body", 0, 0);

    var conflicts: std.ArrayListUnmanaged(Store.MergeConflict) = .empty;
    defer conflicts.deinit(alloc);
    try local.scanMergeConflicts(&imported, &conflicts);
    try std.testing.expectEqual(@as(usize, 1), conflicts.items.len);

    const resolutions = [_]Store.MergeResolution{.keep_imported};
    try local.mergeFromWithResolutions(&imported, conflicts.items, &resolutions);

    const idx = local.findIndex(id).?;
    try std.testing.expectEqualStrings("new body", local.nodes.items[idx].entry.body);
}

test "entry preview_image roundtrip kdat v3" {
    const alloc = std.testing.allocator;
    var store = Store.init(alloc);
    defer store.deinit();
    var id: Uuid = undefined;
    @memset(&id, 0xab);
    try store.addEntry(id, root_parent, "A", "https://ex.test/a", "", 1, 1);
    try store.setPreview(id, "T", "D", "JPEGDATA");
    const encoded = try store.encode(alloc);
    defer alloc.free(encoded);
    var decoded = try Store.decode(alloc, encoded);
    defer decoded.deinit();
    const e = decoded.getEntry(id).?;
    try std.testing.expectEqualStrings("JPEGDATA", e.preview_image);
    try std.testing.expectEqualStrings("T", e.preview_title);
    try std.testing.expectEqualStrings("D", e.preview_description);
}

test "senhas policy requires four classes" {
    try std.testing.expect(!passwordMeetsSenhasPolicy("password"));
    try std.testing.expect(!passwordMeetsSenhasPolicy("Password1"));
    try std.testing.expect(passwordMeetsSenhasPolicy("Password1!"));
}

test "secrets gate set verify and secret roundtrip" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var store = Store.init(alloc);
    defer store.deinit();

    try std.testing.expectError(error.WeakPassword, store.setSecretsGateFromPassword(io, "Password1"));
    try store.setSecretsGateFromPassword(io, "Password1!");
    try std.testing.expect(store.verifySecretsGate(io, "Password1!"));
    try std.testing.expect(!store.verifySecretsGate(io, "WrongPass1!"));

    const sid = try store.addSecret("Bank", "alice", "s3cret", "note", 10);
    const encoded = try store.encode(alloc);
    defer alloc.free(encoded);
    var decoded = try Store.decode(alloc, encoded);
    defer decoded.deinit();
    try std.testing.expect(decoded.verifySecretsGate(io, "Password1!"));
    const secret = decoded.getSecret(sid).?;
    try std.testing.expectEqualStrings("Bank", secret.label);
    try std.testing.expectEqualStrings("alice", secret.username);
    try std.testing.expectEqualStrings("s3cret", secret.password);
    try std.testing.expectEqualStrings("note", secret.notes);
}

test "ingestUrls same host is one collection not one per url" {
    const alloc = std.testing.allocator;
    var store = Store.init(alloc);
    defer store.deinit();
    const sample =
        \\https://e-hentai.org/g/1/1fea9e2241/
        \\https://e-hentai.org/g/2/fab9af6925/
        \\https://e-hentai.org/g/3/d54c6bf833/
        \\https://e-hentai.org/?f_search=%5Bfoo%5D
    ;
    const result = try store.ingestUrls(sample, 1000, null);
    try std.testing.expectEqual(@as(u32, 4), result.created);
    const host_id = store.findCollectionByNameUnderParent(root_parent, "e-hentai.org") orelse
        return error.TestUnexpectedResult;
    var collections: u32 = 0;
    var root_entries: u32 = 0;
    for (store.nodes.items) |node| {
        switch (node) {
            .collection => |c| {
                if (std.mem.eql(u8, &c.parent_id, &root_parent)) collections += 1;
            },
            .entry => |e| {
                if (std.mem.eql(u8, &e.parent_id, &root_parent)) root_entries += 1;
                try std.testing.expectEqualSlices(u8, &host_id, &e.parent_id);
            },
        }
    }
    try std.testing.expectEqual(@as(u32, 1), collections);
    try std.testing.expectEqual(@as(u32, 0), root_entries);
}

test "ensureNamedCollection reuses same name under parent" {
    const alloc = std.testing.allocator;
    var store = Store.init(alloc);
    defer store.deinit();
    const first = try store.ensureNamedCollection(root_parent, "XYZ");
    const second = try store.ensureNamedCollection(root_parent, "xyz");
    try std.testing.expectEqualSlices(u8, &first, &second);
    const nested = try store.ensureNamedCollection(first, "QBitTorrent");
    try std.testing.expect(!std.mem.eql(u8, &nested, &first));
}

test "ingestUrls dest collection skips host grouping" {
    const alloc = std.testing.allocator;
    var store = Store.init(alloc);
    defer store.deinit();
    var host_id: Uuid = undefined;
    @memset(&host_id, 0x31);
    try store.addCollection(host_id, root_parent, "amazon.com");
    var folder_id: Uuid = undefined;
    @memset(&folder_id, 0x32);
    try store.addCollection(folder_id, host_id, "Livros");
    const sample =
        \\https://www.amazon.com/hz/wishlist/ls/BOOKS
        \\https://www.amazon.com/hz/wishlist/ls/MORE
        \\https://github.com/foo/bar
    ;
    const result = try store.ingestUrls(sample, 1000, folder_id);
    try std.testing.expectEqual(@as(u32, 3), result.created);
    try std.testing.expect(store.findCollectionByNameUnderParent(root_parent, "github.com") == null);
    for (store.nodes.items) |node| {
        switch (node) {
            .entry => |e| try std.testing.expectEqualSlices(u8, &folder_id, &e.parent_id),
            else => {},
        }
    }
}

test "ingestUrls groups by host and dedupes" {
    const alloc = std.testing.allocator;
    var store = Store.init(alloc);
    defer store.deinit();
    const sample =
        \\https://simpcity.cr/threads/ashley-alban.9988/page-2?order=reaction_score
        \\https://bunkr.pk/f/ZqgFmEqdng4QV
        \\https://bunkr.pk/f/ZqgFmEqdng4QV
        \\https://cyberfile.me/folder/83a8f2407979ea70afc06e2414bc3a47/Ashley_Alban_2024
    ;
    const result = try store.ingestUrls(sample, 1000, null);
    try std.testing.expectEqual(@as(u32, 3), result.created);
    try std.testing.expectEqual(@as(u32, 1), result.skipped_dup);
    try std.testing.expectEqual(@as(u32, 0), result.invalid);

    const hosts = [_][]const u8{ "simpcity.cr", "bunkr.pk", "cyberfile.me" };
    for (hosts) |host| {
        try std.testing.expect(store.findCollectionByNameUnderParent(root_parent, host) != null);
    }
}

test "formatExtractedUrls splits glued urls one per line" {
    const sample = "see https://a.test/xhttps://b.test/y, and https://a.test/x.";
    var buf: [256]u8 = undefined;
    const n = formatExtractedUrls(sample, &buf);
    try std.testing.expectEqualStrings("https://a.test/x\nhttps://b.test/y\nhttps://a.test/x", buf[0..n]);
}

test "formatExtractedUrls empty when no url" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), formatExtractedUrls("not a link yet", &buf));
}

test "ingestUrls splits glued urls and strips trailing punctuation" {
    const alloc = std.testing.allocator;
    var store = Store.init(alloc);
    defer store.deinit();
    const sample = "junk https://simpcity.cr/threads/xhttps://bunkr.pk/f/ZqgFmEqdng4QV, https://cyberfile.me/folder/y.";
    const result = try store.ingestUrls(sample, 1000, null);
    try std.testing.expectEqual(@as(u32, 3), result.created);
    try std.testing.expectEqual(@as(u32, 0), result.skipped_dup);
    try std.testing.expectEqual(@as(u32, 0), result.invalid);
    try std.testing.expect(store.findCollectionByNameUnderParent(root_parent, "simpcity.cr") != null);
    try std.testing.expect(store.findCollectionByNameUnderParent(root_parent, "bunkr.pk") != null);
    try std.testing.expect(store.findCollectionByNameUnderParent(root_parent, "cyberfile.me") != null);
}

test "ingestUrls e-hentai host query encodes" {
    const alloc = std.testing.allocator;
    var store = Store.init(alloc);
    defer store.deinit();
    const text =
        \\https://e-hentai.org/g/1/1fea9e2241/
        \\https://e-hentai.org/g/2/fab9af6925/
        \\https://e-hentai.org/g/3/d54c6bf833/
        \\https://e-hentai.org/?f_search=%5Bfoo%5D
    ;
    const result = try store.ingestUrls(text, 1000, null);
    try std.testing.expectEqual(@as(u32, 4), result.created);
    const encoded = try store.encode(alloc);
    defer alloc.free(encoded);
    try std.testing.expect(encoded.len > 12);
}

test "ingestUrls accepts hundreds of urls then encodes" {
    const alloc = std.testing.allocator;
    var store = Store.init(alloc);
    defer store.deinit();
    var text: [24576]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < 600) : (i += 1) {
        const line = std.fmt.bufPrint(text[n..], "https://bulk.test/u{d}\n", .{i}) catch unreachable;
        n += line.len;
    }
    const result = try store.ingestUrls(text[0..n], 1000, null);
    try std.testing.expectEqual(@as(u32, 600), result.created);
    const encoded = try store.encode(alloc);
    defer alloc.free(encoded);
    try std.testing.expect(encoded.len > 12);
}
