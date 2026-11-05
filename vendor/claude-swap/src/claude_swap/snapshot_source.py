"""Snapshot source — the supported read path for dashboards and GUI shells.

Pacing is store-governed: the usage store's persisted poll plans plus its
freshness/backoff/claim gates (decided atomically in ``UsageStore.reserve``)
cap every surface at the same per-account cadence, so a dashboard repainting
every few seconds and a one-shot ``cswap list`` produce identical network
behavior. The one exception is ``force``, an explicit user refresh that skips
poll plans, the serve TTL and ordinary failure backoff (server deadlines,
recent 429s, holds and claims still gate it). This class therefore
runs the same on-demand pass as ``cswap list`` (``fetch=None``) by default —
the store decides which accounts, if any, may actually be fetched — and
offers ``store_only`` for shells that host an auto engine (which already
collects on its own schedule).

``take()`` is blocking (file locks, keychain subprocesses, network): call it
from a background thread, never a UI event loop.
"""

from __future__ import annotations

import json
import logging
import threading
import time
from dataclasses import replace

from claude_swap import oauth
from claude_swap.autoswitch import STATE_FILENAME
from claude_swap.json_output import USAGE_TOKEN_EXPIRED
from claude_swap.models import AccountSnapshot, AccountsSnapshot
from claude_swap.poll_policy import EXHAUSTED_INTERVAL_S
from claude_swap.switcher import ClaudeAccountSwitcher
from claude_swap.usage_store import UsageEntry

_logger = logging.getLogger("claude-swap")


class SnapshotSource:
    """Takes one coherent snapshot per call; the store paces the network.

    ``full`` is accepted (the TUI passes it on its explicit refresh) and
    ignored: that pass is the normal store-paced one.
    ``force=True`` (the menu bar's explicit refresh) skips ordinary poll plans
    for the active account and every enabled, unquarantined rotation account:
    each is fetched now, through the serve TTL and an ordinary failure
    backoff (``UsageStore.reserve(force=True)``); a server deadline, a recent
    429, a hold and an in-flight claim still gate it. A rotation account on a
    deliberately slow plan keeps it (see ``_keeps_plan``). ``store_only=True``
    reads the store without any network eligibility and wins over ``force``.
    """

    def __init__(self, switcher: ClaudeAccountSwitcher) -> None:
        self.switcher = switcher
        self._last: AccountsSnapshot | None = None
        self._lock = threading.Lock()
        self._plans_lock = threading.Lock()

    def take(
        self, *, full: bool = False, store_only: bool = False, force: bool = False
    ) -> AccountsSnapshot:
        """Blocking snapshot pass; call from a thread worker. ``full`` is
        accepted and ignored."""
        fetch: set[str] | None = None
        if store_only:
            fetch = set()
        elif force:
            fetch = self._forced_fetch_set()
        snap = self.switcher.accounts_snapshot(fetch=fetch, force=force)
        with self._lock:
            snap = self._reconcile(snap)
            self._last = snap
            return snap

    def _forced_fetch_set(self) -> set[str]:
        """The active slot plus the rotation accounts a forced pass may fetch.

        As in the auto engine's escalation set, quarantined slots are left
        out; so is a rotation row whose plan is a deliberate slow-down
        (``_keeps_plan``).
        """
        switcher = self.switcher
        quarantined = _quarantined(switcher)
        entries = switcher.usage_entries_by_account(fetch=set())
        _threshold, _weekly_threshold, models = switcher._poll_policy_inputs()
        now = time.time()
        fetch = {
            num
            for num in switcher.switchable_account_numbers()
            if num not in quarantined
            and not _keeps_plan(entries.get(num), now, models)
        }
        active = switcher.current_account_number()
        if active is not None:
            fetch.add(active)
        return fetch

    def refresh_plans(self) -> None:
        """Refresh due subscription plans; blocking, so call it from a worker.

        The counterpart of ``take(store_only=True)``, which never reaches the
        network: a shell whose snapshots are store-only calls this to keep its
        plan labels current. Overlapping calls collapse into the running one.
        Display-only, so a failure is logged and goes no further.
        """
        if not self._plans_lock.acquire(blocking=False):
            return
        try:
            self.switcher.refresh_subscription_plans()
        except Exception:
            _logger.debug("plan refresh failed", exc_info=True)
        finally:
            self._plans_lock.release()

    def _reconcile(self, snap: AccountsSnapshot) -> AccountsSnapshot:
        if self._last is None:
            return snap
        previous = {acc.number: acc for acc in self._last.accounts}
        accounts = tuple(
            self._reconcile_account(acc, previous.get(acc.number), snap.taken_at)
            for acc in snap.accounts
        )
        return replace(snap, accounts=accounts)

    def _reconcile_account(
        self,
        acc: AccountSnapshot,
        prev: AccountSnapshot | None,
        taken_at: float,
    ) -> AccountSnapshot:
        if prev is None or account_identity(acc) != account_identity(prev):
            return acc

        prev_fetched = prev.usage.fetched_at
        fetched = acc.usage.fetched_at
        if prev_fetched is not None and (fetched is None or fetched < prev_fetched):
            return replace(acc, usage=_with_current_age(prev.usage, taken_at))
        if acc.usage.sentinel is not None:
            return acc

        if (
            prev.usage.sentinel == USAGE_TOKEN_EXPIRED
            and fetched == prev_fetched
        ):
            return replace(acc, usage=replace(acc.usage, sentinel=USAGE_TOKEN_EXPIRED))
        return acc


def account_identity(acc: AccountSnapshot) -> tuple[str, str, str]:
    """The identity discriminator for a slot across snapshots.

    The single definition of "same account": snapshot reconciliation here and
    the TUI's snapshot merge must agree, or an identity change (e.g. a slot
    re-used by another login) is detected by one and missed by the other.
    """
    return (acc.email, acc.org_uuid, acc.kind)


def _with_current_age(usage: UsageEntry, taken_at: float) -> UsageEntry:
    fetched = usage.fetched_at
    if fetched is None:
        return usage
    return replace(usage, age_s=max(0.0, taken_at - fetched))


def _quarantined(switcher: ClaudeAccountSwitcher) -> set[str]:
    """Slots the auto engine's state file holds in quarantine."""
    try:
        state = json.loads(
            (switcher.backup_dir / STATE_FILENAME).read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        return set()
    quarantine = state.get("quarantine") if isinstance(state, dict) else None
    return set(quarantine) if isinstance(quarantine, dict) else set()


def _keeps_plan(
    entry: UsageEntry | None, now: float, models: tuple[str, ...]
) -> bool:
    """Whether a forced pass must leave this row to its future poll plan.

    Two plans are deliberate slow-downs: the post-429 cadence while that 429
    is recent (beating it re-spends a saturated request budget), and an
    exhausted row's plan wider than ``EXHAUSTED_INTERVAL_S`` (the escalation
    filter in ``AutoSwitchEngine._collect_scheduled_usage``, duplicated).
    """
    if entry is None or entry.next_poll_at is None or now >= entry.next_poll_at:
        return False
    if entry.recent_429(now):
        return True
    value = entry.decision_value()
    headroom = oauth.account_headroom(
        value if isinstance(value, dict) else None, models
    )
    return (
        (entry.poll_interval_s or 0.0) > EXHAUSTED_INTERVAL_S
        and headroom is not None
        and headroom <= 0
    )
