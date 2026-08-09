# Kakuriyo dev shell. The app links GTK4 on Linux (native SDK host), so
# `zig build`/`native build` need gtk4 dev files visible to pkg-config.
# Zig 0.16.0 is the SDK's pinned toolchain version.
#
# SCRIPTC_CC=zigcc: the TS core's external compiler (scriptc) drives its
# C backend through `clang` by default, which this NixOS box does not
# ship; `zig cc` bundles clang + sysroots and is the stable driver here.
#
# Usage: nix-shell
# CI (GitHub Actions) uses ubuntu + apt instead of this file; keep it
# honest by running the same gate command here.
{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  SCRIPTC_CC = "zigcc";
  packages = [
    pkgs.zig
    pkgs.gtk4
    pkgs.pkg-config
    pkgs.nodejs_24
  ];
}