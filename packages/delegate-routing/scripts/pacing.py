"""Rank normalized credential allowances without collecting or selecting a route.

Owner tests call rank() with normalize() output and a typed ranking policy.
The result retains that snapshot and adds ordered entries; it never advances
observations or infers a refill from elapsed time.
"""

from typing import Literal, NamedTuple

from pydantic import BaseModel, Field

from usage.scope import Amount, Positive, Route
from usage_normalize import Normalized, Observation


class RankingPolicy(BaseModel, extra="forbid"):
    """Parse pool preferences and the fallback pace for idle windows."""

    idleBaseline: Positive = 1.0
    weights: dict[str, Amount] = Field(default_factory=dict)


class Entry(Route):
    """Expose readiness and weighted pace for one route and credential alternative."""

    pace: Amount | None
    pool: str | None
    score: Amount
    state: Literal["out", "ready"]


class PoolLimits(NamedTuple):
    """The limits one pool applies to one route, and whether that pool's scope is resolved."""

    pool: str | None
    resolved: bool
    limits: list[Observation]


class Ranking(NamedTuple):
    """Retain the trusted snapshot alongside computed entries without revalidation."""

    snapshot: Normalized
    entries: list[Entry]


def allowance(
    limits: list[Observation], resolved: bool, now: int, idle_baseline: float
) -> tuple[float | None, bool]:
    """Return a route's pace in one pool (the lowest of its pace limits) and whether it is ready.

    Any limit at zero blocks the route. A pace limit at zero also makes the pace
    zero, even when other evidence is unknown; otherwise unknown evidence leaves
    the pace unknown and the route out.
    """
    paces: list[float] = []
    blocked, uncertain = False, not resolved
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
        elif limit.remaining is None or limit.windowSeconds is None or limit.naturalResetAt is None:
            uncertain = True
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


def rank(snapshot: Normalized, policy: RankingPolicy | None = None) -> Ranking:
    """Keep every offer and applicable pool, sorting ready scores by preference."""
    ranking_policy = policy or RankingPolicy()
    if ranking_policy.weights.keys() - snapshot.pools.keys():
        raise ValueError("unknown-policy-pool")
    entries: list[Entry] = []
    for offer in snapshot.routes:
        applicable = [
            PoolLimits(pool, evidence.scopeResolved, [limit for limit in evidence.limits if offer.id in limit.models])
            for pool, evidence in sorted(snapshot.pools.items())
        ]
        # A route that no pool's limits cover still gets one entry, so callers see it as out.
        applicable = [item for item in applicable if item.limits] or [PoolLimits(None, False, [])]
        for pool, resolved, limits in applicable:
            pace, ready = allowance(limits, resolved, snapshot.asOf, ranking_policy.idleBaseline)
            score = 0.0
            if ready and pace is not None and pool is not None:
                score = pace * ranking_policy.weights.get(pool, 1)
            # Entry's finite score constraint refuses overflow of otherwise finite factors.
            entries.append(
                Entry(
                    id=offer.id,
                    maker=offer.maker,
                    model=offer.model,
                    pace=pace,
                    pool=pool,
                    score=score,
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
