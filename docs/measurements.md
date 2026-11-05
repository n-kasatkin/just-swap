# Measurements

The numbers behind "light" in the README, measured by `scripts/measure.sh`.

- Date: 2026-11-05
- Machine: Apple Silicon Mac (arm64), macOS 26
- Build: just swap 1.0.0, built by `scripts/build.sh` (Release, arm64, Developer ID), core claude-swap 0.30.0b1 (snapshot `23a6543b43`) on the bundled CPython.
- DMG: built like `scripts/release.sh` (UDZO, HFS+, the app and an Applications link), unsigned.

## Size

| What | Raw | Rounded |
|---|---|---|
| DMG (`ls -l`) | 38164833 bytes | 38.2 MB |
| Installed app (`du -sk`) | 92856 KB | 90.7 MiB (`du -sh`: 91M) |
| Bundled Python and core, `Contents/Resources/python` (`du -sk`) | 87488 KB | 85.4 MiB, 94% of the app |
| App code, `Contents/MacOS` and `Contents/Frameworks` (`du -sk`) | 3836 KB | 3.7 MiB |

## Idle

The installed app as it runs every day: menu bar item shown, popover closed, Autoswitch on; running for 00:22 (`ps -o etime=`) when measured.

| What | App | `cswap auto` child |
|---|---|---|
| Physical footprint (`footprint -p`) | 20 MB | 26 MB |
| Physical footprint (`vmmap --summary`) | 20.5M | 26.4M |
| CPU (`top -l 3 -s 5 -stats pid,cpu`, last sample) | 0.1% | 0.0% |
| Threads (`ps -M`) | 5 | 2 |
| RSS (`ps -o rss=`) | 71520 KB | 29168 KB |

## Commands

```sh
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
```

The same for `<child>`.
