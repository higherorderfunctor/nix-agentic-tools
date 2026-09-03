// The lifecycle widget: one state field's machine, drawn as an inline SVG.
//
// Data is the snapshot's `semantics` key (schema sdoc-semantics/1), which the
// engine computes from the SAME parsed grammar the Grammars tab already
// renders. Nothing here knows a field name: DEPTH, STATUS, STANDING and
// AUTHORED_BY are data, and a machine the engine stops emitting stops being
// drawn (WORK-DEPTH-RENAME is live -- hard-coding a field name here would
// hard-code a rename).
//
// THE LAYOUT IS TRANSPOSED, on purpose. A transitions machine reads left to
// right; this pane is 350px wide and a six-rung ladder never fit that, so
// rank runs DOWN and branches spread ACROSS: one row per BFS depth from the
// initial state, siblings sharing the row's width. An ordered ladder becomes
// a straight vertical run, and a branching machine (STATUS: open -> accepted
// | rejected) fans into two boxes on one row.
//
// GEOMETRY IS MEASURED, NEVER SCALED. There is no viewBox: user units are
// CSS pixels, so nothing shrinks type below the 10px floor the app's ramp
// sets. That costs a second pass -- the widget cannot lay itself out until it
// knows its own width -- which is why `machineFigure()` returns an EMPTY svg
// and `layoutMachines(root)` fills it after the caller has mounted it.
// Labels are then measured with getComputedTextLength() and ellipsized to
// their box, so a long state word ("interface-settled") never bleeds past its
// border; the untruncated word stays in the box's <title>.
import { htmlNode } from "/assets/card.js";

// Type-coupled geometry in the same spirit as app.css's --u: these are the
// px they had at the 12px reading size. They are not tokens because SVG
// coordinates cannot carry a calc() of a custom property.
const BOX_HEIGHT = 30;
const RANK_GAP = 34; // enough vertical run to seat an edge label
const COLUMN_GAP = 10;
const TOP_PAD = 15; // the initial marker lives here
const BOTTOM_PAD = 6;
const LABEL_PAD = 14; // total horizontal breathing room inside a box
const SIDE_LANE = 18; // reserved right margin for a non-forward edge
const MIN_WIDTH = 180; // a floor for the pre-mount / zero-width case

const SVG_NS = "http://www.w3.org/2000/svg";

// Every mounted figure, so a resize (the inspector narrows to 290px under the
// app's own breakpoint) re-measures instead of keeping a stale width. Entries
// are dropped when their element leaves the document.
const mounted = new Set();
const machines = new WeakMap();
let markerSeq = 0;
let resizePending = false;

function svgNode(name, className) {
  const node = document.createElementNS(SVG_NS, name);
  if (className) node.setAttribute("class", className);
  return node;
}

function titled(node, text) {
  const title = svgNode("title");
  title.textContent = text;
  node.append(title);
  return node;
}

// Rank by LONGEST path from the initial state, not by BFS depth. The
// difference only shows on a machine with a shortcut -- two triggers out of
// `sketch`, one of them skipping a rung -- and there it is the difference
// between a readable drawing and a broken one: shortest-path puts both
// destinations on ONE row, which makes the rung-to-rung edge between them
// horizontal, unlabellable and routed around the outside. Longest-path
// guarantees every edge of an acyclic machine points strictly downward.
//
// A CYCLE cannot be layered this way, so the relaxation is capped at one
// pass per state; whatever edges still point up or sideways afterwards are
// the cycle's, and the drawing routes those out into the side lane.
//
// A state no transition can reach still gets drawn -- in a rank of its own
// past the deepest reachable one -- because "nothing enters this state" is
// exactly what the payload's diagnostics complain about, and hiding the
// state would hide the finding.
function ranksOf(machine) {
  const names = machine.states.map((state) => state.name);
  const known = new Set(names);
  const edges = machine.transitions.filter(
    (transition) => known.has(transition.source) && known.has(transition.dest),
  );
  const rank = new Map();
  if (known.has(machine.initial)) rank.set(machine.initial, 0);
  for (let pass = 0; pass < names.length; pass += 1) {
    let moved = false;
    for (const { source, dest } of edges) {
      if (!rank.has(source)) continue;
      const proposed = rank.get(source) + 1;
      if (!rank.has(dest) || rank.get(dest) < proposed) {
        rank.set(dest, proposed);
        moved = true;
      }
    }
    if (!moved) break;
  }
  const deepest = rank.size ? Math.max(...rank.values()) : -1;
  const unreachable = names.filter((name) => !rank.has(name));
  for (const name of unreachable) rank.set(name, deepest + 1);
  return { rank, unreachable: new Set(unreachable) };
}

