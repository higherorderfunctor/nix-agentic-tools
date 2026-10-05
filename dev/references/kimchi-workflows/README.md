# Kimchi workflows research notes

Working notes behind #2227, kept on this draft for the operator to prune.
Neither file is authoritative; each labels its claims OBSERVED or INFERRED.

- `prose-to-workflow.md`: how Kiro, KiroCrew, Claude Code and Kimchi turn a
  prose request into a running workflow, and ranked paths for Kimchi's model.
- `pi-extension-feasibility.md`: whether a Claude-style dynamic workflow runner
  fits as a pi extension around the kimchi-workflows engine, with sizes.

Sources: `getkimchi/kimchi@v1.5.1`, `@kimchi-dev/kimchi-workflows@0.0.9`,
`@earendil-works/pi-coding-agent@0.85.1`, KiroCrew, and Claude Code's public
workflow documentation. Line citations refer to those versions.
