# claude-swap snapshot

A copy of [claude-swap](https://github.com/realiti4/claude-swap) by Onur Cetinkol, MIT (see
[LICENSE](LICENSE)), with the patches just swap needs. Only `src/`, `pyproject.toml`, `uv.lock`,
`LICENSE` and `README.md` are copied; tests and history stay upstream.

- Upstream base: [`e86b19b`](https://github.com/realiti4/claude-swap/commit/e86b19b9612295033dcc18085c64b346eda648a1)
  (`main`, 2026-11-03, "Merge pull request #541 from claycantrell/feat/weekly-first").
- Snapshot: commit `6a9500e` of the patched branch (full hash in [COMMIT](COMMIT)); the
  app shows its first characters in Settings.
- Refreshed with `CORE_PATH=<claude-swap checkout> scripts/sync-core.sh`.

## Patches on top of upstream

| Commit | Change |
|---|---|
| `7c5d8c1` | autoswitch, usage: leave a spent account before its limit; refresh on demand |
| `96f730e` | usage: probe setup-token usage by default |
| `136255c` | Refresh re-checks accounts that are in failure backoff |
| `0817e3b` | usage: a forced refresh skips a row attempted in the last 15 s |
| `435edb4` | list: `--refresh` and `--no-fetch` |
| `cbe1322` | list: quarantine, fetch timing and in-flight fetches in the JSON rows |
| `dfe330b` | config: the setting schema in `config list/get --json` |
| `007afbb` | auto: SIGUSR1 wakes the loop for an immediate poll |
| `1c1d193` | README: the new list flags, row fields, config schema and SIGUSR1 |
| `4323052` | hardening of the list and auto JSON additions |
| `f28968e` | list: `--refresh-all` probes every slot with credentials |
| `fb62bfa` | list: the priority tier in the JSON rows when set |
| `452381f` | `map --json` and `unclaimed --json` listings; `list --refresh-slot` probes one account |
| `23a6543` | `add-token --slot N` with the slot's own email keeps its alias, threshold, priority, disabled flag and identity |
| `6a9500e` | `add-token --slot N` with the same email checks the token's organization with one probe and refuses another organization's token |
