// The Graph view is a bounded lens over the canon: the left pane lists WORK
// nodes, the canvas draws one focal node's neighborhood, and graph-card clicks
// only change the detail inspector. The focal node remains the raw #UID so
// links stay compatible with the other views.
import { colorOf, htmlNode, renderNodeCard } from "/assets/card.js";
import { CARD, layoutNeighborhood } from "/assets/layout.js";

const SVG_NS = "http://www.w3.org/2000/svg";
const DESIGN_BODY_PX = 12;
const MAX_VISIBLE_NODES = 48;

const elements = {
  boardView: document.querySelector("#view-board"),
  closeInspector: document.querySelector("#close-inspector"),
  closeWorkBrowser: document.querySelector("#close-work-browser"),
  depthOptions: document.querySelector("#depth-options"),
  edges: document.querySelector("#edges"),
  empty: document.querySelector("#graph-empty"),
  filterCount: document.querySelector("#filter-count"),
  graphFilters: document.querySelector("#graph-filters"),
  inspectorContent: document.querySelector("#inspector-content"),
  inspectorEmpty: document.querySelector("#inspector-empty"),
  legend: document.querySelector("#legend"),
  nodes: document.querySelector("#nodes"),
  resetFilters: document.querySelector("#reset-filters"),
  roleFilters: document.querySelector("#role-filters"),
  summary: document.querySelector("#neighborhood-summary"),
  svg: document.querySelector("#graph"),
  toggleWorkBrowser: document.querySelector("#toggle-work-browser"),
  typeFilters: document.querySelector("#type-filters"),
  viewport: document.querySelector("#viewport"),
  workCount: document.querySelector("#work-count"),
  workList: document.querySelector("#work-list"),
  workListSummary: document.querySelector("#work-list-summary"),
  workSearch: document.querySelector("#work-search"),
  workState: document.querySelector("#work-state"),
};

const state = {
  depth: 1,
  enabledRelations: new Set(),
  enabledTypes: new Set(),
  focusId: null,
  inspectId: null,
  query: "",
  workState: "",
};
const view = { x: 0, y: 0, scale: 1 };

let allRelations = [];
let allTypes = [];
let allWorkStates = [];
let bound = false;
let card = CARD;
let drag = null;
let layout = null;
let layoutRequest = 0;
let measure = {};
let nodeTypesById = new Map();
let roleStyles = new Map();
let snapshot = null;
let typeScale = 1;
let workItems = [];

const measurer = document.createElement("canvas").getContext("2d");

function scaled(designPx) {
  return designPx * typeScale;
}

function readTypeScale() {
  typeScale =
    parseFloat(getComputedStyle(elements.svg).fontSize) / DESIGN_BODY_PX;
  card = { width: scaled(CARD.width), height: scaled(CARD.height) };
}

function svgNode(name, attributes = {}) {
  const node = document.createElementNS(SVG_NS, name);
  for (const [key, value] of Object.entries(attributes)) {
    if (value !== null && value !== undefined) node.setAttribute(key, value);
  }
  return node;
}

function buildRoleStyles(relations) {
  const roles = [...new Set(relations.map((relation) => relation.role))].sort();
  return new Map(
    roles.map((role, index) => [
      role,
      {
        // Binary low-discrepancy steps spread every growing prefix around the
        // wheel; fixed OKLCH lightness/chroma keeps those hues similarly
        // legible on the dark canvas. Orange is intentionally the first slot.
        color: `oklch(80% 0.15 ${distributedHue(index)})`,
        markerId: `role-arrow-${index}`,
      },
    ]),
  );
}

function distributedHue(index) {
  let fraction = 0;
  let place = 0.5;
  let remaining = index;
  while (remaining > 0) {
    fraction += (remaining % 2) * place;
    remaining = Math.floor(remaining / 2);
    place /= 2;
  }
  return Math.round(((48 + fraction * 360) % 360) * 10) / 10;
}

