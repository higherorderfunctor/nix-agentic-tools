# Static model catalog

`ai.catalog` contains canonical model identities and vendor offers. It contains
no credentials, secrets, pools, client routes, runtime selections, transport
URLs or overlap policy. Billing and usage Readers are absent. Declaring an offer
does not enable an instance or route a request.

- `models.<id>.maker` is a nonempty maker name, or `null` when unknown.
- `models.<id>.source` is a nonempty list of evidence strings.
- `vendors.<name>.models` declares a finite list of canonical model ids.
- `vendors.<name>.maker` declares every model of one maker, including later
  additions. Exactly one of `models` and `maker` must be non-null. An empty
  finite list is a valid static offer.

Core imports only its types and generic module libraries. Owners import their
own extracted facts and contribute ordinary module definitions. CPA contributes
OpenCode Go and Z.ai through `packages/cliproxyapi/modules/catalog.nix`; its
per-vendor files own maker identities and evidence. OpenCode Go's canonical
namespaces are used as maker ids unchanged. The undisclosed iceman identity
stays separate; no other maker is inferred. claude-code contributes its
extracted Anthropic models and the `claude` vendor (every `anthropic` model)
through `packages/claude-code/modules/catalog.nix`; chatgpt-codex contributes
its extracted OpenAI model slugs and the `codex` vendor (every `openai` model)
through `packages/chatgpt-codex/modules/catalog.nix`. Both are imported whether
or not their runtime is enabled. Core supplies no vendor or model itself.

Owner contributions use `mkDefault` on each field. Equal-priority evidence lists
concatenate; compare them as sets. Identical maker defaults agree, and
conflicting maker defaults fail evaluation. An ordinary user field replaces its
default without suppressing other owners or unrelated fields:

```nix
{
  ai.catalog = {
    models.example = {
      source = ["configured private model"];
    };
    vendors.example-vendor.models = ["example"];
  };
}
```

This finite-only identity has an unknown maker. Extracted owner inventories must
supply maker evidence; the owner's property check fails when it is missing. To
add an owner, load its facts in its package, contribute model fields and a
finite or maker-wide vendor declaration, and add checks against independent
extracted inputs. Adding a vendor requires no core edit. When owners share a
canonical id, contribute evidence to that id rather than replacing the entire
model map.

CPA credential defaults are the production reader. Facts flow through owner
definitions into the merged catalog, then into vendor construction in
`instances.nix`. The same constructor serves standalone library callers using
the vendor's own facts. A normal definition of
`ai.catalog.vendors.zhipuai.models` or `.opencode-go.models` replaces that
vendor's default list and changes rendered credential models. CPA keeps exact
served spellings in `ai.cliproxyapi.servedModels.<vendor>.<canonical-id>`,
outside the catalog. The vendor owner supplies a list of spellings per identity;
consumers extend or override that option using ordinary module definitions. For
example:

```nix
ai.cliproxyapi.servedModels.opencode-go.example = ["upstream-example"];
```

When a catalog offer selects `example`, its mapping must identify measured
transport metadata in that vendor's extracted input. Otherwise construction
fails with the vendor, canonical model and unknown served ids. URLs, native
APIs, tool names and transport metadata stay in the owner. Explicit credential
API/model definitions remain available for independently configured transports.

The catalog describes all extracted Go offers. Consumer `excludeMakers` settings
narrow individual credential offers after canonicalization through CPA's
mapping. CPA checks compare the contributed inventory and rendered models on
Home Manager and devenv. Core checks use synthetic identities for merging,
overrides, conflicts and field refusals.
