import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fillPlaceholders, repoRoot, worktreeBase } from "./repo-root.mjs";

// Applies checkout-dependent prompt edits for one session.
// `lib/kiro-bundle-patch.py` installs this module beside the KAS bundle with
// `prompt-fragments.json` (`{ key: [[original, value, kind], ...] }`) and calls
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
export async function fillPrompt(key, text, cwd, templated = false) {
  const entries = fragments[key] ?? [];
  const root = cwd && entries.length ? await repoRoot(cwd) : undefined;
  if (!root) return text;
  const spans = entries
    .map(([original, value, kind]) => ({
      original,
      value,
      kind,
      at: text.indexOf(original),
    }))
    .filter(({ original, at }) => at >= 0 && at === text.lastIndexOf(original))
    .sort((a, b) => b.at - a.at);
  for (const { original, value, kind, at } of spans) {
    let replacement;
    if (kind === "worktree-base") {
      const oid = await worktreeBase(cwd, value);
      replacement = `When asked to run in a worktree, plan its name and branch and use commit \`${oid}\` as the base.`;
    } else if (kind === "worktree-location") {
      const parent = fillPlaceholders(value, root);
      replacement = resolve(root.primary, parent, "<name>");
    } else {
      replacement = fillPlaceholders(value, root, templated);
    }
    text = text.slice(0, at) + replacement + text.slice(at + original.length);
  }
  return text;
}

// An agent definition whose prompt is filled for the session behind `context`
// (Kiro's `subagentPrompt` argument, which names the session workspace). Kiro
// then renders the prompt as a template only when the agent supports it.
export async function fillAgentDefinition(definition, context) {
  if (!fragments[definition.id]) return definition;
  const cwd = context.defaultPromptWorkspace().listWorkspaceFolders().folders[0]
    ?.uri.fsPath;
  const templated = Boolean(
    definition.supportsTemplating && context.promptContext,
  );
  const prompt = await fillPrompt(
    definition.id,
    definition.prompt,
    cwd,
    templated,
  );
  return { ...definition, prompt };
}
