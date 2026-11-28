import { readFileSync } from "node:fs";
import { fillPlaceholders, repoRoot } from "./repo-root.mjs";

// Applies the consumer's `{{primary}}`/`{{repo}}` prompt edits for one session.
// `lib/kiro-bundle-patch.py` installs this module beside the KAS bundle with
// `prompt-fragments.json` (`{ key: [[original, replacement], ...] }`) and calls
// it where Kiro reads the three workflow prompts, before Kiro renders them. The
// fill is per call, from the session's own directory, so no checkout is
// remembered across sessions; edits without placeholders were applied at build.
const fragments = JSON.parse(
  readFileSync(new URL("./prompt-fragments.json", import.meta.url), "utf8"),
);

// The prompt with each fragment's original swapped for its filled replacement.
// A session without a repository root keeps the original text for every
// fragment. Fragments are located first and spliced from the end, so a
// replacement is never searched for the next original.
export async function fillPrompt(key, text, cwd, table = fragments) {
  const entries = table[key] ?? [];
  const root = cwd && entries.length ? await repoRoot(cwd) : undefined;
  if (!root) return text;
  return entries
    .map(([original, replacement]) => ({
      original,
      replacement,
      at: text.indexOf(original),
    }))
    .filter(({ original, at }) => at >= 0 && at === text.lastIndexOf(original))
    .sort((a, b) => b.at - a.at)
    .reduce(
      (filled, { original, replacement, at }) =>
        filled.slice(0, at) +
        fillPlaceholders(replacement, root) +
        filled.slice(at + original.length),
      text,
    );
}

// An agent definition whose prompt is filled for the session behind `context`
// (Kiro's `subagentPrompt` argument, which names the session workspace).
export async function fillAgentDefinition(
  definition,
  context,
  table = fragments,
) {
  if (!table[definition.id]) return definition;
  const cwd = context.defaultPromptWorkspace().listWorkspaceFolders().folders[0]
    ?.uri.fsPath;
  const prompt = await fillPrompt(definition.id, definition.prompt, cwd, table);
  return { ...definition, prompt };
}
