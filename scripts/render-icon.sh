#!/bin/bash
# Regenerates the AppIcon set and the logo previews in docs/screenshots from LogoArt.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
iconset=JustSwap/Assets.xcassets/AppIcon.appiconset
mkdir -p "$iconset" docs/screenshots
xcrun swiftc -parse-as-library -O scripts/RenderIcon.swift JustSwap/UI/Logo.swift -o "$out/render-icon"
"$out/render-icon" "$iconset" docs/screenshots
