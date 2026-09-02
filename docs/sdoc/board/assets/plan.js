// The Plan view: the canon as a collapsible tree, the selected node's full
// card in the right pane. Groups are the declaring directories (paths serve
// navigation -- WORK-PATH-NOT-LOAD-BEARING owns making that the ONLY thing
// they serve). Within a group a node nests under the same-group node it
// Assumes -- the carve of docs/plans/shared-understanding/ writes exactly
// that edge for its tiers; elsewhere most nodes sit flat. Cycle-guarded:
// a node already placed never nests again.
import { colorOf, htmlNode, renderNodeCard } from "/assets/card.js";

const elements = {
  tree: document.querySelector("#plan-tree"),
  inspectorEmpty: document.querySelector("#plan-inspector-empty"),
  inspectorContent: document.querySelector("#plan-inspector-content"),
};

let snapshot;
let selected = null;

function byDir(nodes) {
  const groups = new Map();
  for (const node of nodes) {
    const path = node.source.path || "unknown";
    const dir = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : ".";
    if (!groups.has(dir)) groups.set(dir, []);
    groups.get(dir).push(node);
  }
  return groups;
}

function childrenWithin(group) {
  // uid -> nodes that Assume it, both ends inside this group
  const ids = new Set(group.map((node) => node.id));
  const children = new Map();
  const placed = new Set();
  for (const edge of snapshot.edges) {
    if (edge.role !== "Assumes") continue;
    if (!ids.has(edge.source) || !ids.has(edge.target)) continue;
    if (placed.has(edge.source)) continue; // first parent wins, no cycles
    if (edge.source === edge.target) continue;
    placed.add(edge.source);
    if (!children.has(edge.target)) children.set(edge.target, []);
    children.get(edge.target).push(edge.source);
  }
  // a cycle would leave every member "placed"; break it by unplacing any
  // node that is an ancestor of itself
  const roots = group.filter((node) => !placed.has(node.id));
  if (!roots.length && group.length)
    return { children: new Map(), placed: new Set() };
  return { children, placed };
}

function row(node) {
  const label = htmlNode("button", "plan-row");
  label.type = "button";
  label.dataset.id = node.id;
  label.style.setProperty("--accent", colorOf(node.type));
  label.append(
    htmlNode("span", "plan-dot"),
    htmlNode("span", "plan-uid", node.id),
    htmlNode("span", "plan-title", node.title),
  );
  if (node.state) {
    label.append(htmlNode("span", "plan-state", node.state.value));
  }
  label.addEventListener("click", () => selectPlanNode(node.id));
  return label;
}

function renderTreeNode(node, children, byId) {
  const kids = (children.get(node.id) || []).sort();
  if (!kids.length) {
    const leaf = htmlNode("div", "plan-leaf");
    leaf.append(row(node));
    return leaf;
  }
  const details = htmlNode("details", "plan-branch");
  details.open = true;
  const summary = htmlNode("summary");
  summary.append(row(node));
  details.append(summary);
  const nest = htmlNode("div", "plan-nest");
  for (const kid of kids) {
    nest.append(renderTreeNode(byId.get(kid), children, byId));
  }
  details.append(nest);
  return details;
}

function renderGroup(dir, group, openByDefault) {
  const byId = new Map(group.map((node) => [node.id, node]));
  const { children, placed } = childrenWithin(group);
  const details = htmlNode("details", "plan-group");
  details.dataset.dir = dir;
  details.open = openByDefault;
  const summary = htmlNode("summary");
  summary.append(
    htmlNode("span", "plan-group-dir", dir),
    htmlNode("span", "plan-group-count", `${group.length}`),
  );
  details.append(summary);
  const body = htmlNode("div", "plan-group-body");
  const roots = group.filter((node) => !placed.has(node.id));
  const ordered = roots.length ? roots : group;
  for (const node of ordered.sort((a, b) => a.id.localeCompare(b.id))) {
    body.append(renderTreeNode(node, children, byId));
  }
  details.append(body);
  return details;
}

export function selectPlanNode(id, { updateHash = true } = {}) {
  const node = snapshot?.nodes.find((candidate) => candidate.id === id);
  if (!node) return;
  selected = id;
  for (const item of elements.tree.querySelectorAll(".plan-row")) {
    item.classList.toggle("is-selected", item.dataset.id === id);
  }
  const item = elements.tree.querySelector(
    `.plan-row[data-id="${CSS.escape(id)}"]`,
  );
  if (item) {
    for (
      let open = item.closest("details");
      open;
      open = open.parentElement?.closest("details")
    ) {
      open.open = true;
    }
    item.scrollIntoView({ block: "nearest" });
  }
  renderNodeCard(snapshot, node, elements.inspectorContent, {
    onSelect: selectPlanNode,
  });
  elements.inspectorEmpty.hidden = true;
  elements.inspectorContent.hidden = false;
  if (updateHash) {
    history.replaceState(
      null,
      "",
      `${location.search}#${encodeURIComponent(id)}`,
    );
  }
}

export function renderPlan(nextSnapshot) {
  snapshot = nextSnapshot;
  const groups = [...byDir(snapshot.nodes).entries()].sort(([a], [b]) =>
    a.localeCompare(b),
  );
  const fragments = document.createDocumentFragment();
  for (const [dir, group] of groups) {
    fragments.append(
      renderGroup(dir, group, dir === "docs/plans/shared-understanding"),
    );
  }
  elements.tree.replaceChildren(fragments);
  const requested = decodeURIComponent(location.hash.slice(1));
  if (requested) selectPlanNode(requested, { updateHash: false });
  else if (selected) selectPlanNode(selected, { updateHash: false });
}
