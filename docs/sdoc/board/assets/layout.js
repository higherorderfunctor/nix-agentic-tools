export const CARD = Object.freeze({ width: 244, height: 102 });

const DEFAULTS = Object.freeze({
  card: CARD,
  depth: 1,
  margin: 60,
  maxNodes: 48,
  mergeThreshold: 3,
});
const ELK_API_URL = new URL("./vendor/elkjs/elk-api.js", import.meta.url).href;
const ELK_WORKER_URL = new URL(
  "./vendor/elkjs/elk-worker.min.js",
  import.meta.url,
).href;

let elkPromise;

async function elkEngine() {
  if (!elkPromise) {
    elkPromise = import(ELK_API_URL).then(() => {
      if (typeof globalThis.ELK !== "function") {
        throw new Error("the ELK API did not register itself");
      }
      return new globalThis.ELK({ workerUrl: ELK_WORKER_URL });
    });
  }
  return elkPromise;
}

function neighborhoodRanks(centerId, incoming, outgoing, depth) {
  const distances = new Map([[centerId, 0]]);
  const ranks = new Map([[centerId, 0]]);
  let leftCount = 0;
  let rightCount = 0;
  let frontier = [centerId];

  for (let distance = 1; distance <= depth && frontier.length; distance += 1) {
    const candidates = new Map();
    for (const id of frontier) {
      const neighbors = new Set([
        ...(incoming.get(id) ?? []),
        ...(outgoing.get(id) ?? []),
      ]);
      for (const neighbor of [...neighbors].sort()) {
        if (neighbor === centerId) continue;
        const knownDistance = distances.get(neighbor);
        if (knownDistance !== undefined && knownDistance < distance) continue;
        if (knownDistance === undefined) distances.set(neighbor, distance);
        if (distances.get(neighbor) !== distance) continue;
        const sides = candidates.get(neighbor) ?? new Set();
        if (id === centerId) {
          if (incoming.get(centerId)?.includes(neighbor)) sides.add(-1);
          if (outgoing.get(centerId)?.includes(neighbor)) sides.add(1);
        } else {
          sides.add(Math.sign(ranks.get(id)) || 1);
        }
        candidates.set(neighbor, sides);
      }
    }

    frontier = [...candidates.keys()].sort();
    for (const id of frontier) {
      const sides = candidates.get(id);
      let side;
      if (sides.size === 1) side = [...sides][0];
      else side = rightCount <= leftCount ? 1 : -1;
      ranks.set(id, side * distance);
      if (side < 0) leftCount += 1;
      else rightCount += 1;
    }
  }
  return ranks;
}

function selectNeighborhood(snapshot, centerId, depth, maxNodes) {
  const allNodes = new Map(snapshot.nodes.map((node) => [node.id, node]));
  if (!allNodes.has(centerId)) {
    return {
      nodes: [],
      edges: [],
      ranks: new Map(),
      clipped: 0,
      totalNodes: 0,
    };
  }

  const ids = [...allNodes.keys()].sort();
  const incoming = new Map(ids.map((id) => [id, []]));
  const outgoing = new Map(ids.map((id) => [id, []]));
  const validEdges = snapshot.edges.filter(
    (edge) => allNodes.has(edge.source) && allNodes.has(edge.target),
  );
  for (const edge of validEdges) {
    if (edge.source === edge.target) continue;
    incoming.get(edge.target).push(edge.source);
    outgoing.get(edge.source).push(edge.target);
  }
  for (const neighbors of [...incoming.values(), ...outgoing.values()]) {
    neighbors.sort();
  }

  const ranks = neighborhoodRanks(centerId, incoming, outgoing, depth);
  const neighborhoodIds = new Set(ranks.keys());
  const candidates = snapshot.nodes.filter((node) =>
    neighborhoodIds.has(node.id),
  );
  const totalNodes = candidates.length;
  const nodes =
    candidates.length <= maxNodes
      ? candidates
      : candidates
          .map((node) => ({
            id: node.id,
            node,
            rank: ranks.get(node.id) ?? 0,
          }))
          .sort(
            (left, right) =>
              Number(right.id === centerId) - Number(left.id === centerId) ||
              Math.abs(left.rank) - Math.abs(right.rank) ||
              Number(right.rank > 0) - Number(left.rank > 0) ||
              left.node.title.localeCompare(right.node.title) ||
              left.id.localeCompare(right.id),
          )
          .slice(0, maxNodes)
          .map(({ node }) => node);
  const keptIds = new Set(nodes.map((node) => node.id));
  const edges = validEdges.filter(
    (edge) => keptIds.has(edge.source) && keptIds.has(edge.target),
  );
  return {
    nodes,
    edges,
    ranks,
    clipped: totalNodes - nodes.length,
    totalNodes,
  };
}

