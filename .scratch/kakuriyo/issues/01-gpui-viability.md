# gpui viability for Kakuriyo

Type: research
Status: resolved
Blocked by:

## Question

Can **gpui** (and optionally longbridge/gpui-component) support Kakuriyo’s needs as a **standalone** desktop app on **Windows 11** and **Linux (NixOS priority)**: keyboard-first navigation, dark UI, nested list + detail/Preview image panel, local file I/O, and distribution as a standalone executable — without telemetry? What are hard blockers, maturity risks, and honest fallbacks (e.g. Tauri/egui) if gpui cannot deliver?

## Answer

**go-with-caveats** — GPUI (+ gpui-component) covers Win11/Linux, keyboard Actions, dark Theme, Tree + Dock + images, local I/O, and a native binary with no framework telemetry; risks are pre-1.0 churn, thin docs, and NixOS packaging. Fallbacks: egui (lower churn), Tauri (web UI).

Research: [research/01-gpui-viability.md](../research/01-gpui-viability.md)
