# The run-time half of a CLIProxyAPI config rendered from `settingsType`:
# applied by the ai.proxy start script to `render`'s store value, and by the
# `cliproxyapi-config-validates` check before CLIProxyAPI's own LoadConfig,
# so the check loads exactly what a service would.
#
# Inputs: `$secrets`, `render`'s `file` or `helper` secrets as
# `[{path, var}]`, each value in the environment variable `var`;
# `$authDir`, the resolved auth directory; and the client key in the
# environment variable CPA_CLIENT_KEY, appended after any keys `settings`
# lists. Secrets travel through the environment, never argv, which any
# local process can read.
reduce $secrets[] as $secret (.; setpath($secret.path; env[$secret.var]))
| .access["api-keys"] = ((.access["api-keys"] // []) + [env.CPA_CLIENT_KEY])
| .oauth["auth-dir"] = $authDir
