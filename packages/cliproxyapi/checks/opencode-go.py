"""Limits come from the pricing tabs only, keyed by catalog ID; drift fails."""

import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("extractor", sys.argv[1])
extractor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extractor)


def model(model_id, name):
    return {"id": model_id, "object": "model", "created": 1, "name": name, "api": {"messages": {}}}


def catalog_with(*extra):
    return json.dumps({"object": "list", "data": [model("alpha-1", "Alpha-1 (New)"), model("beta-2", "Beta 2"), *extra]})


catalog = catalog_with()


def tab(slot, alpha, beta):
    return f"""  <div slot="{slot}">

    | Model | Input | Output | Monthly limit |
    | --- | --- | --- | --- |
    | Alpha 1 (≤ 200K tokens) | $1.00 | $2.00 | **{alpha}** |
    | Alpha 1 (> 200K tokens) | $2.00 | $4.00 | **{alpha}** |
    | Beta 2 | Free | Free | **{beta}**<br /><small>limited time</small> |
    | Gamma 3 | $9.00 | $9.00 | **$1** |

  </div>
"""


def page(go="$15", plus="$60", teams="$20", requests="go-requests", endpoints=None):
    endpoints = endpoints or [("Alpha 1", "alpha-1"), ("Beta 2", "beta-2"), ("Gamma 3", "mimo-v2.5"), ("Delta 4", "mimo-v2.5-pro")]
    rows = "".join(f"| {name} | {model_id} | `https://example.com` |\n" for name, model_id in endpoints)
    return f"""# Go

<PlanTabs id="go-pricing" label="Go plan" syncKey="go-plan">
{tab("go", go, "Unlimited")}{tab("go-plus", plus, "Unlimited")}{tab("go-teams", teams, "Unlimited")}</PlanTabs>

<PlanTabs id="{requests}" label="Go plan" syncKey="go-plan">
  <div slot="go">

    | Model | Monthly limit |
    | --- | --- |
    | Alpha 1 | **$999** |

  </div>
  <div slot="go-plus">
  </div>
  <div slot="go-teams">
  </div>
</PlanTabs>

```markdown
| Model | Model ID | Endpoint |
| --- | --- | --- |
| Alpha 1 | wrong | example |
```

<div class="docs-table-scroll" tabIndex={{0}}>

| Model | Model ID | Endpoint |
| --- | --- | --- |
{rows}
</div>
"""


result = extractor.extract(catalog, page())
assert result["models"] == {
    "alpha-1": {"id": "alpha-1", "object": "model", "name": "Alpha-1 (New)", "api": {"messages": {}}},
    "beta-2": {"id": "beta-2", "object": "model", "name": "Beta 2", "api": {"messages": {}}},
}, result
assert result["monthlyLimits"] == {
    "go": {"alpha-1": 15, "beta-2": "unlimited"},
    "go-plus": {"alpha-1": 60, "beta-2": "unlimited"},
    "go-teams": {"alpha-1": 20, "beta-2": "unlimited"},
}, result
assert extractor.extract(catalog, page(plus="$60.50"))["monthlyLimits"]["go-plus"]["alpha-1"] == 60.5
misses = []
for name, bad_catalog, bad_page in [
    ("catalog model absent from a plan", catalog_with(model("zeta-9", "Zeta")), page()),
    ("duplicate catalog id", catalog_with(model("alpha-1", "Again")), page()),
    ("catalog not a list", json.dumps({"data": []}), page()),
    ("limit row without a model ID", catalog, page().replace("| Beta 2 | Free", "| Beta Two | Free")),
    ("qualifier inside the name", catalog, page().replace("| Alpha 1 (> 200K tokens)", "| Alpha (new) 1")),
    ("conflicting tiered limits", catalog, page().replace("| Alpha 1 (> 200K tokens) | $2.00 | $4.00 | **$15**", "| Alpha 1 (> 200K tokens) | $2.00 | $4.00 | **$16**")),
    ("limit not in bold", catalog, page(go="$15").replace("**$15**", "$15")),
    ("limit not a dollar amount", catalog, page(go="15 credits")),
    ("text beside the bold limit", catalog, page().replace("**$15**", "**$15** or $16")),
    ("unlimited without its note", catalog, page().replace("**Unlimited**<br /><small>limited time</small>", "**Unlimited**", 1)),
    ("amount with the unlimited note", catalog, page().replace("**Unlimited**<br />", "**$5**<br />", 1)),
    ("unclassified tab group", catalog, page(requests="go-something")),
    ("missing plan tab", catalog, page().replace(tab("go-teams", "$20", "Unlimited"), "")),
    ("unknown plan tab", catalog, page().replace('<div slot="go-teams">', '<div slot="go-team">', 1)),
    ("flush-left table in a plan slot", catalog, page().replace('  <div slot="go">\n', '  <div slot="go">\n\n| Model | Monthly limit |\n| --- | --- |\n| Alpha 1 | **$999** |\n', 1)),
    ("missing limit column", catalog, page().replace("| Model | Input | Output | Monthly limit |", "| Model | Input | Output | Limit |")),
    ("documented model the catalog lacks", catalog, page(endpoints=[("Alpha 1", "alpha-1"), ("Beta 2", "beta-2"), ("Gamma 3", "gamma-3"), ("Delta 4", "mimo-v2.5-pro"), ("Epsilon", "mimo-v2.5")])),
    ("stale documented-only exclusion", catalog, page(endpoints=[("Alpha 1", "alpha-1"), ("Beta 2", "beta-2"), ("Gamma 3", "mimo-v2.5")])),
    ("documented-only model now in the catalog", catalog_with(model("mimo-v2.5", "Gamma 3")), page()),
    ("duplicate endpoint name", catalog, page(endpoints=[("Alpha 1", "alpha-1"), ("Alpha 1", "beta-2"), ("Gamma 3", "mimo-v2.5"), ("Delta 4", "mimo-v2.5-pro")])),
    ("endpoint table missing", catalog, page().replace("| Model | Model ID | Endpoint |\n| --- | --- | --- |\n|", "|")),
]:
    try:
        extractor.extract(bad_catalog, bad_page)
    except ValueError:
        print(f"ok: refused {name}")
    else:
        misses.append(name)
assert misses == [], f"changed OpenCode Go source shape was accepted: {misses}"
print("ok: OpenCode Go catalog copy, plan limits and shape refusals")
