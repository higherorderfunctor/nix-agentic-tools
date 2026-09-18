#!/usr/bin/env python3
# cspell:ignore unrelate
"""The stdlib-only operation-name registry shared by scribe's two processes."""

READS = ("show", "list", "check")
WRITES = ("new", "set", "relate", "unrelate", "move", "delete")
OPERATIONS = READS + WRITES
