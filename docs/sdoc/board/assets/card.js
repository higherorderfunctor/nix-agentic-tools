// The shared node card: the full detail pane the Graph and Plan views both
// render for a selected node -- header with type and state, UID, declaring
// file, both relation directions resolved to titles, every field. One
// renderer so a node reads the same wherever it is selected.

export const TYPE_COLORS = {
  DECISION: "#a78bfa",
  EVIDENCE: "#7dd3fc",
  MECHANISM: "#64ffda",
  NARRATIVE: "#fb7185",
  REQUIREMENT: "#fbbf24",
  USE_CASE: "#fdba74",
  WORK: "#4ade80",
};
const FALLBACK_COLOR = "#94a3b8";

export function colorOf(type) {
  return TYPE_COLORS[type] ?? FALLBACK_COLOR;
}

export function htmlNode(name, className, text) {
  const node = document.createElement(name);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function relationItem(snapshot, edge, direction, onSelect) {
  const targetId = direction === "out" ? edge.target : edge.source;
  const target = snapshot.nodes.find((node) => node.id === targetId);
  const item = htmlNode("li");
  item.append(
    htmlNode(
      "span",
      "relation-role",
      direction === "out"
        ? edge.role || edge.type
        : `← ${edge.role || edge.type}`,
    ),
    htmlNode(
      "span",
      "relation-target",
      target ? `${target.id} · ${target.title}` : targetId,
    ),
  );
  if (onSelect) item.addEventListener("click", () => onSelect(targetId));
  return item;
}

function relationSection(snapshot, title, edges, direction, onSelect) {
  const section = htmlNode("section", "inspector-section");
  section.append(htmlNode("h2", null, `${title} · ${edges.length}`));
  const list = htmlNode("ul", "relation-list");
  for (const edge of edges) {
    list.append(relationItem(snapshot, edge, direction, onSelect));
  }
  if (!edges.length) list.append(htmlNode("li", null, "None"));
  section.append(list);
  return section;
}

export function renderNodeCard(snapshot, node, mount, { onSelect } = {}) {
  const accent = colorOf(node.type);
  const outgoing = snapshot.edges.filter((edge) => edge.source === node.id);
  const incoming = snapshot.edges.filter((edge) => edge.target === node.id);
  const head = htmlNode("header", "inspector-head");
  head.style.setProperty("--accent", accent);
  const kicker = htmlNode("div", "inspector-kicker");
  const typeLink = htmlNode("button", "type-link", node.type);
  typeLink.type = "button";
  typeLink.title = `Open ${node.type} in the Grammars view`;
  typeLink.addEventListener("click", () => {
    window.dispatchEvent(
      new CustomEvent("sdoc:show-grammar", { detail: node.type }),
    );
  });
  kicker.append(typeLink, htmlNode("span", null, node.state?.value ?? "node"));
  head.append(
    kicker,
    htmlNode("h1", null, node.title),
    htmlNode("div", "inspector-uid", node.id),
    htmlNode("div", "inspector-source", node.source.path ?? "path unknown"),
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

  mount.replaceChildren(
    head,
    relationSection(
      snapshot,
      "Outgoing declarations",
      outgoing,
      "out",
      onSelect,
    ),
    relationSection(
      snapshot,
      "Incoming declarations",
      incoming,
      "in",
      onSelect,
    ),
    fields,
  );
}
