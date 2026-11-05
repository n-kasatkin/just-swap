#!/bin/bash
# Builds, checks, notarizes and staples dist/just-swap.dmg for a release, on the owner's Mac
# so the Developer ID key never leaves the Keychain.
# Usage: scripts/release.sh [--publish] VERSION
#   Without --publish it stops after printing the `gh release create` command; with it, it runs it.
# Needs: a "Developer ID Application" identity of team 3V43DGM2S6 in the Keychain, the notarytool
# keychain profile just-swap-notary, and gh logged in as n-kasatkin.
# Sourcing the script only defines its functions (scripts/measure.sh reuses make_dmg).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The project's team; set TEAM_ID in the environment to use your own.
TEAM_ID="${TEAM_ID:-3V43DGM2S6}"
NOTARY_PROFILE="${NOTARY_PROFILE:-just-swap-notary}"
GH_OWNER=n-kasatkin
GH_REPO=n-kasatkin/just-swap
APP_NAME="just swap"
DMG_NAME=just-swap.dmg
DIST="$ROOT/dist"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"

die() { echo "release.sh: $*" >&2; exit 1; }
stage() { printf '\n==> %s\n' "$*"; }

marketing_version() { sed -nE 's/^ *MARKETING_VERSION: *"?([^" ]*)"?.*/\1/p' "$ROOT/project.yml"; }
core_version() { sed -nE 's/^version = "(.*)"/\1/p' "$ROOT/vendor/claude-swap/pyproject.toml"; }

# --- preflight -------------------------------------------------------------------------------
preflight() { # version
  local version="$1" current
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must look like 1.2.3, got '$version'"
  [[ -z "$(git -C "$ROOT" status --porcelain)" ]] \
    || die "the git tree is not clean; commit or stash first (git status --short)"
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
    die "tag v$version already exists locally"
  fi
  if git -C "$ROOT" remote get-url origin >/dev/null 2>&1 \
    && [[ -n "$(git -C "$ROOT" ls-remote --tags origin "refs/tags/v$version")" ]]; then
    die "tag v$version already exists on origin"
  fi
  current="$(marketing_version)"
  [[ "$current" == "$version" ]] \
    || die "VERSION $version does not match MARKETING_VERSION \"$current\" in project.yml. To bump, set MARKETING_VERSION: \"$version\" (and raise CURRENT_PROJECT_VERSION) in project.yml, commit, then rerun."
  [[ -n "$(developer_id)" ]] \
    || die "no valid 'Developer ID Application: … ($TEAM_ID)' signing identity in the Keychain. Create it in Xcode > Settings > Accounts > Manage Certificates (Account Holder), then rerun."
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "notarytool keychain profile '$NOTARY_PROFILE' is missing or rejected. Create it with: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple ID> --team-id $TEAM_ID"
  gh_token >/dev/null 2>&1 \
    || die "gh has no login for $GH_OWNER. Run: gh auth login --hostname github.com (as $GH_OWNER)"
  [[ "$(GH_TOKEN="$(gh_token)" gh api user --jq .login 2>/dev/null)" == "$GH_OWNER" ]] \
    || die "the stored gh token for $GH_OWNER does not authenticate as $GH_OWNER. Run: gh auth refresh --hostname github.com --user $GH_OWNER"
}

# SHA-1 of the team's Developer ID Application identity, so another team's never signs.
developer_id() {
  security find-identity -v -p codesigning \
    | awk -v team="($TEAM_ID)\"" '/"Developer ID Application: / && index($0, team) {print $2; exit}'
}

# gh may hold several accounts; the release always uses n-kasatkin's token, whichever is active.
gh_token() { gh auth token --hostname github.com --user "$GH_OWNER"; }

# --- build -----------------------------------------------------------------------------------
archive_and_export() { # work dir -> exported app at <work>/export/<APP_NAME>.app
  local work="$1"
  (cd "$ROOT" && xcodegen generate --quiet)
  # The vendored core (vendor/claude-swap), never a CORE_PATH from the environment.
  env -u CORE_PATH xcodebuild archive -quiet -project "$ROOT/JustSwap.xcodeproj" -scheme JustSwap \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$work/DerivedData" -archivePath "$work/JustSwap.xcarchive" \
    DEVELOPMENT_TEAM="$TEAM_ID"
  cat >"$work/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive -quiet -archivePath "$work/JustSwap.xcarchive" \
    -exportPath "$work/export" -exportOptionsPlist "$work/ExportOptions.plist"
  [[ -d "$work/export/$APP_NAME.app" ]] || die "export produced no '$APP_NAME.app' in $work/export"
}

