import { CARD, layoutGraph } from "/assets/layout.js";

const SVG_NS = "http://www.w3.org/2000/svg";
const TYPE_COLORS = {
  DECISION: "#ad8cff",
  EVIDENCE: "#53b6ff",
  MECHANISM: "#39d7cf",
  NARRATIVE: "#ff80b5",
  REQUIREMENT: "#f2c84b",
  USE_CASE: "#ff9f5a",
  WORK: "#48e38b",
};
const FALLBACK_COLOR = "#9fb8c5";

const elements = {
  svg: document.querySelector("#graph"),
  viewport: document.querySelector("#viewport"),
  edges: document.querySelector("#edges"),
  nodes: document.querySelector("#nodes"),
  loading: document.querySelector("#loading"),
  legend: document.querySelector("#legend"),
  inspectorEmpty: document.querySelector("#inspector-empty"),
  inspectorContent: document.querySelector("#inspector-content"),
  error: document.querySelector("#error"),
};

const view = { x: 0, y: 0, scale: 1 };
let snapshot;
let layout;
let drag = null;

function svgNode(name, attributes = {}) {
  const node = document.createElementNS(SVG_NS, name);
  for (const [key, value] of Object.entries(attributes)) {
    if (value !== null && value !== undefined) node.setAttribute(key, value);
  }
  return node;
}

