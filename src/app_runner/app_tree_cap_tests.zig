//! Tree-row cap after ingest: `appendTreeChildren` must stop at
//! `max_tree_rows` even when every host collection is expanded.
//! Paint seam: `app_view.build` + layout (1024 nodes) + emit (2048
//! commands) — Ingest crash is a frame rebuild, not URL parse.
const std = @import("std");
const native_sdk = @import("native_sdk");
const app_controller = @import("app_controller.zig");
const app_view = @import("app_view.zig");
const domain = @import("domain.zig");
const core = @import("core.zig");

const AppUi = native_sdk.TsUiApp(core).Ui;
const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

fn expandRootHosts(ctrl: *app_controller.AppController) !void {
    for (ctrl.store.nodes.items) |node| {
        switch (node) {
            .collection => |c| {
                if (std.mem.eql(u8, &c.parent_id, &domain.root_parent)) {
                    try ctrl.expanded.put(ctrl.allocator, app_controller.uuidKey(c.id), {});
                }
            },
            else => {},
        }
    }
}

fn ingestExpanded(ctrl: *app_controller.AppController, text: []const u8, expected: u32) !void {
    const ingested = try ctrl.store.ingestUrls(text, 1000, null);
    try std.testing.expectEqual(expected, ingested.created);
    try expandRootHosts(ctrl);
    ctrl.rebuildTree();
}

const max_widget_nodes: usize = 1024;
const max_canvas_commands: usize = 2048;

const PaintStats = struct {
    nodes: usize,
    commands: usize,
    semantics: usize,
};

fn paintIngestView(ctrl: *app_controller.AppController, command_cap: usize) !PaintStats {
    ctrl.slots.phase = @intFromEnum(app_controller.Phase.unlocked);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var ui = AppUi.init(arena_state.allocator());
    const model = std.mem.zeroes(core.Model);
    const node = app_view.build(&ui, &model, ctrl);
    const tree = try ui.finalize(node);
    var nodes: [max_widget_nodes]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 1280, 800), &nodes);
    var semantics_buf: [max_widget_nodes]canvas.WidgetSemanticsNode = undefined;
    const semantics = try layout.collectSemantics(&semantics_buf);
    var commands: [max_canvas_commands]canvas.CanvasCommand = undefined;
    if (command_cap > commands.len) return error.TestUnexpectedResult;
    var builder = canvas.Builder.init(commands[0..command_cap]);
    try layout.emitDisplayList(&builder, .{});
    return .{
        .nodes = layout.nodes.len,
        .commands = builder.displayList().commandCount(),
        .semantics = semantics.len,
    };
}

test "ingest many urls does not overflow tree rows" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
    defer alloc.free(path);

    var ctrl = try app_controller.AppController.init(io, alloc, path);
    defer ctrl.deinit();

    var text: [24576]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < 600) : (i += 1) {
        const line = std.fmt.bufPrint(text[n..], "https://h{d}.bulk.test/u\n", .{i}) catch unreachable;
        n += line.len;
    }
    try ingestExpanded(&ctrl, text[0..n], 600);
    try std.testing.expect(ctrl.tree_row_count <= app_controller.max_tree_rows_pub);
    try std.testing.expectEqual(app_controller.max_tree_rows_pub, ctrl.tree_row_count);
}

test "ingest many urls paints under widget node budget" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
    defer alloc.free(path);

    var ctrl = try app_controller.AppController.init(io, alloc, path);
    defer ctrl.deinit();

    var text: [24576]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < 600) : (i += 1) {
        const line = std.fmt.bufPrint(text[n..], "https://h{d}.bulk.test/u\n", .{i}) catch unreachable;
        n += line.len;
    }
    try ingestExpanded(&ctrl, text[0..n], 600);
    try std.testing.expectError(error.DisplayListFull, paintIngestView(&ctrl, 1));
    const painted = try paintIngestView(&ctrl, max_canvas_commands);
    try std.testing.expect(painted.nodes <= max_widget_nodes);
    try std.testing.expect(painted.nodes > ctrl.tree_row_count);
    try std.testing.expect(painted.semantics <= max_widget_nodes);
    try std.testing.expect(painted.commands <= max_canvas_commands);
    try std.testing.expect(painted.commands > ctrl.tree_row_count);
}