function renderRoleMarkers() {
  const defs = elements.svg.querySelector("defs");
  for (const marker of defs.querySelectorAll("[data-role-marker]")) {
    marker.remove();
  }
  for (const style of roleStyles.values()) {
    const marker = svgNode("marker", {
      "data-role-marker": "",
      id: style.markerId,
      markerHeight: "7",
      markerWidth: "7",
      orient: "auto-start-reverse",
      refX: "9",
      refY: "5",
      viewBox: "0 0 10 10",
    });
    marker.append(
      svgNode("path", {
        d: "M 0 0 L 10 5 L 0 10 z",
        fill: style.color,
        "fill-opacity": "0.72",
      }),
    );
    defs.append(marker);
  }
}

function edgeLabelMeasurer() {
  const probe = svgNode("text", { class: "edge-label", x: "0", y: "0" });
  probe.textContent = "Ag";
  elements.edges.append(probe);
  const style = getComputedStyle(probe);
  const font = `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
  const spacing = style.letterSpacing.endsWith("px")
    ? style.letterSpacing
    : "0px";
  const box = probe.getBBox();
  const halo = Math.max(scaled(2), parseFloat(style.strokeWidth) || 0);
  probe.remove();
  return (value) => {
    measurer.font = font;
    measurer.letterSpacing = spacing;
    return {
      baseline: halo - box.y,
      height: box.height + halo * 2,
      width: measurer.measureText(value).width + halo * 2,
    };
  };
}

function readMeasurers() {
  measure = {
    edge: edgeLabelMeasurer(),
  };
}

function cardTabInset() {
  return scaled(3) / view.scale;
}

function outsideOutlineGeometry(strokeWidth) {
  const halfStroke = scaled(strokeWidth / 2) / view.scale;
  return {
    height: card.height + halfStroke * 2,
    rx: scaled(6) + halfStroke,
    width: card.width + halfStroke * 2,
    x: -halfStroke,
    y: -halfStroke,
  };
}

function updateCardChrome() {
  const inset = cardTabInset();
  for (const surface of elements.nodes.querySelectorAll(".card-main")) {
    surface.setAttribute("x", inset);
    surface.setAttribute("width", card.width - inset);
  }
  for (const [selector, strokeWidth] of [
    [".card-border", 1],
    [".card-outline", 2],
  ]) {
    const geometry = outsideOutlineGeometry(strokeWidth);
    for (const outline of elements.nodes.querySelectorAll(selector)) {
      for (const [name, value] of Object.entries(geometry)) {
        outline.setAttribute(name, value);
      }
    }
  }
}

function setView(next) {
  view.x = next.x;
  view.y = next.y;
  view.scale = next.scale;
  updateCardChrome();
  elements.viewport.setAttribute(
    "transform",
    `translate(${view.x} ${view.y}) scale(${view.scale})`,
  );
}

function fitGraph() {
  if (!layout?.nodes.length || !layout.bounds.width || !layout.bounds.height)
    return;
  const rect = elements.svg.getBoundingClientRect();
  const pad = 48;
  const scale = Math.max(
    0.035,
    Math.min(
      1,
      Math.max(1, rect.width - pad * 2) / layout.bounds.width,
      Math.max(1, rect.height - pad * 2) / layout.bounds.height,
    ),
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

function renderEdges() {
  const fragments = document.createDocumentFragment();
  for (const route of layout.routes) {
    const edge = route.edge;
    const semanticEdges = route.edges ?? [edge];
    const role = edge.role || edge.type;
    const roleStyle = roleStyles.get(role);
    const sources = [...new Set(semanticEdges.map(({ source }) => source))];
    const targets = [...new Set(semanticEdges.map(({ target }) => target))];
    const wrapper = svgNode("g", {
      class: "edge",
      "data-role": role,
      "data-source": edge.source,
      "data-sources": JSON.stringify(sources),
      "data-target": edge.target,
      "data-targets": JSON.stringify(targets),
    });
    wrapper.style.setProperty("--role-color", roleStyle.color);
    const path = svgNode("path", { class: "edge-path", d: route.d });
    if (route.terminal !== false) {
      path.setAttribute("marker-end", `url(#${roleStyle.markerId})`);
    }
    wrapper.append(path);
    if (route.label) {
      const label = svgNode("text", {
        class: "edge-label",
        x: route.label.x,
        y: route.label.y,
      });
      label.textContent = route.label.text || role;
      wrapper.append(label);
    }
    fragments.append(wrapper);
  }
  elements.edges.replaceChildren(fragments);
}