check_notices() { # work dir, app
  "$ROOT/scripts/notices.sh" "$1/THIRD_PARTY_NOTICES.md" "$2" >/dev/null
  cmp -s "$1/THIRD_PARTY_NOTICES.md" "$ROOT/THIRD_PARTY_NOTICES.md" \
    || die "THIRD_PARTY_NOTICES.md is stale. Run scripts/build.sh and scripts/notices.sh, commit the result, then rerun."
}

# --- checks ----------------------------------------------------------------------------------
check_signature() { # file, expected authority prefix, [runtime: 1 to require the flag]
  local info
  info="$(codesign -dvv "$1" 2>&1)" || die "codesign cannot read the signature of $1"
  grep -q "^Authority=$2" <<<"$info" || die "$1: no 'Authority=$2' line"
  grep -q '^Timestamp=' <<<"$info" || die "$1: no secure timestamp (Timestamp= line)"
  if [[ "${3:-0}" == 1 ]] && ! grep -qE '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<<"$info"; then
    die "$1: hardened runtime flag is missing"
  fi
  grep -E '^(Authority|Timestamp|CodeDirectory|TeamIdentifier|Identifier)=?' <<<"$info" \
    | grep -vE '^Authority=(Apple|Developer ID) (Root|Certification)' | sed 's/^/    /'
}

check_entitlements() { # file
  if codesign -d --entitlements - --xml "$1" 2>/dev/null | grep -q 'com.apple.security.get-task-allow'; then
    die "$1: carries get-task-allow, which notarization rejects"
  fi
  echo "    entitlements: no get-task-allow"
}

check_app() { # app, expected authority prefix
  local app="$1" python="$1/Contents/Resources/python/bin/python3" out expected
  [[ -x "$python" ]] || die "$python is missing"
  echo "  app:"
  check_signature "$app" "$2" 1
  check_entitlements "$app"
  echo "  Resources/python/bin/python3:"
  check_signature "$python" "$2" 1
  codesign --verify --deep --strict --verbose=2 "$app" 2>&1 | sed 's/^/    /'
  # --version reads no account data.
  out="$(perl -e 'alarm 20; exec @ARGV' -- "$python" -I -B -m claude_swap --version 2>&1)" \
    || die "the bundled core failed --version: $out"
  expected="cswap $(core_version)"
  [[ "$out" == "$expected" ]] || die "bundled core reports '$out', expected '$expected'"
  echo "    core --version: $out"
}

# --- DMG -------------------------------------------------------------------------------------
make_dmg() { # app, output dmg, [signing identity]
  local app="$1" dmg="$2" staging
  staging="$(mktemp -d)"
  ditto "$app" "$staging/$APP_NAME.app"
  ln -s /Applications "$staging/Applications"
  mkdir -p "$(dirname "$dmg")"
  rm -f "$dmg"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$staging" -fs HFS+ -format UDZO "$dmg"
  rm -rf "$staging"
  if [[ -n "${3:-}" ]]; then
    codesign --sign "$3" --timestamp "$dmg"
  fi
}

notarize() { # file
  local result status id
  # One retry: the upload's first connection can time out (e.g. while a firewall prompt is open).
  result="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist)" \
    || result="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist)" \
    || die "notarytool submit failed"
  status="$(plutil -extract status raw - <<<"$result")"
  id="$(plutil -extract id raw - <<<"$result")"
  echo "  submission $id: $status"
  if [[ "$status" != Accepted ]]; then
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
    die "notarization ended with status $status"
  fi
}

check_gatekeeper() { # stapled dmg
  local out mnt
  out="$(spctl -a -vvv -t install "$1" 2>&1)" || die "spctl rejects the DMG: $out"
  grep -q 'source=Notarized Developer ID' <<<"$out" || die "DMG is not 'Notarized Developer ID': $out"
  echo "    DMG: $(grep '^source=' <<<"$out")"
  mnt="$(mktemp -d)"
  hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mnt" "$1"
  out="$(spctl -a -vvv "$mnt/$APP_NAME.app" 2>&1)" || { hdiutil detach -quiet "$mnt"; die "spctl rejects the app in the DMG: $out"; }
  xcrun stapler validate -q "$mnt/$APP_NAME.app" \
    || { hdiutil detach -quiet "$mnt"; die "the app in the DMG has no stapled ticket"; }
  hdiutil detach -quiet "$mnt"
  rmdir "$mnt"
  grep -q 'source=Notarized Developer ID' <<<"$out" || die "app is not 'Notarized Developer ID': $out"
  echo "    app: $(grep '^source=' <<<"$out")"
}