function roleOf(edge) {
  return edge.role || edge.type || "Relation";
}

function groupedEdges(edges, minimumSize) {
  const records = edges.map((edge, index) => ({
    edge,
    key: edge.id || `semantic-${index}`,
  }));
  const assigned = new Set();
  const groups = [];

  function collect(direction) {
    const candidates = new Map();
    for (const record of records) {
      if (assigned.has(record.key) || record.edge.source === record.edge.target)
        continue;
      const endpoint =
        direction === "outgoing" ? record.edge.source : record.edge.target;
      const other =
        direction === "outgoing" ? record.edge.target : record.edge.source;
      const key = `${endpoint}\u0000${roleOf(record.edge)}`;
      const group = candidates.get(key) ?? {
        direction,
        endpoint,
        others: new Set(),
        records: [],
        role: roleOf(record.edge),
      };
      group.others.add(other);
      group.records.push(record);
      candidates.set(key, group);
    }
    for (const group of [...candidates.values()].sort(
      (left, right) =>
        left.endpoint.localeCompare(right.endpoint) ||
        left.role.localeCompare(right.role),
    )) {
      if (group.records.length < minimumSize || group.others.size < minimumSize)
        continue;
      for (const record of group.records) assigned.add(record.key);
      groups.push(group);
    }
  }

  // Prefer fan-out groups. An edge is assigned to at most one junction, which
  // keeps the display graph simple and the semantic edge mapping unambiguous.
  collect("outgoing");
  collect("incoming");
  return {
    direct: records.filter((record) => !assigned.has(record.key)),
    groups,
  };
}

function normalizedLabelMeasure(measureLabel, value) {
  const measured = measureLabel?.(value) ?? {};
  const height = Math.max(1, Number(measured.height) || 16);
  return {
    baseline: Number(measured.baseline) || height * 0.78,
    height,
    width: Math.max(1, Number(measured.width) || value.length * 7.5),
  };
}

