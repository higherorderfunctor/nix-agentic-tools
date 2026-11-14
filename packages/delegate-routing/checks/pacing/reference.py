"""Supply the ranking tests with an independent rational arithmetic oracle.

Synthetic rows describe native quantities and time left. Fraction arithmetic
computes their restrictive weighted rate without importing the ranking engine.
"""

from fractions import Fraction


def score(rows, weight=1):
    # Rows are (role, capacity, remaining, duration, time left), not production objects.
    if any(remaining == 0 for _, _, remaining, _, _ in rows):
        return Fraction(0)
    paced = [(Fraction(remaining) * duration) / (capacity * left)
             for role, capacity, remaining, duration, left in rows if role == "pace"]
    return min(paced) * Fraction(weight)
