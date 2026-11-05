#!/bin/bash
# Builds the signed Release app into build/just swap.app, with the core from vendor/claude-swap.
#   scripts/build.sh
#   CORE_PATH=<claude-swap checkout> scripts/build.sh   # another core source
#   TEAM_ID=<your team id> scripts/build.sh             # your own Developer ID identity
#   TEAM_ID= scripts/build.sh                            # ad hoc ("Sign to Run Locally")
#   DESTINATION=id=<Mac id> scripts/build.sh             # a specific Mac (xcodebuild -showdestinations)
# Needs Xcode 26, XcodeGen and uv (it downloads a python-build-standalone 3.14 if none is installed).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
if [[ -n "${CORE_PATH:-}" ]]; then export CORE_PATH; fi
TEAM_ID="${TEAM_ID-3V43DGM2S6}"
APP="build/just swap.app"

SIGN=(DEVELOPMENT_TEAM="$TEAM_ID")
[[ -z "$TEAM_ID" ]] && SIGN=(DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=-)
uv python find --no-project --managed-python 3.14 >/dev/null 2>&1 || uv python install 3.14

xcodegen generate --quiet
xcodebuild -project JustSwap.xcodeproj -scheme JustSwap -configuration Release \
    -derivedDataPath build/DerivedData -destination "${DESTINATION:-platform=macOS}" \
    "${SIGN[@]}" build -quiet
rm -rf "$APP"
ditto "build/DerivedData/Build/Products/Release/just swap.app" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP (core $(cat "$APP/Contents/Resources/core-commit.txt"))"
