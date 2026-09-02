// The Grammars view: one uniform card per grammar element on a grid, the
// full declaration in the right-hand pane on selection -- fields with kinds,
// choice words and required flags, and the relation roles the element may
// write. Data is the snapshot's `grammar` key (parsed from grammar.sgra;
// the JSON export types every field as String, which is why the .sgra is
// the source here).
import { colorOf } from "/assets/card.js";

const elements = {
  grid: document.querySelector("#grammar-grid"),
  inspectorEmpty: document.querySelector("#grammar-inspector-empty"),
  inspectorContent: document.querySelector("#grammar-inspector-content"),
};

let snapshot;
let selected = null;

function htmlNode(name, className, text) {
  const node = document.createElement(name);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function nodeCount(tag) {
  return snapshot.stats.types[tag] ?? 0;
}

function card(tag, element) {
  const item = htmlNode("button", "grammar-card");
  item.type = "button";
  item.dataset.tag = tag;
  item.style.setProperty("--accent", colorOf(tag));
  const head = htmlNode("div", "grammar-card-head");
  head.append(
    htmlNode("span", "grammar-card-tag", tag),
    htmlNode("span", "grammar-card-prefix", element.prefix || "no prefix"),
  );
  const facts = htmlNode("dl", "grammar-card-facts");
  for (const [label, value] of [
    ["fields", element.fields.length],
    ["roles", element.roles.length],
    ["nodes", nodeCount(tag)],
  ]) {
    const fact = htmlNode("div");
    fact.append(
      htmlNode("dt", null, label),
      htmlNode("dd", null, String(value)),
    );
    facts.append(fact);
  }
  item.append(head, facts);
  item.addEventListener("click", () => selectGrammar(tag));
  return item;
}

function fieldItem(field) {
  const item = htmlNode("li", "grammar-field");
  const head = htmlNode("div", "grammar-field-head");
  head.append(
    htmlNode("span", "grammar-field-name", field.name),
    htmlNode("span", "grammar-field-kind", field.kind),
    htmlNode(
      "span",
      field.required ? "grammar-required" : "grammar-optional",
      field.required ? "required" : "optional",
    ),
  );
  item.append(head);
  if (field.options.length) {
    const words = htmlNode("div", "grammar-options");
    for (const option of field.options) {
      words.append(htmlNode("span", "grammar-option", option));
    }
    item.append(words);
  }
  return item;
}

function roleItem(role) {
  const item = htmlNode("li");
  item.append(
    htmlNode("span", "relation-role", role.role || role.type),
    htmlNode("span", "relation-target", role.type),
  );
  return item;
}

function section(title, list) {
  const wrapper = htmlNode("section", "inspector-section");
  wrapper.append(htmlNode("h2", null, title));
  wrapper.append(list);
  return wrapper;
}

function renderInspector(tag) {
  const element = snapshot.grammar[tag];
  const head = htmlNode("header", "inspector-head");
  head.style.setProperty("--accent", colorOf(tag));
  const kicker = htmlNode("div", "inspector-kicker");
  kicker.append(
    htmlNode("span", null, tag),
    htmlNode("span", null, `${nodeCount(tag)} nodes`),
  );
  head.append(
    kicker,
    htmlNode("h1", null, tag),
    htmlNode(
      "div",
      "inspector-uid",
      element.prefix ? `UID prefix ${element.prefix}` : "no UID prefix",
    ),
    htmlNode("div", "inspector-source", "docs/sdoc/grammar.sgra"),
  );

  const fields = htmlNode("ul", "grammar-field-list");
  for (const field of element.fields) fields.append(fieldItem(field));
  const roles = htmlNode("ul", "relation-list");
  for (const role of element.roles) roles.append(roleItem(role));
  if (!element.roles.length) roles.append(htmlNode("li", null, "None"));

  elements.inspectorContent.replaceChildren(
    head,
    section(`Fields · ${element.fields.length}`, fields),
    section(`Relations it may write · ${element.roles.length}`, roles),
  );
  elements.inspectorEmpty.hidden = true;
  elements.inspectorContent.hidden = false;
}

export function selectGrammar(tag) {
  if (!snapshot?.grammar[tag]) return;
  selected = tag;
  for (const item of elements.grid.querySelectorAll(".grammar-card")) {
    item.classList.toggle("is-selected", item.dataset.tag === tag);
  }
  renderInspector(tag);
}

export function renderGrammars(nextSnapshot) {
  snapshot = nextSnapshot;
  const fragments = document.createDocumentFragment();
  for (const tag of Object.keys(snapshot.grammar).sort()) {
    fragments.append(card(tag, snapshot.grammar[tag]));
  }
  elements.grid.replaceChildren(fragments);
  if (selected) selectGrammar(selected);
}
