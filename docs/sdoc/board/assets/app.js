// The shell: one top bar, the views over one daemon-served dataset.
// Following beadboard's shape: the chrome is global and stable, the middle
// content swaps, and the active view lives in the URL (?view=perspective) so
// it survives reload and can be linked. Node selection stays in the #hash.
import { renderBoard } from "/assets/board.js";
import { renderGrammars, selectGrammar } from "/assets/grammars.js";
import { loadPerspective } from "/assets/perspective.js";

const VIEWS = ["perspective", "grammars", "board"];
const elements = {
  error: document.querySelector("#error"),
  loading: document.querySelector("#loading"),
  loadingDetail: document.querySelector("#loading-detail"),
  loadingTitle: document.querySelector("#loading-title"),
  noDaemon: document.querySelector("#no-daemon"),
  noDaemonDetail: document.querySelector("#no-daemon-detail"),
  projectName: document.querySelector("#project-name"),
  statusText: document.querySelector("#status-text"),
};
const sections = {
  board: document.querySelector("#view-board"),
  grammars: document.querySelector("#view-grammars"),
  perspective: document.querySelector("#view-perspective"),
};
const switches = {
  board: document.querySelector("#switch-board"),
  grammars: document.querySelector("#switch-grammars"),
  perspective: document.querySelector("#switch-perspective"),
};

const cache = { graph: null, rows: null };
const loaded = { board: false, perspective: false };

function activeView() {
  const requested = new URLSearchParams(location.search).get("view");
  return VIEWS.includes(requested) ? requested : "board";
}

function setStatus(text, state) {
  elements.statusText.textContent = text;
  document.documentElement.dataset.status = state;
}

function showLoading(title, detail) {
  elements.loadingTitle.textContent = title;
  elements.loadingDetail.textContent = detail;
  elements.loading.hidden = false;
}

async function fetchJson(path) {
  const response = await fetch(path, { cache: "no-store" });
  const payload = await response.json();
  if (response.status === 503 && payload.error === "no-daemon") {
    const refusal = new Error(payload.detail);
    refusal.noDaemon = true;
    throw refusal;
  }
  if (!response.ok) {
    throw new Error(payload.detail || `${path} failed: ${response.status}`);
  }
  return payload;
}

function renderStats(payload) {
  elements.projectName.textContent = `${payload.project.name} · generation ${payload.project.generation}`;
  document.querySelector("#node-count").textContent = payload.stats.nodes;
  document.querySelector("#edge-count").textContent = payload.stats.edges;
  document.querySelector("#type-count").textContent = Object.keys(
    payload.stats.types,
  ).length;
  document.querySelector("#generation").textContent =
    payload.project.generation;
}

async function showBoard() {
  if (!cache.graph) {
    showLoading("Asking the scribe daemon", "Exporting the held graph");
    cache.graph = await fetchJson("/api/graph");
  }
  const payload = cache.graph;
  if (payload.schema !== "sdoc-board/2") {
    throw new Error(`unsupported snapshot schema: ${payload.schema}`);
  }
  renderStats(payload);
  renderBoard(payload);
  loaded.board = true;
}

async function showGrammars() {
  if (!cache.graph) {
    showLoading("Asking the scribe daemon", "Exporting the held graph");
    cache.graph = await fetchJson("/api/graph");
  }
  const payload = cache.graph;
  if (payload.schema !== "sdoc-board/2") {
    throw new Error(`unsupported snapshot schema: ${payload.schema}`);
  }
  renderStats(payload);
  renderGrammars(payload);
}

async function showPerspective() {
  if (!cache.rows) {
    showLoading("Asking the scribe daemon", "Adapting rows for Perspective");
    cache.rows = await fetchJson("/api/rows");
  }
  const payload = cache.rows;
  if (payload.schema !== "sdoc-perspective/2") {
    throw new Error(`unsupported rows schema: ${payload.schema}`);
  }
  renderStats(payload);
  await loadPerspective(payload);
  loaded.perspective = true;
}

async function activate(view, { push = false } = {}) {
  for (const name of VIEWS) {
    sections[name].hidden = name !== view;
    switches[name].classList.toggle("is-active", name === view);
  }
  if (push) {
    const params = new URLSearchParams(location.search);
    params.set("view", view);
    history.replaceState(null, "", `?${params}${location.hash}`);
  }
  elements.noDaemon.hidden = true;
  elements.error.hidden = true;
  try {
    if (view === "board") await showBoard();
    else if (view === "grammars") await showGrammars();
    else await showPerspective();
    elements.loading.hidden = true;
    setStatus("live from the daemon", "ready");
  } catch (loadError) {
    elements.loading.hidden = true;
    if (loadError.noDaemon) {
      elements.noDaemonDetail.textContent = loadError.message;
      elements.noDaemon.hidden = false;
      setStatus("daemon down", "error");
      return;
    }
    elements.error.textContent = `sdoc-board: ${loadError.message}`;
    elements.error.hidden = false;
    setStatus("load failed", "error");
    console.error(loadError);
  }
}

function refresh() {
  cache.graph = null;
  cache.rows = null;
  activate(activeView());
}

for (const name of VIEWS) {
  switches[name].addEventListener("click", () => {
    activate(name, { push: true });
  });
}
document.querySelector("#refresh").addEventListener("click", refresh);
window.addEventListener("sdoc:show-grammar", (event) => {
  activate("grammars", { push: true }).then(() => selectGrammar(event.detail));
});
document.querySelector("#retry").addEventListener("click", refresh);

activate(activeView());