function renderNode(node) {
  const position = layout.positions[node.id];
  const accent = colorOf(node.type);
  const group = svgNode("g", {
    class: node.id === state.focusId ? "node-card is-center" : "node-card",
    transform: `translate(${position.x} ${position.y})`,
    "data-id": node.id,
    "data-rank": position.rank,
    style: `--accent:${accent}`,
  });
  const radius = scaled(6);
  const foreignObject = svgNode("foreignObject", {
    class: "card-foreign-object",
    width: card.width,
    height: card.height,
  });
  const item = summaryCard(node, { graph: true });
  item.setAttribute("aria-label", `${node.type} ${node.id}: ${node.title}`);
  item.addEventListener("click", (event) => {
    event.stopPropagation();
    selectNode(node.id);
  });
  foreignObject.append(item);
  const inset = cardTabInset();
  group.append(
    svgNode("rect", {
      class: "card-glow",
      width: card.width,
      height: card.height,
      rx: radius,
    }),
    svgNode("rect", {
      class: "card-tab",
      width: card.width,
      height: card.height,
      rx: radius,
    }),
    svgNode("rect", {
      class: "card-main",
      x: inset,
      width: card.width - inset,
      height: card.height,
      rx: radius,
    }),
    foreignObject,
    svgNode("rect", {
      class: "card-border",
      ...outsideOutlineGeometry(1),
    }),
    svgNode("rect", {
      class: "card-outline",
      ...outsideOutlineGeometry(2),
    }),
  );
  return group;
}

function renderNodes() {
  const fragments = document.createDocumentFragment();
  for (const node of layout.nodes) fragments.append(renderNode(node));
  elements.nodes.replaceChildren(fragments);
}

function renderLegend() {
  const visibleTypes = new Set(layout.nodes.map((node) => node.type));
  const nodeItems = htmlNode("div", "legend-items");
  for (const type of [...visibleTypes].sort()) {
    const item = htmlNode("span", "legend-item legend-node-item", type);
    item.style.setProperty("--accent", colorOf(type));
    nodeItems.append(item);
  }
  const visibleRoles = new Set(
    layout.edges.map((edge) => edge.role || edge.type),
  );
  const roleItems = htmlNode("div", "legend-items");
  for (const role of [...visibleRoles].sort()) {
    const item = htmlNode("span", "legend-item legend-role-item");
    item.style.setProperty("--role-color", roleStyles.get(role).color);
    item.append(htmlNode("span", "legend-line"), htmlNode("span", null, role));
    roleItems.append(item);
  }
  const outlineItems = htmlNode("div", "legend-items legend-outline-items");
  const focalType = layout.nodes.find(
    (node) => node.id === state.focusId,
  )?.type;
  for (const [kind, label] of [
    ["focus", "Focused work"],
    ["inspected", "Inspected"],
    ["source", "Source → inspected"],
    ["target", "Inspected → target"],
  ]) {
    const item = htmlNode("span", "legend-item legend-outline-item");
    const swatch = htmlNode("span", `legend-outline-swatch outline-${kind}`);
    if (kind === "focus") {
      swatch.style.setProperty("--outline-color", colorOf(focalType));
    }
    item.append(swatch, htmlNode("span", null, label));
    outlineItems.append(item);
  }
  const group = (title, items, className = "") => {
    const section = htmlNode(
      "section",
      `legend-group${className ? ` ${className}` : ""}`,
    );
    section.append(htmlNode("h3", "legend-title", title), items);
    return section;
  };
  elements.legend.replaceChildren(
    htmlNode("h2", "legend-heading", "Key"),
    group("Nodes", nodeItems),
    group("Relations", roleItems),
    group("Card outlines", outlineItems, "legend-outline-group"),
  );
}

