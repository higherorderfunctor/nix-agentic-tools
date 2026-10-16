// The boundary shared by preparation, printed commands and direct exec callers.
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const [pnpm, shell, runtime, ...args] = process.argv.slice(2);
// pnpm reads configuration from --dir for most commands but from the working
// directory for some (--version ignores --dir). pnpm runs in the one directory
// checked below, so the caller's own project configuration is never read.
let directory = process.cwd();
let run = false;
// Match pnpm's argument boundaries for the framework's install, run, exec and
// --version calls. Options after a run script, exec or -- belong to the child.
for (let index = 0; index < args.length; index++) {
  const arg = args[index];
  if (["--", "create", "exec", "test"].includes(arg)) break;
  if (arg === "--dir" || arg === "-C") {
    if (!args[index + 1]) throw new Error(`${arg} requires a directory`);
    directory = path.resolve(args[++index]);
  } else if (arg.startsWith("--dir=")) {
    directory = path.resolve(arg.slice("--dir=".length));
  } else if (arg === "run") {
    run = true;
  } else if (run && !arg.startsWith("-")) {
    break;
  }
}
for (const name of [".npmrc", ".pnpmfile.cjs", "pnpm-workspace.yaml"]) {
  if (fs.existsSync(path.join(directory, name))) {
    console.error(
      `Kimchi-owned workflow package forbids project configuration file ${name}: ${directory}`,
    );
    process.exit(1);
  }
}

// pnpm accepts mixed case, including names Bash cannot represent as variables.
// Preserve arbitrary caller variables (workflow tests may read them).
const env = Object.fromEntries(
  Object.entries(process.env).filter(
    ([key]) => !/^(?:npm_config_|pnpm_config_|pnpm_)/i.test(key),
  ),
);
Object.assign(env, {
  PNPM_HOME: path.join(runtime, "data"),
  XDG_CACHE_HOME: path.join(runtime, "cache"),
  XDG_CONFIG_HOME: path.join(runtime, "config"),
  XDG_DATA_HOME: path.join(runtime, "data"),
  XDG_STATE_HOME: path.join(runtime, "state"),
  npm_config_cache_dir: path.join(runtime, "cache"),
  npm_config_enable_pre_post_scripts: "false",
  npm_config_globalconfig: "/dev/null",
  npm_config_ignore_scripts: "true",
  npm_config_manage_package_manager_versions: "false",
  npm_config_offline: "true",
  npm_config_script_shell: shell,
  npm_config_store_dir: path.join(runtime, "store"),
  npm_config_update_notifier: "false",
  // Defense in depth against any remaining configuration source selecting Node.
  npm_config_use_node_version: process.versions.node,
  npm_config_userconfig: "/dev/null",
});
const result = spawnSync(pnpm, ["--ignore-workspace", ...args], {
  cwd: directory,
  env,
  stdio: "inherit",
});
if (result.error) throw result.error;
if (result.signal) process.kill(process.pid, result.signal);
else process.exit(result.status ?? 1);
