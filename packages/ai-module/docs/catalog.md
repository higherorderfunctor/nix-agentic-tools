# Static model catalog

`ai.catalog` contains canonical model identities and provider offers. It
contains no credentials, secrets, pools, client routes, runtime selections,
transport URLs or overlap policy. Billing and usage Readers are absent.
Declaring an offer does not enable an instance or route a request.

- `models.<id>.maker` is a nonempty maker name, or `null` when unknown.
- `models.<id>.aliases.<provider>` lists exact alternative provider spellings.
- `models.<id>.source` is a nonempty list of evidence strings.
- `providers.<name>.models` declares a finite list of canonical model ids.
- `providers.<name>.maker` declares every model of one maker, including later
  additions. Exactly one of `models` and `maker` must be non-null. An empty
  finite list is a valid static offer.

Core imports only its types and generic module libraries. Owners import their
own extracted facts and contribute ordinary module definitions. CPA contributes
OpenCode Go and z.ai through `packages/cliproxyapi/modules/catalog.nix`; its
per-vendor files own namespace normalization, aliases and evidence. OpenCode
Go's `zhipuai` namespace becomes `zhipu`. The undisclosed iceman identity stays
separate; no other maker is inferred. claude-code contributes its extracted
Anthropic models and the `claude` provider (every `anthropic` model) through
`packages/claude-code/modules/catalog.nix`; chatgpt-codex contributes its
extracted OpenAI model slugs and the `codex` provider (every `openai` model)
through `packages/chatgpt-codex/modules/catalog.nix`. Both are imported whether
or not their runtime is enabled. Core supplies no provider or model itself.

Owner contributions use `mkDefault` on each field. Equal-priority evidence and
alias lists concatenate; compare them as sets. Identical maker defaults agree,
and conflicting maker defaults fail evaluation. An ordinary user field replaces
its default without suppressing other owners or unrelated fields:

```nix
{
  ai.catalog = {
    models.example = {
      aliases.example-provider = ["upstream-example"];
      source = ["configured private model"];
    };
    providers.example-provider.models = ["example"];
  };
}
```

This finite-only identity has an unknown maker. Extracted owner inventories must
supply maker evidence; the owner's property check fails when it is missing. To
add an owner, load its facts in its package, contribute model fields and a
finite or maker-wide provider declaration, and add checks against independent
extracted inputs. Adding a provider requires no core edit. When owners share a
canonical id, contribute evidence and aliases to that id rather than replacing
the entire model map.

CPA credential defaults are the production reader. Facts flow through owner
definitions into the merged catalog, then into vendor construction in
`instances.nix`. The same constructor serves standalone library callers using
the vendor's own facts. A normal definition of
`ai.catalog.providers.z-ai.models` or `.opencode-go.models` replaces that
provider's default list and changes rendered credential models. Go looks up
transport metadata using the selected identity and its provider aliases; an
identity without known Go transport metadata is refused. z.ai keeps its common
transport endpoints locally.

The catalog describes all extracted Go offers. Existing Go credential prefix
exclusions still narrow rendered defaults and refuse explicitly configured
excluded credentials; catalog membership does not bypass them. CPA's checks
compare the full contributed inventory and the eligible rendered subset on Home
Manager and devenv. Core checks use synthetic identities for merging, overrides,
conflicts and field refusals. No personal configuration is involved.
