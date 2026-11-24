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
result = extractor.extract(claude, overview, quick_start)
assert result["models"] == ["glm-42", "glm-43", "glm-5.2"], result
assert result["claudeModels"] == dict.fromkeys(["haiku", "opus", "sonnet"], "glm-42"), result
repeated_endpoint = '\n```json\n{"env":{"ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic"}}\n```\n'
assert extractor.extract(claude + repeated_endpoint, overview, quick_start) == result
manual_endpoint = repeated_endpoint.replace("```json", "```bash\n# Manual configuration")
assert extractor.extract(claude + manual_endpoint, overview, quick_start) == result
assert extractor.extract(claude, overview.replace(
    "](/api-reference/", "](https://docs.z.ai/api-reference/"
), quick_start) == result
language_row = next(line for line in overview.splitlines() if line.startswith("> | GLM-5.2 |"))
notice = "> GLM-5.4 is now available to all GLM Coding Plan users. The Model API will be made available after completing the security assessment."
plan_row = "| GLM-5.4 | [Guide](https://docs.z.ai/guides/llm/glm-5.4.md) |"
conflicting_plan_row = plan_row.removesuffix(" |") + " [API Reference](/api-reference/llm/chat-completion.md) |"
with_plan_row = overview.replace("| GLM-42 |", f"{plan_row}\n| GLM-42 |")
plan_overview = f"{notice}\n\n{with_plan_row}"
plan_result = extractor.extract(claude, plan_overview, quick_start)
assert plan_result == {**result, "codingPlanOnly": ["glm-5.4"]}, plan_result
wrapped_plan_overview = plan_overview.replace("users. The", "users.\n> The")
assert extractor.extract(claude, wrapped_plan_overview, quick_start) == plan_result
assert extractor.extract(claude.replace("GLM-42", "GLM-5.4"), plan_overview, quick_start)["claudeModels"]["opus"] == "glm-5.4"
assert result["codingPlanOnly"] == [], result
misses = []
for name, bad_claude, bad_overview in [
    ("guide without pending Model API notice", claude, with_plan_row),
    ("notice without matching row", claude, f"{notice}\n\n{overview}"),
    ("duplicate Coding Plan row", claude, plan_overview.replace(plan_row, f"{plan_row}\n{plan_row}")),
    ("foreign Coding Plan guide", claude, plan_overview.replace("/guides/llm/glm-5.4.md", ".example.com/guides/llm/glm-5.4.md")),
    ("pending model with Model API reference", claude, wrapped_plan_overview.replace(plan_row, conflicting_plan_row)),
    ("missing tier", claude.replace("ANTHROPIC_DEFAULT_HAIKU_MODEL", "REMOVED"), overview),
    ("tier outside catalog", claude, overview.replace("GLM-42", "GLM-43")),
    ("foreign reference host", claude, overview.replace(
        "](/api-reference/", "](https://docs.z.ai.example.com/api-reference/"
    )),
    ("all references changed", claude, overview.replace("chat-completion", "removed")),
    ("partial row reference drift", claude, overview.replace("| GLM-43 | [API Reference](/api-reference/llm/chat-completion.md)", "| GLM-43 | [API Reference](/api-reference/llm/new-chat-completion.md)")),
    ("model repeated across chat sections", claude, overview.replace("> | GLM-5.2 |", "> | GLM-43 |")),
    ("model repeated within one section", claude, overview.replace(language_row, f"{language_row}\n{language_row}")),
    ("unclassified table section", claude, overview.replace("### Language Models", "### Video Models")),
    ("conflicting Anthropic URLs", claude + repeated_endpoint.replace("/api/anthropic", "/api/changed"), overview),
    ("conflicting shell-labeled JSON endpoint", claude + manual_endpoint.replace("/api/anthropic", "/api/changed"), overview),
]:
    try:
        extractor.extract(bad_claude, bad_overview, quick_start)
    except ValueError:
        print(f"ok: refused {name}")
    else:
        misses.append(name)
assert misses == [], f"changed z.ai documentation shape was accepted: {misses}"
print("ok: z.ai prose defaults, catalog scope and shape refusals")