function rowsOf(machine, rank) {
  const rows = [];
  for (const state of machine.states) {
    const index = rank.get(state.name) ?? 0;
    if (!rows[index]) rows[index] = [];
    rows[index].push(state);
  }
  return rows.filter(Boolean);
}

function fitText(node, full, maxWidth) {
  node.textContent = full;
  if (maxWidth <= 0 || node.getComputedTextLength() <= maxWidth) return;
  let text = full;
  while (text.length > 1) {
    text = text.slice(0, -1);
    node.textContent = `${text}…`;
    if (node.getComputedTextLength() <= maxWidth) return;
  }
}

function stateBox(state, box, machine, options) {
  const group = svgNode("g", "fsm-state");
  if (state.name === machine.initial) group.classList.add("is-initial");
  if ((machine.terminal ?? []).includes(state.name)) {
    group.classList.add("is-terminal");
  }
  if (options.unreachable.has(state.name))
    group.classList.add("is-unreachable");
  if (options.current === state.name) group.classList.add("is-current");

  const rect = svgNode("rect", "fsm-state-body");
  rect.setAttribute("x", box.x);
  rect.setAttribute("y", box.y);
  rect.setAttribute("width", box.width);
  rect.setAttribute("height", box.height);
  rect.setAttribute("rx", 7);
  group.append(rect);

  // UML's double border for a final state, drawn as an inset rect so the
  // terminal reading survives a theme that changes the stroke color.
  if (group.classList.contains("is-terminal")) {
    const inner = svgNode("rect", "fsm-state-inner");
    inner.setAttribute("x", box.x + 3);
    inner.setAttribute("y", box.y + 3);
    inner.setAttribute("width", Math.max(0, box.width - 6));
    inner.setAttribute("height", Math.max(0, box.height - 6));
    inner.setAttribute("rx", 4);
    group.append(inner);
  }

  const label = svgNode("text", "fsm-state-label");
  label.setAttribute("x", box.x + box.width / 2);
  label.setAttribute("y", box.y + box.height / 2);
  label.setAttribute("text-anchor", "middle");
  label.setAttribute("dominant-baseline", "central");
  group.append(label);

  const words = [state.label || state.name];
  if (state.note) words.push(state.note);
  titled(group, words.join(" — "));
  return { box, group, label, state };
}

function edgePath(from, to, geometry) {
  const path = svgNode("path", "fsm-edge-path");
  path.setAttribute("marker-end", `url(#${geometry.marker})`);
  if (to.box.y > from.box.y) {
    const x1 = from.box.x + from.box.width / 2;
    const y1 = from.box.y + from.box.height;
    const x2 = to.box.x + to.box.width / 2;
    const y2 = to.box.y;
    const bend = Math.max(6, (y2 - y1) / 2);
    path.setAttribute(
      "d",
      `M ${x1} ${y1} C ${x1} ${y1 + bend}, ${x2} ${y2 - bend}, ${x2} ${y2}`,
    );
    // In the FIRST gap under the source, not at the edge's midpoint. They
    // are the same point for a one-rung edge and very different for a
    // shortcut spanning two: the midpoint of THAT lands squarely on the
    // state it skips, printing the trigger over a state name.
    return {
      anchor: "middle",
      labelX: x1,
      labelY: y1 + Math.min(RANK_GAP, y2 - y1) / 2,
      path,
    };
  }
  // Backward or self: route out into the reserved right lane rather than
  // over the boxes, so a regression edge (should the operator decide DEPTH
  // may regress) is legible instead of hidden under a state.
  const lane = geometry.width - 2;
  const x1 = from.box.x + from.box.width;
  const y1 = from.box.y + from.box.height / 2;
  const x2 = to.box.x + to.box.width;
  const y2 = to.box.y + to.box.height / 2;
  path.setAttribute(
    "d",
    `M ${x1} ${y1} C ${lane} ${y1}, ${lane} ${y2}, ${x2} ${y2}`,
  );
  // Two boxes on ONE row have no midpoint that is not inside a box, so that
  // label goes above the row instead of over a state name.
  const sameRow = Math.abs(y1 - y2) < 1;
  return {
    anchor: "end",
    labelX: lane,
    labelY: sameRow ? y1 - BOX_HEIGHT / 2 - 8 : (y1 + y2) / 2,
    path,
  };
}

