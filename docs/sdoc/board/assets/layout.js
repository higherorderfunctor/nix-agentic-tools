export const CARD = Object.freeze({ width: 244, height: 102 });

const DEFAULTS = Object.freeze({
  card: CARD,
  columnGap: 28,
  margin: 90,
  maxRows: 32,
  rankGap: 116,
  rowGap: 28,
  sweeps: 6,
});

function stronglyConnectedComponents(ids, adjacency) {
  let cursor = 0;
  const indices = new Map();
  const low = new Map();
  const stack = [];
  const onStack = new Set();
  const components = [];

  function visit(id) {
    indices.set(id, cursor);
    low.set(id, cursor);
    cursor += 1;
    stack.push(id);
    onStack.add(id);

    for (const target of adjacency.get(id) ?? []) {
      if (!indices.has(target)) {
        visit(target);
        low.set(id, Math.min(low.get(id), low.get(target)));
      } else if (onStack.has(target)) {
        low.set(id, Math.min(low.get(id), indices.get(target)));
      }
    }

    if (low.get(id) !== indices.get(id)) return;
    const component = [];
    while (stack.length) {
      const member = stack.pop();
      onStack.delete(member);
      component.push(member);
      if (member === id) break;
    }
    component.sort();
    components.push(component);
  }

  for (const id of ids) {
    if (!indices.has(id)) visit(id);
  }
  components.sort((a, b) => a[0].localeCompare(b[0]));
  return components;
}

function componentRanks(components, edges) {
  const componentOf = new Map();
  components.forEach((members, component) => {
    members.forEach((id) => {
      componentOf.set(id, component);
    });
  });

  const outgoing = components.map(() => new Set());
  const incoming = components.map(() => new Set());
  for (const edge of edges) {
    const source = componentOf.get(edge.source);
    const target = componentOf.get(edge.target);
    if (source === target || outgoing[source].has(target)) continue;
    outgoing[source].add(target);
    incoming[target].add(source);
  }

  const indegree = incoming.map((values) => values.size);
  const queue = indegree
    .map((degree, component) => ({ degree, component }))
    .filter(({ degree }) => degree === 0)
    .map(({ component }) => component)
    .sort((a, b) => components[a][0].localeCompare(components[b][0]));
  const order = [];
  while (queue.length) {
    const component = queue.shift();
    order.push(component);
    for (const target of [...outgoing[component]].sort((a, b) => a - b)) {
      indegree[target] -= 1;
      if (indegree[target] === 0) {
        queue.push(target);
        queue.sort((a, b) => components[a][0].localeCompare(components[b][0]));
      }
    }
  }

  const rank = components.map(() => 0);
  for (const component of order) {
    for (const target of outgoing[component]) {
      rank[target] = Math.max(rank[target], rank[component] + 1);
    }
  }
  return { componentOf, rank };
}

function neighborMaps(ids, edges) {
  const incoming = new Map(ids.map((id) => [id, []]));
  const outgoing = new Map(ids.map((id) => [id, []]));
  for (const edge of edges) {
    outgoing.get(edge.source)?.push(edge.target);
    incoming.get(edge.target)?.push(edge.source);
  }
  return { incoming, outgoing };
}

function stableBarycentricSort(bucket, neighbors, positions) {
  const original = new Map(bucket.map((id, index) => [id, index]));
  bucket.sort((left, right) => {
    const leftValues = (neighbors.get(left) ?? [])
      .map((id) => positions.get(id))
      .filter((value) => value !== undefined);
    const rightValues = (neighbors.get(right) ?? [])
      .map((id) => positions.get(id))
      .filter((value) => value !== undefined);
    const leftMean = leftValues.length
      ? leftValues.reduce((sum, value) => sum + value, 0) / leftValues.length
      : original.get(left);
    const rightMean = rightValues.length
      ? rightValues.reduce((sum, value) => sum + value, 0) / rightValues.length
      : original.get(right);
    return leftMean - rightMean || original.get(left) - original.get(right);
  });
}

function orderBuckets(buckets, edges, sweeps) {
  const ids = buckets.flat();
  const { incoming, outgoing } = neighborMaps(ids, edges);
  for (let sweep = 0; sweep < sweeps; sweep += 1) {
    let positions = new Map(
      buckets.flatMap((bucket) => bucket.map((id, index) => [id, index])),
    );
    for (let rank = 1; rank < buckets.length; rank += 1) {
      stableBarycentricSort(buckets[rank], incoming, positions);
      buckets[rank].forEach((id, index) => {
        positions.set(id, index);
      });
    }
    positions = new Map(
      buckets.flatMap((bucket) => bucket.map((id, index) => [id, index])),
    );
    for (let rank = buckets.length - 2; rank >= 0; rank -= 1) {
      stableBarycentricSort(buckets[rank], outgoing, positions);
      buckets[rank].forEach((id, index) => {
        positions.set(id, index);
      });
    }
  }
}

export function layoutGraph(snapshot, options = {}) {
  const config = { ...DEFAULTS, ...options };
  const ids = snapshot.nodes.map((node) => node.id).sort();
  const idSet = new Set(ids);
  const edges = snapshot.edges.filter(
    (edge) => idSet.has(edge.source) && idSet.has(edge.target),
  );
  const adjacency = new Map(ids.map((id) => [id, []]));
  for (const edge of edges) adjacency.get(edge.source).push(edge.target);
  for (const targets of adjacency.values()) targets.sort();

  const components = stronglyConnectedComponents(ids, adjacency);
  const { componentOf, rank } = componentRanks(components, edges);
  const maxRank = Math.max(0, ...rank);
  const buckets = Array.from({ length: maxRank + 1 }, () => []);
  components.forEach((members, component) => {
    buckets[rank[component]].push(...members);
  });
  buckets.forEach((bucket) => {
    bucket.sort();
  });
  orderBuckets(buckets, edges, config.sweeps);

  const rowStep = config.card.height + config.rowGap;
  const tallest = Math.max(
    1,
    ...buckets.map((bucket) => Math.min(config.maxRows, bucket.length)),
  );
  const contentHeight = tallest * rowStep - config.rowGap;
  const rankStarts = [];
  let nextRankX = config.margin;
  buckets.forEach((bucket, rankIndex) => {
    rankStarts[rankIndex] = nextRankX;
    const columns = Math.max(1, Math.ceil(bucket.length / config.maxRows));
    nextRankX +=
      columns * config.card.width +
      Math.max(0, columns - 1) * config.columnGap +
      config.rankGap;
  });
  const positions = {};
  buckets.forEach((bucket, rankIndex) => {
    bucket.forEach((id, index) => {
      const column = Math.floor(index / config.maxRows);
      const row = index % config.maxRows;
      const rowsInColumn = Math.min(
        config.maxRows,
        bucket.length - column * config.maxRows,
      );
      const columnHeight = rowsInColumn * rowStep - config.rowGap;
      const yStart = config.margin + (contentHeight - columnHeight) / 2;
      positions[id] = {
        x:
          rankStarts[rankIndex] +
          column * (config.card.width + config.columnGap),
        y: yStart + row * rowStep,
        rank: rankIndex,
        component: componentOf.get(id),
      };
    });
  });

  return {
    positions,
    components,
    bounds: {
      x: 0,
      y: 0,
      width: nextRankX - config.rankGap + config.margin,
      height: config.margin * 2 + contentHeight,
    },
  };
}
