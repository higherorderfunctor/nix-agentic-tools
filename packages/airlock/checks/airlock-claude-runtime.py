"""Exercise both actual generated backend launchers against a mock child."""
# cspell:words urandom

import contextlib
import http.client
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


def healthy():
    connection = http.client.HTTPConnection("127.0.0.1", 18448, timeout=0.2)
    try:
        connection.request("GET", "/health")
        response = connection.getresponse()
        return response.status == 200 and response.read() == b"ok\n"
    except OSError:
        return False
    finally:
        connection.close()


@contextlib.contextmanager
def service(case, environment, output):
    child = subprocess.Popen([case["serviceLauncher"]], env=environment, stdout=output, stderr=output)
    try:
        deadline = time.monotonic() + 10
        while not healthy():
            assert child.poll() is None, "service exited before readiness"
            assert time.monotonic() < deadline, "service did not become ready"
            time.sleep(0.02)
        yield
    except BaseException:
        output.flush()
        output.seek(0)
        captured = output.read()
        token = Path(environment["R10_TOKEN_SOURCE"]).read_text().rstrip("\n")
        sys.stderr.write(f"Airlock service fixture: {case['backend']} interception={case['intercepted']}\n")
        assert not token or token not in captured, "captured service output contains the test token"
        sys.stderr.write(captured)
        raise
    finally:
        child.terminate()
        child.wait(timeout=10)


def check(case):
    runtime = Path("/tmp") / ("ai-service-airlock-" + case["name"])
    state = Path("/tmp") / (case["name"] + "-state")
    assert not runtime.exists() and not state.exists(), "fixture paths must be unused"
    with tempfile.TemporaryDirectory(prefix="airlock-claude-") as directory:
        root = Path(directory)
        token = root / "source-token"
        marker = root / "child-started"
        inherited = root / "inherited.pem"
        inherited.write_bytes(b"independent inherited certificate fixture")
        config_root = root / "native-config"
        config_root.mkdir()
        credentials = config_root / ".credentials.json"
        credentials.write_bytes(b"native oauth fixture")
        settings = root / "native-settings.json"
        settings.write_text(json.dumps(case["settings"], sort_keys=True))
        original_settings = settings.read_bytes()
        environment = os.environ | case["settings"]["env"] | {
            "CLAUDE_CONFIG_DIR": str(config_root),
            "INVOCATION_ID": "r10-test",
            "R10_INTERCEPTED": "1" if case["intercepted"] else "0",
            "R10_MARKER": str(marker),
            "R10_NATIVE_DIRECTORY": case["nativeDirectory"],
            "R10_RUNTIME": str(runtime),
            "R10_TOKEN_SOURCE": str(token),
            "TMPDIR": "/tmp",
            "XDG_RUNTIME_DIR": "/tmp",
        }
        # Supply hostile ambient proxy/bypass values to prove managed delivery.
        for variable in ("ALL_PROXY", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "all_proxy", "http_proxy", "https_proxy", "no_proxy"):
            environment[variable] = "http://ambient.invalid"

        def launch(success, extra=None):
            marker.unlink(missing_ok=True)
            child_environment = environment | {"XDG_RUNTIME_DIR": str(root / "wrong-runtime")}
            child_environment.pop("NODE_EXTRA_CA_CERTS", None)
            child_environment.pop("R10_INHERITED_CA", None)
            if extra is not None:
                child_environment.update(NODE_EXTRA_CA_CERTS=str(extra), R10_INHERITED_CA=str(extra))
            read_descriptor, write_descriptor = os.pipe()
            try:
                os.write(write_descriptor, b"native descriptor")
                os.close(write_descriptor)
                child_environment["CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR"] = str(read_descriptor)
                result = subprocess.run(
                    [case["clientLauncher"], "literal argument", "quotes'\"$;", "--native-flag"],
                    env=child_environment,
                    input=b"preserved standard input\n",
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    pass_fds=(read_descriptor,),
                    timeout=10,
                )
            finally:
                os.close(read_descriptor)
            assert result.returncode == (23 if success else 1), result.stderr.decode()
            assert marker.exists() == success, "child exec readiness mismatch"
            assert token.read_bytes().rstrip(b"\n") not in result.stdout + result.stderr
            if not success:
                assert b"start the selected airlock service" in result.stderr
            return json.loads(marker.read_text())["extra"] if success else None

        try:
            # Runtime-only secrets cannot accidentally occur in any store input.
            secret_prefix = "runtime-" + os.urandom(12).hex()
            for attempt in range(2):
                token.write_text(secret_prefix + str(attempt) + ":@%#/?'\"$;\\!\n")
                with (root / "service-output").open("w+") as output:
                    with service(case, environment, output):
                        launch(True)
                        bundle = launch(True, inherited)
                        assert launch(True, inherited) == bundle
                        if case["intercepted"]:
                            assert len(list(runtime.glob("claude-extra-ca-*.pem"))) == attempt + 1
                        config_path = runtime / "config.json"
                        config = json.loads(config_path.read_text())
                        token_path = Path(config["clients"]["fixture"]["token_file"])
                        for path in [config_path, token_path] + ([runtime / "ca" / "ca.pem"] if case["intercepted"] else []):
                            saved = path.with_name(path.name + ".saved")
                            path.rename(saved)
                            try:
                                launch(False)
                                path.symlink_to(saved)
                                launch(False)
                                path.unlink()
                            finally:
                                saved.rename(path)
                        original_token = token_path.read_bytes()
                        token_path.write_bytes(b"")
                        try:
                            launch(False)
                        finally:
                            token_path.write_bytes(original_token)
                        saved_runtime = runtime.with_name(runtime.name + ".saved")
                        runtime.rename(saved_runtime)
                        try:
                            runtime.symlink_to(saved_runtime, target_is_directory=True)
                            launch(False)
                        finally:
                            runtime.unlink(missing_ok=True)
                            saved_runtime.rename(runtime)
                        if case["intercepted"]:
                            launch(False, root / "missing-inherited.pem")
                        else:
                            launch(True, root / "unused-inherited.pem")
                    # Stale config/token/CA must not launch against a stopped service.
                    launch(False)
                    assert secret_prefix not in (root / "service-output").read_text()
                if attempt == 0 and case["intercepted"]:
                    first_ca = (runtime / "ca" / "ca.pem").read_bytes()
                    shutil.rmtree(runtime / "ca")
            if case["intercepted"]:
                assert (runtime / "ca" / "ca.pem").read_bytes() != first_ca
            assert settings.read_bytes() == original_settings
            assert credentials.read_bytes() == b"native oauth fixture"
            assert not list(runtime.glob(".claude-ca-*")), "temporary bundles leaked"
            print(f"ok: {case['backend']} interception={case['intercepted']}")
        finally:
            shutil.rmtree(runtime, ignore_errors=True)
            shutil.rmtree(state, ignore_errors=True)


if __name__ == "__main__":
    for case in json.loads(Path(sys.argv[1]).read_text()):
        check(case)
