extends Node2D
## Harakiri's visual bridge: a dying node's outline travels to wherever its
## same-family replacement just landed (see game.gd's _on_node_corrupted/
## _spawn_ghost) and pops it into being on arrival — so a fresh shape
## appearing mid-run always reads as "that one's rebirth," not an unrelated
## spawn the player has to notice on their own.
##
## Two stages, not one continuous blend: TRAVEL, where it stays a dim,
## constant ghost the whole journey (playtest note: gradually solidifying
## en route read as "it's already there," not "it's arriving" — the shape
## has to look and stay ghostly until it actually lands), then REVEAL, a
## short pop once it does. The real replacement spawns hidden/tiny-scaled
## the instant this starts (see start()) and only becomes visible here —
## it already exists for gameplay purposes the whole time (see
## _spawn_ghost's own comment: "always have a move" never waits on this),
## only its VISIBILITY is gated on the ghost's arrival.
##
## Same instantiate-and-forget pattern as burst.gd/shatter.gd: manual
## _process/_draw interpolation, no Tween, self-frees when done.

## A fraction of VNode.COLLAPSE_TIME (8s) — long enough to read as a real
## journey, well short of the full collapse window so it never looks like
## it's racing the death timer it's actually just echoing. Slower than the
## first pass on purpose — playtest: the quicker version felt distracting,
## more of a dart than a drift.
const TRAVEL_TIME := 2.8
const REVEAL_TIME := 0.45
## Dim and CONSTANT for the whole journey — no gradual solidify, see the
## header comment on why that read badly. Lowered again (was 0.45) —
## still meant to be noticed, not to compete with the board.
const GHOST_ALPHA := 0.30
const GLYPH_S := 13.0
## A slow secondary wobble on top of the main bow — a clean single arc read
## as a thrown object, not something drifting. Small amplitude, not the
## main shape of the path.
const WOBBLE_AMP := 5.0
const WOBBLE_FREQ := 3.4

var _from := Vector2.ZERO
var _to := Vector2.ZERO
var _res := VNode.Res.RAW
var _target: VNode
var _rng := RandomNumberGenerator.new()
## A perpendicular bow so the path reads as travel, not a teleport — same
## "outward, not a straight line" instinct _spawn_node's own placement uses.
var _bow := 0.0
var _wobble_phase := 0.0
var _t := 0.0


## `target` is the already-created replacement (see _on_node_corrupted) —
## hidden and shrunk here so its own normal appearance never shows until
## the reveal stage below un-hides and grows it back.
func start(from: Vector2, target: VNode, kind: int, run_seed: int) -> void:
	_from = from
	_target = target
	_to = target.position
	_res = _res_for_kind(kind)
	_rng.seed = run_seed
	var side := 1.0 if _rng.randf() < 0.5 else -1.0
	_bow = side * from.distance_to(_to) * _rng.randf_range(0.12, 0.22)
	_wobble_phase = _rng.randf() * TAU
	z_index = 11
	target.visible = false
	target.scale = Vector2(0.1, 0.1)


## Mirrors game.gd's own Kind->Res table (see _make_node) — kept local
## rather than reaching into game.gd's private mapping, a one-shot VFX node
## has no business depending on that.
func _res_for_kind(kind: int) -> int:
	match kind:
		VNode.Kind.FORGE: return VNode.Res.REFINED
		VNode.Kind.LOOM: return VNode.Res.CLOTH
		VNode.Kind.KILN: return VNode.Res.PRISM
		VNode.Kind.CRUCIBLE: return VNode.Res.HEXAGON
	return VNode.Res.RAW


func _process(delta: float) -> void:
	_t += delta
	if _t >= TRAVEL_TIME + REVEAL_TIME:
		if is_instance_valid(_target):
			_target.visible = true
			_target.scale = Vector2.ONE
		queue_free()
		return
	if _t >= TRAVEL_TIME and is_instance_valid(_target):
		var rt := (_t - TRAVEL_TIME) / REVEAL_TIME
		var s := _ease_pop(rt)
		_target.visible = true
		_target.scale = Vector2(s, s)
	queue_redraw()


## Ease-out with a small overshoot bounce — "pop," not a flat grow-in. Cheap
## two-term formula for a single shot-and-forget value, no Tween needed.
func _ease_pop(t: float) -> float:
	if t >= 1.0:
		return 1.0
	var eased := 1.0 - pow(1.0 - t, 3.0)
	return eased * (1.0 + 0.12 * sin(t * PI))


func _draw() -> void:
	if _t >= TRAVEL_TIME:
		# The ghost fades out over the reveal window as the real shape pops
		# in on top of it — a brief exchange, not an instant swap.
		var fade_out := 1.0 - clampf((_t - TRAVEL_TIME) / REVEAL_TIME, 0.0, 1.0)
		_draw_ghost(_to, GHOST_ALPHA * fade_out)
		return
	var raw_t := _t / TRAVEL_TIME
	# Smoothstep — gentle at both ends, not a snap into motion. A flat lerp
	# read as mechanical; this is what actually makes the movement itself
	# feel ghostly rather than just the tint.
	var travel_t := raw_t * raw_t * (3.0 - 2.0 * raw_t)
	var pos := _from.lerp(_to, travel_t)
	var perp := (_to - _from).orthogonal().normalized()
	pos += perp * _bow * sin(travel_t * PI)
	pos += perp * WOBBLE_AMP * sin(_t * WOBBLE_FREQ + _wobble_phase)
	_draw_ghost(pos, GHOST_ALPHA)


func _draw_ghost(at: Vector2, alpha: float) -> void:
	var col := Palette.of_res(_res)
	col.a = alpha
	var pts := VNode.demand_glyph_points(_res, GLYPH_S)
	if pts.is_empty():
		draw_arc(at, GLYPH_S * VNode.DEMAND_GLYPH_CIRCLE_RATIO, 0.0, TAU, 22, col, 2.2, true)
		return
	var shifted := PackedVector2Array()
	for p in pts:
		shifted.append(p + at)
	draw_polyline(shifted, col, 2.2, true)
