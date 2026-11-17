"""Rank normalized credential allowances without collecting or selecting a route.

Owner tests call rank() with normalize() output and a typed ranking policy.
The result retains that snapshot and adds ordered entries; it never advances
observations or infers a refill from elapsed time.
"""

from pathlib import Path
import runpy
import types
from typing import Literal, NamedTuple

from pydantic import BaseModel, Field

# Share the normalizer's boundary types without an installed Python package.
normalizer = types.SimpleNamespace(**runpy.run_path(str(Path(__file__).with_name("usage-normalize.py"))))


class RankingPolicy(BaseModel, extra="forbid"):
    """Parse pool preferences and the fallback pace for idle windows."""

    idleBaseline: normalizer.Positive = 1.0
    weights: dict[str, normalizer.Amount] = Field(default_factory=dict)


class Entry(normalizer.Route):
    """Expose readiness and weighted pace for one route and credential alternative."""

    pace: normalizer.Amount | None
    pool: str | None
    score: normalizer.Amount
    state: Literal["out", "ready"]


class Ranking(NamedTuple):
    """Retain the trusted snapshot alongside computed entries without revalidation."""

    snapshot: normalizer.Normalized
    entries: list[Entry]


def allowance(
    limits: list[normalizer.Observation], resolved: bool, now: int, idle_baseline: float
) -> tuple[float | None, bool]:
    """Use normalized enforcement and validity; independent paced zero survives uncertainty."""
    paces, blocked, uncertain = [], False, not resolved
    for limit in limits:
        valid = limit.status == "valid" and limit.enforced is True
        if limit.remaining == 0:
            blocked = True
            uncertain |= not valid
            if limit.role == "pace":
                paces.append(0.0)
            continue
        if not valid:
            uncertain = True
            continue
        if limit.role != "pace":
            continue
        if limit.remaining == limit.capacity and (
            limit.naturalResetAt is None or limit.naturalResetAt <= now
        ):
            paces.append(idle_baseline)
        else:
            paces.append(
                limit.remaining / limit.capacity * limit.windowSeconds / (limit.naturalResetAt - now)
            )
    if 0 in paces:
        pace = 0.0
    elif uncertain or not paces:
        pace = None
    else:
        pace = min(paces)
    return pace, pace is not None and pace > 0 and not blocked and not uncertain


def rank(snapshot: normalizer.Normalized, policy: RankingPolicy | None = None) -> Ranking:
    """Keep every offer and applicable pool, sorting ready scores by preference."""
    ranking_policy = policy or RankingPolicy()
    if ranking_policy.weights.keys() - snapshot.pools.keys():
        raise ValueError("unknown-policy-pool")
    entries = []
    for offer in snapshot.routes:
        applicable = [
            (pool, evidence.scopeResolved, [limit for limit in evidence.limits if offer.id in limit.models])
            for pool, evidence in sorted(snapshot.pools.items())
        ]
        applicable = [item for item in applicable if item[2]] or [(None, False, [])]
        for pool, resolved, limits in applicable:
            pace, ready = allowance(limits, resolved, snapshot.asOf, ranking_policy.idleBaseline)
            # Entry's finite score constraint refuses overflow of otherwise finite factors.
            entries.append(
                Entry(
                    id=offer.id,
                    maker=offer.maker,
                    model=offer.model,
                    pace=pace,
                    pool=pool,
                    score=pace * ranking_policy.weights.get(pool, 1) if ready else 0,
                    state="ready" if ready else "out",
                )
            )
    entries.sort(
        key=lambda entry: (
            -entry.score,
            entry.state != "ready",
            entry.pool or "",
            entry.model,
            entry.id,
            entry.maker is not None,
            entry.maker or "",
        )
    )
    return Ranking(snapshot, entries)
