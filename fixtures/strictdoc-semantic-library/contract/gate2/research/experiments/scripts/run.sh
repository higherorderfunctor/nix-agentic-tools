#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

experiment_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python_bin="$experiment_root/venv/bin/python"
mode=${1:---all}
case "$mode" in
--all | --backends) ;;
*)
  printf 'usage: %s [--all|--backends]\n' "$0" >&2
  exit 2
  ;;
esac
mkdir -p "$experiment_root/logs" "$experiment_root/results"
if [[ $mode == --all ]]; then
  "$python_bin" "$experiment_root/scripts/native_probe.py" >"$experiment_root/logs/native-run.log" 2>&1
  /nix/store/cck3q51nd32dpbmpkwv5xpkxxhpnr2ak-strictdoc-env/bin/python3.14 "$experiment_root/scripts/native_scope_probe.py" >"$experiment_root/logs/native-scope.log" 2>&1
fi
"$experiment_root/opa" check --strict "$experiment_root/scripts/policy.rego"
"$python_bin" "$experiment_root/scripts/finalists.py" >"$experiment_root/logs/finalists-run.log" 2>&1
"$python_bin" "$experiment_root/scripts/providers.py" >"$experiment_root/logs/providers-run.log" 2>&1
"$python_bin" "$experiment_root/scripts/cozo_lock_probe.py" >"$experiment_root/logs/cozo-lock.log" 2>&1
"$experiment_root/opa" build --target=wasm --entrypoint=gate2/result --output="$experiment_root/opa-bun/bundle.tar.gz" "$experiment_root/scripts/policy.rego"
tar -xzf "$experiment_root/opa-bun/bundle.tar.gz" -C "$experiment_root/opa-bun" /policy.wasm
bun "$experiment_root/scripts/opa-bun.cjs" >"$experiment_root/results/opa-bun.json" 2>"$experiment_root/logs/opa-bun.log"
"$python_bin" "$experiment_root/scripts/cost_probe.py" >"$experiment_root/logs/cost-run.log" 2>&1
if [[ $mode == --all ]]; then
  bash "$experiment_root/scripts/interop.sh" >"$experiment_root/results/interop.txt" 2>&1
fi
printf 'Gate 2 evidence v2 runner completed: %s\n' "$mode"
