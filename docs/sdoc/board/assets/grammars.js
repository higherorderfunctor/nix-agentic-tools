// The Grammars view: one uniform card per grammar element, grouped by the
// hand-authored layout in grammar-groups.json -- a section is a top-level
// heading over a rule, a group a subtitle over centered cards or the axis
// grid -- with the full declaration in the right-hand pane on selection:
// fields with kinds, choice words and required flags, and the relation
// roles the element may write. Data is the snapshot's `grammar` key (parsed
// from grammar.sgra; the JSON export types every field as String, which is
// why the .sgra is the source here).
//
// The layout is hand-authored, which REQ-BOARD-GRAMMAR-DRIVEN otherwise
// forbids, so it is guarded twice: dev/scripts/grammar-groups-check.py in
// nix flake check, and checkGroups() here on every render. A finding raises
// the red banner at the top of the tab and never hides a type -- whatever
// the layout leaves out lands in Unsorted.
//
// The one-line glosses under the axis words and the card titles are prose
// the layout carries verbatim from the canon (its $comment names the
// sources); they are drawn as given and never composed here.
//
// The inspector's last two sections come from the snapshot's `semantics`
// key, not from the .sgra: the grammar says a type HAS a STATUS field with
// four words in it, and the semantics engine says which of those words a
// node may move to next, and under what rule. Rules first, then the machine
// each rule is about -- an operator shaping the model reads the sentence
// before the diagram. Both sections degrade to a named absence: no engine,
// no machine for this type, or a machine with no rules yet all render a
// section that says so, because a missing section reads as "settled" and
// nothing here is.
import { colorOf, htmlNode } from "/assets/card.js";
import { layoutMachines, machineFigure } from "/assets/fsm.js";

const elements = {
  grid: document.querySelector("#grammar-grid"),
  inspectorEmpty: document.querySelector("#grammar-inspector-empty"),
  inspectorContent: document.querySelector("#grammar-inspector-content"),
};

const REST = "rest";
const WIDGETS = new Set(["cards", "grid"]);

let snapshot;
let selected = null;

