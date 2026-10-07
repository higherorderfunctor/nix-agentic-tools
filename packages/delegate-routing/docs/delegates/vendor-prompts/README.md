# Vendor prompts

Reference copies of the vendor-authored base prompt each harness sends, taken
from the offline map captures and scrubbed of machine-specific values. Each file
names its pinned version, launcher and capture case.

| File                     | Harness         |
| ------------------------ | --------------- |
| [claude.md](./claude.md) | Claude Code CLI |
| [codex.md](./codex.md)   | Codex CLI       |
| [kimchi.md](./kimchi.md) | Kimchi CLI      |
| [kiro.md](./kiro.md)     | Kiro CLI (v3)   |

Regenerate with
`python3 packages/delegate-routing/probes/delegates/vendor_prompts.py`.
