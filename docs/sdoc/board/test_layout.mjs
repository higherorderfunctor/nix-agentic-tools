import assert from "node:assert/strict";

import { CARD, layoutGraph } from "./assets/layout.js";

const snapshot = {
  nodes: ["A", "B", "C", "D", "E"].map((id) => ({ id })),
  edges: [
    { source: "A", target: "B" },
    { source: "B", target: "C" },
    { source: "C", target: "A" },
    { source: "C", target: "D" },
    { source: "D", target: "E" },
    { source: "D", target: "E" },
  ],
};

const first = layoutGraph(snapshot);
const second = layoutGraph(snapshot);

assert.deepEqual(first, second, "unchanged input must receive a stable layout");
assert.equal(Object.keys(first.positions).length, snapshot.nodes.length);
assert.ok(
  first.components.some(
    (component) => component.length === 3 && component.includes("A"),
  ),
  "the A-B-C cycle must survive as one strongly connected component",
);
assert.ok(first.positions.D.rank > first.positions.A.rank);
assert.ok(first.positions.E.rank > first.positions.D.rank);
for (const position of Object.values(first.positions)) {
  assert.ok(Number.isFinite(position.x));
  assert.ok(Number.isFinite(position.y));
}
assert.ok(first.bounds.width > CARD.width);
assert.ok(first.bounds.height > CARD.height);

console.log("layout contract: 5 nodes, cyclic input, deterministic positions");
