# Shared model catalog and runtime reach

`ai.catalog` describes model identities, budgets and runtime reach. Both Home
Manager and devenv import its option module through
`ai-module/modules/common.nix`. The checked `ai.catalog.resolved` graph supplies
CPA client credential grants and delegate-routing's model and pool projection.
External delegates use the destination runtime's reach; pools are never combined
with the caller's.

## Identity and offers

`models.<id>` contains `maker`, exact `aliases.<provider>` spellings and a
`source` reference. Native Claude/Codex identities and CPA's Go/z.ai facts are
loaded once by `lib/catalog/models.nix`; the resolver and both consumers use
that owner. Go maker facts map extracted IDs to makers; provider namespaces such
as `moonshotai` remain aliases for the `moonshot` maker. `owned_by` identifies
the serving vendor. Missing maker evidence remains null. A finite model with an
unknown maker cannot be combined with an OAuth catalog because absence of
overlap cannot be established. Declare its identity with evidence or omit that
finite offer.

`iceman-contributor-free` has the distinct maker identity `iceman`. Its upstream
maker is undisclosed; this identity does not attribute it to another vendor. The
fact is preserved from
`dcaf19f9:packages/delegate-routing/lib/opencode-go.nix:132`. The aggregate
exercises the full extracted Go offer set after the operator's Anthropic, OpenAI
and Zhipu exclusions, including iceman, through all three native CPA API
families.

`providers.<provider>.maker` identifies the maker belonging to an open provider
catalog. Defaults map CPA's `claude` catalog to `anthropic` and `codex` to
`openai`. Provider names and makers remain separate identities. Two provider
names declaring the same maker describe the same open set for overlap checking.

Each `pools.<pool>` describes one budget:

- `credentials.<name> = { auth; binding; }` identifies an existing local
  `instance/credential` binding; it holds no secret value. Several credentials
  can spend the same budget.
- `models` lists finite API-key offers, canonicalized before comparison.
- `providerCatalogs` lists open OAuth offers, including models registered after
  evaluation. It is not a finite snapshot or an OAuth model allowlist.

Existing CPA credentials supply their actual offers automatically. A named
credential defaults to its `instance/credential` budget identity; declaring its
binding under a catalog pool gives that budget a shared name. Explicit model
fields add offers; they cannot hide what a bound CPA credential really serves.
Narrow an API-key offer through its existing `apiKey.models` or per-API model
declaration; for a vendor whose per-API defaults list models, such as OpenCode
Go, only the per-API form narrows it. OAuth cannot be narrowed this way.

CPA's predicate `clientKeyAllowlist.allows(clientKey, auth)` checks provider,
credential kind, account, ID and base URL, but takes no requested model
(`packages/cliproxyapi/patches/key-allowlist.patch:1025–1040`). Its model
listing then checks the live registry (`1071–1097`). The hot-registration test
(`1468–1500`) retains the original credential grant when a matching login
appears. These are why the graph represents OAuth as an open catalog.
`oauth.excluded-models` is provider-global, so it cannot express different model
grants for two budgets on the same provider.

## Reach and refusal

`runtimes.<runtime>.pools` replaces reach inferred from existing client routes
and family budget bindings. CPA clients selected through `settings.inference`
use that runtime's graph; an unselected named client is checked independently as
`cliproxyapi:<instance>/<client>`. Two runtimes sharing one client key must have
identical reach, because CPA sees the same principal. Existing route order and
API choices are preserved for retained credentials. The graph uses CPA's
existing route resolver to compute each runtime's effective finite offers: a
selected chat API does not expose models served only by that credential's
Anthropic API. Pool records retain the full offer inventory; `modelsFor` and
`poolFor` apply this runtime restriction.

Evaluation refuses:

- Two finite pools offering the same canonical model, including exact aliases
  and the same upstream provider.
- A finite model whose maker belongs to a reachable OAuth provider catalog on
  another pool.
- Two pools offering the same open OAuth provider catalog.

Multiple credentials on one budget pass. Different runtimes may reach the same
model from different budgets. Unknown model/pool/provider references and
ambiguous aliases fail before consumption.

Diagnostics sort runtime, model and pool IDs. They retain the shared error
template and append a reason:

```text
ai.catalog: runtime "codex" offers model "gpt-6.1-sol" from multiple pools: codex, opencode-go. Select one pool for this model in this runtime. Reason: finite offer intersects an open OAuth catalog.
```

Two open catalogs use `provider-catalog:<provider>` in the model position. This
is a diagnostic marker for the whole open set, not an invented model ID. The
reason states that the same open provider catalog is reachable through multiple
budgets. Future models do not escape the check: catalog membership is
maker-based, and the open/open check does not need a currently observed model.

## Consumers and manual use

CPA keeps its protocol validation, secret delivery and OAuth account matching.
Its API-key model aliases render canonical request IDs. Routing retains family
fit, tier and effort guidance, but uses reachable catalog models for concrete
launch pins and the shared graph for pool identity. Standalone unbound family
guidance remains available; a direct routing builder with named budget bindings
must receive an evaluated graph.

```nix
let
  catalog = nat.lib.aiModule.catalog { inherit lib; };
  graph = catalog.resolve {
    models = catalog.defaults.models;
    pools = {
      codex.providerCatalogs = [ "codex" ];
      go.models = [ "deepseek-v4-pro" ];
    };
    runtimes.codex.pools = [ "codex" "go" ];
  };
in content.mkSkill { catalog = graph; runtime = "codex"; }
```

`resolved.modelFor <id-or-alias>` returns the checked model identity for a
concrete selection. Routing validates the maker of each concrete launch against
that catalog identity. A selected custom model must declare
`ai.catalog.models.<id>.maker`, including on finite-only pools; a missing maker
fails rather than inheriting the billing provider's name. Unselected offers with
unknown makers remain available for inspection, subject to the OAuth overlap
refusal above. Unbound pattern guidance has no concrete model or maker claim.

Native family selectors remain associations used by routing, not ranks.
Claude/Codex groupings and the GLM/GLM Flash identities use pinned extracted
IDs; no live catalog discovery or guessed concrete IDs are added. Existing fit,
tier and effort guidance stays with delegate-routing.

No reset, credit, cost or usage policy is declared by this catalog.

CPA's Go preset exposes every extracted offer, including Claude, GLM and GPT.
Consumers narrow those offers with their existing per-API model declarations;
the package imposes no maker exclusions. Shared runtime overlap evaluation then
checks the selected offers alongside OAuth catalogs. Go's research-preset
ownership check remains a guidance check, independent of pool overlap.

`ai-catalog-provider-offers` checks the full provider inventory and maker
aliases, native API placement, operator exclusions and canonical CPA/routing
parity on both backends. Unknown canonical aliases fail at the shared resolver.

`ai-catalog-runtime-reach` evaluates the graph, CPA grants and routing
manifest/prose together on both backends. Its literal diagnostic and grant
expectations reject credential-kind exemptions, instance-wide overlap,
alias-only string comparisons, and consumers that ignore the graph.

`ai-catalog-native-models` checks literal native, Go and GLM identities, alias
resolution and selected custom-maker refusal. It rejects maker/provider
conflation, invented concrete IDs and fit metadata in identity records.