function applyInspection() {
  const inspected = state.inspectId;
  const incoming = new Set(
    layout.edges
      .filter((edge) => edge.target === inspected)
      .map((edge) => edge.source),
  );
  const outgoing = new Set(
    layout.edges
      .filter((edge) => edge.source === inspected)
      .map((edge) => edge.target),
  );
  for (const node of elements.nodes.querySelectorAll(".node-card")) {
    const id = node.dataset.id;
    node.classList.toggle("is-center", id === state.focusId);
    node.classList.toggle("is-selected", id === inspected);
    node.classList.toggle("points-to-inspected", incoming.has(id));
    node.classList.toggle("pointed-to-by-inspected", outgoing.has(id));
    node.classList.toggle(
      "is-dim",
      Boolean(inspected) &&
        id !== inspected &&
        !incoming.has(id) &&
        !outgoing.has(id),
    );
  }
  for (const edge of elements.edges.querySelectorAll(".edge")) {
    const sources = JSON.parse(edge.dataset.sources || "[]");
    const targets = JSON.parse(edge.dataset.targets || "[]");
    const touchesInspected =
      sources.includes(inspected) || targets.includes(inspected);
    edge.classList.toggle("touches-inspected", touchesInspected);
    edge.classList.toggle("is-dim", Boolean(inspected) && !touchesInspected);
  }
}

export function selectNode(id) {
  const node = snapshot?.nodes.find((candidate) => candidate.id === id);
  if (!node) return;
  state.inspectId = id;
  applyInspection();
  renderNodeCard(snapshot, node, elements.inspectorContent, {
    onSelect: selectNode,
  });
  elements.inspectorEmpty.hidden = true;
  elements.inspectorContent.hidden = false;
}

function clearInspection() {
  state.inspectId = null;
  if (layout) applyInspection();
  elements.inspectorEmpty.hidden = false;
  elements.inspectorContent.hidden = true;
}

function workHaystack(node) {
  return [
    node.id,
    node.title,
    node.summary,
    node.state?.value,
    node.source?.path,
  ]
    .filter(Boolean)
    .join(" ")
    .toLocaleLowerCase();
}

function summaryCard(node, { graph = false } = {}) {
  const item = htmlNode(
    "button",
    graph ? "work-item graph-work-item" : "work-item",
  );
  item.type = "button";
  const head = htmlNode("span", "work-item-head");
  head.append(
    htmlNode("span", "work-item-uid", node.id),
    htmlNode(
      "span",
      "work-item-state",
      node.state?.value ?? (graph ? "node" : "work"),
    ),
  );
  const path = node.source?.path ?? "path unknown";
  const dir = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : path;
  item.append(
    head,
    htmlNode("strong", "work-item-title", node.title),
    htmlNode("span", "work-item-path", dir),
  );
  return item;
}

function workItem(node) {
  const item = summaryCard(node);
  item.dataset.id = node.id;
  item.style.setProperty("--accent", colorOf(node.type));
  item.addEventListener("click", () => {
    void setFocus(node.id).catch(reportLayoutError);
  });
  return item;
}

function renderWorkList() {
  const query = state.query.trim().toLocaleLowerCase();
  const matches = workItems.filter(
    (node) =>
      (!query || workHaystack(node).includes(query)) &&
      (!state.workState || node.state?.value === state.workState),
  );
  const focused = workItems.find((node) => node.id === state.focusId);
  const pinned = focused && !matches.some((node) => node.id === focused.id);
  const visible = pinned ? [focused, ...matches] : matches;
  const fragments = document.createDocumentFragment();
  for (const node of visible) fragments.append(workItem(node));
  if (!visible.length) {
    fragments.append(
      htmlNode(
        "p",
        "work-list-empty",
        workItems.length
          ? "No work items match."
          : "No work items in this canon.",
      ),
    );
  }
  elements.workList.replaceChildren(fragments);
  for (const item of elements.workList.querySelectorAll(".work-item")) {
    const selected = item.dataset.id === state.focusId;
    item.classList.toggle("is-selected", selected);
    if (selected) item.setAttribute("aria-current", "true");
    else item.removeAttribute("aria-current");
  }
  elements.workCount.textContent = String(workItems.length);
  elements.workListSummary.textContent =
    query || state.workState
      ? `${matches.length} of ${workItems.length}${pinned ? " · focus pinned" : ""}`
      : `${workItems.length} work items`;
}

