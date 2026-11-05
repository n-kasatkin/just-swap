#!/bin/bash
# Refreshes the vendored claude-swap snapshot in vendor/claude-swap from a checkout:
# src/, pyproject.toml, uv.lock, LICENSE and README.md at the checkout's HEAD (committed files
# only, no tests or history), plus COMMIT with that HEAD's hash. PATCHES.md is kept; update it
# by hand when the patch list changes.
# Usage: CORE_PATH=<claude-swap checkout> scripts/sync-core.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/claude-swap"
die() { echo "sync-core.sh: $*" >&2; exit 1; }

[[ -n "${CORE_PATH:-}" ]] || die "set CORE_PATH to a claude-swap checkout"
git -C "$CORE_PATH" rev-parse --git-dir >/dev/null 2>&1 || die "$CORE_PATH is not a git checkout"
[[ -z "$(git -C "$CORE_PATH" status --porcelain --untracked-files=no)" ]] \
  || die "$CORE_PATH has uncommitted changes; commit or stash them first"

COMMIT="$(git -C "$CORE_PATH" rev-parse HEAD)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git -C "$CORE_PATH" archive --format=tar HEAD src pyproject.toml uv.lock LICENSE README.md | tar -x -C "$TMP"

[[ -f "$DEST/PATCHES.md" ]] && cp "$DEST/PATCHES.md" "$TMP/PATCHES.md"
echo "$COMMIT" >"$TMP/COMMIT"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$TMP" "$DEST"
trap - EXIT
chmod 755 "$DEST"
echo "vendor/claude-swap now at $COMMIT"
