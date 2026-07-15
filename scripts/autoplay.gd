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
	if not game.alive or not game.can_afford():
		return

	var pick: VNode = null
	var target: VNode = null
	var best := INF

	for n in game.nodes:
		if n.kind == VNode.Kind.HEART or n.depth >= 0:
			continue
		for m in game.nodes:
			if m.depth < 0 or not game.in_reach(n, m):
				continue
			var score: float = float(m.depth) * 10000.0 + n.position.distance_to(m.position)
			if score < best:
				best = score
				pick = n
				target = m

	if pick != null and target != null:
		game._add_vein(pick, target)