function elkInput(selection, config) {
  const scale = config.card.width / CARD.width;
  const scaled = (value) => Math.round(value * scale * 100) / 100;
  const { direct, groups } = groupedEdges(
    selection.edges,
    config.mergeThreshold,
  );
  const children = selection.nodes
    .map((node) => ({
      height: config.card.height,
      id: node.id,
      width: config.card.width,
    }))
    .sort((left, right) => left.id.localeCompare(right.id));
  const edges = [];
  const pieces = new Map();
  const labelBaselines = new Map();
  let pieceIndex = 0;
  let labelIndex = 0;

  function addPiece({ records, source, target, label = null, terminal }) {
    const id = `display-edge-${pieceIndex}`;
    pieceIndex += 1;
    const elkEdge = { id, sources: [source], targets: [target] };
    if (label) {
      const dimensions = normalizedLabelMeasure(config.measureLabel, label);
      const labelId = `display-label-${labelIndex}`;
      labelIndex += 1;
      elkEdge.labels = [
        {
          height: dimensions.height,
          id: labelId,
          layoutOptions: { "elk.edgeLabels.placement": "CENTER" },
          text: label,
          width: dimensions.width,
        },
      ];
      labelBaselines.set(labelId, dimensions.baseline);
    }
    edges.push(elkEdge);
    pieces.set(id, { records, terminal });
  }

  for (const record of direct) {
    addPiece({
      label: roleOf(record.edge),
      records: [record],
      source: record.edge.source,
      target: record.edge.target,
      terminal: true,
    });
  }

  groups.forEach((group, groupIndex) => {
    const junctionId = `__elk_role_junction_${groupIndex}`;
    children.push({ height: scaled(1), id: junctionId, width: scaled(1) });
    if (group.direction === "outgoing") {
      addPiece({
        label: group.role,
        records: group.records,
        source: group.endpoint,
        target: junctionId,
        terminal: false,
      });
      for (const record of group.records) {
        addPiece({
          records: [record],
          source: junctionId,
          target: record.edge.target,
          terminal: true,
        });
      }
    } else {
      for (const record of group.records) {
        addPiece({
          records: [record],
          source: record.edge.source,
          target: junctionId,
          terminal: false,
        });
      }
      addPiece({
        label: group.role,
        records: group.records,
        source: junctionId,
        target: group.endpoint,
        terminal: true,
      });
    }
  });

  return {
    graph: {
      children,
      edges,
      id: "bounded-neighborhood",
      layoutOptions: {
        "elk.algorithm": "layered",
        "elk.direction": "RIGHT",
        "elk.edgeRouting": "ORTHOGONAL",
        "elk.layered.considerModelOrder.strategy": "NODES_AND_EDGES",
        "elk.layered.cycleBreaking.strategy": "GREEDY_MODEL_ORDER",
        "elk.layered.edgeLabels.sideSelection": "SMART_DOWN",
        // Role junctions above are the only merge mechanism. ELK's generic
        // merge is not role-aware and could overlay differently styled roles.
        "elk.layered.mergeEdges": "false",
        "elk.layered.spacing.edgeEdgeBetweenLayers": String(scaled(18)),
        "elk.layered.spacing.edgeNodeBetweenLayers": String(scaled(24)),
        "elk.layered.spacing.nodeNodeBetweenLayers": String(scaled(116)),
        "elk.padding": `[top=${scaled(config.margin)},left=${scaled(config.margin)},bottom=${scaled(config.margin)},right=${scaled(config.margin)}]`,
        "elk.randomSeed": "1",
        "elk.spacing.edgeEdge": String(scaled(18)),
        "elk.spacing.edgeLabel": String(scaled(6)),
        "elk.spacing.edgeNode": String(scaled(24)),
        "elk.spacing.labelLabel": String(scaled(14)),
        "elk.spacing.labelNode": String(scaled(20)),
        "elk.spacing.nodeNode": String(scaled(32)),
      },
    },
    labelBaselines,
    pieces,
  };
}

function pointsOf(elkEdge) {
  const points = [];
  for (const section of elkEdge.sections ?? []) {
    const sectionPoints = [
      section.startPoint,
      ...(section.bendPoints ?? []),
      section.endPoint,
    ].filter(Boolean);
    if (
      points.length &&
      sectionPoints.length &&
      points.at(-1).x === sectionPoints[0].x &&
      points.at(-1).y === sectionPoints[0].y
    ) {
      sectionPoints.shift();
    }
    points.push(...sectionPoints);
  }
  return points;
}

function pathOf(points) {
  return points
    .map(({ x, y }, index) => `${index === 0 ? "M" : "L"} ${x} ${y}`)
    .join(" ");
}

const ROUTE_AXIS_QUANTUM = 0.01;

function quantize(value) {
  return Math.round(value / ROUTE_AXIS_QUANTUM) * ROUTE_AXIS_QUANTUM;
}

function intervalsTouch(left, right, tolerance = ROUTE_AXIS_QUANTUM) {
  return Math.max(left.lo, right.lo) <= Math.min(left.hi, right.hi) + tolerance;
}

function semanticEdgesOf(routes, routeIndexes) {
  const seen = new Set();
  const edges = [];
  for (const routeIndex of routeIndexes) {
    for (const edge of routes[routeIndex].edges ?? [routes[routeIndex].edge]) {
      if (seen.has(edge)) continue;
      seen.add(edge);
      edges.push(edge);
    }
  }
  return edges;
}

