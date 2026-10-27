"""Exercise both actual generated backend launchers against a mock child."""
# cspell:words urandom

from dataclasses import dataclass
from functools import cached_property
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from airlock_service import running, wait_ready

PROXY_VARIABLES = ("ALL_PROXY", "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "all_proxy", "http_proxy", "https_proxy", "no_proxy")
NATIVE_CREDENTIALS = b"native oauth fixture"


@dataclass
class Fixture:
    case: dict
    root: Path
    runtime: Path

    @property
    def marker(self):
        return self.root / "child-started"

    @property
    def token(self):
        return self.root / "source-token"

    @cached_property
    def environment(self):
        environment = os.environ | self.case["settings"]["env"] | {
            "CLAUDE_CONFIG_DIR": str(self.root / "native-config"),
            "AIRLOCK_TEST_INTERCEPTED": "1" if self.case["intercepted"] else "0",
            "AIRLOCK_TEST_MARKER": str(self.marker),
            "AIRLOCK_TEST_NATIVE_DIRECTORY": self.case["nativeDirectory"],
            "AIRLOCK_TEST_PORT": str(self.case["port"]),
            "AIRLOCK_TEST_RUNTIME": str(self.runtime),
            "AIRLOCK_TEST_TOKEN": str(self.token),
            "INVOCATION_ID": "airlock-claude-test",
            "TMPDIR": "/tmp",
            "XDG_RUNTIME_DIR": "/tmp",
        }
        # Supply hostile ambient proxy/bypass values to prove managed delivery.
        for variable in PROXY_VARIABLES:
            environment[variable] = "http://ambient.invalid"
        return environment


def write_native_files(case, root):
    """Native Claude inputs a launch must leave untouched."""
    (root / "inherited.pem").write_bytes(b"independent inherited certificate fixture")
    (root / "native-config").mkdir()
    (root / "native-config" / ".credentials.json").write_bytes(NATIVE_CREDENTIALS)
    (root / "native-settings.json").write_text(json.dumps(case["settings"], sort_keys=True))


def native_files_untouched(case, root):
    settings = (root / "native-settings.json").read_text()
    assert settings == json.dumps(case["settings"], sort_keys=True)
    assert (root / "native-config" / ".credentials.json").read_bytes() == NATIVE_CREDENTIALS


def launch(fixture, success, extra=None):
    """Run the Claude launcher; return the mock child's extra-CA path on success."""
    fixture.marker.unlink(missing_ok=True)
    environment = fixture.environment | {"XDG_RUNTIME_DIR": str(fixture.root / "wrong-runtime")}
    environment.pop("NODE_EXTRA_CA_CERTS", None)
    environment.pop("AIRLOCK_TEST_INHERITED_CA", None)
    if extra is not None:
        environment.update(NODE_EXTRA_CA_CERTS=str(extra), AIRLOCK_TEST_INHERITED_CA=str(extra))
    read_descriptor, write_descriptor = os.pipe()
    try:
        os.write(write_descriptor, b"native descriptor")
        os.close(write_descriptor)
        environment["CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR"] = str(read_descriptor)
        result = subprocess.run(
            [fixture.case["clientLauncher"], "literal argument", "quotes'\"$;", "--native-flag"],
            env=environment,
            input=b"preserved standard input\n",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            pass_fds=(read_descriptor,),
            timeout=10,
        )
    finally:
        os.close(read_descriptor)
    assert result.returncode == (23 if success else 1), result.stderr.decode()
    assert fixture.marker.exists() == success, "child exec readiness mismatch"
    assert fixture.token.read_bytes().rstrip(b"\n") not in result.stdout + result.stderr
    if not success:
        assert b"start the selected airlock service" in result.stderr
    return json.loads(fixture.marker.read_text())["extra"] if success else None


def launches_succeed(fixture, attempt):
    launch(fixture, True)
    inherited = fixture.root / "inherited.pem"
    bundle = launch(fixture, True, inherited)
    assert launch(fixture, True, inherited) == bundle
    if fixture.case["intercepted"]:
        # Each service run's CA yields one more cached bundle.
        assert len(list(fixture.runtime.glob("claude-extra-ca-*.pem"))) == attempt + 1


def tampered_artifacts_refuse_launch(fixture):
    """A missing, symlinked or emptied runtime file refuses the launch."""
    config_path = fixture.runtime / "config.json"
    config = json.loads(config_path.read_text())
    token_path = Path(config["clients"]["fixture"]["token_file"])
    paths = [config_path, token_path]
    if fixture.case["intercepted"]:
        paths.append(fixture.runtime / "ca" / "ca.pem")
    for path in paths:
        saved = path.with_name(path.name + ".saved")
        path.rename(saved)
        try:
            launch(fixture, False)
            path.symlink_to(saved)
            launch(fixture, False)
            path.unlink()
        finally:
            saved.rename(path)
    original_token = token_path.read_bytes()
    token_path.write_bytes(b"")
    try:
        launch(fixture, False)
    finally:
        token_path.write_bytes(original_token)


def symlinked_runtime_refuses_launch(fixture):
    runtime = fixture.runtime
    saved = runtime.with_name(runtime.name + ".saved")
    runtime.rename(saved)
    try:
        runtime.symlink_to(saved, target_is_directory=True)
        launch(fixture, False)
    finally:
        runtime.unlink(missing_ok=True)
        saved.rename(runtime)


def missing_inherited_trust(fixture):
    """Only interception reads an inherited extra CA, so only it refuses a missing one."""
    if fixture.case["intercepted"]:
        launch(fixture, False, fixture.root / "missing-inherited.pem")
    else:
        launch(fixture, True, fixture.root / "unused-inherited.pem")


def service_run(fixture, attempt, secret_prefix):
    """Start the service with a fresh token, run every launch case against it,
    then launch once more after it stops."""
    case = fixture.case
    fixture.token.write_text(secret_prefix + str(attempt) + ":@%#/?'\"$;\\!\n")
    output_path = fixture.root / "service-output"
    with output_path.open("w+") as output:
        with running(case["serviceLauncher"], fixture.environment, output, secret_prefix) as child:
            wait_ready(child, case["port"])
            launches_succeed(fixture, attempt)
            tampered_artifacts_refuse_launch(fixture)
            symlinked_runtime_refuses_launch(fixture)
            missing_inherited_trust(fixture)
        # Stale config/token/CA must not launch against a stopped service.
        launch(fixture, False)
        assert secret_prefix not in output_path.read_text()


def check(case):
    runtime = Path("/tmp") / ("ai-service-airlock-" + case["name"])
    state = Path("/tmp") / (case["name"] + "-state")
    assert not runtime.exists() and not state.exists(), "fixture paths must be unused"
    with tempfile.TemporaryDirectory(prefix="airlock-claude-") as directory:
        root = Path(directory)
        write_native_files(case, root)
        fixture = Fixture(case, root, runtime)
        try:
            # Runtime-only secrets cannot accidentally occur in any store input.
            secret_prefix = "runtime-" + os.urandom(12).hex()
            service_run(fixture, 0, secret_prefix)
            if case["intercepted"]:
                # Removing the CA makes the next service run create a new one.
                first_ca = (runtime / "ca" / "ca.pem").read_bytes()
                shutil.rmtree(runtime / "ca")
            service_run(fixture, 1, secret_prefix)
            if case["intercepted"]:
                assert (runtime / "ca" / "ca.pem").read_bytes() != first_ca
            native_files_untouched(case, root)
            assert not list(runtime.glob(".claude-ca-*")), "temporary bundles leaked"
            print(f"ok: {case['backend']} interception={case['intercepted']}")
        finally:
            shutil.rmtree(runtime, ignore_errors=True)
            shutil.rmtree(state, ignore_errors=True)


if __name__ == "__main__":
    for case in json.loads(Path(sys.argv[1]).read_text()):
        check(case)
