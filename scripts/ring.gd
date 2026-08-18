class_name Ring
extends RefCounted
## The ring: a closed circuit of orphaned Wells becomes the shape with that
## many sides. Three circles wired into a triangle ARE a triangle — the
## topology you draw is the shape you get, which is the whole reason this
## mechanic needs no words to teach (see game.gd's _fuse_ring and
## ring_tell.gd for the two halves that make it visible).
##
## Pure graph logic: no state, no rendering, no reaching into game.gd. Every
## entry point is static and takes the board as arguments, so the rules below
## are testable in isolation and so game.gd doesn't grow another traversal
## inline. The only two callers are _add_vein (find_closed) and
## _rebuild_graph (find_pending).
##
## This is the first cycle-detection code in the repo — everything else that
## walks the graph (_rebuild_graph's two BFS passes, _island_ready_to_collapse)
## only ever needed reachability.

## Ring sizes that map to a real shape. A 2-ring is a duplicate vein (already
## refused by _find_vein) and a 7-ring has nothing to become.
const MIN := 3
const MAX := 6


## N sides -> the tool that IS that polygon. The Kind enum's own shapes, so
## this table is really just "count the corners."
static func kind_for(n: int) -> int:
	match n:
		3: return VNode.Kind.FORGE      # triangle
		4: return VNode.Kind.LOOM       # square
		5: return VNode.Kind.KILN       # pentagon
		6: return VNode.Kind.CRUCIBLE   # hexagon
	return -1


## What a forged node will produce — mirrors game.gd's Kind->Res mapping in
## _make_node, same deliberate duplication ghost_spawn.gd's _res_for_kind
## makes: a rule this small has no business reaching into game.gd's private
## match statement.
static func res_for_kind(kind: int) -> int:
	match kind:
		VNode.Kind.FORGE: return VNode.Res.REFINED
		VNode.Kind.LOOM: return VNode.Res.CLOTH
		VNode.Kind.KILN: return VNode.Res.PRISM
		VNode.Kind.CRUCIBLE: return VNode.Res.HEXAGON
	return VNode.Res.RAW


## Can this node be ring material?
##
## `depth < 0` — ORPHANED — is the load-bearing clause, and it is doing three
## jobs at once. It stops the common accident (you wire three LIVE supply
## Wells into a loop for throughput and lose them permanently). It is
## diegetically exact: you can only remake what the Heart isn't already using
## — blood in service can't be reforged. And it forces the whole build
## off-network, which puts it on the orphan wither clock (VNode.WITHER_TIME)
## and inside rage's blast radius, so building a ring is genuinely exposure
## rather than a free option you take whenever you feel like it.
static func usable(n: VNode) -> bool:
	return n != null and is_instance_valid(n) \
		and n.kind == VNode.Kind.WELL and not n.corrupted and n.depth < 0


## Adjacency over ring-eligible veins only. `skip` excludes the vein that
## just closed the circuit, so the search below looks for the OTHER way round.
static func _adjacency(veins: Array[Vein], skip: Vein) -> Dictionary:
	var adj := {}
	for v in veins:
		if v == skip or not is_instance_valid(v):
			continue
		if not usable(v.a) or not usable(v.b):
			continue
		if not adj.has(v.a):
			adj[v.a] = [] as Array[VNode]
		if not adj.has(v.b):
			adj[v.b] = [] as Array[VNode]
		adj[v.a].append(v.b)
		adj[v.b].append(v.a)
	return adj


## BFS, so the path returned is always a SHORTEST one — which is what makes
## the smallest ring win, and what makes every ring chordless for free.
##
## The chordless property is worth spelling out because nothing checks it
## explicitly: if the cycle had a chord between two non-adjacent members,
## that chord would be a shorter route between them, so BFS would have
## returned the shorter path instead and this cycle would never have been
## built. Shortest implies induced. That matters because a ring with a chord
## does not read as a clean polygon, and the eye is the only rulebook this
## mechanic gets.
##
## Ties between equal-length paths resolve by `veins` order, which is a plain
## ordered Array, and Dictionary preserves insertion order — so this is
## deterministic, which the seeded sim requires (see game.gd's header).
static func _shortest_path(from: VNode, to: VNode, adj: Dictionary, max_hops: int) -> Array[VNode]:
	var none: Array[VNode] = []
	if from == to or not adj.has(from) or not adj.has(to):
		return none
	var prev := {}
	var seen := {from: true}
	var frontier: Array[VNode] = [from]
	var hops := 0
	while not frontier.is_empty() and hops < max_hops:
		hops += 1
		var next: Array[VNode] = []
		for cur in frontier:
			for nb in adj.get(cur, []):
				if seen.has(nb):
					continue
				seen[nb] = true
				prev[nb] = cur
				if nb == to:
					var path: Array[VNode] = [to]
					var walk: VNode = to
					while prev.has(walk):
						walk = prev[walk]
						path.append(walk)
					path.reverse()
					return path
				next.append(nb)
		frontier = next
	return none


static func _joined(adj: Dictionary, u: VNode, w: VNode) -> bool:
	return adj.has(u) and w in adj[u]


