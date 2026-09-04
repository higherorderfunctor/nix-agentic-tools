#!/usr/bin/env python3
# cspell:ignore sgra sdoc
"""Read the option surface out of the .sgra grammar file, with no strictdoc
import and no corpus load (docs/plans/scribe-daemon/).

WHY THIS EXISTS. The scribe command line's flags are derived from the
grammar: one per declared field, each choice list read off that field, the
relation roles off the element. Building that has always required a loaded
graph, which is why `scribe --help` cost a full load and why a client could
not parse anything for itself.

It does not require the CORPUS, only the grammar, and the grammar is a file.
Reading it here was verified to reproduce the loaded grammar exactly -- zero
differences across tags, fields, required, options, roles and prefixes -- so
this is the same source the daemon resolves rather than a second copy
somebody has to keep in agreement.

Shared with docs/sdoc/view/view-check.py, which had the only implementation.
"""

from sdoc_semantics.grammar import _SGRA_LINE, _TYPE_RE, parse_sgra

__all__ = ["_SGRA_LINE", "_TYPE_RE", "parse_sgra"]
