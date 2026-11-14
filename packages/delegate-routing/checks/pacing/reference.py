"""Independent arithmetic and release-time oracles for synthetic observations."""

from fractions import Fraction


def score(rows, weight=1):
    # Rows are (role, capacity, remaining, duration, time left), not production objects.
    if any(remaining == 0 for _, _, remaining, _, _ in rows):
        return Fraction(0)
    paced = [(Fraction(remaining) * duration) / (capacity * left)
             for role, capacity, remaining, duration, left in rows if role == "pace"]
    return min(paced) * Fraction(weight)


def availability(now, blockers, complete=True):
    # Each blocker is a release instant or None; search observed instants, not minima.
    # This truth model knows nothing about normalized limits or the ranking engine.
    if not complete or None in blockers:
        return None
    candidates = sorted({now, *blockers})
    return next(instant for instant in candidates if all(release <= instant for release in blockers))
