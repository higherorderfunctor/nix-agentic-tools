## Coding Standards

### Bash

All shell scripts must use full strict mode:

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
```

### Ordering

Keep entries sorted alphabetically within categorical groups. Use section
headers for readability, sort entries within each group.

### DRY Principle

Never duplicate logic, configuration, or patterns. When the same thing appears
twice, extract it. Skills reference shared docs in `references/` rather than
duplicating content.
