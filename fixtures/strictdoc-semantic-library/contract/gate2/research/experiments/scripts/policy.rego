package gate2

import rego.v1

# Authored ownership and contextual relation selectors remain input facts.
selected(r) if {
	r.model == input.hierarchy.model
	r.owner_type == input.hierarchy.owner_type
	r.kind == input.hierarchy.kind
	r.role == input.hierarchy.role
}

endpoints(r) := [r.target, r.owner] if r.kind == "Parent"
endpoints(r) := [r.owner, r.target] if r.kind == "Child"

parents := {n: {p | some r in input.relations; selected(r); [p, c] := endpoints(r); c == n} |
	some n in object.keys(input.nodes)
}

children := {n: {c | some r in input.relations; selected(r); [p, c] := endpoints(r); p == n} |
	some n in object.keys(input.nodes)
}

inside(origin, boundary) if boundary in graph.reachable(parents, {origin})

expand(_, node) if input.nodes[node].closed == false
expand(origin, node) if inside(origin, node)

# Two comprehensions avoid a quadratic all-node cross product.
adjacency(q) := {n: union({up, down}) |
	some n in object.keys(input.nodes)
	up := {p | q.mode == "visible"; some p in parents[n]}
	down := {c | expand(q.origin, n); some c in children[n]}
}

answers := {q.id: answer |
	some q in input.queries
	reachable := graph.reachable(adjacency(q), {q.origin})
	answer := q.target in reachable
}

protection contains uid if {
	some uid, old in input.snapshot.records
	object.get(input.projection, uid, null) != old
}

result := {
	"answers": answers, "protected_changes": protection,
	"snapshot": input.snapshot.id,
}