function nodeCount(tag) {
  return snapshot.stats.types[tag] ?? 0;
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function asList(value) {
  return Array.isArray(value) ? value : [];
}

function cellKey(row, column) {
  return `${row} ${column}`;
}

function sectionLabel(section, index) {
  return section?.title != null
    ? String(section.title)
    : `section ${index + 1}`;
}

function groupLabel(section, group, sectionIndex, groupIndex) {
  const own =
    group?.title != null ? String(group.title) : `group ${groupIndex + 1}`;
  return `${sectionLabel(section, sectionIndex)} / ${own}`;
}

// Every TAG the layout places, so the check and the renderer walk one
// definition of "placed". A grid entry whose position is not a [row, column]
// of the axes is still placed (the position is what is invalid), and the
// renderer draws it beside the matrix rather than losing it.
function* placements(layout) {
  for (const section of asList(layout?.sections)) {
    for (const group of asList(section?.groups)) {
      if (!isObject(group)) continue;
      if (group.widget === "grid" && isObject(group.cells)) {
        yield* Object.keys(group.cells);
      } else if (group.widget === "cards" && Array.isArray(group.types)) {
        yield* group.types;
      }
    }
  }
}

function gridCells(group) {
  const rows = asList(group.axes?.rows).map(String);
  const columns = asList(group.axes?.columns).map(String);
  const at = new Map();
  const misplaced = [];
  const cells = isObject(group.cells) ? group.cells : {};
  for (const [tag, position] of Object.entries(cells)) {
    const placed =
      Array.isArray(position) &&
      position.length === 2 &&
      rows.includes(String(position[0])) &&
      columns.includes(String(position[1]));
    if (!placed) {
      misplaced.push(tag);
      continue;
    }
    const key = cellKey(position[0], position[1]);
    at.set(key, [...(at.get(key) ?? []), tag]);
  }
  return { at, columns, misplaced, rows };
}

// A group's optional "glosses" map (name -> sentence), and the axes' own,
// read defensively: anything that is not a non-empty string draws nothing.
function glossOf(owner, name) {
  const gloss = isObject(owner?.glosses) ? owner.glosses[name] : undefined;
  return typeof gloss === "string" && gloss.trim() ? gloss : null;
}

// Gloss keys that name nothing the owner places: the check's rule, mirrored
// so the banner shows what the tab would otherwise silently drop.
function strayGlosses(owner, allowed) {
  if (!isObject(owner?.glosses)) return [];
  return Object.keys(owner.glosses).filter((name) => !allowed.has(name));
}

// The runtime guard. Pure: the layout object and the grammar's TAG names in,
// the findings out -- missing (in the grammar, placed nowhere, and no "rest"
// group to catch it), stale (placed, not in the grammar), duplicate (placed
// twice), unfilled (an axis pair no cell fills) and invalid (a shape the
// page would otherwise have to guess at). Every list is empty on a clean
// layout. Mirrors dev/scripts/grammar-groups-check.py; keep them in step.
export function checkGroups(layout, typeNames) {
  const findings = {
    duplicate: [],
    invalid: [],
    missing: [],
    stale: [],
    unfilled: [],
  };
  if (!isObject(layout) || !Array.isArray(layout.sections)) {
    findings.invalid.push("the layout needs a sections list");
    findings.missing.push(...typeNames);
    return findings;
  }
  const placedAnywhere = new Set(placements(layout));
  const restTypes = new Set(
    typeNames.filter((tag) => !placedAnywhere.has(tag)),
  );
  const glossFindings = (label, owner, allowed, what) => {
    if (owner?.glosses !== undefined && !isObject(owner.glosses)) {
      findings.invalid.push(`${label}: glosses must map names to sentences`);
      return;
    }
    for (const name of strayGlosses(owner, allowed)) {
      findings.invalid.push(`${label}: ${name} has a gloss but is not ${what}`);
    }
  };
  let rests = 0;
  layout.sections.forEach((section, s) => {
    if (!isObject(section) || !Array.isArray(section.groups)) {
      findings.invalid.push(`${sectionLabel(section, s)}: needs a groups list`);
      return;
    }
    section.groups.forEach((group, g) => {
      const label = groupLabel(section, group, s, g);
      if (!isObject(group) || !WIDGETS.has(group.widget)) {
        findings.invalid.push(`${label}: widget must be "cards" or "grid"`);
        return;
      }
      if (group.widget === "grid") {
        const { at, columns, misplaced, rows } = gridCells(group);
        if (rows.length !== 2 || columns.length !== 2) {
          findings.invalid.push(`${label}: axes need two rows and two columns`);
        }
        if (!isObject(group.cells)) {
          findings.invalid.push(
            `${label}: cells must map TAG to [row, column]`,
          );
        }
        glossFindings(
          label,
          group.axes,
          new Set([...rows, ...columns]),
          "a word of this grid's axes",
        );
        glossFindings(
          label,
          group,
          new Set(Object.keys(isObject(group.cells) ? group.cells : {})),
          "a type in a cell of this grid",
        );
        for (const tag of misplaced) {
          const position = JSON.stringify(group.cells[tag]);
          findings.invalid.push(
            `${label}: ${tag} sits at ${position}, not a [row, column] of the axes`,
          );
        }
        for (const row of rows) {
          for (const column of columns) {
            const tags = at.get(cellKey(row, column)) ?? [];
            if (!tags.length) {
              findings.unfilled.push(`${label}: ${row} × ${column}`);
            } else if (tags.length > 1) {
              findings.invalid.push(
                `${label}: ${row} × ${column} holds ${tags.join(", ")}`,
              );
            }
          }
        }
      } else if (group.types === REST) {
        rests += 1;
        if (rests > 1)
          findings.invalid.push(`${label}: "rest" may appear once`);
        glossFindings(label, group, restTypes, 'a type the "rest" absorbs');
      } else if (!Array.isArray(group.types)) {
        findings.invalid.push(
          `${label}: types must be a list of TAGs or "rest"`,
        );
      } else {
        glossFindings(
          label,
          group,
          new Set(group.types),
          "a type this group lists",
        );
      }
    });
  });
  const counts = new Map();
  for (const tag of placements(layout)) {
    counts.set(tag, (counts.get(tag) ?? 0) + 1);
  }
  const known = new Set(typeNames);
  for (const [tag, count] of counts) {
    if (count > 1) findings.duplicate.push(tag);
    if (!known.has(tag)) findings.stale.push(tag);
    if (typeof tag === "string" && tag.endsWith("-")) {
      findings.invalid.push(`${tag}: looks like a UID prefix, not a TAG`);
    }
  }
  if (!rests) {
    findings.missing.push(...typeNames.filter((tag) => !counts.has(tag)));
  }
  return findings;
}

function card(tag, element, gloss) {
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
  // The middle band is drawn whether or not the type carries a gloss: it is
  // the box fitCards() measures against, and an empty one still holds the
  // facts down on the card's floor.
  const body = htmlNode("div", "grammar-card-body");
  if (gloss) body.append(htmlNode("p", "grammar-card-gloss", gloss));
  item.append(head, body, facts);
  item.addEventListener("click", () => selectGrammar(tag));
  return item;
}

// A placed name the grammar does not declare: drawn where the layout put it
// so the stale entry is visible in place, but not a .grammar-card, so it
// cannot be selected.
function ghost(tag) {
  const item = htmlNode("div", "grammar-ghost");
  item.dataset.tag = tag;
  item.append(
    htmlNode("strong", null, String(tag)),
    htmlNode("span", null, "not in the grammar"),
  );
  return item;
}

function typeCard(tag, owner) {
  const element = snapshot.grammar[tag];
  return element ? card(tag, element, glossOf(owner, tag)) : ghost(tag);
}

function cardRow(tags, emptyText, owner) {
  if (!tags.length) return htmlNode("p", "grammar-empty", emptyText);
  const row = htmlNode("div", "grammar-cards");
  for (const tag of tags) row.append(typeCard(tag, owner));
  return row;
}

// An axis label: the word, and its gloss when the axes carry one. The
// column reads "UNIVERSAL -- EVERY CASE" on one line; the row label is the
// same two spans stood on end down the left edge (CSS does the turning).
function axisLabel(axes, word, orientation) {
  const wrapper = htmlNode("div", `grammar-axis grammar-axis-${orientation}`);
  const label = htmlNode("span", "grammar-axis-label");
  label.append(htmlNode("span", "grammar-axis-word", word));
  const gloss = glossOf(axes, word);
  if (gloss) label.append(htmlNode("span", "grammar-axis-gloss", gloss));
  wrapper.append(label);
  return wrapper;
}

function matrix(group) {
  const { at, columns, misplaced, rows } = gridCells(group);
  const widget = htmlNode("div", "grammar-matrix");
  widget.style.setProperty("--columns", String(columns.length));
  widget.append(htmlNode("div", "grammar-axis-corner"));
  for (const column of columns) {
    widget.append(axisLabel(group.axes, column, "column"));
  }
  for (const row of rows) {
    widget.append(axisLabel(group.axes, row, "row"));
    for (const column of columns) {
      const cell = htmlNode("div", "grammar-cell");
      cell.dataset.row = row;
      cell.dataset.column = column;
      const tags = at.get(cellKey(row, column)) ?? [];
      if (!tags.length) {
        cell.classList.add("is-empty");
        cell.append(htmlNode("span", null, "unfilled"));
      }
      for (const tag of tags) cell.append(typeCard(tag, group));
      widget.append(cell);
    }
  }
  const parts = [widget];
  if (misplaced.length) {
    parts.push(
      htmlNode("p", "grammar-note", "placed outside the axes:"),
      cardRow(misplaced, "", group),
    );
  }
  return parts;
}

function renderGroup(group, context) {
  const wrapper = htmlNode("section", "grammar-group");
  if (group?.title != null) {
    wrapper.append(htmlNode("h2", "grammar-group-title", String(group.title)));
  }
  if (!isObject(group) || !WIDGETS.has(group.widget)) {
    wrapper.append(
      htmlNode("p", "grammar-note", 'widget must be "cards" or "grid"'),
    );
  } else if (group.widget === "grid") {
    wrapper.append(...matrix(group));
  } else if (group.types === REST) {
    wrapper.append(
      context.restUsed
        ? cardRow([], '"rest" was already drawn above')
        : cardRow(
            context.rest,
            "nothing unsorted · every type is placed",
            group,
          ),
    );
    context.restUsed = true;
  } else {
    wrapper.append(cardRow(asList(group.types), "no types listed", group));
  }
  return wrapper;
}

function renderSection(section, index, context) {
  const wrapper = htmlNode("section", "grammar-section");
  wrapper.append(
    htmlNode("h1", "grammar-section-title", sectionLabel(section, index)),
    htmlNode("hr", "grammar-rule"),
  );
  for (const group of asList(section?.groups)) {
    wrapper.append(renderGroup(group, context));
  }
  return wrapper;
}

function banner(findings) {
  const box = htmlNode("div", "grammar-banner");
  box.id = "grammar-banner";
  box.setAttribute("role", "alert");
  const lines = [];
  if (findings.missing.length) {
    lines.push(
      `not placed by the layout, drawn under Unsorted: ${findings.missing.join(", ")}`,
    );
  }
  if (findings.stale.length) {
    lines.push(`stale · not in the grammar: ${findings.stale.join(", ")}`);
  }
  if (findings.duplicate.length) {
    lines.push(`placed more than once: ${findings.duplicate.join(", ")}`);
  }
  for (const cell of findings.unfilled) lines.push(`unfilled cell: ${cell}`);
  for (const reason of findings.invalid) lines.push(`invalid: ${reason}`);
  box.hidden = !lines.length;
  if (lines.length) {
    const list = htmlNode("ul");
    for (const line of lines) list.append(htmlNode("li", null, line));
    box.append(
      htmlNode(
        "strong",
        null,
        "grammar-groups.json does not match the grammar",
      ),
      list,
    );
  }
  return box;
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

// The semantics payload keys machines by FIELD and indexes them by type, so
// the inspector never has to know which fields a type carries -- that answer
// is the engine's, computed from the same parsed grammar.
function machinesFor(tag) {
  const semantics = snapshot.semantics ?? {};
  const fields = semantics.by_type?.[tag] ?? [];
  return fields
    .map((field) => semantics.machines?.[field])
    .filter((machine) => machine);
}

function ruleItem(rule, field) {
  const item = htmlNode("li", "rule-item");
  // `settled: false` is the engine saying "this is written down, not
  // decided". It rides as a dashed edge on the row rather than a second
  // pill, so the pill keeps meaning one thing: where the rule came from.
  if (rule.settled === false) item.classList.add("is-unsettled");
  const head = htmlNode("div", "rule-head");
  head.append(
    htmlNode("span", "rule-field", field),
    htmlNode("span", "rule-id", rule.id),
    htmlNode("span", `rule-kind is-${rule.kind}`, rule.kind),
  );
  item.append(head, htmlNode("div", "rule-text", rule.text));
  if (rule.cites?.length) {
    const cites = htmlNode("div", "rule-cites");
    for (const uid of rule.cites)
      cites.append(htmlNode("span", "rule-cite", uid));
    item.append(cites);
  }
  return item;
}

function noteItem(text, className) {
  const list = htmlNode("ul", "rule-list");
  list.append(
    htmlNode("li", className ? `rule-note ${className}` : "rule-note", text),
  );
  return list;
}

function rulesSection(tag, machines) {
  const unavailable = snapshot.semantics?.unavailable;
  if (unavailable) {
    return section(
      "Rules · unavailable",
      noteItem(unavailable, "is-unavailable"),
    );
  }
  const rules = machines.flatMap((machine) =>
    (machine.rules ?? []).map((rule) => ({ field: machine.field, rule })),
  );
  if (!rules.length) {
    return section(
      "Rules · 0",
      noteItem(`No lifecycle rule is recorded for ${tag} yet.`),
    );
  }
  const list = htmlNode("ul", "rule-list");
  for (const entry of rules) list.append(ruleItem(entry.rule, entry.field));
  return section(`Rules · ${rules.length}`, list);
}

function lifecycleSection(tag, machines) {
  if (snapshot.semantics?.unavailable) {
    return section(
      "Lifecycle · unavailable",
      noteItem(
        "The semantics engine did not load; see Rules.",
        "is-unavailable",
      ),
    );
  }
  if (!machines.length) {
    return section(
      "Lifecycle · 0",
      noteItem(`No state field of ${tag} has a machine yet.`),
    );
  }
  const wrapper = htmlNode("div", "fsm-list");
  for (const machine of machines) wrapper.append(machineFigure(machine));
  return section(`Lifecycle · ${machines.length}`, wrapper);
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

  const machines = machinesFor(tag);
  elements.inspectorContent.replaceChildren(
    head,
    section(`Fields · ${element.fields.length}`, fields),
    section(`Relations it may write · ${element.roles.length}`, roles),
    rulesSection(tag, machines),
    lifecycleSection(tag, machines),
  );
  elements.inspectorEmpty.hidden = true;
  elements.inspectorContent.hidden = false;
  // Only now does a figure know how wide it is; see fsm.js's header.
  elements.inspectorContent.style.setProperty("--accent", colorOf(tag));
  layoutMachines(elements.inspectorContent);
}

export function selectGrammar(tag) {
  if (!snapshot?.grammar[tag]) return;
  selected = tag;
  for (const item of elements.grid.querySelectorAll(".grammar-card")) {
    item.classList.toggle("is-selected", item.dataset.tag === tag);
  }
  renderInspector(tag);
}

// ---- one height for every card on the tab ------------------------------
//
// Two requirements CSS cannot express on its own. Every card must render
// the same height -- but the tab's cards sit in three different formatting
// contexts (the axis grid, and a centred flex row per "cards" group), and
// no single CSS box equalizes across those, which is why the grid's own
// `1fr` rows only ever levelled the Definition group. And an oversized
// gloss must cost FONT SIZE before it costs height, for which there is no
// property at all. So the page measures, in two batched passes:
//
//   1. Release the shared height and set every gloss to the ramp FLOOR.
//      Each card is then as short as it can be, and the tallest of those
//      is the shared height: the tightest one that fits every card without
//      any gloss going under 10px.
//   2. Apply that height everywhere, then walk the ramp from the top,
//      writing one step across all glosses still overflowing and reading
//      back which now fit. A card that fits at a step keeps it; the rest
//      drop to the next. By construction the floor always fits, since
//      pass 1 sized the card for exactly that.
//
// Idempotent: pass 1 discards the previous run's state before it measures,
// so re-running settles on the same number rather than ratcheting up. Each
// pass writes every card before it reads any, so the layout flushes once
// per ramp step (at most four) rather than once per card.
const RAMP = ["--fs-body", "--fs-meta", "--fs-small", "--fs-micro"];
const FLOOR_PX = 10;
const REFIT_MS = 100;

// The ramp resolved to px, largest first. Read off a probe rather than
// recomputed from --fs-base, so app.css stays the one definition of the
// steps. A token the knob has pushed under the floor is dropped: app.css's
// ramp says nothing renders below 10px, and that holds here too.
function rampSteps(root) {
  const probe = htmlNode("span");
  probe.style.cssText =
    "position:absolute;visibility:hidden;pointer-events:none;";
  root.append(probe);
  const sizes = new Set();
  for (const token of RAMP) {
    probe.style.fontSize = `var(${token})`;
    const px = Number.parseFloat(getComputedStyle(probe).fontSize);
    if (Number.isFinite(px) && px >= FLOOR_PX) sizes.add(px);
  }
  probe.remove();
  const steps = [...sizes].sort((a, b) => b - a);
  return steps.length ? steps : [FLOOR_PX];
}

// Returns the height it settled on, or null when there was nothing to
// measure -- a hidden tab has no width, and measuring it would set every
// card to the height of a zero-width column.
function fitCards() {
  const root = elements.grid;
  if (!root?.isConnected || !root.clientWidth) return null;
  const cards = [...root.querySelectorAll(".grammar-card")];
  if (!cards.length) {
    root.style.removeProperty("--card-h");
    return null;
  }
  const steps = rampSteps(root);
  const floor = steps[steps.length - 1];
  const parts = cards.map((item) => ({
    body: item.querySelector(".grammar-card-body"),
    card: item,
    gloss: item.querySelector(".grammar-card-gloss"),
  }));

  root.style.setProperty("--card-h", "auto");
  for (const part of parts) {
    if (part.gloss) part.gloss.style.fontSize = `${floor}px`;
  }
  // Rounded up: a fractional height leaves a sub-pixel overflow behind,
  // and the whole point of pass 1 is that the floor is guaranteed to fit.
  const height = Math.ceil(
    Math.max(...parts.map((part) => part.card.getBoundingClientRect().height)),
  );
  root.style.setProperty("--card-h", `${height}px`);

  let pending = parts.filter((part) => part.gloss && part.body);
  for (const size of steps) {
    if (!pending.length) break;
    for (const part of pending) part.gloss.style.fontSize = `${size}px`;
    pending = pending.filter(
      (part) => part.gloss.offsetHeight > part.body.clientHeight,
    );
  }
  return height;
}

// The tab's width decides how many lines a gloss takes, so a width change
// invalidates the fit. Height changes do NOT -- those are this function's
// own doing, and re-fitting on them would loop forever, which is what the
// width guard in the observer is for. Web fonts landing after first paint
// change the line count too, hence document.fonts.ready.
let fitWidth = null;
let fitTimer = 0;

function runFit() {
  fitWidth = elements.grid?.clientWidth ?? null;
  return fitCards();
}

function scheduleFit() {
  clearTimeout(fitTimer);
  fitTimer = setTimeout(runFit, REFIT_MS);
}

if (elements.grid) {
  new ResizeObserver(() => {
    if (elements.grid.clientWidth !== fitWidth) scheduleFit();
  }).observe(elements.grid);
  document.fonts?.ready.then(runFit);
}

// `groups` is app.js's cached fetch of grammar-groups.json, {layout, error}.
// An unreadable layout is a finding, not an exception: the tab still draws
// every type, all of them under a synthetic Unsorted.
export function renderGrammars(nextSnapshot, groups = {}) {
  snapshot = nextSnapshot;
  const types = Object.keys(snapshot.grammar).sort();
  const layout = groups.layout ?? null;
  const findings = groups.error
    ? {
        duplicate: [],
        invalid: [groups.error],
        missing: types,
        stale: [],
        unfilled: [],
      }
    : checkGroups(layout, types);
  window.boardGrammarGroups.layout = layout;
  window.boardGrammarGroups.types = types;

  const placed = new Set(placements(layout));
  const context = {
    rest: types.filter((tag) => !placed.has(tag)),
    restUsed: false,
  };
  const sections = Array.isArray(layout?.sections) ? layout.sections : [];
  const outline = sections.map((section, index) =>
    renderSection(section, index, context),
  );
  if (findings.missing.length) {
    const extra = { title: null, types: findings.missing, widget: "cards" };
    const unsorted = sections.findIndex(
      (section) => section?.title === "Unsorted",
    );
    if (unsorted >= 0) {
      outline[unsorted].append(renderGroup(extra, context));
    } else {
      outline.push(
        renderSection(
          { groups: [extra], title: "Unsorted" },
          outline.length,
          context,
        ),
      );
    }
  }
  elements.grid.replaceChildren(banner(findings), ...outline);
  if (selected) selectGrammar(selected);
  runFit();
}

// For a verifier or the operator's console: the guard itself, plus what the
// last render ran it over, so a mutated layout can be checked in-page
// without editing a file. `fit` re-runs the card fit and hands back the
// height it settled on -- calling it twice must give the same answer.
window.boardGrammarGroups = {
  check: checkGroups,
  fit: runFit,
  layout: null,
  types: [],
};
