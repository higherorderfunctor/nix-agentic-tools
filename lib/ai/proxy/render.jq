# The run-time half of lib/ai/proxy/default.nix (`renderProgram`): look one
# instance up in the ai.proxy registry, validate its entry against the same
# `patterns` table evaluation uses, and fill the placeholders of the template
# for its key form. Every failure names the registry and the instance.
#
# Inputs: $instance, $registryPath, $lines, $patterns, $placeholders, and the
# slurped $registry and $templates (one JSON document each).
def fail($message): "ai-proxy-render: \($message)\n" | halt_error(1);
def anchored($pattern): "\\A(?:\($pattern))\\z";
def where: "instance \"\($instance)\" in \($registryPath)";
def forms: $patterns | del(.url) | keys;

($registry[0]) as $entries
| if ($entries | type) != "object" then
    fail("\($registryPath) must be a JSON object mapping instance names to {\"url\", \"key\"} entries.")
  else . end
| ($entries[$instance]
    // fail("\($registryPath) has no instance \"\($instance)\"; it lists: \($entries | keys | join(", ")).")) as $entry
| ($entry.url
    | if type == "string" and test(anchored($patterns.url)) then .
      else fail("\(where): url must be the proxy origin only, http://<host>:<port>, with no path.") end) as $url
| ($entry.key
    | if type == "object" and length == 1 and (keys[0] | IN(forms[])) then .
      else fail("\(where): key must be an object with exactly one field, one of: \(forms | join(", ")).") end) as $key
| ($key | keys[0]) as $form
| ($key[$form]
    | if type == "string" and test(anchored($patterns[$form])) then .
      else fail("\(where): key.\($form) must match \($patterns[$form]), so it can be substituted unescaped.") end) as $value
| ($templates[0][$form] // fail("the template file has no rendering for a \($form) key."))
| walk(
    if type == "string" then
      split($placeholders.url) | map(split($placeholders.key) | join($value)) | join($url)
    else . end)
| if $lines then
    if type == "array" and all(.[]; type == "string" and (contains("\n") | not)) then .[]
    else fail("--lines needs a template that renders to an array of single-line strings.") end
  else tojson end