function htmlNode(name, className, text) {
  const node = document.createElement(name);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function colorOf(type) {
  return TYPE_COLORS[type] ?? FALLBACK_COLOR;
}

function truncate(value, length) {
  if (value.length <= length) return value;
  return `${value.slice(0, Math.max(1, length - 1)).trimEnd()}…`;
}

function titleLines(title, width = 36, maxLines = 2) {
  const words = title.split(/\s+/).filter(Boolean);
  const lines = [];
  let line = "";
  for (const word of words) {
    const candidate = line ? `${line} ${word}` : word;
    if (candidate.length <= width || !line) {
      line = candidate;
      continue;
    }
    lines.push(line);
    line = word;
    if (lines.length === maxLines - 1) break;
  }
  if (line && lines.length < maxLines) lines.push(line);
  const consumed = lines.join(" ").length;
  if (consumed < title.length && lines.length) {
    lines[lines.length - 1] = truncate(lines[lines.length - 1], width - 1);
  }
  return lines;
}

function setView(next) {
  view.x = next.x;
  view.y = next.y;
  view.scale = next.scale;
  elements.viewport.setAttribute(
    "transform",
    `translate(${view.x} ${view.y}) scale(${view.scale})`,
  );
}

function fitGraph() {
  if (!layout) return;
  const rect = elements.svg.getBoundingClientRect();
  const pad = 54;
  const scale = Math.min(
    1,
    (rect.width - pad * 2) / layout.bounds.width,
    (rect.height - pad * 2) / layout.bounds.height,
  );
  setView({
    scale,
    x: (rect.width - layout.bounds.width * scale) / 2,
    y: (rect.height - layout.bounds.height * scale) / 2,
  });
}

function zoomAt(factor, clientX, clientY) {
  const rect = elements.svg.getBoundingClientRect();
  const pointX = clientX - rect.left;
  const pointY = clientY - rect.top;
  const nextScale = Math.min(2.6, Math.max(0.035, view.scale * factor));
  const ratio = nextScale / view.scale;
  setView({
    scale: nextScale,
    x: pointX - (pointX - view.x) * ratio,
    y: pointY - (pointY - view.y) * ratio,
  });
}

function edgePath(source, target, offset) {
  const x1 = source.x + CARD.width;
  const y1 = source.y + CARD.height / 2 + offset;
  const x2 = target.x;
  const y2 = target.y + CARD.height / 2 + offset;
  if (x2 > x1 + 24) {
    const bend = Math.max(48, (x2 - x1) * 0.46);
    return {
      d: `M ${x1} ${y1} C ${x1 + bend} ${y1}, ${x2 - bend} ${y2}, ${x2} ${y2}`,
      label: { x: (x1 + x2) / 2, y: (y1 + y2) / 2 - 4 },
    };
  }
  const lift = Math.min(y1, y2) - 66 - Math.abs(offset);
  return {
    d: `M ${x1} ${y1} C ${x1 + 55} ${lift}, ${x2 - 55} ${lift}, ${x2} ${y2}`,
    label: { x: (x1 + x2) / 2, y: lift - 4 },
  };
}

function renderEdges() {
  const parallel = new Map();
  for (const edge of snapshot.edges) {
    const key = `${edge.source}\u0000${edge.target}`;
    if (!parallel.has(key)) parallel.set(key, []);
    parallel.get(key).push(edge);
  }
  const fragments = document.createDocumentFragment();
  for (const group of parallel.values()) {
    group.forEach((edge, index) => {
      const source = layout.positions[edge.source];
      const target = layout.positions[edge.target];
      if (!source || !target) return;
      const offset = (index - (group.length - 1) / 2) * 10;
      const geometry = edgePath(source, target, offset);
      const wrapper = svgNode("g", {
        class: "edge",
        "data-source": edge.source,
        "data-target": edge.target,
      });
      wrapper.append(
        svgNode("path", { class: "edge-path", d: geometry.d }),
        svgNode("text", {
          class: "edge-label",
          x: geometry.label.x,
          y: geometry.label.y,
        }),
      );
      wrapper.lastChild.textContent = edge.role || edge.type;
      fragments.append(wrapper);
    });
  }
  elements.edges.replaceChildren(fragments);
}

function renderNode(node) {
  const position = layout.positions[node.id];
  const accent = colorOf(node.type);
  const group = svgNode("g", {
    class: "node-card",
    transform: `translate(${position.x} ${position.y})`,
    tabindex: "0",
    role: "button",
    "aria-label": `${node.type} ${node.id}: ${node.title}`,
    "data-id": node.id,
    style: `--accent:${accent}`,
  });
  group.append(
    svgNode("rect", {
      class: "card-body",
      width: CARD.width,
      height: CARD.height,
      rx: 7,
    }),
    svgNode("rect", {
      class: "card-accent",
      width: 4,
      height: CARD.height,
      rx: 2,
    }),
  );

  const type = svgNode("text", { class: "card-type", x: 15, y: 18 });
  type.textContent = node.type;
  const uid = svgNode("text", { class: "card-id", x: 15, y: 34 });
  uid.textContent = truncate(node.id, 39);
  group.append(type, uid);

  titleLines(node.title).forEach((line, index) => {
    const text = svgNode("text", {
      class: "card-title",
      x: 15,
      y: 57 + index * 15,
    });
    text.textContent = line;
    group.append(text);
  });

  if (node.state) {
    const label = truncate(node.state.value, 22);
    const width = Math.max(42, label.length * 5.3 + 14);
    group.append(
      svgNode("rect", {
        class: "card-state-bg",
        x: CARD.width - width - 10,
        y: CARD.height - 22,
        width,
        height: 14,
        rx: 3,
      }),
    );
    const state = svgNode("text", {
      class: "card-state",
      x: CARD.width - width - 3,
      y: CARD.height - 12,
    });
    state.textContent = label;
    group.append(state);
  }

  group.addEventListener("click", (event) => {
    event.stopPropagation();
    selectNode(node.id);
  });
  group.addEventListener("keydown", (event) => {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      selectNode(node.id);
    }
  });
  return group;
}

function renderNodes() {
  const fragments = document.createDocumentFragment();
  for (const node of snapshot.nodes) fragments.append(renderNode(node));
  elements.nodes.replaceChildren(fragments);
}

function renderLegend() {
  const fragments = document.createDocumentFragment();
  for (const type of Object.keys(snapshot.stats.types).sort()) {
    const item = htmlNode(
      "span",
      "legend-item",
      `${type} ${snapshot.stats.types[type]}`,
    );
    item.style.setProperty("--accent", colorOf(type));
    fragments.append(item);
  }
  elements.legend.replaceChildren(fragments);
}

