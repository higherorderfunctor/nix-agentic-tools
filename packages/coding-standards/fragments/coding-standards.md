## Coding Standards

### Bash

All shell scripts must use full strict mode:

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
```

This applies everywhere: standalone scripts, generated wrappers,
`writeShellApplication`, heredocs in Nix.

### Ordering

Keep entries sorted alphabetically within categorical groups. Use section
headers for readability, sort entries within each group. This applies to
lists, attribute sets, JSON objects, markdown tables, TOML sections, and
similar collections.

### DRY Principle

Never duplicate logic, configuration, or patterns. When the same thing
appears twice, extract it. Three similar lines is better than a premature
abstraction, but three similar blocks means it is time to extract.