function sharedSemanticEdges(routes, leftRouteIndexes, rightRouteIndexes) {
  const rightEdges = new Set(semanticEdgesOf(routes, rightRouteIndexes));
  return semanticEdgesOf(routes, leftRouteIndexes).filter((edge) =>
    rightEdges.has(edge),
  );
}

function terminalPath(points, terminalAtLow, terminalAtHigh) {
  const [low, high] = points;
  if (terminalAtLow && terminalAtHigh) {
    const middle = {
      x: (low.x + high.x) / 2,
      y: (low.y + high.y) / 2,
    };
    // SVG applies marker-end to each open subpath. The two halves meet but do
    // not overlap, so bidirectional traffic still draws the shared stroke once.
    return `M ${middle.x} ${middle.y} L ${low.x} ${low.y} M ${middle.x} ${middle.y} L ${high.x} ${high.y}`;
  }
  return pathOf(terminalAtLow ? [high, low] : points);
}

function coalesceOrthogonalRoutes(routes, laneTolerance) {
  const segments = [];
  const segmentsByRoute = new Map();
  const passthrough = [];
  const labels = [];

  routes.forEach((route, routeIndex) => {
    if (route.label) {
      // Labels keep their original semantic edge set. A move-only path lets
      // the existing renderer and inspection code handle them without drawing
      // another stroke beneath a coalesced segment.
      labels.push({
        ...route,
        d: `M ${route.label.x} ${route.label.y}`,
        points: [],
        terminal: false,
      });
    }

    const routeSegments = [];
    let orthogonal = true;
    for (let index = 1; index < route.points.length; index += 1) {
      const start = route.points[index - 1];
      const end = route.points[index];
      const horizontal = Math.abs(start.y - end.y) <= ROUTE_AXIS_QUANTUM;
      const vertical = Math.abs(start.x - end.x) <= ROUTE_AXIS_QUANTUM;
      if (!horizontal && !vertical) {
        orthogonal = false;
        break;
      }
      const orientation = horizontal ? "horizontal" : "vertical";
      const startAxis = quantize(horizontal ? start.x : start.y);
      const endAxis = quantize(horizontal ? end.x : end.y);
      if (Math.abs(startAxis - endAxis) <= ROUTE_AXIS_QUANTUM) continue;
      routeSegments.push({
        endAxis,
        fixed: horizontal ? (start.y + end.y) / 2 : (start.x + end.x) / 2,
        hi: Math.max(startAxis, endAxis),
        lo: Math.min(startAxis, endAxis),
        orientation,
        role: roleOf(route.edge),
        routeIndex,
        startAxis,
        terminal: route.terminal !== false && index === route.points.length - 1,
      });
    }
    if (orthogonal) {
      segments.push(...routeSegments);
      segmentsByRoute.set(routeIndex, routeSegments);
    } else passthrough.push({ ...route, label: null });
  });

  // ELK distributes connections across the one-unit invisible role junction,
  // yielding visually doubled lanes about 0.2–0.6 units apart. Cluster only
  // same-role, overlapping lanes and require the complete cluster to fit the
  // tolerance; this avoids transitive merging of genuinely parallel routes.
  const lanesByStyle = new Map();
  for (const segment of segments) {
    const key = JSON.stringify([segment.role, segment.orientation]);
    const lanes = lanesByStyle.get(key) ?? [];
    let lane = lanes.find(
      (candidate) =>
        Math.max(candidate.max, segment.fixed) -
          Math.min(candidate.min, segment.fixed) <=
          laneTolerance &&
        candidate.segments.some(
          (member) =>
            intervalsTouch(member, segment) ||
            (intervalsTouch(member, segment, laneTolerance) &&
              sharedSemanticEdges(
                routes,
                [member.routeIndex],
                [segment.routeIndex],
              ).length > 0),
        ),
    );
    if (!lane) {
      lane = { max: segment.fixed, min: segment.fixed, segments: [] };
      lanes.push(lane);
      lanesByStyle.set(key, lanes);
    }
    lane.max = Math.max(lane.max, segment.fixed);
    lane.min = Math.min(lane.min, segment.fixed);
    lane.segments.push(segment);
  }

  for (const lanes of lanesByStyle.values()) {
    for (const lane of lanes) {
      const fixed = quantize((lane.min + lane.max) / 2);
      for (const segment of lane.segments) segment.fixed = fixed;
    }
  }

  // When one side of a bend moves onto a shared lane, carry that coordinate
  // into its perpendicular neighbor. Otherwise the two normalized segments
  // would retain ELK's subpixel port spread as a tiny visual gap at the bend.
  for (const routeSegments of segmentsByRoute.values()) {
    routeSegments.forEach((segment, index) => {
      const previous = routeSegments[index - 1];
      const next = routeSegments[index + 1];
      if (previous && previous.orientation !== segment.orientation) {
        segment.startAxis = previous.fixed;
      }
      if (next && next.orientation !== segment.orientation) {
        segment.endAxis = next.fixed;
      }
      segment.lo = Math.min(segment.startAxis, segment.endAxis);
      segment.hi = Math.max(segment.startAxis, segment.endAxis);
    });
  }

  const coalesced = [];
  for (const lanes of lanesByStyle.values()) {
    for (const lane of lanes) {
      const fixed = lane.segments[0].fixed;
      const breakpoints = [
        ...new Set(
          lane.segments.flatMap((segment) => [segment.lo, segment.hi]),
        ),
      ].sort((left, right) => left - right);
      for (let index = 1; index < breakpoints.length; index += 1) {
        const lo = breakpoints[index - 1];
        const hi = breakpoints[index];
        if (hi - lo <= ROUTE_AXIS_QUANTUM) continue;
        const middle = (lo + hi) / 2;
        const contributors = lane.segments.filter(
          (segment) => segment.lo < middle && segment.hi > middle,
        );
        let routeIndexes;
        let semanticEdges;
        let terminalAtLow = false;
        let terminalAtHigh = false;
        if (contributors.length) {
          routeIndexes = [
            ...new Set(contributors.map(({ routeIndex }) => routeIndex)),
          ];
          semanticEdges = semanticEdgesOf(routes, routeIndexes);
          terminalAtLow = contributors.some(
            (segment) =>
              segment.terminal &&
              Math.abs(segment.endAxis - lo) <= ROUTE_AXIS_QUANTUM,
          );
          terminalAtHigh = contributors.some(
            (segment) =>
              segment.terminal &&
              Math.abs(segment.endAxis - hi) <= ROUTE_AXIS_QUANTUM,
          );
        } else {
          // ELK routes to opposite faces of the one-unit invisible junction,
          // leaving a one-unit hole between otherwise continuous pieces. Fill
          // only a tiny gap whose two sides carry the same semantic edge; this
          // cannot join unrelated nearby routes or draw through a visible node.
          if (hi - lo > laneTolerance + ROUTE_AXIS_QUANTUM) continue;
          const leftRouteIndexes = [
            ...new Set(
              lane.segments
                .filter(
                  (segment) => Math.abs(segment.hi - lo) <= ROUTE_AXIS_QUANTUM,
                )
                .map(({ routeIndex }) => routeIndex),
            ),
          ];
          const rightRouteIndexes = [
            ...new Set(
              lane.segments
                .filter(
                  (segment) => Math.abs(segment.lo - hi) <= ROUTE_AXIS_QUANTUM,
                )
                .map(({ routeIndex }) => routeIndex),
            ),
          ];
          semanticEdges = sharedSemanticEdges(
            routes,
            leftRouteIndexes,
            rightRouteIndexes,
          );
          if (!semanticEdges.length) continue;
          routeIndexes = [
            ...new Set([...leftRouteIndexes, ...rightRouteIndexes]),
          ];
        }
        const points =
          lane.segments[0].orientation === "horizontal"
            ? [
                { x: lo, y: fixed },
                { x: hi, y: fixed },
              ]
            : [
                { x: fixed, y: lo },
                { x: fixed, y: hi },
              ];
        coalesced.push({
          d: terminalPath(points, terminalAtLow, terminalAtHigh),
          edge: semanticEdges[0],
          edges: semanticEdges,
          label: null,
          points,
          terminal: terminalAtLow || terminalAtHigh,
        });
      }
    }
  }

  return [...coalesced, ...passthrough, ...labels];
}