test "ingest few host urls paints tree" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
    defer alloc.free(path);

    var ctrl = try app_controller.AppController.init(io, alloc, path);
    defer ctrl.deinit();

    const text =
        \\https://alpha.example/a
        \\https://beta.example/b
        \\https://gamma.example/c
        \\https://delta.example/d
        \\https://epsilon.example/e
        \\https://zeta.example/f
        \\https://eta.example/g
        \\https://theta.example/h
        \\https://iota.example/i
        \\https://kappa.example/j
    ;
    try ingestExpanded(&ctrl, text, 10);
    try std.testing.expectEqual(@as(u32, 10), ctrl.tree_row_count);
    const painted = try paintIngestView(&ctrl, max_canvas_commands);
    try std.testing.expect(painted.nodes > 0);
    try std.testing.expect(painted.commands > 0);
}

test "ingestPaste same host stays one collapsed collection" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
    defer alloc.free(path);

    var ctrl = try app_controller.AppController.init(io, alloc, path);
    defer ctrl.deinit();
    ctrl.setPasswordText("test-password-123");
    ctrl.slots.confirm_password_mode = 1;
    ctrl.setConfirmText("test-password-123");
    ctrl.createVault();
    try std.testing.expectEqual(@as(u8, @intFromEnum(app_controller.Phase.unlocked)), ctrl.slots.phase);

    const text =
        \\https://e-hentai.org/g/1/1fea9e2241/
        \\https://e-hentai.org/g/2/fab9af6925/
        \\https://e-hentai.org/g/3/d54c6bf833/
        \\https://e-hentai.org/?f_search=%5Bfoo%5D
    ;
    ctrl.applyPasteEdit(.{ .insert_text = text });
    ctrl.ingestPaste();
    try std.testing.expectEqual(@as(u32, @intFromEnum(app_controller.ErrorCode.none)), ctrl.slots.error_code);

    var root_collections: usize = 0;
    var root_entries: usize = 0;
    const inbox_id = ctrl.store.findCollectionByNameUnderParent(domain.root_parent, domain.inbox_name) orelse
        return error.TestUnexpectedResult;
    for (ctrl.store.nodes.items) |node| {
        switch (node) {
            .collection => |c| {
                if (std.mem.eql(u8, &c.parent_id, &domain.root_parent)) root_collections += 1;
            },
            .entry => |e| {
                if (std.mem.eql(u8, &e.parent_id, &domain.root_parent)) root_entries += 1;
                try std.testing.expectEqualSlices(u8, &inbox_id, &e.parent_id);
            },
        }
    }
    try std.testing.expectEqual(@as(usize, 1), root_collections);
    try std.testing.expectEqual(@as(usize, 0), root_entries);
    try std.testing.expectEqual(@as(u32, 1), ctrl.tree_row_count);
    try std.testing.expectEqual(@as(u8, 0), ctrl.tree_rows[0].kind);
    try std.testing.expectEqualStrings(domain.inbox_name, ctrl.tree_rows[0].title);
    try std.testing.expectEqual(@as(u32, 4), ctrl.entry_row_count);

    ctrl.slots.phase = @intFromEnum(app_controller.Phase.unlocked);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var ui = AppUi.init(arena_state.allocator());
    const model = std.mem.zeroes(core.Model);
    const node = app_view.build(&ui, &model, &ctrl);
    const tree = try ui.finalize(node);
    var nodes: [max_widget_nodes]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, 1280, 800), &nodes);
    var saw_inbox = false;
    var saw_child = false;
    for (layout.nodes) |ln| {
        if (std.mem.indexOf(u8, ln.widget.text, domain.inbox_name) != null) saw_inbox = true;
        if (std.mem.indexOf(u8, ln.widget.text, "1fea9e2241") != null) saw_child = true;
    }
    try std.testing.expect(saw_inbox);
    try std.testing.expect(saw_child);
}

