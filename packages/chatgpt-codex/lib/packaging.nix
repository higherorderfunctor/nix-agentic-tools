rec {
  # Extract the deterministic configuration vocabularies Codex exposes through
  # supported CLI commands. Recursive Clap help supplies the command/flag tree,
  # `features list` supplies feature metadata, and `debug models --bundled`
  # supplies the packaged (soft-enum) model catalog. Codex exposes no native
  # config.toml schema; the raw carries only fields consumers read.
  codexExtractScript = pkgs:
    pkgs.writeText "codex-extract.py" ''
      import json
      import os
      import re
      import subprocess
      import sys
      import tempfile


      binary, destination = sys.argv[1:]


      def invoke(arguments, root):
          environment = os.environ.copy()
          environment.update({"CODEX_HOME": root + "/codex-home", "HOME": root + "/home"})
          command = [binary, *arguments]
          try:
              completed = subprocess.run(
                  command,
                  check=True,
                  env=environment,
                  stderr=subprocess.PIPE,
                  stdout=subprocess.PIPE,
                  text=True,
                  timeout=30,
              )
          except subprocess.TimeoutExpired as error:
              raise SystemExit(
                  f"codex-extract: command timed out after 30 seconds: {command!r}"
              ) from error
          except subprocess.CalledProcessError as error:
              raise SystemExit(
                  f"codex-extract: command failed ({error.returncode}): {command!r}\n{error.stderr}"
              ) from error
          return completed.stdout


      def section(text, name):
          match = re.search(rf"(?ms)^{name}:\n(.*?)(?=^[A-Z][A-Za-z ]+:\n|\Z)", text)
          return match.group(1) if match else ""


      def parse_commands(text):
          commands = []
          for line in section(text, "Commands").splitlines():
              match = re.match(r"^  ([a-z][a-z0-9-]*)(?:\s{2,}.*)?$", line)
              if match and match.group(1) != "help":
                  commands.append(match.group(1))
          return commands


      def parse_flags(text):
          flags = []
          lines = section(text, "Options").splitlines()
          for index, line in enumerate(lines):
              match = re.match(
                  r"^  (?:(-[A-Za-z]), |    )(--[A-Za-z][A-Za-z0-9-]*)"
                  r"(?: <([^>]+)>)?(?:\.\.\.)?(?:\s{2,}(.*))?$",
                  line,
              )
              if not match:
                  continue
              names = sorted(set(filter(None, [match.group(1), match.group(2)])))
              body = [match.group(4)] if match.group(4) else []
              for following in lines[index + 1:]:
                  if match.re.match(following):
                      break
                  body.append(following.strip())
              prose = " ".join(part for part in body if part)
              possible = re.search(r"\[possible values: ([^]]+)\]", prose)
              if possible:
                  accepted = [item.strip() for item in possible.group(1).split(",")]
              else:
                  accepted = re.findall(r"(?:^| )- ([a-z0-9-]+):", prose)
              flags.append({
                  "acceptedValues": sorted(set(accepted)),
                  "names": names,
                  "valueName": match.group(3),
              })
          return flags


      with tempfile.TemporaryDirectory(prefix="codex-extract.") as root:
          os.makedirs(root + "/home")
          os.makedirs(root + "/codex-home")
          queue = [[]]
          records = {}
          while queue:
              path = queue.pop(0)
              help_text = invoke([*path, "--help"], root)
              children = parse_commands(help_text)
              key = "codex" if not path else "codex " + " ".join(path)
              records[key] = parse_flags(help_text)
              for child in children:
                  queue.append([*path, child])

          feature_rows = []
          for line in invoke(["features", "list"], root).splitlines():
              match = re.match(r"^(\S+)\s{2,}(.+?)\s{2,}(?:true|false)$", line)
              if not match:
                  raise SystemExit(f"codex-extract: malformed feature row: {line!r}")
              feature_rows.append({
                  "maturity": match.group(2),
                  "name": match.group(1),
              })

          bundled = json.loads(invoke(["debug", "models", "--bundled"], root))
          models = []
          for model in bundled.get("models", []):
              models.append({
                  "reasoningLevels": sorted(
                      level["effort"] for level in model.get("supported_reasoning_levels", [])
                  ),
                  "slug": model["slug"],
              })

      root_flags = records.get("codex", [])
      flag_values = {
          name: flag["acceptedValues"]
          for flag in root_flags
          for name in flag["names"]
      }
      approval_values = {"never", "on-request"}
      required_values = {
          "--ask-for-approval": approval_values,
          "--sandbox": {"danger-full-access", "read-only", "workspace-write"},
      }
      if "codex" not in records or len(records) < 20:
          raise SystemExit("codex-extract: recursive command tree lost its root or fell below 20 commands")
      for flag, expected in required_values.items():
          if set(flag_values.get(flag, [])) != expected:
              raise SystemExit(f"codex-extract: {flag} values changed: {flag_values.get(flag, [])!r}")
      if not feature_rows:
          raise SystemExit("codex-extract: features list returned no rows")
      if not models:
          raise SystemExit("codex-extract: bundled model catalog returned no models")

      result = {
          "cli": {
              "commands": {
                  name: {"flags": [
                      {"names": flag["names"], "valueName": flag["valueName"]}
                      for flag in flags
                  ]}
                  for name, flags in records.items()
              },
              "globalFlags": [
                  {"acceptedValues": flag["acceptedValues"], "names": flag["names"]}
                  for flag in root_flags
              ],
          },
          "features": sorted(feature_rows, key=lambda row: row["name"]),
          "models": sorted(models, key=lambda model: model["slug"]),
      }
      with open(destination, "w", encoding="utf-8") as output:
          json.dump(result, output, indent=2, sort_keys=True)
          output.write("\n")
    '';

  mkCodexExtract = {
    bin,
    pkgs,
    dest ? "/dev/stdout",
  }: ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    "${pkgs.python3}/bin/python3" ${codexExtractScript pkgs} "${bin}" "${dest}"
  '';
}
