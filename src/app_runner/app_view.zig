//! Kakuriyo native UI — auth, Links ingest+preview, Senhas gate+CRUD.

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
    const body = if (ctrl.slots.activity == @intFromEnum(app_controller.Activity.senhas))
        senhasShell(ui, ctrl)
    else
        linksShell(ui, ctrl);

    var stacked = ui.column(.{ .grow = 1 }, .{
        topBar(ui, ctrl),
        body,
    });
    if (ctrl.slots.show_delete_modal != 0) {
        stacked = ui.stack(.{ .grow = 1 }, .{ stacked, deleteModal(ui) });
    }
    return stacked;
}

fn topBar(ui: *AppUi, ctrl: *Ctrl) AppUi.Node {
    const links_on = ctrl.slots.activity == 0;
    const senhas_on = ctrl.slots.activity == 1;
    return ui.row(.{ .padding = 8, .gap = 8, .cross = .center }, .{
        ui.text(.{ .size = .heading }, "Kakuriyo"),
        ui.spacer(1),
        ui.button(.{
            .variant = if (links_on) .primary else .ghost,
            .on_press = .{ .activity_tab = 0 },
        }, "Links"),
        ui.button(.{
            .variant = if (senhas_on) .primary else .ghost,
            .on_press = .{ .activity_tab = 1 },
        }, "Senhas"),
        ui.button(.{ .on_press = .lock_press }, "Lock"),
    });
}

fn linksShell(ui: *AppUi, ctrl: *Ctrl) AppUi.Node {
    return ui.column(.{ .grow = 1 }, .{
        ui.row(.{ .padding = 8, .gap = 8, .cross = .center }, .{
            ui.textField(.{
                .placeholder = "Cole URLs http(s) — uma por linha",
                .text = ctrl.pasteText(),
                .grow = 1,
                .on_input = text_input_bridge.pasteInput,
            }),
            ui.button(.{ .variant = .primary, .on_press = .ingest_press }, "Ingerir"),
        }),
        ui.row(.{ .grow = 1 }, .{
            explorerPane(ui, ctrl),
            editorPane(ui, ctrl),
            previewPane(ui, ctrl),
        }),
    });
}

fn explorerPane(ui: *AppUi, ctrl: *Ctrl) AppUi.Node {
    var rows: [app_controller.max_tree_rows_pub]AppUi.Node = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < ctrl.tree_row_count) : (i += 1) {
        const row = ctrl.tree_rows[i];
        var label_buf: [512]u8 = undefined;
        const twisty: []const u8 = if (row.kind == 0)
            if (row.expanded) "▾" else "▸"
        else
            "·";
        var indent_buf: [64]u8 = undefined;
        @memset(&indent_buf, ' ');
        const indent_len = @min(row.depth * 2, indent_buf.len);
        const indent = indent_buf[0..indent_len];
        const label = std.fmt.bufPrint(&label_buf, "{s}{s}  {s}", .{ indent, twisty, row.title }) catch row.title;

        const selected = if (ctrl.selected_id) |sid|
            std.mem.eql(u8, &sid, &row.id)
        else
            false;

        rows[n] = ui.listItem(.{
            .on_press = .{ .select_row = @as(f64, @floatFromInt(i)) },
            .selected = selected,
        }, label);
        n += 1;
    }

    return ui.column(.{ .width = 280 }, .{
        ui.panel(.{ .padding = 8 }, ui.text(.{ .size = .sm }, "Coleções")),
        ui.scroll(.{ .grow = 1 }, if (n > 0) ui.column(.{}, rows[0..n]) else ui.column(.{}, .{})),
    });
}

