# Fragments & Composition

Fragments are typed building blocks for instruction content. They solve
the problem of maintaining the same coding standards, conventions, and
routing tables across multiple AI CLIs without copy-paste duplication.

## What Is a Fragment?

A fragment is a Nix attrset with four fields:

```nix
{
  text = "The actual instruction content (markdown).";
  description = "Human label for identification.";  # null OK
  paths = ["src/**"];  # file globs for scoped instructions, null = always
  priority = 10;       # higher = earlier in composed output
}
```

Create one with `mkFragment`:

```nix
fragments.mkFragment {
  text = builtins.readFile ./my-standard.md;
  description = "coding-standards/my-standard";
  priority = 10;
}
```

## Composition

`compose` takes a list of fragments and produces a single fragment.
The algorithm:

1. **Sort** by priority descending (higher priority appears first)
2. **Deduplicate** by SHA-256 hash of the text content
3. **Concatenate** the remaining texts with newline separators

```nix
fragments.compose {
  fragments = [
    (fragments.mkFragment { text = "Rule A"; priority = 20; })
    (fragments.mkFragment { text = "Rule B"; priority = 10; })
    (fragments.mkFragment { text = "Rule A"; priority = 5; })  # duplicate, dropped
  ];
  description = "combined rules";
  paths = ["src/**"];
}
# Result: mkFragment { text = "Rule A\nRule B"; description = "combined rules"; paths = ["src/**"]; }
```

## Content Packages

Content packages are regular Nix derivations (store paths with files)
that also carry typed fragment data in `passthru`. This gives you both:

- **Build-time files** -- copy into store paths, reference in configs
- **Eval-time data** -- compose fragments without building anything

### coding-standards

```nix
pkgs.coding-standards.passthru.fragments
# => {
#   coding-standards = { text = "..."; description = "..."; priority = 10; };
#   commit-convention = { ... };
#   config-parity = { ... };
#   tooling-preference = { ... };
#   validation = { ... };
# }

# Named presets compose subsets:
pkgs.coding-standards.passthru.presets.all     # all 5 fragments
pkgs.coding-standards.passthru.presets.minimal  # coding-standards + commit-convention
```

### stacked-workflows-content

```nix
pkgs.stacked-workflows-content.passthru.fragments.routing-table
# => { text = "..."; description = "Stacked workflow skill routing table"; }

pkgs.stacked-workflows-content.passthru.skillsDir
# => source path to skills/ directory
```

## Ecosystem Content

`mkEcosystemContent` applies per-ecosystem YAML frontmatter to a
composed fragment. Each ecosystem has different frontmatter conventions:

```nix
fragments.mkEcosystemContent {
  ecosystem = "claude";
  package = "my-project";
  composed = myComposedFragment;
  paths = ["src/**"];
}
```

| Ecosystem  | Frontmatter fields                                     |
| ---------- | ------------------------------------------------------ |
| `claude`   | `description`, `paths` (list)                          |
| `copilot`  | `applyTo` (glob string)                                |
| `kiro`     | `name`, `description`, `inclusion`, `fileMatchPattern` |
| `agentsmd` | None (no frontmatter)                                  |

When `paths` is null: Claude emits no frontmatter, Copilot uses
`applyTo: "**"`, and Kiro uses `inclusion: always`.

## Shorthand Generators

The `ai-common` library provides per-ecosystem shorthand that wraps
`mkEcosystemContent` logic for the module system:

| Function               | Ecosystem | Output                                                              |
| ---------------------- | --------- | ------------------------------------------------------------------- |
| `mkClaudeRule`         | Claude    | Frontmatter with `description` + `paths`, then body                 |
| `mkCopilotInstruction` | Copilot   | Frontmatter with `applyTo`, then body                               |
| `mkKiroSteering`       | Kiro      | Frontmatter with `name`, `inclusion`, `fileMatchPattern`, then body |

These are used internally by the `ai.*` module during fanout. You
typically don't call them directly unless building custom tooling.

## Using Fragments in Practice

### In home-manager (via ai.\*)

```nix
ai.instructions.coding-standards = {
  text = pkgs.coding-standards.passthru.presets.all.text;
  description = "Project coding standards";
};
```

The `ai.*` module applies the correct frontmatter for each enabled CLI
automatically.

### In devenv

```nix
ai.instructions.coding-standards = {
  text = pkgs.coding-standards.passthru.presets.all.text;
  paths = ["src/**"];
  description = "Project coding standards";
};
```

### With lib directly

```nix
let
  composed = fragments.compose {
    fragments = builtins.attrValues pkgs.coding-standards.passthru.fragments;
  };
  content = fragments.mkEcosystemContent {
    ecosystem = "claude";
    package = "my-project";
    composed = composed;
    paths = ["src/**"];
  };
in
  builtins.toFile "rules.md" content
```

### In mdBook (DRY documentation)

Fragment source files live in content packages at known paths. You can
include them in mdBook pages to keep documentation and runtime
instructions in sync:

```text
\{{#include ../../packages/coding-standards/fragments/commit-convention.md}}
```
