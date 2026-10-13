// Loaded by package-bound KAS. All mutable state belongs to a conversation.
import { constants } from "node:fs";
import { open, readFile } from "node:fs/promises";
import { dirname, isAbsolute, join, resolve } from "node:path";

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

async function settings(path) {
  let bytes;
  try {
    bytes = await readFile(path, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return {};
    fail(path, error.message);
  }
  let value;
  try {
    value = JSON.parse(bytes);
  } catch (error) {
    fail(path, error.message);
  }
  if (!object(value)) fail(path, "settings must be an object");
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

export async function resolveSnapshot(homeDir, cwd) {
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
  const globalPath = join(
    process.env.KIRO_HOME || join(homeDir, ".kiro"),
    "settings",
    "cli.json",
  );
  const layers = [[globalPath, dirname(globalPath)]];
  if (cwd) layers.push([join(cwd, ".kiro/settings/cli.json"), cwd]);
  const selected = {};
  for (const [path, base] of layers)
    for (const [slot, file] of Object.entries(await settings(path)))
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
  return validateSnapshot({ version: 1, slots: defaults });
}

// Internal server sessions already carry a trusted ownerSessionId. Public ACP
// metadata is never an input to this inheritance path.
export async function ownerSnapshot(agent, owner) {
  if (!owner) fail("workflow", "missing owner session id");
  const resident = agent.sessionState(owner);
  if (resident) return resident.nixPromptSnapshot;
  const metadata = await agent.persistence.loadSessionMetadata(owner);
  if (!metadata) fail("workflow", `owner session ${owner} is unavailable`);
  return storedSnapshot(metadata);
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
