"""Prose defaults must beat later examples; catalog rows must beat mentions."""

import importlib.util
import sys

spec = importlib.util.spec_from_file_location("extractor", sys.argv[1])
extractor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extractor)

claude = """
Mapping, with the default configuration as follows:

* `ANTHROPIC_DEFAULT_OPUS_MODEL: GLM-42`
* `ANTHROPIC_DEFAULT_SONNET_MODEL: GLM-42`
* `ANTHROPIC_DEFAULT_HAIKU_MODEL: GLM-42`

Example below deliberately has a different model.

```json
{"env":{"ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic","ANTHROPIC_DEFAULT_OPUS_MODEL":"glm-example"}}
```
"""
overview = """
GLM-99 is mentioned outside the catalog.

## Featured Models

| Model | Resource |
| --- | --- |
| GLM-42 | [API Reference](/api-reference/llm/chat-completion.md) |
| GLM-43 | [API Reference](/api-reference/llm/chat-completion.md) |

> [accordion] Other Models, Agents and Tools
>
> ### Language Models
>
> | Model | Strength | Language | Context | Resource |
> | :- | :- | :- | :- | :- |
> | GLM-5.2 | Open-source SOTA coding, from generation to delivery | English & Chinese | 1M | [Guide](https://docs.z.ai/guides/llm/glm-5.2.md) [API Reference](https://docs.z.ai/api-reference/llm/chat-completion.md) |

### Image Generation Models

| Model | Resource |
| --- | --- |
| GLM-Image | [API Reference](/api-reference/image/generate-image.md) |
"""
quick_start = """
```python
client = OpenAI(base_url="https://api.z.ai/api/paas/v4/")
```
"""
expected = {
    "apis": {
        "anthropic": {"base-url": "https://api.z.ai/api/anthropic"},
        "chat": {"base-url": "https://api.z.ai/api/paas/v4"},
    },
    "claudeDefaults": {"ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-example"},
    "claudeModels": dict.fromkeys(["haiku", "opus", "sonnet"], "glm-42"),
    "codingPlanOnly": [],
    "models": ["glm-42", "glm-43", "glm-5.2"],
}
result = extractor.extract(claude, overview, quick_start)
assert result == expected, result
repeated_endpoint = '\n```json\n{"env":{"ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic"}}\n```\n'
manual_endpoint = repeated_endpoint.replace("```json", "```bash\n# Manual configuration")
assert extractor.extract(claude + manual_endpoint, overview, quick_start) == expected
language_row = next(line for line in overview.splitlines() if line.startswith("> | GLM-5.2 |"))
notice = "> GLM-5.4 is now available to all GLM Coding Plan users. The Model API will be made available after completing the security assessment."
plan_row = "| GLM-5.4 | [Guide](https://docs.z.ai/guides/llm/glm-5.4.md) |"
conflicting_plan_row = plan_row.removesuffix(" |") + " [API Reference](/api-reference/llm/chat-completion.md) |"
with_plan_row = overview.replace("| GLM-42 |", f"{plan_row}\n| GLM-42 |")
plan_overview = f"{notice}\n\n{with_plan_row}"
expected_plan = {**expected, "codingPlanOnly": ["glm-5.4"]}
wrapped_plan_overview = plan_overview.replace("users. The", "users.\n> The")
assert extractor.extract(claude, wrapped_plan_overview, quick_start) == expected_plan
assert extractor.extract(claude.replace("GLM-42", "GLM-5.4"), plan_overview, quick_start)["claudeModels"]["opus"] == "glm-5.4"
ambiguous_endpoint = "documented Anthropic base URLs missing or ambiguous"
duplicate_models = "z.ai chat model table missing, duplicated or malformed"
unclassified_plan = "unclassified z.ai chat model reference: GLM-5.4"
unpaired_plan = "pending Model API notice needs exactly one matching Coding Plan row"
for name, diagnostic, bad_claude, bad_overview in [
    # Chat catalog classification.
    ("foreign reference host", "unclassified z.ai chat model reference: GLM-42", claude, overview.replace(
        "](/api-reference/", "](https://docs.z.ai.example.com/api-reference/"
    )),
    ("model repeated across chat sections", duplicate_models, claude, overview.replace("> | GLM-5.2 |", "> | GLM-43 |")),
    ("model repeated within one section", duplicate_models, claude, overview.replace(language_row, f"{language_row}\n{language_row}")),
    ("partial row reference drift", "unclassified z.ai chat model reference: GLM-43", claude, overview.replace("| GLM-43 | [API Reference](/api-reference/llm/chat-completion.md)", "| GLM-43 | [API Reference](/api-reference/llm/new-chat-completion.md)")),
    ("unclassified table section", "unclassified z.ai catalog table section: Video Models", claude, overview.replace("### Language Models", "### Video Models")),
    # Coding Plan membership.
    ("duplicate Coding Plan row", unpaired_plan, claude, plan_overview.replace(plan_row, f"{plan_row}\n{plan_row}")),
    ("foreign Coding Plan guide", unclassified_plan, claude, plan_overview.replace("/guides/llm/glm-5.4.md", ".example.com/guides/llm/glm-5.4.md")),
    ("guide without pending Model API notice", unclassified_plan, claude, with_plan_row),
    ("notice without matching row", unpaired_plan, claude, f"{notice}\n\n{overview}"),
    ("pending model with Model API reference", unclassified_plan, claude, wrapped_plan_overview.replace(plan_row, conflicting_plan_row)),
    # Endpoint and tier declarations.
    ("conflicting shell-labeled JSON endpoint", ambiguous_endpoint, claude + manual_endpoint.replace("/api/anthropic", "/api/changed"), overview),
    ("missing tier", "must publish all three Claude Code default tiers", claude.replace("ANTHROPIC_DEFAULT_HAIKU_MODEL", "REMOVED"), overview),
    ("tier outside catalog", "default tier names a model absent from its chat catalog", claude.replace("OPUS_MODEL: GLM-42", "OPUS_MODEL: GLM-99"), overview),
]:
    try:
        extractor.extract(bad_claude, bad_overview, quick_start)
    except ValueError as error:
        assert diagnostic in str(error), f"{name}: {error}"
    else:
        raise AssertionError(f"changed z.ai documentation shape was accepted: {name}")
print("ok: z.ai prose defaults, catalog scope and shape refusals")