function fallbackLabel(points, baseline) {
  let longest = null;
  for (let index = 1; index < points.length; index += 1) {
    const start = points[index - 1];
    const end = points[index];
    if (start.y !== end.y) continue;
    const length = Math.abs(end.x - start.x);
    if (!longest || length > longest.length) longest = { end, length, start };
  }
  if (!longest) return { x: points[0]?.x ?? 0, y: points[0]?.y ?? 0 };
  return {
    x: (longest.start.x + longest.end.x) / 2,
    y: longest.start.y - Math.max(4, baseline / 3),
  };
}

function displayRoutes(output, pieces, labelBaselines) {
  const routes = [];
  for (const elkEdge of output.edges ?? []) {
    const piece = pieces.get(elkEdge.id);
    if (!piece) continue;
    const points = pointsOf(elkEdge);
    if (points.length < 2) continue;
    const semanticEdges = piece.records.map(({ edge }) => edge);
    const edge = semanticEdges[0];
    const elkLabel = elkEdge.labels?.[0];
    const baseline = elkLabel
      ? labelBaselines.get(elkLabel.id) || elkLabel.height * 0.78
      : 0;
    const label = elkLabel
      ? {
          text: elkLabel.text || roleOf(edge),
          x: elkLabel.x + elkLabel.width / 2,
          y: elkLabel.y + baseline,
        }
      : null;
    routes.push({
      d: pathOf(points),
      edge,
      edges: semanticEdges,
      label:
        label ||
        (elkEdge.labels?.length ? fallbackLabel(points, baseline) : null),
      points,
      terminal: piece.terminal,
    });
  }
  return routes;
}