function arrowDefs(marker) {
  const defs = svgNode("defs");
  const node = svgNode("marker");
  node.setAttribute("id", marker);
  node.setAttribute("viewBox", "0 0 10 10");
  node.setAttribute("refX", "9");
  node.setAttribute("refY", "5");
  node.setAttribute("markerWidth", "6");
  node.setAttribute("markerHeight", "6");
  node.setAttribute("orient", "auto-start-reverse");
  const head = svgNode("path", "fsm-arrow-head");
  head.setAttribute("d", "M 0 1 L 9 5 L 0 9 z");
  node.append(head);
  defs.append(node);
  return defs;
}

function drawMachine(svg, machine, options) {
  const width = Math.max(MIN_WIDTH, svg.clientWidth || 0);
  const { rank, unreachable } = ranksOf(machine);
  const rows = rowsOf(machine, rank);
  const backward = machine.transitions.some(
    (transition) =>
      (rank.get(transition.dest) ?? 0) <= (rank.get(transition.source) ?? 0),
  );
  const content = width - (backward ? SIDE_LANE : 0);
  // Marker ids resolve per DOCUMENT, so two figures sharing one id would
  // share one arrowhead; the counter keeps each figure's own.
  markerSeq += 1;
  const marker = `fsm-arrow-${markerSeq}`;

  const boxes = new Map();
  rows.forEach((row, index) => {
    const boxWidth = (content - (row.length - 1) * COLUMN_GAP) / row.length;
    row.forEach((state, column) => {
      boxes.set(state.name, {
        state,
        box: {
          height: BOX_HEIGHT,
          width: boxWidth,
          x: column * (boxWidth + COLUMN_GAP),
          y: TOP_PAD + index * (BOX_HEIGHT + RANK_GAP),
        },
      });
    });
  });
  const height =
    TOP_PAD +
    rows.length * BOX_HEIGHT +
    Math.max(0, rows.length - 1) * RANK_GAP +
    BOTTOM_PAD;

  svg.replaceChildren(arrowDefs(marker));
  svg.setAttribute("height", height);
  svg.style.height = `${height}px`;
  svg.setAttribute("role", "img");
  svg.setAttribute(
    "aria-label",
    `${machine.field} lifecycle: ${machine.states.length} states, ${machine.transitions.length} transitions`,
  );

  // Three layers, and the order is load-bearing: arrows pass UNDER the state
  // boxes so a long route does not scribble over a word, and their labels sit
  // ON TOP of everything so the same route never hides its own trigger.
  const edgeLayer = svgNode("g", "fsm-edges");
  const stateLayer = svgNode("g", "fsm-states");
  const labelLayer = svgNode("g", "fsm-edge-labels");
  svg.append(edgeLayer, stateLayer, labelLayer);

  const placed = [];
  for (const transition of machine.transitions) {
    const from = boxes.get(transition.source);
    const to = boxes.get(transition.dest);
    if (!from || !to) continue;
    const group = svgNode("g", "fsm-edge");
    if (transition.settled === false) group.classList.add("is-unsettled");
    const drawn = edgePath(from, to, { marker, width });
    group.append(drawn.path);
    // The operator's own shape for an event, spelled out where a tooltip has
    // the room the arrow does not.
    const shape = `[event:${transition.trigger}] -> [state:${transition.dest}]`;
    const detail = transition.rule_text
      ? `${shape}\n${transition.rule_text}`
      : shape;
    titled(group, detail);
    edgeLayer.append(group);
    placed.push({ ...drawn, detail, transition });
  }

  // Two transitions leaving one rank put their labels on the same point --
  // one gap, two triggers, stacked illegibly (STATUS: accept and reject both
  // leave `open`). A gap carrying more than one spreads them across the row.
  const lanes = new Map();
  for (const item of placed) {
    const key = `${item.anchor}:${Math.round(item.labelY / 6)}`;
    if (!lanes.has(key)) lanes.set(key, []);
    lanes.get(key).push(item);
  }
  for (const lane of lanes.values()) {
    if (lane.length < 2) continue;
    lane.forEach((item, index) => {
      // A gap spreads its labels ACROSS; the side lane is one column wide, so
      // it stacks them UPWARD instead.
      if (item.anchor === "middle") {
        item.labelX = ((index + 0.5) * content) / lane.length;
      } else {
        item.labelY -= index * 11;
      }
    });
  }

  for (const item of placed) {
    const label = svgNode("text", "fsm-edge-label");
    label.setAttribute("x", item.labelX);
    label.setAttribute("y", item.labelY);
    label.setAttribute("text-anchor", item.anchor);
    label.setAttribute("dominant-baseline", "central");
    label.textContent = item.transition.trigger;
    if (item.transition.settled === false) label.classList.add("is-unsettled");
    titled(label, item.detail);
    labelLayer.append(label);
  }

  // The entry stub: a dot above the initial state, arrowed into its top edge.
  const start = boxes.get(machine.initial);
  if (start) {
    const cx = start.box.x + start.box.width / 2;
    const dot = svgNode("circle", "fsm-start-dot");
    dot.setAttribute("cx", cx);
    dot.setAttribute("cy", start.box.y - 10);
    dot.setAttribute("r", 3);
    const stub = svgNode("path", "fsm-edge-path");
    stub.setAttribute("marker-end", `url(#${marker})`);
    stub.setAttribute("d", `M ${cx} ${start.box.y - 7} L ${cx} ${start.box.y}`);
    edgeLayer.append(stub, dot);
  }

  const drawn = [];
  for (const entry of boxes.values()) {
    const rendered = stateBox(entry.state, entry.box, machine, {
      current: options.current,
      unreachable,
    });
    stateLayer.append(rendered.group);
    drawn.push(rendered);
  }
  // Measured only now: the text has to be in the document before
  // getComputedTextLength() answers anything but zero.
  for (const rendered of drawn) {
    fitText(
      rendered.label,
      rendered.state.label || rendered.state.name,
      rendered.box.width - LABEL_PAD,
    );
  }
}

