// Kakuriyo app core — lane-safe number slots only.
// Vault, domain, and UI logic run in Zig (app_controller.zig); update
// is identity so the compiled TS lane never issues Cmd.request.
// Keyboard is handled in Zig (app_keyboard.zig) — no keyMsg export.

import type { TextInputEvent } from "@native-sdk/core/events";
import { Sub } from "@native-sdk/core";

export interface Model {
  readonly phase: number;
  readonly errorCode: number;
  readonly selectedHi: number;
  readonly selectedLo: number;
  readonly treeEpoch: number;
  readonly revealSecrets: number;
  readonly vimMotion: number;
  readonly activity: number;
  readonly showDeleteModal: number;
  readonly showImportModal: number;
  readonly showImportPasswordModal: number;
  readonly showSettingsModal: number;
  readonly showChangePasswordModal: number;
  readonly changePasswordStep: number;
  readonly showMergeModal: number;
  readonly mergeConflictIndex: number;
  readonly mergeConflictCount: number;
  readonly filterActive: number;
  readonly idlePreset: number;
  readonly lockoutUntilMs: number;
  readonly dirty: number;
  readonly confirmPasswordMode: number;
  readonly focusRegion: number;
  readonly senhasGateState: number;
  readonly senhasError: number;
  readonly secretIndex: number;
}

export type Msg =
  | { readonly kind: "tick"; readonly at: number }
  | { readonly kind: "password_input"; readonly edit: TextInputEvent }
  | { readonly kind: "confirm_input"; readonly edit: TextInputEvent }
  | { readonly kind: "unlock_press" }
  | { readonly kind: "create_press" }
  | { readonly kind: "lock_press" }
  | { readonly kind: "toggle_show_password" }
  | { readonly kind: "select_row"; readonly row: number }
  | { readonly kind: "toggle_row"; readonly row: number }
  | { readonly kind: "activity_tab"; readonly tab: number }
  | { readonly kind: "toggle_reveal" }
  | { readonly kind: "toggle_vim" }
  | { readonly kind: "filter_toggle" }
  | { readonly kind: "dismiss_delete" }
  | { readonly kind: "confirm_delete" }
  | { readonly kind: "delete_press" }
  | { readonly kind: "save_entry" }
  | { readonly kind: "add_entry" }
  | { readonly kind: "add_collection" }
  | { readonly kind: "export_vault" }
  | { readonly kind: "import_vault" }
  | { readonly kind: "dismiss_import" }
  | { readonly kind: "import_replace" }
  | { readonly kind: "import_merge" }
  | { readonly kind: "dismiss_import_password" }
  | { readonly kind: "import_password_submit" }
  | { readonly kind: "dismiss_merge" }
  | { readonly kind: "merge_keep_local" }
  | { readonly kind: "merge_keep_imported" }
  | { readonly kind: "merge_keep_both" }
  | { readonly kind: "dismiss_settings" }
  | { readonly kind: "change_password_open" }
  | { readonly kind: "dismiss_change_password" }
  | { readonly kind: "change_password_next" }
  | { readonly kind: "change_password_submit" }
  | { readonly kind: "cycle_idle_preset" }
  | { readonly kind: "open_url" }
  | { readonly kind: "cut_node" }
  | { readonly kind: "paste_node" }
  | { readonly kind: "editor_focus" }
  | { readonly kind: "tree_focus" }
  | { readonly kind: "focus_cycle" }
  | { readonly kind: "refresh_preview" }
  | { readonly kind: "ingest_press" }
  | { readonly kind: "paste_input"; readonly edit: TextInputEvent }
  | { readonly kind: "senhas_gate_create" }
  | { readonly kind: "senhas_gate_unlock" }
  | { readonly kind: "secret_add" }
  | { readonly kind: "secret_save" }
  | { readonly kind: "secret_delete" }
  | { readonly kind: "entry_title_input"; readonly edit: TextInputEvent }
  | { readonly kind: "entry_url_input"; readonly edit: TextInputEvent }
  | { readonly kind: "entry_user_input"; readonly edit: TextInputEvent }
  | { readonly kind: "entry_pass_input"; readonly edit: TextInputEvent }
  | { readonly kind: "entry_body_input"; readonly edit: TextInputEvent }
  | { readonly kind: "filter_input"; readonly edit: TextInputEvent }
  | { readonly kind: "move_tree"; readonly delta: number }
  | { readonly kind: "tree_horiz"; readonly delta: number };

const IDLE_MS = [60000, 300000, 900000, 1800000, 0];