// Selection and clipping are completed synchronously before the bounded graph
// is serialized to ELK. The worker therefore never receives the whole canon.
export async function layoutNeighborhood(snapshot, centerId, options = {}) {
  const config = {
    ...DEFAULTS,
    ...options,
    card: { ...CARD, ...options.card },
    depth: Math.max(1, Math.floor(options.depth ?? DEFAULTS.depth)),
    maxNodes: Math.max(1, Math.floor(options.maxNodes ?? DEFAULTS.maxNodes)),
  };
  const selection = selectNeighborhood(
    snapshot,
    centerId,
    config.depth,
    config.maxNodes,
  );
  if (!selection.nodes.length) {
    return {
      bounds: { height: 0, width: 0, x: 0, y: 0 },
      centerId,
      clipped: 0,
      edges: [],
      nodes: [],
      positions: {},
      routes: [],
      totalNodes: 0,
    };
  }

  const { graph, labelBaselines, pieces } = elkInput(selection, config);
  const engine = await elkEngine();
  const output = await engine.layout(graph);
  const positions = Object.fromEntries(
    output.children
      .filter((node) => !node.id.startsWith("__elk_role_junction_"))
      .map((node) => [
        node.id,
        {
          rank: selection.ranks.get(node.id) ?? 0,
          x: node.x,
          y: node.y,
        },
      ]),
  );
  return {
    bounds: {
      height: output.height,
      width: output.width,
      x: output.x || 0,
      y: output.y || 0,
    },
    centerId,
    clipped: selection.clipped,
    edges: selection.edges,
    nodes: selection.nodes,
    positions,
    routes: coalesceOrthogonalRoutes(
      displayRoutes(output, pieces, labelBaselines),
      config.card.width / CARD.width,
    ),
    totalNodes: selection.totalNodes,
  };
}