function renderWorkStateControl() {
  const previous = state.workState;
  const fragments = document.createDocumentFragment();
  const all = document.createElement("option");
  all.value = "";
  all.textContent = "All states";
  fragments.append(all);
  for (const value of allWorkStates) {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = value;
    fragments.append(option);
  }
  elements.workState.replaceChildren(fragments);
  state.workState = allWorkStates.includes(previous) ? previous : "";
  elements.workState.value = state.workState;
}

function relationKey(sourceType, role) {
  return JSON.stringify([sourceType, role]);
}

function nodeTypeFilterOption(value) {
  const label = htmlNode("label", "filter-option");
  label.dataset.kind = "type";
  label.dataset.value = value;
  const input = document.createElement("input");
  input.type = "checkbox";
  input.checked = state.enabledTypes.has(value);
  input.addEventListener("change", () => {
    if (input.checked) state.enabledTypes.add(value);
    else state.enabledTypes.delete(value);
    refreshNeighborhood();
  });
  const swatch = htmlNode("span", "filter-swatch");
  swatch.style.setProperty("--accent", colorOf(value));
  label.append(input, swatch, htmlNode("span", null, value));
  return label;
}

function relationFilterOption(relation) {
  const label = htmlNode("label", "filter-option");
  label.dataset.kind = "relation";
  label.dataset.key = relation.key;
  label.dataset.role = relation.role;
  label.dataset.sourceType = relation.sourceType;
  const input = document.createElement("input");
  input.type = "checkbox";
  input.checked = state.enabledRelations.has(relation.key);
  input.addEventListener("click", (event) => {
    const enabled = input.checked;
    const affected = event.shiftKey
      ? allRelations.filter((candidate) => candidate.role === relation.role)
      : [relation];
    for (const candidate of affected) {
      if (enabled) state.enabledRelations.add(candidate.key);
      else state.enabledRelations.delete(candidate.key);
    }
    refreshNeighborhood();
  });
  const style = roleStyles.get(relation.role);
  const swatch = htmlNode("span", "filter-swatch role-filter-swatch");
  swatch.style.setProperty("--accent", style.color);
  label.append(input, swatch, htmlNode("span", null, relation.role));
  return label;
}

function relationFilterGroup(sourceType, relations) {
  const group = htmlNode("section", "relation-filter-group");
  const title = htmlNode("h4", "relation-filter-group-title");
  const swatch = htmlNode("span", "filter-swatch");
  swatch.style.setProperty("--accent", colorOf(sourceType));
  title.append(swatch, htmlNode("span", null, sourceType));
  const options = htmlNode("div", "relation-filter-options");
  for (const relation of relations) {
    options.append(relationFilterOption(relation));
  }
  group.append(title, options);
  return group;
}

function renderFilterControls() {
  const typeFragments = document.createDocumentFragment();
  for (const type of allTypes) typeFragments.append(nodeTypeFilterOption(type));
  elements.typeFilters.replaceChildren(typeFragments);
  const relationFragments = document.createDocumentFragment();
  for (const sourceType of allTypes) {
    const relations = allRelations.filter(
      (relation) => relation.sourceType === sourceType,
    );
    if (relations.length > 0) {
      relationFragments.append(relationFilterGroup(sourceType, relations));
    }
  }
  elements.roleFilters.replaceChildren(relationFragments);
  syncFilterControls();
}

function syncFilterControls() {
  for (const button of elements.depthOptions.querySelectorAll("button")) {
    button.classList.toggle(
      "is-active",
      Number(button.dataset.depth) === state.depth,
    );
  }
  for (const label of document.querySelectorAll(".filter-option")) {
    label.querySelector("input").checked =
      label.dataset.kind === "type"
        ? state.enabledTypes.has(label.dataset.value)
        : state.enabledRelations.has(label.dataset.key);
  }
}