fn editorPane(ui: *AppUi, ctrl: *Ctrl) AppUi.Node {
    const title = ctrl.editorTitle();
    const url = ctrl.editorUrl();
    const body = ctrl.editorBody();
    const has_entry = ctrl.hasSelectedEntry();
    return ui.column(.{ .padding = 12, .gap = 8, .grow = 1 }, .{
        ui.text(.{ .size = .sm }, "Título"),
        if (has_entry)
            ui.textField(.{
                .text = title,
                .placeholder = "Título",
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
        ui.text(.{ .size = .sm }, "Notas"),
        if (has_entry)
            ui.textField(.{
                .text = body,
                .placeholder = "Notas",
                .grow = 1,
                .on_input = text_input_bridge.entryBodyInput,
            })
        else
            ui.panel(.{ .padding = 8, .grow = 1 }, ui.text(.{}, "—")),
        ui.row(.{ .gap = 8 }, .{
            ui.button(.{ .variant = .primary, .on_press = .save_entry }, "Salvar"),
            ui.button(.{ .on_press = .refresh_preview }, "Refresh"),
            ui.button(.{ .on_press = .delete_press }, "Apagar"),
        }),
    });
}

fn previewPane(ui: *AppUi, ctrl: *Ctrl) AppUi.Node {
    const cached_title = ctrl.previewTitle();
    const cached_desc = ctrl.previewDescription();
    const image = ctrl.previewImage();
    var thumb_buf: [64]u8 = undefined;
    const thumb = if (image.len > 0)
        std.fmt.bufPrint(&thumb_buf, "thumbnail cached ({d} bytes)", .{image.len}) catch "thumbnail cached"
    else
        "sem thumbnail";
    return ui.column(.{ .width = 280, .padding = 12, .gap = 8 }, .{
        ui.text(.{ .size = .sm }, "Preview"),
        ui.panel(.{ .padding = 12 }, ui.text(.{}, thumb)),
        ui.text(.{ .size = .heading }, if (cached_title.len > 0) cached_title else "—"),
        ui.scroll(.{ .grow = 1 }, ui.text(.{ .wrap = true }, if (cached_desc.len > 0) cached_desc else "Select paints cache only — no network.")),
    });
}

fn senhasShell(ui: *AppUi, ctrl: *Ctrl) AppUi.Node {
    return switch (ctrl.slots.senhas_gate_state) {
        0 => senhasCreate(ui, ctrl),
        1 => senhasUnlock(ui, ctrl),
        else => senhasCrud(ui, ctrl),
    };
}

fn senhasCreate(ui: *AppUi, ctrl: *Ctrl) AppUi.Node {
    const err = ctrl.errorText();
    return ui.column(.{ .grow = 1, .main = .center, .cross = .center, .padding = 24 }, .{
        ui.panel(.{ .width = 420, .padding = 24 }, ui.column(.{ .gap = 12 }, .{
            ui.text(.{ .size = .heading }, "Senhas"),
            ui.text(.{}, "Crie a senha-gate (maiúscula, minúscula, dígito, especial)."),
            passwordFieldRow(ui, ctrl.passwordDisplay(), "Senha-gate", text_input_bridge.passwordInput, null),
            passwordFieldRow(ui, ctrl.confirmDisplay(), "Confirmar", text_input_bridge.confirmInput, .senhas_gate_create),
            if (err.len > 0) ui.text(.{}, err) else ui.spacer(0),
            ui.button(.{ .variant = .primary, .on_press = .senhas_gate_create }, "Criar gate"),
        })),
    });
}

fn senhasUnlock(ui: *AppUi, ctrl: *Ctrl) AppUi.Node {
    const err = ctrl.errorText();
    return ui.column(.{ .grow = 1, .main = .center, .cross = .center, .padding = 24 }, .{
        ui.panel(.{ .width = 420, .padding = 24 }, ui.column(.{ .gap = 12 }, .{
            ui.text(.{ .size = .heading }, "Senhas"),
            ui.text(.{}, "Desbloqueie o gate de senhas."),
            passwordFieldRow(ui, ctrl.passwordDisplay(), "Senha-gate", text_input_bridge.passwordInput, .senhas_gate_unlock),
            if (err.len > 0) ui.text(.{}, err) else ui.spacer(0),
            ui.button(.{ .variant = .primary, .on_press = .senhas_gate_unlock }, "Desbloquear"),
        })),
    });
}

fn senhasCrud(ui: *AppUi, ctrl: *Ctrl) AppUi.Node {
    const reveal = ctrl.slots.reveal_secrets != 0;
    const pass = ctrl.editorPass();
    const pass_display = if (reveal or pass.len == 0) pass else "••••••••";
    var rows: [256]AppUi.Node = undefined;
    var n: usize = 0;
    for (ctrl.store.secrets.items, 0..) |s, i| {
        if (n >= rows.len) break;
        const selected = if (ctrl.selected_secret) |sid|
            std.mem.eql(u8, &sid, &s.id)
        else
            false;
        rows[n] = ui.listItem(.{
            .on_press = .{ .select_row = @as(f64, @floatFromInt(i)) },
            .selected = selected,
        }, s.label);
        n += 1;
    }
    return ui.row(.{ .grow = 1 }, .{
        ui.column(.{ .width = 260 }, .{
            ui.panel(.{ .padding = 8 }, ui.text(.{ .size = .sm }, "Segredos")),
            ui.scroll(.{ .grow = 1 }, if (n > 0) ui.column(.{}, rows[0..n]) else ui.column(.{}, .{})),
            ui.button(.{ .on_press = .secret_add }, "+ Segredo"),
        }),
        ui.column(.{ .padding = 12, .gap = 8, .grow = 1 }, .{
            ui.text(.{ .size = .sm }, "Rótulo"),
            ui.textField(.{
                .text = ctrl.editorTitle(),
                .placeholder = "Rótulo",
                .grow = 1,
                .on_input = text_input_bridge.entryTitleInput,
            }),
            ui.text(.{ .size = .sm }, "Usuário"),
            ui.textField(.{
                .text = ctrl.editorUser(),
                .placeholder = "Usuário",
                .grow = 1,
                .on_input = text_input_bridge.entryUserInput,
            }),
            ui.text(.{ .size = .sm }, "Senha"),
            ui.textField(.{
                .text = pass_display,
                .placeholder = "Senha",
                .grow = 1,
                .on_input = text_input_bridge.entryPassInput,
            }),
            ui.text(.{ .size = .sm }, "Notas"),
            ui.textField(.{
                .text = ctrl.editorBody(),
                .placeholder = "Notas",
                .grow = 1,
                .on_input = text_input_bridge.entryBodyInput,
            }),
            ui.row(.{ .gap = 8 }, .{
                ui.button(.{ .variant = .primary, .on_press = .secret_save }, "Salvar"),
                ui.button(.{ .on_press = .toggle_reveal }, if (reveal) "Ocultar" else "Revelar"),
                ui.button(.{ .on_press = .secret_delete }, "Apagar"),
            }),
        }),
    });
}

fn deleteModal(ui: *AppUi) AppUi.Node {
    return ui.panel(.{ .padding = 24, .grow = 1 }, ui.column(.{ .gap = 12 }, .{
        ui.text(.{ .size = .heading }, "Apagar?"),
        ui.text(.{}, "Isto não pode ser desfeito."),
        ui.row(.{ .gap = 8 }, .{
            ui.button(.{ .variant = .primary, .on_press = .confirm_delete }, "Confirmar"),
            ui.button(.{ .on_press = .dismiss_delete }, "Cancelar"),
        }),
    }));
}
