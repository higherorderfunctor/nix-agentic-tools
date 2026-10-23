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

| Model | Resource |
| --- | --- |
| GLM-42 | [API Reference](/api-reference/llm/chat-completion.md) |
| GLM-Image | [API Reference](/api-reference/image/generate-image.md) |
"""
quick_start = """
```python
client = OpenAI(base_url="https://api.z.ai/api/paas/v4/")
```
"""
result = extractor.extract(claude, overview, quick_start)
assert result["models"] == ["glm-42"], result
assert result["claudeModels"] == dict.fromkeys(["haiku", "opus", "sonnet"], "glm-42"), result
for bad_claude, bad_overview in [
    (claude.replace("ANTHROPIC_DEFAULT_HAIKU_MODEL", "REMOVED"), overview),
    (claude, overview.replace("GLM-42", "GLM-43")),
    (claude, overview.replace("chat-completion", "removed")),
]:
    try:
        extractor.extract(bad_claude, bad_overview, quick_start)
    except ValueError:
        pass
    else:
        raise AssertionError("changed z.ai documentation shape was accepted")
print("ok: z.ai prose defaults, catalog scope and shape refusals")
