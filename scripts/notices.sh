#!/bin/bash
# Writes THIRD_PARTY_NOTICES.md from a built app: the claude-swap core (vendor/claude-swap), the
# bundled CPython (python-build-standalone) with the software incorporated in it and the C
# libraries linked into it, and every Python distribution installed in the bundle's
# site-packages, each with its licence files (in .dist-info and inside the package).
# CPython's incorporated-software notices come from vendor/cpython/INCORPORATED-<version>.rst,
# vendored from the matching CPython tag's Doc/license.rst.
# Usage: scripts/notices.sh [OUTPUT] [APP]
#   OUTPUT  default THIRD_PARTY_NOTICES.md at the repo root
#   APP     default "build/just swap.app" (scripts/build.sh)
# Needs network access to fetch the SPDX texts of the C libraries' licences.
# Backticks in printf formats are Markdown code spans, not command substitutions.
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/THIRD_PARTY_NOTICES.md}"
APP="${2:-$ROOT/build/just swap.app}"
PY_DIR="$APP/Contents/Resources/python"
# Pinned so the licence texts stay identical between runs.
SPDX_TEXT=https://raw.githubusercontent.com/spdx/license-list-data/v3.29.0/text

die() { echo "notices.sh: $*" >&2; exit 1; }
[[ -x "$PY_DIR/bin/python3" ]] || die "no bundled Python in $APP; run scripts/build.sh first"

PY="$PY_DIR/bin/python3"
PY_VER="$("$PY" -I -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"
LIB="$PY_DIR/lib/libpython$PY_VER.dylib"
SITE="$PY_DIR/lib/python$PY_VER/site-packages"
[[ -f "$LIB" ]] || die "$LIB is missing"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fence() { # file: the text in a fence longer than any backtick run inside it
  local n=3 f
  while grep -q "$(printf '`%.0s' $(seq 1 "$n"))" "$1"; do n=$((n + 1)); done
  f="$(printf '`%.0s' $(seq 1 "$n"))"
  printf '%stext\n' "$f"
  tr -d '\r' <"$1"
  [[ -z "$(tail -c1 "$1")" ]] || echo
  printf '%s\n\n' "$f"
}

# --- claude-swap -----------------------------------------------------------------------------
core_version="$(sed -nE 's/^version = "(.*)"/\1/p' "$ROOT/vendor/claude-swap/pyproject.toml")"
core_commit="$(<"$ROOT/vendor/claude-swap/COMMIT")"

