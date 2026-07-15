class_name AutoPlay
## A stand-in player, used only by the harnesses in tests/.
##
## Policy: attach the orphaned Well that can join the SHALLOWEST reachable point
## of the network, tie-broken by distance.
##
## Depth dominates proximity because chain depth is what kills. A trunk carries
## Vein.SPEED / Vein.DOT_SPACING items per second while each Well makes one per
## VNode.WELL_PERIOD, so a chain more than about four Wells deep is permanently
## over capacity and ruptures forever. Nearest-first grows one long chain off
## whatever it happened to connect first and cascades: it died around beat 229
## with 2-5 Wells fed and 30-odd ruptures, which measured the bot, not the game.
##
## Candidates must satisfy game.in_reach() — _add_vein silently refuses spans
## over Vein.MAX_LEN, so an unreachable pick is a wasted move, not a no-op.
##
## This is a floor, not optimal play: it never deletes or re-routes.

static func step(game) -> void:
	if not game.alive:
		return

	# Cut the rot first. Without this the bot sits there letting necrotic Wells
	# pump VOID into the Heart and dies at ~69 beats, which measures its
	# blindness rather than the game. Amputation is the basic human response and
	# the floor has to include it.
	for v in game.veins:
		if v.a.corrupted or v.b.corrupted:
			game._remove_vein(v)
			return

	# Once demand changes, old direct lines become traps: they spend scarce vein
	# budget to feed scraps. Humans should learn to amputate them; the probe
	# floor needs the same instinct.
	if game.demand == VNode.Res.REFINED:
		for v in game.veins:
			if _connects(v, VNode.Kind.WELL, VNode.Kind.HEART):
				game._remove_vein(v, true)
				return
	elif game.demand == VNode.Res.CLOTH:
		for v in game.veins:
			if _connects(v, VNode.Kind.WELL, VNode.Kind.HEART) \
					or _connects(v, VNode.Kind.FORGE, VNode.Kind.HEART):
				game._remove_vein(v, true)
				return

	if not game.can_afford():
		return

	# When demand climbs, direct Wells become garbage. Prefer the live production
	# chain over extra raw supply:
	#   REFINED: Well -> Forge -> Heart
	#   CLOTH:   Well -> Forge -> Loom -> Heart
	var need_forge: bool = game.demand == VNode.Res.REFINED or game.demand == VNode.Res.CLOTH
	var need_loom: bool = game.demand == VNode.Res.CLOTH

	var pick: VNode = null
	var target: VNode = null
	var best := INF

	for n in game.nodes:
		# Forges count as orphans worth attaching: once a Forge is on the graph,
		# Wells attach to it by the same rule and its smelting falls out for free.
		if n.kind == VNode.Kind.HEART or n.depth >= 0:
			continue
		for m in game.nodes:
			if m.depth < 0 or not game.in_reach(n, m):
				continue
			var score: float = float(m.depth) * 10000.0 + n.position.distance_to(m.position)
			# Getting the demanded tool chain connected, then fed, outranks
			# everything. These are coarse priorities for a floor bot, not optimal
			# play.
			if need_loom:
				if n.kind == VNode.Kind.LOOM:
					score -= 2000000.0
				elif n.kind == VNode.Kind.FORGE and m.kind == VNode.Kind.LOOM:
					score -= 1500000.0
				elif n.kind == VNode.Kind.WELL and m.kind == VNode.Kind.FORGE:
					score -= 1000000.0
			elif need_forge:
				if n.kind == VNode.Kind.FORGE:
					score -= 1000000.0
				elif n.kind == VNode.Kind.WELL and m.kind == VNode.Kind.FORGE:
					score -= 500000.0
			if score < best:
				best = score
				pick = n
				target = m

	if pick != null and target != null:
		game._add_vein(pick, target)


static func _connects(v: Vein, kind_a: int, kind_b: int) -> bool:
	return (v.a.kind == kind_a and v.b.kind == kind_b) \
		or (v.a.kind == kind_b and v.b.kind == kind_a)
