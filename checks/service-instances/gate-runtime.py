# Live CI check through the real rendered launchers, never run on a live host.
from concurrent.futures import ThreadPoolExecutor
import http.client
import json
from pathlib import Path
import subprocess
import sys

runtime = Path(sys.argv[1])
# Simultaneous first starts must read the same complete secret. A different
# named client must receive an independent secret, with private file modes.
read_key = lambda name: subprocess.check_output([sys.executable, sys.argv[2], "/build/key-race", name])
with ThreadPoolExecutor(max_workers=8) as pool:
    raced = list(pool.map(read_key, ["one"] * 8))
assert len(set(raced)) == 1 and len(raced[0]) == 64
assert read_key("two") != raced[0]
root = Path("/build/key-race/gate-keys")
assert root.stat().st_mode & 0o777 == 0o700
assert all((root / name).stat().st_mode & 0o777 == 0o600 for name in ["one", "two"])
policy = json.loads((runtime / "ai-service-cpa-gate-main/policy.json").read_text())
config = json.loads((runtime / "ai-service-cliproxyapi-main/config.json").read_text())
entries = {entry["name"]: entry for entry in policy["entries"]}
assert {entry["internal"] for entry in entries.values()} == set(config["access"]["api-keys"])
assert len({entry["internal"] for entry in entries.values()}) == 2
assert all(entry["key"] not in config["access"]["api-keys"] for entry in entries.values())


def request(port, key, method, path, body=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    connection.request(method, path, body=json.dumps(body) if body is not None else None,
                       headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    return connection, connection.getresponse()


def result(port, key, method, path, body=None):
    connection, response = request(port, key, method, path, body)
    value = response.status, response.read()
    connection.close()
    return value


for name, api, upstream, allowed in [
    ("a", "messages", "zai", {"glm-shared", "zai-model"}),
    ("b", "responses", "other", {"glm-shared", "other-model"}),
]:
    entry = entries[name]
    key = entry["key"]
    assert set(entry["models"]) == allowed
    status, raw = result(28426, key, "GET", "/v1/models")
    assert status == 200 and {model["id"] for model in json.loads(raw)["data"]} == allowed
    # External keys work only at the gate; its internal principal still works
    # at CPA as the positive control for the internal listener's authentication.
    assert result(28429, key, "GET", "/v1/models")[0] == 401
    assert result(28429, entry["internal"], "GET", "/v1/models")[0] == 200
    path = "/v1/" + api
    for model in allowed:
        body = {"model": model, "max_tokens": 16, "messages": [{"role": "user", "content": "hi"}]} if api == "messages" else {"model": model, "input": "hi"}
        assert result(28426, key, "POST", path, body)[0] == 200
        connection, response = request(28426, key, "POST", path, body | {"stream": True})
        assert response.status == 200
        while True:
            line = response.readline()
            assert line
            if line.startswith(b"data:"):
                break
        assert not Path(upstream + ".log.done").exists(), "SSE was buffered until the final event"
        assert response.read()
        connection.close()

    # A negative batch follows working calls: every refusal is exactly the
    # same status/body and reaches neither upstream. Nested model positions
    # include hosted tools and a case-distinct spelling of an allowed model.
    logs = [Path("zai.log"), Path("other.log")]
    for log in logs:
        log.write_text("")
    refused = [result(28426, key, "GET", route) for route in ["/healthz", "/v0/management/config", "/v1/models/"]]
    for bad in [
        {"model": "outside"},
        {"model": "GLM-shared"},
        {"model": "glm-shared", "fallbacks": [{"model": "outside"}]},
        {"model": "glm-shared", "tools": [{"type": "web_search"}]},
        {"model": "glm-shared", "tools": [{"type": "function", "function": {"name": "x", "model": "outside"}}]},
    ]:
        refused.append(result(28426, key, "POST", path, bad))
    assert set(refused) == {(404, b"")}
    assert all(log.read_bytes() == b"" for log in logs)

# Both template secrets stay in runtime files; logs must hold neither keys nor
# model IDs. A synthetic log is the positive control for the leak detector.
secrets = [entry[field].encode() for entry in entries.values() for field in ["key", "internal"]]
models = [model.encode() for entry in entries.values() for model in entry["models"]]
leaks = lambda raw: any(value in raw for value in secrets + models)
assert leaks(secrets[0])
assert not leaks(Path("gate.log").read_bytes())
assert not leaks(Path("cpa.log").read_bytes())
for log in [Path("zai.log"), Path("other.log")]:
    log.write_text("")
print("ok: per-key listings, HTTP, incremental SSE, split keys and uniform refusals")
