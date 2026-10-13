// Shared settings source selection for the two package-bound KAS extensions.
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";

export async function settingsLayers(homeDir, cwd) {
  const globalPath = join(
    process.env.KIRO_HOME || join(homeDir, ".kiro"),
    "settings",
    "cli.json",
  );
  const layers = [[globalPath, dirname(globalPath)]];
  if (cwd) layers.push([join(cwd, ".kiro/settings/cli.json"), cwd]);
  return Promise.all(
    layers.map(async ([path, base]) => {
      let value;
      try {
        value = JSON.parse(await readFile(path, "utf8"));
      } catch (error) {
        if (error.code === "ENOENT") value = {};
        else throw new Error(`KAS settings: ${path}: ${error.message}`);
      }
      if (value === null || typeof value !== "object" || Array.isArray(value))
        throw new Error(`KAS settings: ${path}: settings must be an object`);
      return { path, base, value };
    }),
  );
}