test "ingestPaste into selected nested collection not host inbox" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
    defer alloc.free(path);

    var ctrl = try app_controller.AppController.init(io, alloc, path);
    defer ctrl.deinit();
    ctrl.setPasswordText("test-password-123");
    ctrl.slots.confirm_password_mode = 1;
    ctrl.setConfirmText("test-password-123");
    ctrl.createVault();

    ctrl.addCollection();
    const movies_id = ctrl.selected_id orelse return error.TestUnexpectedResult;
    const movies_name = "Movies";
    @memcpy(ctrl.editor_title[0..movies_name.len], movies_name);
    ctrl.editor_title_len = movies_name.len;
    ctrl.saveEditor();

    ctrl.selectNode(movies_id);
    ctrl.applyPasteEdit(.{ .insert_text = "https://www.amazon.com/hz/wishlist/ls/INBOX\n" });
    ctrl.ingestPaste();
    try std.testing.expect(ctrl.store.findCollectionByNameUnderParent(domain.root_parent, "amazon.com") == null);

    ctrl.selectNode(movies_id);
    ctrl.addCollection();
    const folder_id = ctrl.selected_id orelse return error.TestUnexpectedResult;
    const renamed = "Livros";
    @memcpy(ctrl.editor_title[0..renamed.len], renamed);
    ctrl.editor_title_len = renamed.len;
    ctrl.saveEditor();
    try std.testing.expect(ctrl.store.findCollectionByNameUnderParent(movies_id, "Livros") != null);

    ctrl.selectNode(folder_id);
    ctrl.applyPasteEdit(.{ .insert_text = "https://www.amazon.com/hz/wishlist/ls/BOOKS\nhttps://github.com/foo/bar\n" });
    ctrl.ingestPaste();
    try std.testing.expectEqual(@as(u32, @intFromEnum(app_controller.ErrorCode.none)), ctrl.slots.error_code);
    try std.testing.expect(ctrl.store.findCollectionByNameUnderParent(domain.root_parent, "github.com") == null);

    var movies_entries: u32 = 0;
    var livros: u32 = 0;
    for (ctrl.store.nodes.items) |node| {
        switch (node) {
            .entry => |e| {
                if (std.mem.eql(u8, &e.parent_id, &movies_id)) movies_entries += 1;
                if (std.mem.eql(u8, &e.parent_id, &folder_id)) livros += 1;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(u32, 1), movies_entries);
    try std.testing.expectEqual(@as(u32, 2), livros);
}

test "unlock then persistDomain does not free session payload" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
    defer alloc.free(path);

    var ctrl = try app_controller.AppController.init(io, alloc, path);
    defer ctrl.deinit();
    ctrl.setPasswordText("test-password-123");
    ctrl.slots.confirm_password_mode = 1;
    ctrl.setConfirmText("test-password-123");
    ctrl.createVault();
    try std.testing.expectEqual(@as(u8, @intFromEnum(app_controller.Phase.unlocked)), ctrl.slots.phase);

    ctrl.lock();
    ctrl.setPasswordText("test-password-123");
    ctrl.unlock();
    try std.testing.expectEqual(@as(u8, @intFromEnum(app_controller.Phase.unlocked)), ctrl.slots.phase);

    try ctrl.persistDomain();
    const payload = ctrl.session.payload orelse return error.TestUnexpectedResult;
    try std.testing.expect(payload.len > 0);

    ctrl.applyPasteEdit(.{ .insert_text = "https://example.test/a\n" });
    ctrl.ingestPaste();
    try std.testing.expectEqual(@as(u32, @intFromEnum(app_controller.ErrorCode.none)), ctrl.slots.error_code);
    try std.testing.expect(ctrl.store.findCollectionByNameUnderParent(domain.root_parent, domain.inbox_name) != null);
}

fn fillPasteUrls(ctrl: *app_controller.AppController, count: usize) void {
    var line_buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const line = std.fmt.bufPrint(&line_buf, "https://bulk.test/u{d}\n", .{i}) catch unreachable;
        ctrl.applyPasteEdit(.{ .insert_text = line });
    }
}

test "paste keystroke applyPasteEdit vs extract path cost" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
    defer alloc.free(path);

    var ctrl = try app_controller.AppController.init(io, alloc, path);
    defer ctrl.deinit();
    fillPasteUrls(&ctrl, 400);

    const start_single = std.Io.Timestamp.now(io, .awake).nanoseconds;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        ctrl.applyPasteEdit(.{ .insert_text = "x" });
    }
    const single_ns = std.Io.Timestamp.now(io, .awake).nanoseconds - start_single;

    const start_chunk = std.Io.Timestamp.now(io, .awake).nanoseconds;
    i = 0;
    while (i < 200) : (i += 1) {
        ctrl.applyPasteEdit(.{ .insert_text = "xy" });
    }
    const chunk_ns = std.Io.Timestamp.now(io, .awake).nanoseconds - start_chunk;

    try std.testing.expect(single_ns < 20 * std.time.ns_per_ms);
    try std.testing.expect(chunk_ns < 20 * std.time.ns_per_ms);
    try std.testing.expect(std.mem.endsWith(u8, ctrl.pasteText(), "xy"));
}

test "paste of glued urls still extracts on insert" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
    defer alloc.free(path);

    var ctrl = try app_controller.AppController.init(io, alloc, path);
    defer ctrl.deinit();
    ctrl.applyPasteEdit(.{ .insert_text = "see https://a.test/xhttps://b.test/y, and more" });
    try std.testing.expectEqualStrings("https://a.test/x\nhttps://b.test/y", ctrl.pasteText());
}

