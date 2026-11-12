# Kiro authenticated model catalog

> **Last verified:** 2026-11-12 — authenticated CLI JSON supplies suggestions;
> offline checks validate the committed facts and refresh boundary.

`cli.native.settings.chat.defaultModel` reads the committed `models` fact
through `lib.extracted` as a soft enum. Any string remains accepted across the
library, Home Manager and devenv. Suggestions reflect the updater account's
catalog, not every user's entitlements.

The independent `kiro-model-catalog` update target runs its existing
`updateScript` with the pinned `kiro-cli.unwrapped` payload and
`chat --list-models --format json`. It requires `KIRO_API_KEY` from the
environment before starting the process. The update workflow supplies that
secret only to this target's preparation step; PR checks and package builds
remain offline.

`extract/catalog.py` runs the CLI with stdin closed, a 60-second timeout, a
fresh working directory and fresh HOME and XDG config, cache, data and state
directories. Only transport settings, PATH and the API key enter its
environment; telemetry and auto-updates are disabled. Temporary account state is
removed on success and failure. Failures never print the CLI's captured output
or credentials.

The response must be a JSON object with a nonempty `models` list. Each row needs
a unique, nonempty `model_id` without whitespace, and at least one ID must be
concrete rather than `auto`. Provider names and numeric versions are data, and
Auto need not be present. Other response fields are ignored.

The updater adds exactly one manual fallback, `claude-fable-5.1`, because
enterprise governance can hide it from the updater account. It replaces the
previous suggestions with sorted live IDs plus that fallback: absent historical
IDs disappear. Only IDs persist; context windows, rates, descriptions and
response timestamps do not. Validation completes before atomic replacement, and
equivalent IDs preserve the destination bytes and modification time.

A missing key, failed CLI, timeout or invalid response preserves committed
suggestions and fails the update target on its first sweep, after existing PR
preservation and receipt publication. Other targets keep their existing
hold-back policy. The package has a stable version because source changes,
rather than a daily version, drive the custom update script's commit.

The offline package exposes committed suggestions through the shared facts
loader. It has no fetched source, extraction passthru or drift regeneration:
there is no offline upstream catalog to compare. `kiro-models-fixtures`
exercises the production updater with fake CLI responses and validates committed
suggestions through `lib.extracted`; `extracted-index` retains shared fact
validation and Kiro's module checks retain soft-enum parity.
