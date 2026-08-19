extends Node2D
## THE STRUGGLE COACH — help that arrives whenever the player is stuck, at any
## point in a run, instead of once during a scripted opening.
##
## Playtest, and the reason this exists: a tester took twenty minutes to work
## out the basic mechanics, having played the linear tutorial more than once.
## The tutorial teaches the first connection well and then stops forever, so a
## player who understood "drag a circle to the Heart" and nothing else was left
## with no way back in. Every device needed to un-stick them already existed and
## was simply unreachable after Step.DONE — see hint.gd, which is where they now
## live so this can aim them.
##
## Three ways to be stuck, in chain order — each is a strictly earlier link
## than the next, so the earliest unmet one is always the honest thing to teach:
##
##   UNANSWERED  nothing is wired to the Heart that makes what it wants.
##   UNFED       something is, but nothing feeds THAT.
##   WRONG       it is being fed, but the wrong shape is arriving.
##
## Wordless, per VEIN's standing rule. Help escalates in loudness rather than
## switching to text: the node's own jiggle (see VNode.starve) owns the first
## seconds alone, then a halo names the shape and the thing that makes it, and
## finally a ghost thumb performs the exact drag. A player who is not stuck
## never sees any of it, and the moment they fix it, it stops.

enum Stuck { NONE, UNANSWERED, UNFED, WRONG }

## The jiggle alone owns this long — it is often all the nudge a player who
## already knows the game needs, and stepping on it immediately would make the
## quiet cue pointless.
const NOTICE_AT := 3.0
## Then the ghost performs the drag. Far enough after the halo that the halo
## gets a fair chance to be the whole lesson.
const SHOW_AT := 8.0
const BLINK_PERIOD := 1.1
## How far outside a shape's own extent its highlight halo sits — enough to
## read as a ring around it rather than tracing on top of its own outline.
const HEART_HALO_S := 0.34 * 1.35
const NODE_HALO_PAD := 1.3
const DIAGNOSE_EVERY := 0.25

var game: Node2D
var _t := 0.0
var _stuck: int = Stuck.NONE
var _stuck_t := 0.0
## What needs something, what should be dragged to it, and (for WRONG) the line
## to cut. Resolved once per frame in _diagnose.
var _target: VNode = null
var _source: VNode = null
var _cut_at := Vector2.ZERO
var _want: int = VNode.Res.RAW
var _diag_t := 0.0


func _ready() -> void:
	game = get_parent()


func _process(delta: float) -> void:
	# The linear tutorial owns the opening outright: two overlays teaching at
	# once is worse than either alone.
	if game == null or not game.alive or game.heart == null \
			or (game.tutorial != null and game.tutorial.active()):
		_reset()
		visible = false
		return
	visible = true
	_t += delta

	# Diagnosing walks nodes and veins, and none of its answers can change
	# meaningfully between frames — a player cannot get stuck and unstuck in
	# 16ms. Throttled so this overlay costs nothing measurable in a project
	# that went to some trouble to stop redrawing unchanged nodes.
	_diag_t += delta
	if _diag_t >= DIAGNOSE_EVERY:
		_diag_t = 0.0
		var was := _stuck
		var was_target := _target
		_diagnose()
		if _stuck == Stuck.NONE or _stuck != was or _target != was_target:
			_stuck_t = 0.0
	if _stuck != Stuck.NONE:
		_stuck_t += delta
	queue_redraw()


func _reset() -> void:
	_stuck = Stuck.NONE
	_stuck_t = 0.0
	_target = null
	_source = null


## Which link in the chain is the earliest one broken, and who the actors are.
func _diagnose() -> void:
	_stuck = Stuck.NONE
	_target = null
	_source = null

	# 1. Nothing wired to the Heart makes what it wants. Reuses the graph
	# answer game.gd already maintains (see _demand_answered) rather than
	# recomputing reachability here.
	if not game._demand_answered_now:
		_stuck = Stuck.UNANSWERED
		_target = game.heart
		_want = game.demand
		_source = _best_source(game.demand, game.heart)
		return

	# 2. A wired-in tool with nothing supplying its ingredient. Recipes are
	# homogeneous, so recipe[0] is THE ingredient (see game._roll_recipe).
	for n in game.nodes:
		if n.recipe.is_empty() or n.corrupted or n.depth < 0 or n.fed:
			continue
		_stuck = Stuck.UNFED
		_target = n
		_want = n.recipe[0]
		_source = _best_source(_want, n)
		return

	# 3. Something wrong is on its way to the Heart. Last because it is a leak,
	# not a blockage — the chain above it is working.
	for v in game.veins:
		if v.wrong_flow:
			_stuck = Stuck.WRONG
			_cut_at = v.sample(0.5)
			return


## The node the player should drag to `to`: something that makes `res`, isn't
## already wired to it, and is close enough to actually reach. Nearest wins, so
## the suggested drag is always the shortest one available.
func _best_source(res: int, to: VNode) -> VNode:
	if to == null or not game.can_afford():
		return null
	var best: VNode = null
	var best_d := INF
	for n in game.nodes:
		if n == to or n.corrupted or n.produces != res:
			continue
		if not game.in_reach(n, to) or _linked(n, to):
			continue
		var d: float = n.position.distance_squared_to(to.position)
		if d < best_d:
			best_d = d
			best = n
	return best


func _linked(a: VNode, b: VNode) -> bool:
	for v in game.veins:
		if (v.a == a and v.b == b) or (v.a == b and v.b == a):
			return true
	return false


func _draw() -> void:
	if _stuck == Stuck.NONE or _stuck_t < NOTICE_AT:
		return
	var blink := sin(fmod(_t, BLINK_PERIOD) / BLINK_PERIOD * TAU) * 0.5 + 0.5

	if _stuck == Stuck.WRONG:
		# The line itself is the lesson: cut here. No halo stage — a scissor on
		# the offending vein is already unambiguous.
		if _stuck_t >= SHOW_AT:
			Hint.cut_ghost(self, _cut_at, _t)
		return

	if _target == null:
		return

	# Ring the thing that needs something. Each halo is drawn in the colour of
	# the shape it is actually tracing, never a borrowed one — a warm-tinted
	# triangle (the ingredient's hue on the tool's own silhouette) reads as a
	# fourth shape that does not exist rather than as a highlight.
	if _target == game.heart:
		var hc: Color = Palette.of_res(_want)
		hc.a = 0.35 + blink * 0.45
		Hint.shape_halo(self, _target.position + _target.demand_glyph_offset(),
			_want, _target.radius() * HEART_HALO_S, hc, 3.0 + blink * 2.0)
	else:
		var tc: Color = Palette.of_res(_target.produces)
		tc.a = 0.35 + blink * 0.45
		Hint.shape_halo(self, _target.position, _target.produces,
			_target.radius() * NODE_HALO_PAD, tc, 3.0 + blink * 2.0)

	if _source == null:
		# Nothing on the board can answer this and there is no drag to show. The
		# halo above still says WHICH shape is missing, which is the only true
		# thing available — inventing a gesture the player cannot perform would
		# teach them the game is broken.
		return

	# And name the thing that makes it.
	var sc: Color = Palette.of_res(_want)
	sc.a = 0.3 + blink * 0.5
	Hint.shape_halo(self, _source.position, _source.produces,
		_source.radius() * NODE_HALO_PAD, sc, 2.5 + blink * 1.5)

	if _stuck_t >= SHOW_AT:
		Hint.drag_ghost(self, _source.position, _target.position, _t)
