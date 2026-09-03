# cspell:ignore sdoc
"""One module per state FIELD, each a pure declaration.

Nothing here imports `transitions` and nothing here runs. A file in this
directory is meant to be read and argued with the way a design note is; the
machinery that interrogates it lives one level up in `engine.py`.

Adding a field is a new module exporting `SEMANTIC`, plus one row in
`registry.py`. Nothing else moves.
"""
