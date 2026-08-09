#!/usr/bin/env bash
# Mutation gate: vault v1 envelope (Task 2).
#
# Applies each mutant M1..M8 to src/vault/vault.zig in turn, expects
# `zig build test-vault` to FAIL under the mutant, and restores the
# pristine copy from a backup afterwards. Any mutant whose oracles all
# pass is a SURVIVOR: the script exits 1 and names it.
#
# Run from inside the repo's nix shell:
#   nix-shell --run "bash tools/gates/mutate.sh"
set -euo pipefail
cd "$(dirname "$0")/../.."
TARGET=src/vault/vault.zig
BACKUP="$(mktemp)"
LOG_DIR=/tmp/kakuriyo-mutants
mkdir -p "$LOG_DIR"
cp "$TARGET" "$BACKUP"
trap 'cp "$BACKUP" "$TARGET"; rm -f "$BACKUP"' EXIT

# patch_with: run a python patch against $TARGET; fails the mutant
# instantly if the expected anchor text is missing (never a silent no-op).
patch_with() {
  python3 - "$TARGET" <<PYEOF
import sys
p = sys.argv[1]
s = open(p).read()
old = """$1"""
assert old in s, f"anchor missing for mutant"
open(p, 'w').write(s.replace(old, """$2""", 1))
PYEOF
}

run_mutant() { # name
  local name="$1"
  cp "$BACKUP" "$TARGET"
  if ! "$name"; then
    echo "MUTANT ANCHOR MISSING for ${name} — fix the mutant definition"
    exit 1
  fi
  set +e
  zig build test-vault >"$LOG_DIR/$name.log" 2>&1
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "SURVIVOR: $name — all oracles passed under this mutant"
    tail -3 "$LOG_DIR/$name.log"
    exit 1
  fi
  local failed
  failed=$(grep -oE "[0-9]+ pass, [0-9]+ fail" "$LOG_DIR/$name.log" | head -1)
  if [ -z "$failed" ]; then
    failed=$(grep -oE "[0-9]+/21 vault" "$LOG_DIR/$name.log" | head -1)
  fi
  echo "killed $name: ${failed:-compile failure}"
}

m1_wrong_aad() {
  patch_with 'pub const aad = "kakuriyo/vault-v1";' 'pub const aad = "kakuriyo/vault-v2";'
}

m2_constant_nonce() {
  # save() must reuse the DEK nonce for the payload nonce. Scoped to the
  # save fn only: create() keeps its fresh nonce, the rotate-nonce oracle
  # reads on-disk files after save().
  python3 - "$TARGET" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = "pub fn save(self: *Session, payload: []const u8) SaveError!void {"
old = "self.io.random(&payload_nonce);"
i = s.index(anchor)
j = s.index(old, i)
assert s.index("pub fn changePassword", i) > j, "patch would escape save()"
s = s[:j] + "@memcpy(&payload_nonce, &self.dek_nonce);" + s[j + len(old):]
open(p, 'w').write(s)
PYEOF
}

m3_no_zero_on_lock() {
  patch_with 'pub fn lock(self: *Session) void {
        std.crypto.secureZero(u8, &self.dek);' 'pub fn lock(self: *Session) void {'
}

m4_ignore_auth_error() {
  # Distort the payload-auth error into a password error: the tampered-
  # ciphertext oracle must fail (it expects error.Corrupt).
  patch_with '            std.crypto.secureZero(u8, &self.dek);
            return error.Corrupt;' '            std.crypto.secureZero(u8, &self.dek);
            return error.WrongPassword;'
}

m5_reuse_dek() {
  patch_with '        self.io.random(&self.dek);' '        @memcpy(&self.dek, &kek);'
}

m6_no_atomic() {
  patch_with '        var atomic = dir.createFileAtomic(self.io, std.fs.path.basename(self.path), .{ .replace = (mode == .replace) }) catch |err| switch (err) {
            // The createFileAtomic error set carries no OutOfMemory;
            // the else is exhaustive.
            else => return error.Io,
        };
        defer atomic.deinit(self.io);

        atomic.file.writeStreamingAll(self.io, out) catch return error.Io;
        atomic.file.sync(self.io) catch return error.Io;
        if (mode == .replace) {
            atomic.replace(self.io) catch return error.Io;
        } else {
            atomic.link(self.io) catch |err| switch (err) {
                error.PathAlreadyExists => return error.AlreadyExists,
                else => return error.Io,
            };
        }' '        // M6 mutant: plain create + write, no atomic temp/replace.
        var f = dir.createFile(self.io, std.fs.path.basename(self.path), .{}) catch |err| switch (err) {
            else => return error.Io,
        };
        defer f.close(self.io);
        f.writeStreamingAll(self.io, out) catch return error.Io;'
}

m7_no_rewrap() {
  patch_with '        @memcpy(&payload_nonce, bytes[108..132]);
        const payload_ct = bytes[132..];' '        self.io.random(&payload_nonce);
        const payload_ct = try self.encryptPayload(&payload_nonce, self.payload.?);'
}

m8_no_version_bind() {
  patch_with 'pub const aad = "kakuriyo/vault-v1";' 'pub const aad = "kakuriyo/vault";'
}

run_mutant m1_wrong_aad
run_mutant m2_constant_nonce
run_mutant m3_no_zero_on_lock
run_mutant m4_ignore_auth_error
run_mutant m5_reuse_dek
run_mutant m6_no_atomic
run_mutant m7_no_rewrap
run_mutant m8_no_version_bind

echo "all 8 mutants killed: no survivors"