function metaLine(machine) {
  const terminal = (machine.terminal ?? []).join(", ") || "none";
  return `initial ${machine.initial} · terminal ${terminal}`;
}

/** One machine as a mountable figure. The svg inside is EMPTY until
 * `layoutMachines()` runs over the mounted tree -- see the header. */
export function machineFigure(machine, options = {}) {
  const figure = htmlNode("figure", "fsm-figure");
  const head = htmlNode("div", "fsm-figure-head");
  head.append(
    htmlNode("span", "fsm-field", machine.field),
    htmlNode(
      "span",
      "fsm-counts",
      `${machine.states.length} states · ${machine.transitions.length} transitions`,
    ),
  );
  figure.append(head, htmlNode("div", "fsm-meta", metaLine(machine)));

  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("class", "fsm-svg");
  figure.append(svg);

  const diagnostics = machine.diagnostics ?? [];
  if (diagnostics.length) {
    const list = htmlNode("ul", "fsm-diagnostics");
    for (const message of diagnostics) {
      list.append(htmlNode("li", null, message));
    }
    figure.append(list);
  }

  machines.set(figure, { machine, options });
  return figure;
}

/** Lay out (or re-lay out) every figure under `root`. Call it AFTER the
 * figures are in the document; before that the pane's width is unknown and
 * text measures zero. */
export function layoutMachines(root) {
  for (const figure of root.querySelectorAll(".fsm-figure")) {
    const entry = machines.get(figure);
    if (!entry) continue;
    mounted.add(figure);
    drawMachine(figure.querySelector(".fsm-svg"), entry.machine, entry.options);
  }
  for (const figure of mounted) {
    if (!figure.isConnected) mounted.delete(figure);
  }
}

window.addEventListener("resize", () => {
  if (resizePending) return;
  resizePending = true;
  requestAnimationFrame(() => {
    resizePending = false;
    for (const figure of mounted) {
      if (!figure.isConnected) {
        mounted.delete(figure);
        continue;
      }
      const entry = machines.get(figure);
      if (entry) {
        drawMachine(
          figure.querySelector(".fsm-svg"),
          entry.machine,
          entry.options,
        );
      }
    }
  });
});