export const viewUnbound = [
  "phase",
  "errorCode",
  "selectedHi",
  "selectedLo",
  "treeEpoch",
  "revealSecrets",
  "vimMotion",
  "activity",
  "showDeleteModal",
  "showImportModal",
  "showImportPasswordModal",
  "showSettingsModal",
  "showChangePasswordModal",
  "changePasswordStep",
  "showMergeModal",
  "mergeConflictIndex",
  "mergeConflictCount",
  "filterActive",
  "idlePreset",
  "lockoutUntilMs",
  "dirty",
  "confirmPasswordMode",
  "focusRegion",
  "senhasGateState",
  "senhasError",
  "secretIndex",
  "password_input",
  "confirm_input",
  "unlock_press",
  "create_press",
  "lock_press",
  "toggle_show_password",
  "select_row",
  "toggle_row",
  "activity_tab",
  "toggle_reveal",
  "toggle_vim",
  "filter_toggle",
  "dismiss_delete",
  "confirm_delete",
  "delete_press",
  "save_entry",
  "add_entry",
  "add_collection",
  "export_vault",
  "import_vault",
  "dismiss_import",
  "import_replace",
  "import_merge",
  "dismiss_import_password",
  "import_password_submit",
  "dismiss_merge",
  "merge_keep_local",
  "merge_keep_imported",
  "merge_keep_both",
  "dismiss_settings",
  "change_password_open",
  "dismiss_change_password",
  "change_password_next",
  "change_password_submit",
  "cycle_idle_preset",
  "open_url",
  "cut_node",
  "paste_node",
  "editor_focus",
  "tree_focus",
  "focus_cycle",
  "refresh_preview",
  "ingest_press",
  "paste_input",
  "senhas_gate_create",
  "senhas_gate_unlock",
  "secret_add",
  "secret_save",
  "secret_delete",
  "entry_title_input",
  "entry_url_input",
  "entry_user_input",
  "entry_pass_input",
  "entry_body_input",
  "filter_input",
  "move_tree",
  "tree_horiz",
  "tick",
] as const;

export function initialModel(): Model {
  return {
    phase: 0,
    errorCode: 0,
    selectedHi: 0,
    selectedLo: 0,
    treeEpoch: 0,
    revealSecrets: 0,
    vimMotion: 1,
    activity: 0,
    showDeleteModal: 0,
    showImportModal: 0,
    showImportPasswordModal: 0,
    showSettingsModal: 0,
    showChangePasswordModal: 0,
    changePasswordStep: 0,
    showMergeModal: 0,
    mergeConflictIndex: 0,
    mergeConflictCount: 0,
    filterActive: 0,
    idlePreset: 1,
    lockoutUntilMs: 0,
    dirty: 0,
    confirmPasswordMode: 0,
    focusRegion: 0,
    senhasGateState: 0,
    senhasError: 0,
    secretIndex: 0,
  };
}

export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "tick":
    case "password_input":
    case "confirm_input":
    case "unlock_press":
    case "create_press":
    case "lock_press":
    case "toggle_show_password":
    case "select_row":
    case "toggle_row":
    case "activity_tab":
    case "toggle_reveal":
    case "toggle_vim":
    case "filter_toggle":
    case "dismiss_delete":
    case "confirm_delete":
    case "delete_press":
    case "save_entry":
    case "add_entry":
    case "add_collection":
    case "export_vault":
    case "import_vault":
    case "dismiss_import":
    case "import_replace":
    case "import_merge":
    case "dismiss_import_password":
    case "import_password_submit":
    case "dismiss_merge":
    case "merge_keep_local":
    case "merge_keep_imported":
    case "merge_keep_both":
    case "dismiss_settings":
    case "change_password_open":
    case "dismiss_change_password":
    case "change_password_next":
    case "change_password_submit":
    case "cycle_idle_preset":
    case "open_url":
    case "cut_node":
    case "paste_node":
    case "editor_focus":
    case "tree_focus":
    case "focus_cycle":
    case "refresh_preview":
    case "ingest_press":
    case "paste_input":
    case "senhas_gate_create":
    case "senhas_gate_unlock":
    case "secret_add":
    case "secret_save":
    case "secret_delete":
    case "entry_title_input":
    case "entry_url_input":
    case "entry_user_input":
    case "entry_pass_input":
    case "entry_body_input":
    case "filter_input":
    case "move_tree":
    case "tree_horiz":
      return model;
  }
}

export function subscriptions(model: Model): Sub<Msg> {
  if (model.phase !== 2) return Sub.none;
  const ms = IDLE_MS[model.idlePreset] ?? 300000;
  if (ms === 0) return Sub.none;
  return Sub.timer("idle", ms, "tick");
}

export function commandMsg(name: string): Msg | null {
  if (name === "vault.lock") return { kind: "lock_press" };
  if (name === "vault.export") return { kind: "export_vault" };
  if (name === "vault.import") return { kind: "import_vault" };
  if (name === "entry.add") return { kind: "add_entry" };
  if (name === "collection.add") return { kind: "add_collection" };
  if (name === "vim.toggle") return { kind: "toggle_vim" };
  if (name === "vault.change_password") return { kind: "change_password_open" };
  if (name === "settings.open") return { kind: "dismiss_settings" };
  return null;
}
