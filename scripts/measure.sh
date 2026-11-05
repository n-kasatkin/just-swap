#!/bin/bash
# Measures the numbers the README quotes and writes them to docs/measurements.md: DMG size,
# installed size, the bundled Python's share, and the idle memory, CPU and threads of a running
# just swap and of its `cswap auto` child.
# Usage: scripts/measure.sh [APP]   (default: /Applications/just swap.app, already running)
# It only observes: it never launches, quits or signals the app, so the numbers are those of the
# copy you use, with your accounts and settings. The DMG is built the way scripts/release.sh
# builds it, unsigned (signing adds a few KB).
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=release.sh
source "$(dirname "${BASH_SOURCE[0]}")/release.sh"

APP="${1:-/Applications/$APP_NAME.app}"
OUT_DOC="$ROOT/docs/measurements.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sizes() {
  stage "Sizes"
  make_dmg "$APP" "$WORK/$DMG_NAME"
  DMG_BYTES="$(stat -f %z "$WORK/$DMG_NAME")"
  APP_DU_H="$(du -sh "$APP" | awk '{print $1}')"
  APP_KB="$(du -sk "$APP" | awk '{print $1}')"
  PY_KB="$(du -sk "$APP/Contents/Resources/python" | awk '{print $1}')"
  APP_BIN_KB="$(du -sk "$APP/Contents/MacOS" "$APP/Contents/Frameworks" | awk '{s += $1} END {print s}')"
  echo "  DMG $DMG_BYTES bytes; app $APP_KB KB ($APP_DU_H), python $PY_KB KB, app code $APP_BIN_KB KB"
}

footprint_of() { footprint -p "$1" 2>/dev/null | sed -nE 's/.*Footprint: ([0-9.]+ [KMG]B).*/\1/p' | head -1; }
vmmap_of() { vmmap --summary "$1" 2>/dev/null | sed -nE 's/^Physical footprint: +([0-9.]+[KMG]).*/\1/p' | head -1; }
cpu_of() { top -l 3 -s 5 -pid "$1" -stats pid,cpu | awk -v p="$1" '$1 == p {c = $2} END {print c}'; }
threads_of() { echo $(($(ps -M -p "$1" | wc -l) - 1)); }

idle() {
  local exe="$APP/Contents/MacOS/$(defaults read "$APP/Contents/Info.plist" CFBundleExecutable)"
  stage "Idle"
  PID="$(pgrep -f "^$exe" | head -1 || true)"
  [[ -n "$PID" ]] || die "$APP is not running; open it and let it settle first"
  CHILD="$(pgrep -P "$PID" -f 'claude_swap auto' | head -1 || true)"
  UPTIME="$(ps -o etime= -p "$PID" | tr -d ' ')"
  APP_FP="$(footprint_of "$PID")"; APP_VM="$(vmmap_of "$PID")"
  APP_CPU="$(cpu_of "$PID")"; APP_THREADS="$(threads_of "$PID")"
  APP_RSS="$(ps -o rss= -p "$PID" | tr -d ' ')"
  echo "  app pid $PID (up $UPTIME): footprint $APP_FP, vmmap $APP_VM, CPU $APP_CPU%, threads $APP_THREADS, RSS $APP_RSS KB"
  if [[ -n "$CHILD" ]]; then
    AUTO_FP="$(footprint_of "$CHILD")"; AUTO_VM="$(vmmap_of "$CHILD")"
    AUTO_CPU="$(cpu_of "$CHILD")"; AUTO_THREADS="$(threads_of "$CHILD")"
    AUTO_RSS="$(ps -o rss= -p "$CHILD" | tr -d ' ')"
    echo "  auto pid $CHILD: footprint $AUTO_FP, vmmap $AUTO_VM, CPU $AUTO_CPU%, threads $AUTO_THREADS, RSS $AUTO_RSS KB"
  else
    AUTO_FP="not running (Autoswitch off)"; AUTO_VM="-"; AUTO_CPU="-"; AUTO_THREADS="-"; AUTO_RSS="-"
  fi
}

mb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1000000 }'; }
mib_kb() { awk -v k="$1" 'BEGIN { printf "%.1f", k / 1024 }'; }

write_doc() {
  local macos version
  macos="$(sw_vers -productVersion | cut -d. -f1)"
  version="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
  cat >"$OUT_DOC" <<DOC
# Measurements

The numbers behind "light" in the README, measured by \`scripts/measure.sh\`.

- Date: $(date +%Y-%m-%d)
- Machine: Apple Silicon Mac ($(uname -m)), macOS $macos
- Build: just swap $version, built by \`scripts/build.sh\` (Release, arm64, Developer ID), core claude-swap $(core_version) (snapshot \`$(cut -c1-10 "$APP/Contents/Resources/core-commit.txt")\`) on the bundled CPython.
- DMG: built like \`scripts/release.sh\` (UDZO, HFS+, the app and an Applications link), unsigned.

## Size

| What | Raw | Rounded |
|---|---|---|
| DMG (\`ls -l\`) | $DMG_BYTES bytes | $(mb "$DMG_BYTES") MB |
| Installed app (\`du -sk\`) | $APP_KB KB | $(mib_kb "$APP_KB") MiB (\`du -sh\`: $APP_DU_H) |
| Bundled Python and core, \`Contents/Resources/python\` (\`du -sk\`) | $PY_KB KB | $(mib_kb "$PY_KB") MiB, $(awk -v h="$PY_KB" -v a="$APP_KB" 'BEGIN { printf "%.0f", 100 * h / a }')% of the app |
| App code, \`Contents/MacOS\` and \`Contents/Frameworks\` (\`du -sk\`) | $APP_BIN_KB KB | $(mib_kb "$APP_BIN_KB") MiB |

## Idle

The installed app as it runs every day: menu bar item shown, popover closed, Autoswitch on; running for $UPTIME (\`ps -o etime=\`) when measured.

| What | App | \`cswap auto\` child |
|---|---|---|
| Physical footprint (\`footprint -p\`) | $APP_FP | $AUTO_FP |
| Physical footprint (\`vmmap --summary\`) | $APP_VM | $AUTO_VM |
| CPU (\`top -l 3 -s 5 -stats pid,cpu\`, last sample) | $APP_CPU% | $AUTO_CPU% |
| Threads (\`ps -M\`) | $APP_THREADS | $AUTO_THREADS |
| RSS (\`ps -o rss=\`) | $APP_RSS KB | $AUTO_RSS KB |

## Commands

\`\`\`sh
scripts/build.sh
ditto "build/just swap.app" "/Applications/just swap.app"; open "/Applications/just swap.app"
hdiutil create -volname "just swap" -srcfolder <app + Applications link> -fs HFS+ -format UDZO just-swap.dmg
ls -l just-swap.dmg
du -sh "just swap.app"; du -sk "just swap.app" "just swap.app/Contents/Resources/python"
pgrep -f "^/Applications/just swap.app/Contents/MacOS/just-swap"     # <pid>
pgrep -P <pid> -f "claude_swap auto"                                 # <child>
footprint -p <pid>; vmmap --summary <pid>
top -l 3 -s 5 -pid <pid> -stats pid,cpu
ps -M -p <pid>; ps -o rss= -p <pid>
\`\`\`

The same for \`<child>\`.
DOC
  echo "Wrote $OUT_DOC"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  sizes
  idle
  write_doc
fi