function relationItem(edge, direction) {
  const targetId = direction === "out" ? edge.target : edge.source;
  const target = snapshot.nodes.find((node) => node.id === targetId);
  const item = htmlNode("li");
  item.append(
    htmlNode(
      "span",
      "relation-role",
      direction === "out"
        ? edge.role || edge.type
        : edge.reverseRole || edge.role || edge.type,
    ),
    htmlNode(
      "span",
      "relation-target",
      target ? `${target.id} · ${target.title}` : targetId,
    ),
  );
  return item;
}

function renderRelationSection(title, edges, direction) {
  const section = htmlNode("section", "inspector-section");
  section.append(htmlNode("h2", null, `${title} · ${edges.length}`));
  const list = htmlNode("ul", "relation-list");
  for (const edge of edges) list.append(relationItem(edge, direction));
  if (!edges.length) list.append(htmlNode("li", null, "None"));
  section.append(list);
  return section;
}

function renderInspector(node) {
  const accent = colorOf(node.type);
  const outgoing = snapshot.edges.filter((edge) => edge.source === node.id);
  const incoming = snapshot.edges.filter((edge) => edge.target === node.id);
  const head = htmlNode("header", "inspector-head");
  head.style.setProperty("--accent", accent);
  const kicker = htmlNode("div", "inspector-kicker");
  kicker.append(
    htmlNode("span", null, node.type),
    htmlNode("span", null, node.state?.value ?? "node"),
  );
  head.append(
    kicker,
    htmlNode("h1", null, node.title),
    htmlNode("div", "inspector-uid", node.id),
    htmlNode(
      "div",
      "inspector-source",
      `${node.source.path}:${node.source.lineStart ?? "?"}`,
    ),
  );

  const fields = htmlNode("section", "inspector-section");
  fields.append(
    htmlNode("h2", null, `Fields · ${Object.keys(node.fields).length}`),
  );
  const fieldList = htmlNode("dl");
  for (const [name, value] of Object.entries(node.fields)) {
    const wrapper = htmlNode("div", "field");
    wrapper.append(htmlNode("dt", null, name), htmlNode("dd", null, value));
    fieldList.append(wrapper);
  }
  if (node.files.length) {
    const wrapper = htmlNode("div", "field");
    wrapper.append(
      htmlNode("dt", null, "FILES"),
      htmlNode("dd", null, node.files.join("\n")),
    );
    fieldList.append(wrapper);
  }
  fields.append(fieldList);

  elements.inspectorContent.replaceChildren(
    head,
    renderRelationSection("Outgoing declarations", outgoing, "out"),
    renderRelationSection("Incoming declarations", incoming, "in"),
    fields,
  );
  elements.inspectorEmpty.hidden = true;
  elements.inspectorContent.hidden = false;
}

function selectNode(id, { updateHash = true } = {}) {
  const node = snapshot.nodes.find((candidate) => candidate.id === id);
  if (!node) return;
  const incoming = new Set(
    snapshot.edges
      .filter((edge) => edge.target === id)
      .map((edge) => edge.source),
  );
  const outgoing = new Set(
    snapshot.edges
      .filter((edge) => edge.source === id)
      .map((edge) => edge.target),
  );
  document.querySelectorAll(".node-card").forEach((card) => {
    const cardId = card.dataset.id;
    card.classList.toggle("is-selected", cardId === id);
    card.classList.toggle("is-incoming", incoming.has(cardId));
    card.classList.toggle("is-outgoing", outgoing.has(cardId));
    card.classList.toggle(
      "is-dim",
      cardId !== id && !incoming.has(cardId) && !outgoing.has(cardId),
    );
  });
  document.querySelectorAll(".edge").forEach((edge) => {
    const isIncoming = edge.dataset.target === id;
    const isOutgoing = edge.dataset.source === id;
    edge.classList.toggle("is-incoming", isIncoming);
    edge.classList.toggle("is-outgoing", isOutgoing);
    edge.classList.toggle("is-dim", !isIncoming && !isOutgoing);
  });
  renderInspector(node);
  if (updateHash) history.replaceState(null, "", `#${encodeURIComponent(id)}`);
}

