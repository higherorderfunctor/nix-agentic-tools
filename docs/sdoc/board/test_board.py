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

from server import build_server
from snapshot import SCHEMA, compile_snapshot, load_project
from workspace import Workspace


class BoardContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.project_root = Path(__file__).resolve().parents[3]
        cls.state = tempfile.TemporaryDirectory(prefix="sdoc-board-test-")
        cls.workspace = Workspace(cls.project_root, Path(cls.state.name))
        cls.loaded = cls.workspace.hydrate().loaded
        cls.server = build_server(cls.workspace, "127.0.0.1", 0)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        host, port = cls.server.server_address[:2]
        cls.base_url = f"http://{host}:{port}"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)
        cls.state.cleanup()

    def test_failed_reload_retains_the_published_generation(self) -> None:
        calls = 0

        def load_then_fail(project_root: Path, output_dir: Path):
            nonlocal calls
            calls += 1
            if calls == 1:
                return self.loaded
            raise RuntimeError("injected hydration failure")

        with tempfile.TemporaryDirectory(prefix="sdoc-board-failure-") as state:
            workspace = Workspace(
                self.project_root, Path(state), loader=load_then_fail
            )
            first = workspace.hydrate()
            with self.assertRaisesRegex(RuntimeError, "injected"):
                workspace.reload()
            self.assertIs(workspace.current(), first)
            self.assertEqual(workspace.describe()["generation"], 1)

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
            self.assertEqual(
                int(response.headers["X-SDoc-Board-Generation"]),
                self.workspace.current().number,
            )

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

    def test_workspace_retains_state_and_uses_one_stable_output_identity(
        self,
    ) -> None:
        first = self.workspace.current()
        self.assertIs(self.workspace.current(), first)
        self.assertEqual(
            Path(first.loaded.project_config.output_dir),
            self.workspace.output_dir,
        )

        replacement = self.workspace.reload()
        self.assertEqual(replacement.number, first.number + 1)
        self.assertIsNot(replacement.loaded, first.loaded)
        self.assertEqual(
            Path(replacement.loaded.project_config.output_dir),
            self.workspace.output_dir,
        )
        self.assertEqual(
            replacement.loaded.project_config.dir_for_sdoc_cache,
            first.loaded.project_config.dir_for_sdoc_cache,
        )


if __name__ == "__main__":
    unittest.main()
