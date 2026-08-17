//! Kakuriyo native UI — Unlock, Collection tree, Entry list, Preview.

const std = @import("std");
const native_sdk = @import("native_sdk");
const app_controller = @import("app_controller.zig");
const text_input_bridge = @import("text_input_bridge.zig");
const core = @import("core.zig");

const Ctrl = app_controller.AppController;
const Phase = app_controller.Phase;
const AppUi = native_sdk.TsUiApp(core).Ui;

pub fn build(ui: *AppUi, model: *const core.Model, ctrl: *Ctrl) AppUi.Node {
    _ = model;
    return switch (ctrl.phase()) {
        .fresh => sessionView(ui, ctrl, true),
        .locked => sessionView(ui, ctrl, false),
        .unlocked => mainView(ui, ctrl),
    };
}

fn sessionView(ui: *AppUi, ctrl: *Ctrl, creating: bool) AppUi.Node {
    const title = if (creating) "Create Master Password" else "Unlock Vault";
    const hint = if (creating)
        "Choose a Master Password (min 8 characters) and confirm."
    else
        "Enter your Master Password to unlock.";
    const action_label = if (creating) "Create" else "Unlock";
    const action_msg: core.Msg = if (creating) .create_press else .unlock_press;
    const err = ctrl.errorText();

    const form = if (creating) ui.column(.{ .gap = 12 }, .{
        ui.text(.{ .size = .heading }, "Kakuriyo"),
        ui.text(.{}, title),
        ui.text(.{ .size = .sm }, hint),
        passwordFieldRow(ui, ctrl.passwordDisplay(), "Master Password", text_input_bridge.passwordInput, null),
        passwordFieldRow(ui, ctrl.confirmDisplay(), "Confirm Password", text_input_bridge.confirmInput, action_msg),
        if (err.len > 0) ui.text(.{}, err) else ui.spacer(0),
        ui.button(.{ .variant = .primary, .on_press = action_msg }, action_label),
    }) else ui.column(.{ .gap = 12 }, .{
        ui.text(.{ .size = .heading }, "Kakuriyo"),
        ui.text(.{}, title),
        ui.text(.{ .size = .sm }, hint),
        passwordFieldRow(ui, ctrl.passwordDisplay(), "Master Password", text_input_bridge.passwordInput, action_msg),
        if (err.len > 0) ui.text(.{}, err) else ui.spacer(0),
        ui.button(.{ .variant = .primary, .on_press = action_msg }, action_label),
    });

    return ui.column(.{ .grow = 1, .main = .center, .cross = .center, .padding = 24 }, .{
        ui.panel(.{ .width = 400, .padding = 24 }, form),
    });
}

fn passwordFieldRow(
    ui: *AppUi,
    display: []const u8,
    placeholder: []const u8,
    on_input: *const fn (edit: native_sdk.canvas.TextInputEvent) core.Msg,
    on_submit: ?core.Msg,
) AppUi.Node {
    return ui.row(.{ .gap = 4, .cross = .center }, .{
        ui.textField(.{
            .placeholder = placeholder,
            .text = display,
            .grow = 1,
            .on_input = on_input,
            .on_submit = on_submit,
        }),
        ui.button(.{
            .icon = "eye",
            .size = .icon,
            .variant = .ghost,
            .on_press = .toggle_show_password,
        }, ""),
    });
}

fn mainView(ui: *AppUi, ctrl: *Ctrl) AppUi.Node {
    var stacked = ui.column(.{ .grow = 1 }, .{
        topBar(ui, ctrl),
        pasteBar(ui, ctrl),
        ui.row(.{ .grow = 1 }, .{
            explorerPane(ui, ctrl),
            entryListPane(ui, ctrl),
            detailPane(ui, ctrl),
        }),
    });
    if (ctrl.slots.show_delete_modal != 0) {
        stacked = ui.stack(.{ .grow = 1 }, .{ stacked, deleteModal(ui) });
    }
    return stacked;
}

fn topBar(ui: *AppUi, ctrl: *Ctrl) AppUi.Node {
    _ = ctrl;
    return ui.row(.{ .padding = 8, .gap = 8, .cross = .center }, .{
        ui.text(.{ .size = .heading }, "Kakuriyo"),
        ui.spacer(1),
        ui.button(.{ .on_press = .add_collection }, "Folder"),
        ui.button(.{ .on_press = .lock_press }, "Lock"),
    });
}