function activeFilterCount() {
  return (
    allTypes.length -
    state.enabledTypes.size +
    (allRelations.length - state.enabledRelations.size)
  );
}

function quantity(value, singular) {
  return `${value} ${value === 1 ? singular : `${singular}s`}`;
}

function boundedLayout() {
  const filteredNodes = snapshot.nodes.filter(
    (node) => node.id === state.focusId || state.enabledTypes.has(node.type),
  );
  const allowedIds = new Set(filteredNodes.map((node) => node.id));
  const filteredEdges = snapshot.edges.filter(
    (edge) =>
      allowedIds.has(edge.source) &&
      allowedIds.has(edge.target) &&
      state.enabledRelations.has(
        relationKey(
          nodeTypesById.get(edge.source) || "UNKNOWN",
          edge.role || edge.type,
        ),
      ),
  );
  const filtered = { ...snapshot, nodes: filteredNodes, edges: filteredEdges };
  return layoutNeighborhood(filtered, state.focusId, {
    card,
    depth: state.depth,
    maxNodes: MAX_VISIBLE_NODES,
    measureLabel: measure.edge,
  });
}

async function renderNeighborhood({ fit = true } = {}) {
  const request = ++layoutRequest;
  elements.filterCount.textContent = String(activeFilterCount());
  syncFilterControls();
  if (!state.focusId) {
    layout = null;
    elements.edges.replaceChildren();
    elements.nodes.replaceChildren();
    elements.legend.replaceChildren();
    elements.empty.hidden = false;
    elements.summary.textContent = "Choose a work item";
    elements.svg.removeAttribute("aria-busy");
    clearInspection();
    return;
  }

  elements.summary.textContent = "Laying out neighborhood…";
  elements.svg.setAttribute("aria-busy", "true");
  let nextLayout;
  try {
    nextLayout = await boundedLayout();
  } catch (error) {
    if (request !== layoutRequest) return;
    elements.svg.removeAttribute("aria-busy");
    throw error;
  }
  if (request !== layoutRequest) return;
  layout = nextLayout;
  elements.svg.removeAttribute("aria-busy");
  renderEdges();
  renderNodes();
  renderLegend();
  elements.empty.hidden = true;
  const clipped = layout.clipped
    ? ` · ${layout.nodes.length} of ${layout.totalNodes} nearest`
    : "";
  elements.summary.textContent = `${quantity(layout.nodes.length, "node")} · ${quantity(layout.edges.length, "relation")}${clipped}`;

  if (
    state.inspectId &&
    !layout.nodes.some((node) => node.id === state.inspectId)
  ) {
    state.inspectId = null;
  }
  if (state.inspectId) selectNode(state.inspectId);
  else clearInspection();
  if (fit) requestAnimationFrame(fitGraph);
}

function reportLayoutError(error) {
  elements.svg.removeAttribute("aria-busy");
  elements.summary.textContent = "Unable to lay out neighborhood";
  window.dispatchEvent(new CustomEvent("sdoc:board-error", { detail: error }));
}

function refreshNeighborhood(options) {
  void renderNeighborhood(options).catch(reportLayoutError);
}

function hashUid() {
  try {
    return decodeURIComponent(location.hash.slice(1));
  } catch {
    return "";
  }
}

function writeHash(id) {
  history.replaceState(
    null,
    "",
    `${location.pathname}${location.search}#${encodeURIComponent(id)}`,
  );
}

async function setFocus(id, { updateHash = true } = {}) {
  if (!snapshot?.nodes.some((node) => node.id === id)) return;
  state.focusId = id;
  state.inspectId = null;
  if (updateHash) writeHash(id);
  elements.boardView.classList.remove("is-list-open");
  renderWorkList();
  elements.workList
    .querySelector(".work-item.is-selected")
    ?.scrollIntoView({ block: "nearest" });
  await renderNeighborhood();
}

function resetFilters() {
  state.enabledRelations = new Set(
    allRelations.map((relation) => relation.key),
  );
  state.enabledTypes = new Set(allTypes);
  refreshNeighborhood();
}

