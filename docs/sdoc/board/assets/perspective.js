// The Perspective view: two named tables over the same export -- `nodes`
// (one row per node) and `relations` (one row per declared relation, both
// endpoints denormalized in). The spike flattened relations into facet
// strings on the node row, which made them unqueryable; the second table is
// the fix, and the switch below is how a reader moves between the two.
import "https://cdn.jsdelivr.net/npm/@perspective-dev/viewer@5.3.0/dist/cdn/perspective-viewer.js";
import "https://cdn.jsdelivr.net/npm/@perspective-dev/viewer-datagrid@5.3.0/dist/cdn/perspective-viewer-datagrid.js";
import "https://cdn.jsdelivr.net/npm/@perspective-dev/viewer-charts@5.3.0/dist/cdn/perspective-viewer-charts.js";
import perspective from "https://cdn.jsdelivr.net/npm/@perspective-dev/client@5.3.0/dist/cdn/perspective.js";

const THEME = "Aurora";
const STORAGE_PREFIX = "sdoc-board/perspective/v2/";
const DEFAULT_CONFIGS = {
  nodes: {
    plugin: "Datagrid",
    settings: true,
    columns: [
      "UID",
      "TITLE",
      "TYPE",
      "DEPTH",
      "STATUS",
      "DIR",
      "OUT_COUNT",
      "IN_COUNT",
    ],
  },
  relations: {
    plugin: "Datagrid",
    settings: true,
    columns: [
      "SOURCE",
      "SOURCE_TYPE",
      "ROLE",
      "TYPE",
      "TARGET",
      "TARGET_TYPE",
      "TARGET_TITLE",
      "TARGET_STATE",
    ],
  },
};

const viewer = document.querySelector("#viewer");
let worker;
const tables = new Map();
let activeTable = "nodes";
let acceptConfigUpdates = false;
let saveInFlight = Promise.resolve();

function storageKey(name) {
  return `${STORAGE_PREFIX}${name}`;
}

function readSavedConfig(name) {
  try {
    const saved = localStorage.getItem(storageKey(name));
    return saved === null ? null : JSON.parse(saved);
  } catch (storageError) {
    console.warn("Cannot read saved Perspective view", storageError);
    return null;
  }
}

function forgetSavedConfig(name) {
  try {
    localStorage.removeItem(storageKey(name));
  } catch (storageError) {
    console.warn("Cannot remove saved Perspective view", storageError);
  }
}

async function saveConfig() {
  const token = await viewer.save();
  localStorage.setItem(storageKey(activeTable), JSON.stringify(token));
}

viewer.addEventListener("perspective-config-update", () => {
  if (!acceptConfigUpdates) return;
  saveInFlight = saveInFlight.then(saveConfig).catch((saveError) => {
    console.warn("Cannot save Perspective view", saveError);
  });
});

async function restoreTable(name) {
  acceptConfigUpdates = false;
  // Load the Table object itself; restore({table}) merges the new table with
  // the OLD view config, so the old table's columns are validated against
  // the new schema and refused ("Unknown column ... in field `columns`",
  // measured over CDP). Loading resets the view; the config comes after.
  await viewer.load(tables.get(name));
  const saved = readSavedConfig(name);
  const base = { theme: THEME };
  let restored = false;
  if (saved !== null) {
    const { table: _saved_table, ...config } = saved;
    try {
      await viewer.restore({ ...config, ...base }, { suppress_errors: true });
      restored = true;
    } catch (restoreError) {
      console.warn("Saved Perspective view is incompatible", restoreError);
      forgetSavedConfig(name);
    }
  }
  if (!restored) {
    await viewer.restore({ ...DEFAULT_CONFIGS[name], ...base });
  }
  activeTable = name;
  acceptConfigUpdates = true;
  for (const [table, button] of Object.entries(tableButtons())) {
    button.classList.toggle("is-active", table === name);
  }
}

function tableButtons() {
  return {
    nodes: document.querySelector("#table-nodes"),
    relations: document.querySelector("#table-relations"),
  };
}

export async function loadPerspective(payload) {
  await customElements.whenDefined("perspective-viewer");
  if (worker === undefined) {
    worker = await perspective.worker();
    tables.set("nodes", await worker.table(payload.nodes, { name: "nodes" }));
    tables.set(
      "relations",
      await worker.table(payload.relations, { name: "relations" }),
    );
    for (const [name, button] of Object.entries(tableButtons())) {
      button.addEventListener("click", () => {
        restoreTable(name).catch((switchError) => console.error(switchError));
      });
    }
    await restoreTable(activeTable);
    return;
  }
  // A refresh with new data: swap the rows in place. A schema change (a new
  // field in the corpus becomes a new column) cannot be swapped in -- reload
  // the page, which replays the whole load path.
  try {
    await tables.get("nodes").replace(payload.nodes);
    await tables.get("relations").replace(payload.relations);
  } catch (replaceError) {
    console.warn("Table schema changed; reloading", replaceError);
    location.reload();
  }
}
