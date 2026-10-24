"""Adversarial test transport only: never used by the real graph producer."""

import json
import sys
import time

from facts import key, projection, rows

job = json.load(sys.stdin)
mode = job["moduleArguments"]["mode"]
packet = projection(job["identities"], empty=mode == "empty")
if mode == "timeout":
    time.sleep(3)
elif mode == "memory":
    allocation = bytearray(96 * 1024 * 1024)
elif mode == "missing-context":
    witness = rows(packet, "nx_observation_contexts")[0][0]
    packet["facts"] = [item for item in packet["facts"] if not (item[0] in ("nx_observations", "nx_observation_contexts") and item[1][0] == witness)]
elif mode == "foreign-request":
    rows(packet, "nx_observations")[0][1] = key("request", ["foreign"])
elif mode == "missing-module":
    witness = rows(packet, "nx_observation_modules")[0][0]
    packet["facts"] = [item for item in packet["facts"] if not (item[0] in ("nx_observations", "nx_observation_modules") and item[1][0] == witness)]
elif mode == "lying-count":
    rows(packet, "nx_request_results")[0][3] = 1
encoded = json.dumps(packet)
if mode == "bytes":
    # Exactly 128 KiB on stdout, including legal trailing JSON whitespace.
    assert len(encoded.encode()) < 131072
    encoded += " " * (131072 - len(encoded.encode()))
    sys.stdout.write(encoded)
else:
    print(encoded)
