"""Independent rational oracle for complete synthetic allowance observations."""

from fractions import Fraction


def score(rows, weight=1):
    # Rows are (role, capacity, remaining, duration, time left), not production objects.
    if any(remaining == 0 for _, _, remaining, _, _ in rows):
        return Fraction(0)
    paced = [(Fraction(remaining) * duration) / (capacity * left)
             for role, capacity, remaining, duration, left in rows if role == "pace"]
    return min(paced) * Fraction(weight)
