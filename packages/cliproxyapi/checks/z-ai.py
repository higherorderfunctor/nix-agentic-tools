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

### Image Generation Models

| Model | Resource |
| --- | --- |
| GLM-Image | [API Reference](/api-reference/image/generate-image.md) |
"""
devpack_quick_start = """
**5. Endpoint Guide**

| Protocol | Base URL |
| - | - |
| Anthropic Messages | `https://api.z.ai/api/anthropic` |
| OpenAI Chat Completions | `https://api.z.ai/api/coding/paas/v4` |
| OpenAI Responses | `https://api.z.ai/api/v1` |
"""
quick_start = """
```python
client = OpenAI(base_url="https://api.z.ai/api/paas/v4/")
```
"""
result = extractor.extract(claude, devpack_quick_start, overview, quick_start)
assert result["models"] == ["glm-42", "glm-43"], result
assert result["claudeModels"] == dict.fromkeys(["haiku", "opus", "sonnet"], "glm-42"), result
assert result["apis"]["chat"]["base-url"] == "https://api.z.ai/api/coding/paas/v4", result
assert result["generalApis"]["chat"]["base-url"] == "https://api.z.ai/api/paas/v4", result
repeated_endpoint = '\n```json\n{"env":{"ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic"}}\n```\n'
assert extractor.extract(claude + repeated_endpoint, devpack_quick_start, overview, quick_start) == result
manual_endpoint = repeated_endpoint.replace("```json", "```bash\n# Manual configuration")
assert extractor.extract(claude + manual_endpoint, devpack_quick_start, overview, quick_start) == result
assert extractor.extract(claude, devpack_quick_start, overview.replace(
    "](/api-reference/", "](https://docs.z.ai/api-reference/"
), quick_start) == result
# Trailing slashes are normalized on every extracted URL, so slashed pages
# yield the same facts.
assert extractor.extract(
    claude.replace("https://api.z.ai/api/anthropic", "https://api.z.ai/api/anthropic/"),
    devpack_quick_start.replace("https://api.z.ai/api/anthropic", "https://api.z.ai/api/anthropic/").replace(
        "https://api.z.ai/api/coding/paas/v4", "https://api.z.ai/api/coding/paas/v4/"
    ),
    overview,
    quick_start,
) == result
misses = []
for name, expected, bad_claude, bad_devpack, bad_overview in [
    ("missing tier", "all three Claude Code default tiers", claude.replace("ANTHROPIC_DEFAULT_HAIKU_MODEL", "REMOVED"), devpack_quick_start, overview),
    ("tier outside catalog", "absent from its chat catalog", claude, devpack_quick_start, overview.replace("GLM-42", "GLM-44")),
    ("foreign reference host", "unclassified z.ai chat model reference", claude, devpack_quick_start, overview.replace(
        "](/api-reference/", "](https://docs.z.ai.example.com/api-reference/"
    )),
    ("all references changed", "unclassified z.ai chat model reference", claude, devpack_quick_start, overview.replace("chat-completion", "removed")),
    ("partial row reference drift", "unclassified z.ai chat model reference", claude, devpack_quick_start, overview.replace("| GLM-43 | [API Reference](/api-reference/llm/chat-completion.md)", "| GLM-43 | [API Reference](/api-reference/llm/new-chat-completion.md)")),
    ("missing chat endpoint row", "lost its OpenAI Chat Completions row", claude, devpack_quick_start.replace(
        "| OpenAI Chat Completions | `https://api.z.ai/api/coding/paas/v4` |\n", ""
    ), overview),
    ("duplicate chat endpoint row", "duplicate z.ai devpack endpoint protocol", claude, devpack_quick_start.replace(
        "OpenAI Responses", "OpenAI Chat Completions"
    ), overview),
    ("devpack Anthropic endpoint conflict", "conflicts with the Claude Code page", claude, devpack_quick_start.replace(
        "/api/anthropic", "/api/changed"
    ), overview),
    ("foreign chat endpoint host", "left the api.z.ai host", claude, devpack_quick_start.replace(
        "https://api.z.ai/api/coding/paas/v4", "https://api.example.com/api/coding/paas/v4"
    ), overview),
    ("missing endpoint table", "Protocol/Base URL table missing or duplicated", claude, devpack_quick_start.replace(
        "| Protocol | Base URL |", "| Scheme | Base URL |"
    ), overview),
    ("duplicated endpoint table", "Protocol/Base URL table missing or duplicated", claude, devpack_quick_start + """

| Protocol | Base URL |
| - | - |
| Anthropic Messages | `https://api.z.ai/api/anthropic` |
""", overview),
    ("chat endpoint not a code span", "endpoint is not a code span", claude, devpack_quick_start.replace(
        "| OpenAI Chat Completions | `https://api.z.ai/api/coding/paas/v4` |", "| OpenAI Chat Completions | https://api.z.ai/api/coding/paas/v4 |"
    ), overview),
    ("chat endpoint duplicates Anthropic", "duplicates the Anthropic endpoint", claude, devpack_quick_start.replace(
        "https://api.z.ai/api/coding/paas/v4", "https://api.z.ai/api/anthropic"
    ), overview),
    ("chat endpoint duplicates general", "duplicates the general endpoint", claude, devpack_quick_start.replace(
        "https://api.z.ai/api/coding/paas/v4", "https://api.z.ai/api/paas/v4"
    ), overview),
    ("conflicting Anthropic URLs", "Anthropic base URLs missing or ambiguous", claude + repeated_endpoint.replace("/api/anthropic", "/api/changed"), devpack_quick_start, overview),
    ("conflicting shell-labeled JSON endpoint", "Anthropic base URLs missing or ambiguous", claude + manual_endpoint.replace("/api/anthropic", "/api/changed"), devpack_quick_start, overview),
]:
    try:
        extractor.extract(bad_claude, bad_devpack, bad_overview, quick_start)
    except ValueError as error:
        assert expected in str(error), (name, expected, str(error))
        print(f"ok: refused {name}: {error}")
    else:
        misses.append(name)
assert misses == [], f"changed z.ai documentation shape was accepted: {misses}"
print("ok: z.ai prose defaults, catalog scope and shape refusals")