# --- CPython and its C libraries ---------------------------------------------------------------
read -r py_full openssl sqlite mpdec expat zstd < <("$PY" -I -c '
import ssl, sqlite3, decimal, pyexpat, sys
from compression import zstd
print(sys.version.split()[0], ssl.OPENSSL_VERSION.split()[1], sqlite3.sqlite_version,
      decimal.__libmpdec_version__, pyexpat.EXPAT_VERSION.split("_")[1], zstd.zstd_version)')
INCORPORATED="$ROOT/vendor/cpython/INCORPORATED-$py_full.rst"
[[ -f "$INCORPORATED" ]] || die "$INCORPORATED is missing; vendor the incorporated-software section of Doc/license.rst at CPython v$py_full"

# name | version | SPDX id | copyright | project URL | symbol that proves it is linked in
cat >"$TMP/clibs.tsv" <<EOF
OpenSSL	$openssl	Apache-2.0	Copyright (c) 1998-2025 The OpenSSL Project Authors; Copyright (c) 1995-1998 Eric A. Young, Tim J. Hudson	https://www.openssl.org	_OPENSSL_init_ssl
SQLite	$sqlite	blessing	Public domain	https://sqlite.org	_sqlite3_libversion
libffi	-	MIT	Copyright (c) 1996-2024 Anthony Green, Red Hat, Inc and others	https://github.com/libffi/libffi	_ffi_call
XZ Utils (liblzma)	-	0BSD	Copyright (C) The XZ Utils authors and contributors	https://tukaani.org/xz/	_lzma_version_string
bzip2	-	bzip2-1.0.6	Copyright (C) 1996-2019 Julian R Seward	https://sourceware.org/bzip2/	_BZ2_bzlibVersion
mpdecimal	$mpdec	BSD-2-Clause	Copyright (c) 2008-2024 Stefan Krah	https://www.bytereef.org/mpdecimal/	_mpd_version
Expat	$expat	MIT	Copyright (c) 1998-2000 Thai Open Source Software Center Ltd and Clark Cooper; Copyright (c) 2001-2025 Expat maintainers	https://libexpat.github.io	_XML_ExpatVersion
Zstandard	$zstd	BSD-3-Clause	Copyright (c) Meta Platforms, Inc. and affiliates	https://github.com/facebook/zstd	_ZSTD_versionString
libuuid (util-linux)	-	BSD-3-Clause	Copyright (C) 1996, 1997, 1998, 1999 Theodore Ts'o	https://github.com/util-linux/util-linux	_uuid_generate_time_safe
EOF
nm "$LIB" 2>/dev/null | awk '$2 ~ /^[TtSsDd]$/ {print $3}' | sort -u >"$TMP/symbols.txt"
: >"$TMP/clibs-linked.tsv"
while IFS=$'\t' read -r name version spdx copyright url symbol; do
  if grep -qxF "$symbol" "$TMP/symbols.txt"; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$version" "$spdx" "$copyright" "$url" >>"$TMP/clibs-linked.tsv"
  fi
done <"$TMP/clibs.tsv"

# --- site-packages -----------------------------------------------------------------------------
"$PY" -I - "$SITE" >"$TMP/dists.tsv" <<'EOF'
import sys
from importlib.metadata import distributions
from pathlib import Path
site = Path(sys.argv[1])
rows = []
for d in distributions(path=[str(site)]):
    m = d.metadata
    name = m["Name"]
    if name.lower().replace("_", "-") == "claude-swap":
        continue
    lic = m.get("License-Expression") or m.get("License") or ""
    if not lic or len(lic) > 60:
        cls = [c.split(" :: ")[-1].removesuffix(" License") for c in (m.get_all("Classifier") or []) if c.startswith("License ::")]
        lic = ", ".join(cls) or "see licence files"
    url = ""
    for p in m.get_all("Project-URL") or []:
        label, _, u = p.partition(", ")
        if label.lower() in ("source", "repository", "homepage", "source code"):
            url = u.strip(); break
    url = url or m.get("Home-page") or ""
    keys = ("LICEN", "COPYING", "NOTICE", "AUTHORS")
    def notice(f):
        n = f.name.upper()
        if f.parts[0].endswith(".dist-info"):
            return any(k in n for k in keys)
        # Inside the package (e.g. mdit_py_plugins/<plugin>/LICENSE): text files only.
        return n.startswith(keys) and f.suffix.lower() in ("", ".txt", ".md", ".rst")
    files = sorted(str(d.locate_file(f)) for f in (d.files or []) if notice(f))
    rows.append((name.lower(), name, m["Version"], lic, url, "|".join(files)))
for r in sorted(rows):
    print("\t".join(r[1:]))
EOF
[[ -s "$TMP/dists.tsv" ]] || die "found no Python distributions in $SITE"

anchor() { tr '[:upper:] ' '[:lower:]-' <<<"$1" | tr -cd 'a-z0-9.-'; }

# --- write -------------------------------------------------------------------------------------
{
  printf '# Third-party notices\n\n'
  printf 'This file covers the third-party software that ships in just swap.app. just swap itself is MIT-licensed; see LICENSE.\n\n'
  printf 'Generated by `scripts/notices.sh` from a build with claude-swap %s (vendored snapshot `%s`), CPython %s and the Python distributions installed in the bundle. Do not edit by hand.\n\n' \
    "$core_version" "${core_commit:0:10}" "$py_full"
  printf '## Summary\n\n| Component | Version | Licence |\n|---|---|---|\n'
  printf '| [claude-swap](#claude-swap) | %s | `MIT` |\n' "$core_version"
  printf '| [CPython](#cpython) | %s | `PSF-2.0` |\n' "$py_full"
  while IFS=$'\t' read -r name version spdx _ _; do
    printf '| [%s](#c-libraries) | %s | `%s` |\n' "$name" "$version" "$spdx"
  done <"$TMP/clibs-linked.tsv"
  while IFS=$'\t' read -r name version lic _ _; do
    printf '| [%s](#%s) | %s | `%s` |\n' "$name" "$(anchor "$name-$version")" "$version" "$lic"
  done <"$TMP/dists.tsv"
  echo

  printf '<a id="claude-swap"></a>\n## claude-swap %s\n\n' "$core_version"
  printf 'The account-switching core, by Onur Cetinkol: <https://github.com/realiti4/claude-swap>. A patched snapshot is vendored in `vendor/claude-swap`; see `vendor/claude-swap/PATCHES.md`.\n\n'
  fence "$ROOT/vendor/claude-swap/LICENSE"

  printf '<a id="cpython"></a>\n## CPython %s\n\n' "$py_full"
  printf 'The interpreter and standard library in `Contents/Resources/python`, a relocatable build from python-build-standalone (<https://github.com/astral-sh/python-build-standalone>), stripped of Tk, IDLE, the test suite and pip. The licence below is the `LICENSE.txt` that ships with it.\n\n'
  fence "$PY_DIR/lib/python$PY_VER/LICENSE.txt"
  printf '### Incorporated software

CPython incorporates the software below; the notices are the "Licenses and Acknowledgements for Incorporated Software" section of `Doc/license.rst` at CPython v%s, plus the licence header of `Modules/_hacl` (HACL*). Some entries cover modules or tests this bundle leaves out.

' "$py_full"
  sed '/^\.\. /d' "$INCORPORATED" | sed '/./,$!d' >"$TMP/incorporated.rst"
  fence "$TMP/incorporated.rst"

  printf '<a id="c-libraries"></a>\n## C libraries linked into CPython\n\n'
  printf 'python-build-standalone links these libraries statically into `libpython%s.dylib` (each one was found by a symbol in the built library). zlib, libedit and ncurses come from macOS and are not bundled.\n\n' "$PY_VER"
  while IFS=$'\t' read -r name version spdx copyright url; do
    printf '### %s%s\n\n%s. <%s>\n\nLicence: `%s`.\n\n' "$name" "$([[ "$version" == - ]] || echo " $version")" "$copyright" "$url" "$spdx"
  done <"$TMP/clibs-linked.tsv"
  printf '### Licence texts\n\n'
  for spdx in $(cut -f3 "$TMP/clibs-linked.tsv" | grep -vx blessing | sort -u); do
    curl -fsSL --retry 2 --connect-timeout 20 --max-time 120 "$SPDX_TEXT/$spdx.txt" -o "$TMP/$spdx.txt" \
      || die "cannot fetch the SPDX text of $spdx"
    printf '#### %s\n\n' "$spdx"
    fence "$TMP/$spdx.txt"
  done

  printf '## Python packages\n\nInstalled in `Contents/Resources/python/lib/python%s/site-packages` as dependencies of claude-swap.\n\n' "$PY_VER"
  while IFS=$'\t' read -r name version lic url files; do
    printf '<a id="%s"></a>\n### %s %s\n\n' "$(anchor "$name-$version")" "$name" "$version"
    printf 'Licence: `%s`.%s\n\n' "$lic" "$([[ -z "$url" ]] || echo " <$url>")"
    IFS='|' read -ra paths <<<"$files"
    for f in "${paths[@]}"; do
      [[ -f "$f" ]] || continue
      printf '`%s`:\n\n' "${f#"$SITE"/}"
      fence "$f"
    done
  done <"$TMP/dists.tsv"
} >"$TMP/out.md"

mv "$TMP/out.md" "$OUT"
echo "Wrote $OUT ($(wc -l <"$TMP/dists.tsv" | tr -d ' ') Python packages, $(wc -l <"$TMP/clibs-linked.tsv" | tr -d ' ') C libraries)"