function clearSelection() {
  document.querySelectorAll(".node-card, .edge").forEach((node) => {
    node.classList.remove(
      "is-selected",
      "is-incoming",
      "is-outgoing",
      "is-dim",
    );
  });
  elements.inspectorEmpty.hidden = false;
  elements.inspectorContent.hidden = true;
  history.replaceState(null, "", location.pathname);
}

function bindViewport() {
  elements.svg.addEventListener(
    "wheel",
    (event) => {
      event.preventDefault();
      zoomAt(Math.exp(-event.deltaY * 0.0014), event.clientX, event.clientY);
    },
    { passive: false },
  );
  elements.svg.addEventListener("pointerdown", (event) => {
    if (event.target.closest(".node-card")) return;
    drag = { x: event.clientX, y: event.clientY, viewX: view.x, viewY: view.y };
    elements.svg.setPointerCapture(event.pointerId);
    elements.svg.classList.add("is-panning");
  });
  elements.svg.addEventListener("pointermove", (event) => {
    if (!drag) return;
    setView({
      scale: view.scale,
      x: drag.viewX + event.clientX - drag.x,
      y: drag.viewY + event.clientY - drag.y,
    });
  });
  elements.svg.addEventListener("pointerup", (event) => {
    if (!drag) return;
    elements.svg.releasePointerCapture(event.pointerId);
    elements.svg.classList.remove("is-panning");
    drag = null;
  });
  elements.svg.addEventListener("click", (event) => {
    if (!event.target.closest(".node-card")) clearSelection();
  });
  document.querySelector("#fit-view").addEventListener("click", fitGraph);
  document.querySelector("#zoom-in").addEventListener("click", () => {
    const rect = elements.svg.getBoundingClientRect();
    zoomAt(1.25, rect.left + rect.width / 2, rect.top + rect.height / 2);
  });
  document.querySelector("#zoom-out").addEventListener("click", () => {
    const rect = elements.svg.getBoundingClientRect();
    zoomAt(0.8, rect.left + rect.width / 2, rect.top + rect.height / 2);
  });
}

function renderStats() {
  document.querySelector("#project-name").textContent =
    `${snapshot.project.name} · StrictDoc ${snapshot.project.strictdocVersion}`;
  document.querySelector("#node-count").textContent = snapshot.stats.nodes;
  document.querySelector("#edge-count").textContent = snapshot.stats.edges;
  document.querySelector("#type-count").textContent = Object.keys(
    snapshot.stats.types,
  ).length;
  document.querySelector("#diagnostic-count").textContent =
    snapshot.stats.diagnostics;
}

async function start() {
  bindViewport();
  try {
    const response = await fetch("/api/graph", { cache: "no-store" });
    if (!response.ok)
      throw new Error(`graph request failed: ${response.status}`);
    snapshot = await response.json();
    if (snapshot.schema !== "sdoc-board/1") {
      throw new Error(`unsupported snapshot schema: ${snapshot.schema}`);
    }
    layout = layoutGraph(snapshot);
    renderStats();
    renderLegend();
    renderEdges();
    renderNodes();
    requestAnimationFrame(() => {
      fitGraph();
      elements.loading.classList.add("is-done");
      const requested = decodeURIComponent(location.hash.slice(1));
      if (requested) selectNode(requested, { updateHash: false });
    });
  } catch (error) {
    elements.loading.classList.add("is-done");
    elements.error.hidden = false;
    elements.error.textContent = `sdoc-board: ${error.message}`;
    console.error(error);
  }
}

start();