fn pasteBar(ui: *AppUi, ctrl: *Ctrl) AppUi.Node {
    const err = ctrl.errorText();
    return ui.column(.{}, .{
        ui.row(.{ .padding = 8, .gap = 8, .cross = .center }, .{
            ui.textField(.{
                .placeholder = "Paste http(s) URLs — many at once",
                .text = ctrl.pasteText(),
                .grow = 1,
                .on_input = text_input_bridge.pasteInput,
            }),
            ui.textField(.{
                .placeholder = "Save as folder (optional)",
                .text = ctrl.groupText(),
                .width = 220,
                .on_input = text_input_bridge.groupInput,
                .on_submit = .ingest_press,
            }),
            ui.button(.{ .variant = .primary, .on_press = .ingest_press }, "Save"),
        }),
        if (err.len > 0) ui.row(.{ .padding = 8 }, .{ui.text(.{}, err)}) else ui.spacer(0),
    });
}

fn explorerPane(ui: *AppUi, ctrl: *Ctrl) AppUi.Node {
    var rows: [app_controller.max_tree_rows_pub]AppUi.Node = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < ctrl.tree_row_count) : (i += 1) {
        const row = ctrl.tree_rows[i];
        const twisty: []const u8 = if (row.expanded) "▾" else "▸";
        const listing = ctrl.listingCollectionId();
        const selected = if (listing) |lid|
            std.mem.eql(u8, &lid, &row.id)
        else
            false;
        const spaces = "                ";
        const indent = spaces[0..@min(@as(usize, row.depth) * 2, spaces.len)];
        const select_msg: core.Msg = .{ .select_row = @as(f64, @floatFromInt(i)) };
        const pin_folder = selected and ctrl.pin_tree_widget_focus and ctrl.slots.focus_region == 0;
        const row_key: u64 = app_controller.uuidKey(row.id) ^
            (if (pin_folder) @as(u64, ctrl.tree_focus_gen) << 48 else 0);

        rows[n] = ui.listItem(.{
            .key = .{ .int = row_key },
            .on_press = select_msg,
            .selected = selected,
            .tree_level = @as(u16, row.depth) + 1,
            .expanded = row.expanded,
            .autofocus = pin_folder,
            .semantics = .{ .role = .treeitem },
        }, ui.fmt("{s}{s}  {s}", .{ indent, twisty, row.title }));
        n += 1;
    }

    return ui.column(.{ .width = 260 }, .{
        ui.row(.{ .padding = 8, .gap = 8, .cross = .center }, .{
            ui.text(.{ .size = .sm }, "Folders"),
        }),
        ui.scroll(.{ .grow = 1 }, if (n > 0) ui.tree(.{ .semantics = .{ .label = "Folders" } }, rows[0..n]) else ui.column(.{}, .{})),
    });
}

fn entryListPane(ui: *AppUi, ctrl: *Ctrl) AppUi.Node {
    var rows: [app_controller.max_entry_rows_pub]AppUi.Node = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < ctrl.entry_row_count) : (i += 1) {
        const row = ctrl.entry_rows[i];
        const selected = if (ctrl.selected_id) |sid|
            std.mem.eql(u8, &sid, &row.id)
        else
            false;
        rows[n] = ui.listItem(.{
            .key = .{ .int = app_controller.uuidKey(row.id) },
            .on_press = .{ .select_entry = @as(f64, @floatFromInt(i)) },
            .selected = selected,
        }, row.title);
        n += 1;
    }

    const empty = if (ctrl.listingCollectionId() == null)
        "Select a folder"
    else
        "No links in this folder";

    return ui.column(.{ .width = 320, .grow = 1 }, .{
        ui.row(.{ .padding = 8, .gap = 8, .cross = .center }, .{
            ui.text(.{ .size = .sm }, "Links"),
            ui.textField(.{
                .placeholder = "Filter",
                .text = ctrl.filterText(),
                .grow = 1,
                .on_input = text_input_bridge.filterInput,
            }),
        }),
        ui.row(.{ .padding = 8, .gap = 8, .cross = .center }, .{
            ui.button(.{ .on_press = .open_all_urls }, "Open all"),
            ui.button(.{ .on_press = .open_all_incognito }, "Incognito"),
            ui.button(.{ .on_press = .copy_all_urls }, "Copy all"),
        }),
        ui.scroll(.{ .grow = 1 }, if (n > 0) ui.column(.{}, rows[0..n]) else ui.panel(.{ .padding = 12 }, ui.text(.{}, empty))),
    });
}

