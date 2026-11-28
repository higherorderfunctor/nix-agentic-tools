# cspell:ignore aisdk Multimodal opencodeai toggleable
"""Limits come from each catalog entry's go.monthly_usage; drift fails.

The two entries are verbatim from https://opencode.ai/inference/go/v1/models
(fetched 2026-11-17): one metered model and one free model. The pinned
snapshot's normalize step drops `created` before the extractor runs; these
keep it, so the extractor's own drop is exercised too.
"""

import copy
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("extractor", sys.argv[1])
extractor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extractor)

PRICED = json.loads(r'''{"id": "kimi-k3", "object": "model", "created": 1794944169, "owned_by": "opencode", "name": "Kimi K3", "canonical_id": "moonshotai/kimi-k3", "type": "chat", "description": "Multimodal Kimi model with 1M context and toggleable max-effort thinking for long-horizon agent work", "family": "kimi-k3", "open_weights": true, "release_date": "2026-07-16", "last_updated": "2026-07-16", "modalities": {"input": ["text", "image/jpeg", "image/png", "image/gif", "image/webp", "image/bmp", "image/heic", "image/heif", "video/mp4", "video/mpeg", "video/mov", "video/avi", "video/x-flv", "video/mpg", "video/webm", "video/wmv", "video/3gpp"], "output": ["text"]}, "capabilities": {"tools": {"supported": true}, "reasoning": {"supported": true, "effort": ["max"]}, "structured_output": true, "temperature": false, "top_p": false, "top_k": false, "system_updates": true, "effort_updates": false}, "limit": {"context": 1048576, "output": 1048576}, "cost": {"text": {"input": {"price": 3, "cache": {"read": 0.3, "write": 3}}, "output": {"price": 15}}}, "api": {"chat-completions": {"base_url": "https://opencode.ai/inference/go/openai/v1", "sdk": {"aisdk": "@ai-sdk/openai-compatible", "opencodeai": "@opencode/ai/providers/openai-compatible"}, "compatibility": {"reasoning_field": "reasoning_content"}, "capabilities": {"tools": {"strict": true, "choice": ["auto", "none", "required"], "updates": ["add"]}}}}, "go": {"monthly_usage": {"go": 15, "go-plus": 60, "go-teams": 20}, "training": false, "zdr": true, "limited_regions": false, "featured": true}}''')
FREE = json.loads(r'''{"id": "beam-free", "object": "model", "created": 1794944169, "owned_by": "opencode", "name": "Beam Free", "canonical_id": "reflection/beam-1.0-501b-a23b", "type": "chat", "description": "Sparse mixture-of-experts reasoning model with 23B active parameters for coding and agentic workflows", "family": "beam", "open_weights": true, "knowledge": "2026-06-30", "release_date": "2026-10-05", "last_updated": "2026-10-16", "modalities": {"input": ["text"], "output": ["text"]}, "capabilities": {"tools": {"supported": true}, "reasoning": {"supported": true, "effort": ["low", "medium", "high", "xhigh", "max"]}, "structured_output": true, "temperature": true, "top_p": true, "top_k": true, "system_updates": false, "effort_updates": false}, "limit": {"context": 1048576, "output": 131072}, "cost": {"text": {"input": {"price": 0, "cache": {"read": 0}}, "output": {"price": 0}}}, "api": {"chat-completions": {"base_url": "https://opencode.ai/inference/go/openai/v1", "sdk": {"aisdk": "@ai-sdk/openai-compatible", "opencodeai": "@opencode/ai/providers/openai-compatible"}, "compatibility": {"reasoning_field": "reasoning_content"}, "capabilities": {"tools": {"strict": true, "choice": ["auto", "none", "required", "tool"], "updates": []}}}}, "go": {"monthly_usage": null, "training": false, "zdr": false, "limited_regions": true, "featured": true}}''')


def catalog(*entries):
    return json.dumps({"object": "list", "data": list(entries)})


def changed(entry, edit):
    entry = copy.deepcopy(entry)
    edit(entry)
    return entry


result = extractor.extract(catalog(PRICED, FREE))
# Copy both models and omit only the two volatile or separately extracted fields.
assert sorted(result["models"]) == ["beam-free", "kimi-k3"], result
assert sorted(result["models"]["kimi-k3"]) == [
    "api", "canonical_id", "capabilities", "cost", "description", "family", "id", "last_updated",
    "limit", "modalities", "name", "object", "open_weights", "owned_by", "release_date", "type",
], result["models"]["kimi-k3"]
assert result["monthlyLimits"] == {
    "go": {"beam-free": "unlimited", "kimi-k3": 15},
    "go-plus": {"beam-free": "unlimited", "kimi-k3": 60},
    "go-teams": {"beam-free": "unlimited", "kimi-k3": 20},
}, result["monthlyLimits"]
fractional = changed(PRICED, lambda entry: entry["go"]["monthly_usage"].update({"go-plus": 60.5}))
assert extractor.extract(catalog(fractional))["monthlyLimits"]["go-plus"]["kimi-k3"] == 60.5
wrong_plans = "model kimi-k3 monthly usage plans changed"
for name, diagnostic, bad in [
    # Catalog and model envelope.
    ("catalog not a list", "catalog is not a model list", json.dumps({"data": []})),
    ("duplicate catalog id", "catalog id missing or duplicated: kimi-k3", catalog(PRICED, PRICED)),
    ("empty catalog", "catalog is empty", catalog()),
    ("go object without monthly_usage", "model beam-free has no go.monthly_usage", catalog(changed(FREE, lambda entry: entry["go"].pop("monthly_usage")))),
    ("model without a go object", "model kimi-k3 has no go.monthly_usage", catalog(changed(PRICED, lambda entry: entry.pop("go")))),
    # Plan set and amount types.
    ("limit as a dollar string", "model kimi-k3 go monthly usage is not a number: '$15'", catalog(changed(PRICED, lambda entry: entry["go"]["monthly_usage"].update({"go": "$15"})))),
    ("limit as a flag", "model kimi-k3 go monthly usage is not a number: True", catalog(changed(PRICED, lambda entry: entry["go"]["monthly_usage"].update({"go": True})))),
    ("monthly_usage adds a plan", wrong_plans, catalog(changed(PRICED, lambda entry: entry["go"]["monthly_usage"].update({"go-max": 90})))),
    ("monthly_usage lacks a plan", wrong_plans, catalog(changed(PRICED, lambda entry: entry["go"]["monthly_usage"].pop("go-teams")))),
    ("monthly_usage not an object", wrong_plans, catalog(changed(PRICED, lambda entry: entry["go"].update({"monthly_usage": [15, 60, 20]})))),
    ("one plan unlimited", "model kimi-k3 go monthly usage is not a number: None", catalog(changed(PRICED, lambda entry: entry["go"]["monthly_usage"].update({"go": None})))),
]:
    try:
        extractor.extract(bad)
    except ValueError as error:
        assert diagnostic in str(error), f"{name}: {error}"
    else:
        raise AssertionError(f"changed OpenCode Go catalog shape was accepted: {name}")
print("ok: OpenCode Go catalog copy, plan limits and shape refusals")