test "paste keystroke paint cost with filled paste field" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
    defer alloc.free(path);

    var ctrl = try app_controller.AppController.init(io, alloc, path);
    defer ctrl.deinit();
    ctrl.slots.phase = @intFromEnum(app_controller.Phase.unlocked);
    fillPasteUrls(&ctrl, 400);

    const frames: usize = 15;
    const start_filled = std.Io.Timestamp.now(io, .awake).nanoseconds;
    var f: usize = 0;
    while (f < frames) : (f += 1) {
        ctrl.applyPasteEdit(.{ .insert_text = "a" });
        _ = try paintIngestView(&ctrl, max_canvas_commands);
    }
    const filled_ns = std.Io.Timestamp.now(io, .awake).nanoseconds - start_filled;
    try std.testing.expect(filled_ns < 500 * std.time.ns_per_ms);
}

test "named group paste creates collection and keeps urls together" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
    defer alloc.free(path);

    var ctrl = try app_controller.AppController.init(io, alloc, path);
    defer ctrl.deinit();
    ctrl.setPasswordText("test-password-123");
    ctrl.slots.confirm_password_mode = 1;
    ctrl.setConfirmText("test-password-123");
    ctrl.createVault();

    ctrl.applyGroupEdit(.{ .insert_text = "XYZ" });
    ctrl.applyPasteEdit(.{ .insert_text = "https://bunkr.pk/f/a\nhttps://simpcity.cr/t/1\n" });
    ctrl.ingestPaste();
    try std.testing.expectEqual(@as(u32, @intFromEnum(app_controller.ErrorCode.none)), ctrl.slots.error_code);
    const xyz = ctrl.store.findCollectionByNameUnderParent(domain.root_parent, "XYZ") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(ctrl.store.findCollectionByNameUnderParent(domain.root_parent, "bunkr.pk") == null);
    var count: u32 = 0;
    for (ctrl.store.nodes.items) |node| {
        switch (node) {
            .entry => |e| {
                try std.testing.expectEqualSlices(u8, &xyz, &e.parent_id);
                count += 1;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expectEqual(@as(usize, 2), ctrl.entry_row_count);
}

test "entry list caps displayed rows" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
    defer alloc.free(path);

    var ctrl = try app_controller.AppController.init(io, alloc, path);
    defer ctrl.deinit();

    var text: [24576]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const line = std.fmt.bufPrint(text[n..], "https://bulk.test/u{d}\n", .{i}) catch unreachable;
        n += line.len;
    }
    const ingested = try ctrl.store.ingestUrls(text[0..n], 1000, null);
    try std.testing.expectEqual(@as(u32, 200), ingested.created);
    const host = ctrl.store.findCollectionByNameUnderParent(domain.root_parent, "bulk.test") orelse
        return error.TestUnexpectedResult;
    ctrl.rebuildTree();
    ctrl.selectNode(host);
    try std.testing.expect(ctrl.entry_row_count <= app_controller.max_entry_rows_pub);
    try std.testing.expectEqual(app_controller.max_entry_rows_pub, ctrl.entry_row_count);
    try std.testing.expectEqual(@as(usize, 1), ctrl.tree_row_count);
}

test "entry select keeps listing folder; tree arrows move from that folder" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(alloc, ".zig-cache/tmp/{s}/vault.kakuriyo", .{tmp.sub_path});
    defer alloc.free(path);

    var ctrl = try app_controller.AppController.init(io, alloc, path);
    defer ctrl.deinit();
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
    try std.testing.expect(!std.mem.eql(u8, &first_id, &third_id));
    try std.testing.expectEqual(@as(usize, 3), ctrl.tree_row_count);

    ctrl.selectNode(third_id);
    ctrl.addEntry();
    try std.testing.expect(ctrl.hasSelectedEntry());
    try std.testing.expectEqual(@as(usize, 1), ctrl.entry_row_count);
    ctrl.selectEntryAt(0);

    const listing = ctrl.listingCollectionId() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &third_id, &listing);
    try std.testing.expect(ctrl.findTreeIndex(ctrl.selected_id.?) == null);
    try std.testing.expectEqual(@as(usize, 2), ctrl.findTreeIndex(listing).?);

    ctrl.moveTreeSelection(-1);
    try std.testing.expectEqualSlices(u8, &second_id, &(ctrl.selected_id orelse return error.TestUnexpectedResult));
    try std.testing.expect(ctrl.hasSelectedCollection());
}