# --- notes and publish -----------------------------------------------------------------------
write_notes() { # version, sha256, output
  local notes changes previous
  previous="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
  if [[ -n "$previous" ]]; then
    changes="$(git -C "$ROOT" log --no-merges --format='- %s' "$previous..HEAD")"
  else
    changes="- First release."
  fi
  notes="$(<"$ROOT/docs/release-notes-template.md")"
  notes="${notes//\{\{VERSION\}\}/$1}"
  notes="${notes//\{\{CORE_VERSION\}\}/$(core_version)}"
  notes="${notes//\{\{SHA256\}\}/$2}"
  notes="${notes//\{\{CHANGES\}\}/$changes}"
  printf '%s\n' "$notes" >"$3"
}

main() {
  local publish=0 version="" app dmg sha commit
  while (($#)); do
    case "$1" in
      --publish) publish=1 ;;
      -h | --help) sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
      -*) die "unknown option $1" ;;
      *) [[ -z "$version" ]] || die "only one VERSION"; version="$1" ;;
    esac
    shift
  done
  [[ -n "$version" ]] || die "usage: scripts/release.sh [--publish] VERSION"

  stage "Preflight"
  preflight "$version"
  commit="$(git -C "$ROOT" rev-parse HEAD)"

  work="$(mktemp -d)" # global: the EXIT trap runs after main returns
  trap 'rm -rf "$work"' EXIT

  stage "Archive and export (Developer ID)"
  archive_and_export "$work"
  app="$work/export/$APP_NAME.app"
  [[ "$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)" == "$version" ]] \
    || die "the exported app's CFBundleShortVersionString is not $version"

  stage "THIRD_PARTY_NOTICES.md is current"
  check_notices "$work" "$app"

  stage "Check signatures"
  check_app "$app" "Developer ID Application"
  # On macOS 26 syspolicy_check rejects every not-yet-notarized Developer ID app with a generic
  # "Gatekeeper rejected this file", so it only warns; the notary service and check_gatekeeper decide.
  if command -v syspolicy_check >/dev/null; then
    syspolicy_check notary-submission "$app" || echo "  warning: syspolicy_check failed; notarization decides"
  fi

  # The app gets its own ticket: once dragged out of the DMG it no longer carries the DMG's,
  # and Gatekeeper would need a network check on first launch.
  stage "Notarize and staple the app"
  ditto -c -k --keepParent "$app" "$work/app.zip"
  notarize "$work/app.zip"
  xcrun stapler staple "$app"

  stage "DMG"
  rm -rf "$DIST"
  dmg="$DIST/$DMG_NAME"
  make_dmg "$app" "$dmg" "$(developer_id)"
  check_signature "$dmg" "Developer ID Application"

  stage "Notarize and staple the DMG"
  notarize "$dmg"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  check_gatekeeper "$dmg"

  stage "Checksum and notes"
  sha="$(shasum -a 256 "$dmg" | awk '{print $1}')"
  (cd "$DIST" && shasum -a 256 "$DMG_NAME" >"$DMG_NAME.sha256")
  write_notes "$version" "$sha" "$DIST/release-notes.md"
  echo "  $DIST/$DMG_NAME.sha256: $sha"
  echo "  $DIST/release-notes.md"

  local cmd=(gh release create "v$version" "dist/$DMG_NAME" "dist/$DMG_NAME.sha256"
    --repo "$GH_REPO" --target "$commit" --title "$APP_NAME $version" --notes-file dist/release-notes.md)
  stage "Publish"
  # Printed literally, so the token is fetched when the command runs, never shown here.
  # shellcheck disable=SC2016
  printf 'GH_TOKEN="$(gh auth token --hostname github.com --user %s)" %s\n' "$GH_OWNER" "$(printf '%q ' "${cmd[@]}")"
  if ((publish)); then
    (cd "$ROOT" && GH_TOKEN="$(gh_token)" "${cmd[@]}")
  else
    echo "Not published. Rerun with --publish, or run the command above from the repo root."
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