## Did the vein just drawn close a fusable ring? A cycle can only newly form
## through the edge that was just added, so this never has to search the whole
## board — just for a second route between that one vein's two ends.
##
## `floor_after` is the budget floor: forging BURIES its ring's veins
## permanently, and without a floor a player could bury themselves into a
## board they cannot connect anything on, which is exactly the state the
## whole _ensure_move/_ensure_throughput rescue layer exists to prevent.
static func find_closed(v: Vein, veins: Array[Vein], budget: int, floor_after: int) -> Array[VNode]:
	var none: Array[VNode] = []
	if v == null or not is_instance_valid(v) or not usable(v.a) or not usable(v.b):
		return none
	var path := _shortest_path(v.a, v.b, _adjacency(veins, v), MAX - 1)
	if path.size() < MIN or path.size() > MAX:
		return none
	if budget - path.size() < floor_after:
		return none
	return path


## The teach: is the board one vein short of a ring, and which one?
##
## Returns {ring, from, to, kind} for the best candidate, or {} for none.
## Ranked by ring size ASCENDING — the smallest ring is both the likeliest
## intent and the cheapest commitment, and it is also the one find_closed
## would actually fire, so the tell can never promise a shape the drag
## wouldn't deliver. Ties break on the shortest missing edge.
##
## Only ever called from _rebuild_graph, i.e. on graph change — never per
## frame. The pair loop is bounded hard by the degree filter below: a Well
## with no vein on it cannot be an endpoint of a path, and most orphaned
## Wells on a live board have none.
static func find_pending(nodes: Array[VNode], veins: Array[Vein], budget: int, floor_after: int) -> Dictionary:
	# No free slot means the closing vein cannot be drawn at all, so there is
	# nothing to promise. Same silent refusal _add_vein already does.
	if veins.size() >= budget:
		return {}
	var adj := _adjacency(veins, null)
	# Every member of a ring one vein short already has a vein on it (the
	# endpoints one, the interior two), so a board with fewer connected Wells
	# than MIN cannot possibly hold one.
	if adj.size() < MIN:
		return {}
	var wells: Array[VNode] = []
	for n in nodes:
		if usable(n) and adj.has(n):
			wells.append(n)

	# One BFS PER WELL, not per pair. The pair scan below needs only the hop
	# count between two Wells, not the route, so running a full search inside
	# the O(W^2) loop was doing the same work ~W/2 times over — measurably so:
	# at the (unreachable in play) worst case of 20 orphaned Wells meshed with
	# 40 veins, that cost 651us a call, and this runs on every graph edit.
	# The actual route is recovered once, for the winner, at the bottom.
	var hops := {}
	for u in wells:
		hops[u] = _hops_from(u, adj, MAX - 1)

	var best_from: VNode = null
	var best_to: VNode = null
	var best_n := MAX + 1
	var best_d := INF
	for i in wells.size():
		for j in range(i + 1, wells.size()):
			var u := wells[i]
			var w := wells[j]
			var d := u.position.distance_to(w.position)
			# Same one reach ceiling every pair on the board shares.
			if d > Vein.MAX_LEN or _joined(adj, u, w):
				continue
			var h: Dictionary = hops[u]
			if not h.has(w):
				continue
			# Ring size is the path's node count: hops, plus the Well it
			# started from.
			var n: int = int(h[w]) + 1
			if n < MIN or n > MAX or budget - n < floor_after:
				continue
			if n < best_n or (n == best_n and d < best_d):
				best_n = n
				best_d = d
				best_from = u
				best_to = w
	if best_from == null:
		return {}
	var ring := _shortest_path(best_from, best_to, adj, MAX - 1)
	if ring.size() < MIN:
		return {}
	return {"ring": ring, "from": best_from, "to": best_to, "kind": kind_for(ring.size())}


## Hop counts from one Well to every other within `max_hops`. Same BFS as
## _shortest_path, minus the parent bookkeeping — this only has to answer
## "how far", and the route is wanted for exactly one pair per call.
static func _hops_from(from: VNode, adj: Dictionary, max_hops: int) -> Dictionary:
	var dist := {}
	var frontier: Array[VNode] = [from]
	var seen := {from: true}
	var depth := 0
	while not frontier.is_empty() and depth < max_hops:
		depth += 1
		var next: Array[VNode] = []
		for cur in frontier:
			for nb in adj.get(cur, []):
				if seen.has(nb):
					continue
				seen[nb] = true
				dist[nb] = depth
				next.append(nb)
		frontier = next
	return dist


## Centre of the ring, where the forged shape is born. Plain centroid: for
## the convex rings a player actually draws it sits comfortably inside, well
## clear of every member.
static func centroid(ring: Array[VNode]) -> Vector2:
	var c := Vector2.ZERO
	for n in ring:
		c += n.position
	return c / maxf(1.0, float(ring.size()))


## The forged node inherits the MEAN remaining life of the Wells it ate.
##
## This is the whole anti-cheese rule, and it needed no magic numbers: fuse
## three fresh Wells and you get a full-life tool; fuse three nearly-spent
## ones and you get a tool that corrupts almost immediately. "Sacrifice my
## junk" correctly buys junk, so the interesting decision — do I give up
## supply I am still using? — stays interesting.
static func inherited_ratio(ring: Array[VNode]) -> float:
	var total := 0.0
	for n in ring:
		total += n.reserve_ratio()
	return total / maxf(1.0, float(ring.size()))
