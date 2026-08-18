extends Node2D
## The moment a circuit becomes a shape.
##
## Three stages, deliberately separated rather than crossfaded, because they
## are three different statements and the player has to read all three the
## first time it ever happens:
##
##   CLOSE    the current runs all the way around the ring — "this is one
##            circuit now, and here is exactly which veins were in it"
##   COLLAPSE the Wells travel inward and the ring shrinks out from under
##            them — "these are being spent"
##   POP      the new shape arrives at the centre — "and this is what they
##            became"
##
## Same instantiate-and-forget pattern as burst.gd/poison_dart.gd/
## ghost_spawn.gd: a _t accumulator, immediate-mode _draw, self-frees when
## done. No Tween, nothing to clean up.
##
## Purely cosmetic. game.gd's _fuse_ring has already removed the Wells,
## buried the budget and created the new node before this exists — the node
## is merely hidden, and this un-hides it, exactly the division ghost_spawn.gd
## uses so gameplay never waits on an animation.

## The current runs around the ring at a readable pace regardless of how big
## the ring is — a hexagon spanning half the board and a tight triangle both
## take the same time to close, because the statement is the same statement.
const CLOSE_TIME := 0.45
const COLLAPSE_TIME := 0.45
const POP_TIME := 0.25

## How much of the ring is lit at once as the current travels — a comet, not
## a creeping fill. In ring-fraction, so it scales with the polygon.
const ARC := 0.34
const GLYPH_S := 13.0

var _paths: Array[PackedVector2Array] = []
var _from: Array[Vector2] = []
var _to := Vector2.ZERO
var _res := VNode.Res.REFINED
var _target: VNode
var _t := 0.0
var _lengths: Array[float] = []
var _total := 0.0


## `paths` are the ring's veins in order, already sampled (Vein.pts) — the
## real curves the player drew, not straight lines between centres. Same
## reason poison_dart.gd rides vein.pts: a straight chord across a bowed vein
## reads as something shooting past the board rather than running through it.
func start(paths: Array[PackedVector2Array], from: Array[Vector2], to: Vector2,
		res: int, target: VNode) -> void:
	_paths = paths
	_from = from
	_to = to
	_res = res
	_target = target
	z_index = 20
	for path in _paths:
		var l := 0.0
		for i in path.size() - 1:
			l += path[i].distance_to(path[i + 1])
		_lengths.append(l)
		_total += l
	if target != null and is_instance_valid(target):
		target.visible = false
		target.scale = Vector2(0.1, 0.1)


func _process(delta: float) -> void:
	_t += delta
	var pop_at := CLOSE_TIME + COLLAPSE_TIME
	if _t >= pop_at + POP_TIME:
		if is_instance_valid(_target):
			_target.visible = true
			_target.scale = Vector2.ONE
		queue_free()
		return
	if _t >= pop_at and is_instance_valid(_target):
		var s := _ease_pop((_t - pop_at) / POP_TIME)
		_target.visible = true
		_target.scale = Vector2(s, s)
	queue_redraw()


## Ease-out with a small overshoot — the same "pop, not a flat grow-in" curve
## ghost_spawn.gd uses for an arriving shape, so both ways a node can be born
## land the same way.
func _ease_pop(t: float) -> float:
	if t >= 1.0:
		return 1.0
	return (1.0 - pow(1.0 - t, 3.0)) * (1.0 + 0.12 * sin(t * PI))


func _draw() -> void:
	var col := Palette.of_res(_res)
	if _t < CLOSE_TIME:
		_draw_close(_t / CLOSE_TIME, col)
		return
	if _t < CLOSE_TIME + COLLAPSE_TIME:
		_draw_collapse((_t - CLOSE_TIME) / COLLAPSE_TIME, col)


## Stage 1. A bright head running around the whole circuit, with the ring
## already-travelled left glowing behind it, so by the end the entire ring is
## lit at once — the closed-circuit read.
func _draw_close(p: float, col: Color) -> void:
	var head := p * _total
	var walked := 0.0
	for i in _paths.size():
		var path := _paths[i]
		var seg_len: float = _lengths[i]
		# Whole vein already behind the head: hold it lit.
		if walked + seg_len <= head:
			var behind := col
			behind.a = 0.30 + 0.45 * p
			draw_polyline(path, behind, 3.4, true)
		elif walked < head:
			# The vein the head is currently crossing — brightest at the head
			# itself, trailing off over ARC of the ring behind it.
			var local := (head - walked) / seg_len
			var lit := PackedVector2Array()
			var upto := int(ceil(local * float(path.size() - 1)))
			for j in mini(upto + 1, path.size()):
				lit.append(path[j])
			if lit.size() >= 2:
				var hot := col
				hot.a = 0.85
				draw_polyline(lit, hot, 4.2, true)
			if lit.size() >= 1:
				var glow := col
				glow.a = 0.5
				draw_circle(lit[lit.size() - 1], 5.0 + 3.0 * sin(p * PI), glow)
		walked += seg_len
	# A faint hint of the arc length still unlit, so the ring reads as a ring
	# from the first frame rather than assembling out of nowhere.
	var rest := col
	rest.a = 0.12 * (1.0 - p) * ARC
	for path in _paths:
		draw_polyline(path, rest, 2.0, true)


## Stage 2. The Wells travel inward. Smoothstep, the same easing ghost_spawn
## uses for a node in transit — a flat lerp reads mechanical.
func _draw_collapse(p: float, col: Color) -> void:
	var eased := p * p * (3.0 - 2.0 * p)
	var fade := 1.0 - p
	var ring := col
	ring.a = 0.55 * fade
	for path in _paths:
		draw_polyline(path, ring, 3.4 * fade, true)
	var body := col
	body.a = 0.7 * fade + 0.3
	for f in _from:
		var at := f.lerp(_to, eased)
		# Shrinking as it goes: the circle is being consumed on the way in,
		# not just moved.
		draw_arc(at, VNode.RADIUS * (1.0 - eased * 0.65), 0.0, TAU,
			VNode.arc_points(VNode.RADIUS), body, 2.2, true)
	# The shape starts resolving out of the incoming circles over the last of
	# the journey, so the pop lands on something already forming.
	if eased > 0.55:
		var g := col
		g.a = (eased - 0.55) / 0.45
		var pts := VNode.demand_glyph_points(_res, GLYPH_S * eased)
		if pts.is_empty():
			return
		var shifted := PackedVector2Array()
		for pt in pts:
			shifted.append(pt + _to)
		draw_polyline(shifted, g, 2.4, true)
