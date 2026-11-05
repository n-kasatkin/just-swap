#!/bin/bash
# Xcode build phase: embeds a relocatable Python with the claude-swap core
# into Contents/Resources/python and signs every Mach-O in it inside-out.
#
# Inputs (env):
#   CORE_PATH     claude-swap source to build the wheel from (default: vendor/claude-swap)
#   PYTHON_SPEC   uv interpreter request (default: 3.14)
#   EMBED_PYTHON  1 to embed in a Debug build too (Release always embeds)
set -euo pipefail

if [[ "${CONFIGURATION:-Release}" != "Release" && "${EMBED_PYTHON:-0}" != "1" ]]; then
    echo "embed-python: skipped for ${CONFIGURATION} (set EMBED_PYTHON=1 to embed)"
    exit 0
fi

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CORE_PATH="${CORE_PATH:-$SRCROOT/vendor/claude-swap}"
CORE_PATH="$(cd "$CORE_PATH" && pwd)"
PYTHON_SPEC="${PYTHON_SPEC:-3.14}"
RES="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
DEST="$RES/python"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"

# The uv-managed python-build-standalone interpreter, resolved outside any
# project so a .venv in the cwd is never picked.
PY_EXE="$(cd / && uv python find --no-project --managed-python "$PYTHON_SPEC")"
PY_HOME="$(cd "$(dirname "$(readlink -f "$PY_EXE")")/.." && pwd)"
PY_VER="$("$PY_EXE" -I -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"
echo "embed-python: interpreter $PY_HOME ($PY_VER), core $CORE_PATH"

rm -rf "$DEST"
mkdir -p "$DEST"
# Only what a headless CLI needs: no Tk, IDLE, test suite, headers or docs.
rsync -a \
    --exclude '__pycache__' \
    --exclude '/include' --exclude '/share' --exclude '/BUILD' \
    --exclude '/lib/pkgconfig' --exclude '/lib/tcl*' --exclude '/lib/tk*' \
    --exclude '/lib/itcl*' --exclude '/lib/thread*' --exclude '/lib/libtcl*' --exclude '/lib/libtk*' \
    --exclude "/lib/python$PY_VER/test" --exclude "/lib/python$PY_VER/idlelib" \
    --exclude "/lib/python$PY_VER/tkinter" --exclude "/lib/python$PY_VER/turtledemo" \
    --exclude "/lib/python$PY_VER/ensurepip" --exclude "/lib/python$PY_VER/site-packages/pip*" --exclude "/lib/python$PY_VER/lib-dynload/_tkinter*" \
    --exclude "/lib/python$PY_VER/config-*" \
    --exclude '/bin/idle*' --exclude '/bin/pip*' --exclude '/bin/pydoc*' --exclude '/bin/*-config' \
    "$PY_HOME/" "$DEST/"
rm -f "$DEST/lib/python$PY_VER/EXTERNALLY-MANAGED"

WHEEL_DIR="$(mktemp -d)"
trap 'rm -rf "$WHEEL_DIR"' EXIT
(cd "$CORE_PATH" && uv build --wheel --quiet --out-dir "$WHEEL_DIR" .)
WHEEL="$(ls "$WHEEL_DIR"/*.whl | head -n 1)"
# Dependencies at exactly the versions in the core's uv.lock (--locked fails on a stale lock),
# so the bundle matches THIRD_PARTY_NOTICES.md; the core wheel itself goes in without resolving.
(cd / && uv export --locked --no-dev --no-hashes --no-emit-project --quiet \
    --project "$CORE_PATH" --output-file "$WHEEL_DIR/requirements.txt")
echo "embed-python: installing $(basename "$WHEEL") and its locked dependencies"
uv pip install --quiet --python "$DEST/bin/python3" --break-system-packages --no-cache \
    -r "$WHEEL_DIR/requirements.txt"
uv pip install --quiet --python "$DEST/bin/python3" --break-system-packages --no-cache --no-deps "$WHEEL"

# Console-script shims carry this build directory's absolute path; the app
# runs `python3 -m claude_swap` instead.
find "$DEST/bin" -type f ! -name "python$PY_VER" -delete
SITE="$DEST/lib/python$PY_VER/site-packages"
find "$SITE" -depth -type d \( -name tests -o -name test \) -exec rm -rf {} +
find "$DEST" -name '__pycache__' -type d -prune -exec rm -rf {} +
# Fresh bytecode baked in once, hash-checked never: the signed bundle is
# read-only at run time (the app also passes -B).
"$DEST/bin/python3" -I -m compileall -q -j 0 --invalidation-mode unchecked-hash "$DEST/lib/python$PY_VER" >/dev/null || true

# The vendored snapshot names its commit in COMMIT; a checkout is asked directly.
if [[ -f "$CORE_PATH/COMMIT" ]]; then
    COMMIT="$(<"$CORE_PATH/COMMIT")"
else
    COMMIT="$(git -C "$CORE_PATH" rev-parse HEAD)"
    if [[ -n "$(git -C "$CORE_PATH" status --porcelain --untracked-files=no -- src)" ]]; then
        COMMIT="$COMMIT-dirty"
    fi
fi
echo "$COMMIT" > "$RES/core-commit.txt"
echo "embed-python: core commit $COMMIT"

# Inside-out: deepest Mach-O first, the interpreter last.
SIGN_ARGS=(--force --sign "$IDENTITY" --options runtime)
[[ "$IDENTITY" != "-" ]] && SIGN_ARGS+=(--timestamp)
find "$DEST" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0 |
    while IFS= read -r -d '' f; do
        if file -b "$f" | grep -q 'Mach-O'; then
            printf '%s\t%s\n' "$(tr -cd '/' <<<"$f" | wc -c)" "$f"
        fi
    done | sort -rn | cut -f2- | while IFS= read -r f; do
        codesign "${SIGN_ARGS[@]}" "$f"
    done
echo "embed-python: signed $(find "$DEST" -type f \( -name '*.so' -o -name '*.dylib' \) | wc -l | tr -d ' ') libraries + interpreter"

# Reseal the app: on a build with no other changes Xcode skips its own
# signing step, which would leave the replaced Resources/python unsealed.
APP="${CODESIGNING_FOLDER_PATH:-$TARGET_BUILD_DIR/$WRAPPER_NAME}"
codesign "${SIGN_ARGS[@]}" --entitlements "$SRCROOT/JustSwap/JustSwap.entitlements" "$APP"
