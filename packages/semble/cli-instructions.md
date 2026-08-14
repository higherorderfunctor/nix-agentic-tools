Use `semble search` to find code by describing what it does or naming a symbol
or identifier, instead of grep:

```bash
semble search "authentication flow" ./my-project --max-snippet-lines 10
semble search "save_pretrained" ./my-project
semble search "save model to disk" ./my-project --top-k 10
```

Results are cached automatically on first run and invalidated when files change.

`--content` selects which categories to search, and takes several at once:

```bash
semble search "deployment guide" ./my-project --content docs
semble search "database host port" ./my-project --content config
semble search "auth" ./my-project --content code docs
semble search "authentication" ./my-project --content all
```

Use `semble find-related` to discover code similar to a known location. Pass the
`file_path` and `line` from a prior search result:

```bash
semble find-related src/auth.py 42 ./my-project
```

The path defaults to the current directory when omitted; Git URLs are accepted.

### Workflow

1. Start with `semble search` to find relevant chunks. The index is built and
   cached automatically.
2. Pass `--content` when searching beyond code: `docs`, `config`, several
   together such as `code docs`, or `all`.
3. Navigate directly to the returned file and line. Do not re-search or grep for
   the same content.
4. Optionally use `semble find-related` with a promising result's `file_path`
   and `line` to discover related implementations.
5. Use grep only when you need every occurrence of a literal string across the
   whole repository, such as all callers of a renamed function.
