#!/usr/bin/env python3
"""Contract tests for the StrictDoc snapshot and read-only HTTP boundary."""

from __future__ import annotations

import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from server import SnapshotStore, build_server
from snapshot import SCHEMA, compile_snapshot, load_project


class BoardContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.project_root = Path(__file__).resolve().parents[3]
        cls.cache = tempfile.TemporaryDirectory(prefix="sdoc-board-test-")
        cls.loaded = load_project(cls.project_root, Path(cls.cache.name))
        cls.server = build_server(SnapshotStore(cls.loaded), "127.0.0.1", 0)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        host, port = cls.server.server_address[:2]
        cls.base_url = f"http://{host}:{port}"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)
        cls.cache.cleanup()

    def test_snapshot_preserves_loaded_nodes_and_relation_endpoints(self) -> None:
        snapshot = self.loaded.snapshot
        self.assertEqual(snapshot["schema"], SCHEMA)
        self.assertEqual(snapshot["stats"]["nodes"], len(snapshot["nodes"]))
        self.assertEqual(snapshot["stats"]["edges"], len(snapshot["edges"]))
        self.assertGreater(snapshot["stats"]["nodes"], 300)
        self.assertGreater(snapshot["stats"]["edges"], 500)

        node_ids = [node["id"] for node in snapshot["nodes"]]
        self.assertEqual(len(node_ids), len(set(node_ids)))
        node_id_set = set(node_ids)
        self.assertTrue(
            all(
                edge["source"] in node_id_set and edge["target"] in node_id_set
                for edge in snapshot["edges"]
            )
        )
        self.assertIn("WORK-SDOC-BOARD-MVP", node_id_set)

    def test_snapshot_hash_is_stable_for_the_same_loaded_index(self) -> None:
        second = compile_snapshot(
            self.project_root, self.loaded.traceability_index
        )
        self.assertEqual(
            self.loaded.snapshot["project"]["snapshotHash"],
            second["project"]["snapshotHash"],
        )

    def test_get_and_head_serve_the_snapshot(self) -> None:
        with urllib.request.urlopen(f"{self.base_url}/api/graph") as response:
            payload = json.load(response)
            self.assertEqual(response.status, 200)
            self.assertEqual(payload["schema"], SCHEMA)

        request = urllib.request.Request(
            f"{self.base_url}/api/graph", method="HEAD"
        )
        with urllib.request.urlopen(request) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.read(), b"")
            self.assertGreater(int(response.headers["Content-Length"]), 0)

    def test_static_routes_are_allowlisted(self) -> None:
        with urllib.request.urlopen(f"{self.base_url}/") as response:
            self.assertIn(b"SDOC BOARD", response.read())
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(f"{self.base_url}/snapshot.py")
        self.assertEqual(error.exception.code, 404)
        error.exception.close()

    def test_mutating_methods_are_rejected(self) -> None:
        request = urllib.request.Request(
            f"{self.base_url}/api/graph", data=b"{}", method="POST"
        )
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(request)
        self.assertEqual(error.exception.code, 405)
        self.assertEqual(error.exception.headers["Allow"], "GET, HEAD")
        error.exception.close()


if __name__ == "__main__":
    unittest.main()