fn detailPane(ui: *AppUi, ctrl: *Ctrl) AppUi.Node {
    return ui.column(.{ .padding = 12, .gap = 8, .grow = 1 }, .{
        editorPane(ui, ctrl),
        previewPane(ui, ctrl),
    });
}

fn editorPane(ui: *AppUi, ctrl: *Ctrl) AppUi.Node {
    const title = ctrl.editorTitle();
    const url = ctrl.editorUrl();
    const body = ctrl.editorBody();
    const has_entry = ctrl.hasSelectedEntry();
    const title_editable = has_entry or ctrl.hasSelectedCollection();
    const title_label: []const u8 = if (ctrl.hasSelectedCollection()) "Folder name" else "Title";
    return ui.column(.{ .gap = 8 }, .{
        ui.text(.{ .size = .sm }, title_label),
        if (title_editable)
            ui.textField(.{
                .text = title,
                .placeholder = title_label,
                .grow = 1,
                .on_input = text_input_bridge.entryTitleInput,
            })
        else
            ui.panel(.{ .padding = 8 }, ui.text(.{}, "—")),
        ui.text(.{ .size = .sm }, "URL"),
        if (has_entry)
            ui.textField(.{
                .text = url,
                .placeholder = "https://…",
                .grow = 1,
                .on_input = text_input_bridge.entryUrlInput,
            })
        else
            ui.panel(.{ .padding = 8 }, ui.text(.{}, "—")),
        ui.text(.{ .size = .sm }, "Notes"),
        if (has_entry)
            ui.textField(.{
                .text = body,
                .placeholder = "Notes",
                .grow = 1,
                .on_input = text_input_bridge.entryBodyInput,
            })
        else
            ui.panel(.{ .padding = 8 }, ui.text(.{}, "—")),
        ui.row(.{ .gap = 8 }, .{
            ui.button(.{ .variant = .primary, .on_press = .save_entry }, "Save"),
            ui.button(.{ .on_press = .refresh_preview }, "Refresh"),
            ui.button(.{ .on_press = .open_url }, "Open"),
            ui.button(.{ .on_press = .copy_url }, "Copy"),
            ui.button(.{ .on_press = .delete_press }, "Delete"),
        }),
    });
}

fn previewPane(ui: *AppUi, ctrl: *Ctrl) AppUi.Node {
    const cached_title = ctrl.previewTitle();
    const cached_desc = ctrl.previewDescription();
    const image = ctrl.previewImage();
    const thumb = if (image.len > 0)
        ui.fmt("thumbnail cached ({d} bytes)", .{image.len})
    else
        "no thumbnail";
    return ui.column(.{ .gap = 8, .grow = 1 }, .{
        ui.text(.{ .size = .sm }, "Preview"),
        ui.panel(.{ .padding = 12 }, ui.text(.{}, thumb)),
        ui.text(.{ .size = .heading }, if (cached_title.len > 0) cached_title else "—"),
        ui.scroll(.{ .grow = 1 }, ui.text(.{ .wrap = true }, if (cached_desc.len > 0) cached_desc else "Select an entry — cache only, no network until Refresh.")),
    });
}

fn deleteModal(ui: *AppUi) AppUi.Node {
    return ui.panel(.{ .padding = 24, .grow = 1 }, ui.column(.{ .gap = 12 }, .{
        ui.text(.{ .size = .heading }, "Delete?"),
        ui.text(.{}, "This cannot be undone."),
        ui.row(.{ .gap = 8 }, .{
            ui.button(.{ .variant = .primary, .on_press = .confirm_delete }, "Confirm"),
            ui.button(.{ .on_press = .dismiss_delete }, "Cancel"),
        }),
    }));
}
