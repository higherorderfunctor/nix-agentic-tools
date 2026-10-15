// Loaded by package-bound KAS. All mutable state belongs to a conversation.
import { constants } from "node:fs";
import { open, readFile } from "node:fs/promises";
import { isAbsolute, resolve } from "node:path";
import { settingsLayers } from "./session-settings.mjs";
import { admit } from "./worktree-policy.mjs";

const slots = ["identity", "workflowFileCheckGuidance", "worktreeGuidance"];
const limit = 1024 * 1024;
const key = "nixPromptSnapshot";
const object = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value);

function fail(context, message) {
  throw new Error(`chat.promptFiles: ${context}: ${message}`);
}

async function textFile(path) {
  const handle = await open(path, constants.O_RDONLY | constants.O_NONBLOCK);
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size > limit)
      fail(path, "expected a regular UTF-8 file of at most 1 MiB");
    const bytes = await handle.readFile();
    if (bytes.length > limit) fail(path, "file exceeds 1 MiB");
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch (error) {
    fail(path, error.message);
  } finally {
    await handle.close();
  }
}

export function validateSnapshot(value) {
  if (
    !object(value) ||
    value.version !== 1 ||
    Object.keys(value).sort().join() !== "slots,version" ||
    !object(value.slots) ||
    Object.keys(value.slots).sort().join() !== slots.join()
  )
    fail(key, "invalid persisted snapshot shape or version");
  for (const slot of slots)
    if (
      typeof value.slots[slot] !== "string" ||
      Buffer.byteLength(value.slots[slot], "utf8") > limit
    )
      fail(key, `invalid persisted ${slot}`);
  return Object.freeze({
    version: 1,
    slots: Object.freeze({ ...value.slots }),
  });
}

// Null is the explicit legacy carrier: never read today's files on resume.
export function storedSnapshot(metadata) {
  const value = metadata?._meta?.kiro?.[key];
  return value === undefined ? null : validateSnapshot(value);
}

export function stripSnapshot(meta) {
  if (!object(meta?.kiro) || !Object.hasOwn(meta.kiro, key)) return meta;
  const kiro = { ...meta.kiro };
  delete kiro[key];
  return { ...meta, kiro };
}

export function snapshotMetadata(meta, snapshot) {
  const clean = stripSnapshot(meta);
  return snapshot === null
    ? clean
    : { ...clean, kiro: { ...clean?.kiro, [key]: snapshot } };
}

function mapping(value, path) {
  const mapping = value["chat.promptFiles"];
  if (mapping === undefined) return {};
  if (!object(mapping)) fail(path, "chat.promptFiles must be an object");
  for (const [slot, file] of Object.entries(mapping))
    if (
      !slots.includes(slot) ||
      (file !== null &&
        (typeof file !== "string" || file.length === 0 || file.includes("\0")))
    )
      fail(path, `invalid chat.promptFiles.${slot}`);
  return mapping;
}

export async function resolveSnapshot(homeDir, cwd, worktree) {
  const defaults = Object.fromEntries(
    await Promise.all(
      slots.map(async (slot) => [
        slot,
        await textFile(
          new URL(`./prompt-defaults/${slot}.txt`, import.meta.url),
        ),
      ]),
    ),
  );
  const selected = {};
  for (const { path, base, value } of await settingsLayers(homeDir, cwd))
    for (const [slot, file] of Object.entries(mapping(value, path)))
      selected[slot] =
        file === null ? null : isAbsolute(file) ? file : resolve(base, file);
  for (const [slot, file] of Object.entries(selected)) {
    if (file === null) continue;
    try {
      defaults[slot] = await textFile(file);
    } catch (error) {
      fail(slot, error.message);
    }
  }
  if (worktree && !selected.worktreeGuidance) {
    const parts = JSON.parse(
      await readFile(
        new URL("./prompt-defaults/worktree-policy.json", import.meta.url),
        "utf8",
      ),
    );
    // A layout without a derivable root keeps the PR guidance without naming a destination.
    defaults.worktreeGuidance =
      parts[0] +
      (worktree.root
        ? "'" + `${worktree.root}/<name>`.replaceAll("'", "'\"'\"'") + "'"
        : "<path>") +
      parts[1];
  }
  return validateSnapshot({ version: 1, slots: defaults });
}

// Internal server sessions already carry a trusted ownerSessionId. Public ACP
// metadata is never an input to this inheritance path.
export async function ownerSnapshot(agent, owner, cwd) {
  if (!owner) fail("workflow", "missing owner session id");
  const resident = agent.sessionState(owner);
  if (resident) return resident.nixPromptSnapshot;
  const metadata = await agent.persistence.loadSessionMetadata(owner);
  if (metadata) return storedSnapshot(metadata);
  if (cwd === undefined)
    fail("workflow", `owner session ${owner} is unavailable`);
  // Vendor eviction may remove an owner first; resolve from the child's cwd,
  // matching the cwd reauthorization of its workspace roots.
  return resolveSnapshot(
    agent.homeDir,
    cwd,
    await admit(
      await settingsLayers(agent.homeDir, cwd),
      cwd,
      agent.workspaceTrusted,
    ),
  );
}

export function profile(definition, source, snapshot, original) {
  if (
    snapshot === null ||
    snapshot === undefined ||
    source !== "bundled-profile" ||
    definition.id !== "wf-workflow-creator"
  )
    return definition;
  if (typeof definition.prompt !== "string")
    fail("workflow creator", "prompt shape changed");
  const parts = definition.prompt.split(original);
  if (parts.length !== 2)
    fail("workflow creator", "expected one file-check slot");
  return {
    ...definition,
    prompt: parts[0] + snapshot.slots.workflowFileCheckGuidance + parts[1],
  };
}
