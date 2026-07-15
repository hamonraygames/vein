class_name AutoPlay
## A stand-in player, used only by the harnesses in tests/.
##
## Policy: whenever a vein is affordable, connect the nearest orphaned Well to
## the nearest node already reaching the Heart. This is roughly what a competent
## player does on autopilot, so the beat it dies on is a floor for the run
## length — a real player should beat it, and if they can't, the tuning is wrong.

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
			if m.depth < 0:
				continue
			var d: float = n.position.distance_to(m.position)
			if d < best:
				best = d
				pick = n
				target = m

	if pick != null and target != null:
		game._add_vein(pick, target)