function bindViewport() {
  if (bound) return;
  bound = true;
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
    if (!event.target.closest(".node-card")) clearInspection();
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
  elements.workSearch.addEventListener("input", () => {
    state.query = elements.workSearch.value;
    renderWorkList();
  });
  elements.depthOptions.addEventListener("click", (event) => {
    const button = event.target.closest("button[data-depth]");
    if (!button) return;
    state.depth = Number(button.dataset.depth);
    refreshNeighborhood();
  });
  elements.resetFilters.addEventListener("click", resetFilters);
  document.addEventListener("pointerdown", (event) => {
    if (
      elements.graphFilters.open &&
      !elements.graphFilters.contains(event.target)
    ) {
      elements.graphFilters.open = false;
    }
  });
  elements.closeInspector.addEventListener("click", clearInspection);
  elements.closeWorkBrowser.addEventListener("click", () => {
    elements.boardView.classList.remove("is-list-open");
  });
  elements.toggleWorkBrowser.addEventListener("click", () => {
    elements.boardView.classList.toggle("is-list-open");
  });
  elements.workState.addEventListener("change", () => {
    state.workState = elements.workState.value;
    renderWorkList();
  });
  window.addEventListener("hashchange", () => {
    if (!snapshot || elements.boardView.hidden) return;
    const requested = hashUid();
    if (
      workItems.some((node) => node.id === requested) &&
      requested !== state.focusId
    ) {
      void setFocus(requested, { updateHash: false }).catch(reportLayoutError);
    } else if (!workItems.some((node) => node.id === requested)) {
      state.focusId = null;
      state.inspectId = null;
      history.replaceState(null, "", `${location.pathname}${location.search}`);
      renderWorkList();
      refreshNeighborhood();
      elements.boardView.classList.add("is-list-open");
    }
  });
  let resizeFrame = null;
  window.addEventListener("resize", () => {
    if (resizeFrame) cancelAnimationFrame(resizeFrame);
    resizeFrame = requestAnimationFrame(() => {
      resizeFrame = null;
      fitGraph();
    });
  });
}

export async function renderBoard(nextSnapshot) {
  layoutRequest += 1;
  snapshot = nextSnapshot;
  bindViewport();
  readTypeScale();
  readMeasurers();
  nodeTypesById = new Map(
    snapshot.nodes.map((node) => [node.id, node.type || "UNKNOWN"]),
  );
  allTypes = [...new Set(snapshot.nodes.map((node) => node.type))].sort();
  const relationFilters = new Map();
  for (const edge of snapshot.edges) {
    const sourceType = nodeTypesById.get(edge.source) || "UNKNOWN";
    const role = edge.role || edge.type;
    const key = relationKey(sourceType, role);
    relationFilters.set(key, { key, role, sourceType });
  }
  allRelations = [...relationFilters.values()].sort(
    (left, right) =>
      left.sourceType.localeCompare(right.sourceType) ||
      left.role.localeCompare(right.role),
  );
  roleStyles = buildRoleStyles(allRelations);
  renderRoleMarkers();
  state.enabledTypes = new Set(allTypes);
  state.enabledRelations = new Set(
    allRelations.map((relation) => relation.key),
  );
  workItems = snapshot.nodes
    .filter((node) => node.type === "WORK")
    .sort(
      (left, right) =>
        left.title.localeCompare(right.title) ||
        left.id.localeCompare(right.id),
    );
  allWorkStates = [
    ...new Set(workItems.map((node) => node.state?.value).filter(Boolean)),
  ].sort();
  renderWorkStateControl();
  renderFilterControls();
  renderWorkList();
  const requested = hashUid();
  const initial = workItems.some((node) => node.id === requested)
    ? requested
    : workItems[0]?.id;
  if (initial) {
    const defaulted = requested !== initial;
    await setFocus(initial, { updateHash: defaulted });
    if (defaulted) elements.boardView.classList.add("is-list-open");
  } else {
    elements.boardView.classList.add("is-list-open");
    await renderNeighborhood();
  }
}
