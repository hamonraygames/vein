extends Node2D
class_name VNode
## A node in the circulatory diagram: the Heart, or a Well that feeds it.
##
## Shape is the type. Motion is the throughput. Nothing here is ever labelled.

enum Kind { HEART, WELL, FORGE, LOOM }
enum Res { RAW, REFINED, CLOTH }

## A Forge eats this many RAW to emit one REFINED.
const FORGE_RATIO := 2

const RADIUS := 22.0
const HEART_RADIUS := 34.0
const BUFFER_CAP := 6

## What a Well produces, in seconds. Deliberately not beat-locked: wells drift
## against the heartbeat, so supply and demand slide in and out of phase.
const WELL_PERIOD := 1.45

var kind: int = Kind.WELL
var produces: int = Res.RAW

## Distance to the Heart over the vein graph. -1 means orphaned — nothing this
## node makes can reach anything that wants it.
var depth := -1

## Items waiting here for an outgoing vein with room. When this fills, a Well
## stops producing and the pips stack up visibly.
var buffer: Array[int] = []

## Forge only: RAW waiting to be smelted. Separate from `buffer` so a Forge's
## backlog of input doesn't block the REFINED it has already made.
var intake: Array[int] = []

## 0..1, decays. Drives the swell when the node emits or consumes.
var pulse := 0.0

## Heart only: how full it is, 0..1. Drawn as a level inside the hexagon so the
## goal of the game is legible on sight — the vessel is emptying, fill it. This
## is the one thing the player must understand and it must never need a number.
var fuel_ratio := 1.0

var _emit_accum := 0.0
var _round_robin := 0


func _ready() -> void:
	z_index = 10
	Beat.beat.connect(_on_beat)


func radius() -> float:
	return HEART_RADIUS if kind == Kind.HEART else RADIUS


func _on_beat(_i: int) -> void:
	if kind == Kind.HEART:
		# The Heart's swell IS the beat.
		pulse = 1.0


func _process(delta: float) -> void:
	pulse = maxf(0.0, pulse - delta * 3.2)
	if kind == Kind.WELL:
		_emit_accum += delta
		if _emit_accum >= WELL_PERIOD:
			_emit_accum -= WELL_PERIOD
			if buffer.size() < BUFFER_CAP:
				buffer.append(produces)
				pulse = 1.0
	elif kind == Kind.FORGE:
		_smelt()
	queue_redraw()


func take(kind_in: int) -> bool:
	# A Forge only swallows RAW; anything already refined passes through as cargo.
	if kind == Kind.FORGE and kind_in == Res.RAW:
		if intake.size() >= BUFFER_CAP:
			return false
		intake.append(kind_in)
		return true
	if buffer.size() >= BUFFER_CAP:
		return false
	buffer.append(kind_in)
	pulse = maxf(pulse, 0.6)
	return true


## Two RAW in, one REFINED out. The conversion halves the item count carrying the
## same run of fuel, which is why a Forge is the answer to a bursting trunk and
## not just a fuel multiplier.
func _smelt() -> void:
	if intake.size() < FORGE_RATIO or buffer.size() >= BUFFER_CAP:
		return
	for i in FORGE_RATIO:
		intake.pop_front()
	buffer.append(Res.REFINED)
	pulse = 1.0


## Round-robin so a node with two downhill veins splits its output between them
## instead of starving one.
func next_out(count: int) -> int:
	_round_robin = (_round_robin + 1) % maxi(count, 1)
	return _round_robin


func _draw() -> void:
	var col := Palette.HEART if kind == Kind.HEART else Palette.of_res(produces)
	var r := radius() * (1.0 + pulse * (0.16 if kind == Kind.HEART else 0.10))

	match kind:
		Kind.HEART: _draw_hex(r, col)
		Kind.FORGE: _draw_tri(r, col)
		_: _draw_ring(r, col)

	_draw_buffer(r, col)
	_draw_intake(r)


func _draw_hex(r: float, col: Color) -> void:
	var hex := PackedVector2Array()
	for i in 6:
		var a := TAU * (float(i) / 6.0) - PI * 0.5
		hex.append(Vector2(cos(a), sin(a)) * r)

	# A dim wash so an empty Heart is still a shape, not a hole.
	var base := col
	base.a = 0.07 + pulse * 0.10
	draw_colored_polygon(hex, base)

	# The level itself: clip the hexagon to everything below the fuel line. A
	# falling waterline is read instantly and without instruction; a bar or a
	# number would be neither.
	if fuel_ratio > 0.001:
		var line_y := r - 2.0 * r * clampf(fuel_ratio, 0.0, 1.0)
		var below := PackedVector2Array([
			Vector2(-r, line_y), Vector2(r, line_y), Vector2(r, r), Vector2(-r, r),
		])
		var fill := col
		fill.a = 0.34 + pulse * 0.34
		for poly in Geometry2D.intersect_polygons(hex, below):
			draw_colored_polygon(poly, fill)

	var outline := hex.duplicate()
	outline.append(hex[0])
	draw_polyline(outline, col, 3.0, true)


func _draw_ring(r: float, col: Color) -> void:
	var fill := col
	fill.a = 0.10 + pulse * 0.22
	draw_circle(Vector2.ZERO, r, fill)
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 32, col, 2.5, true)


func _draw_tri(r: float, col: Color) -> void:
	var tri := PackedVector2Array()
	for i in 3:
		var a := TAU * (float(i) / 3.0) - PI * 0.5
		tri.append(Vector2(cos(a), sin(a)) * r * 1.25)
	var fill := col
	fill.a = 0.10 + pulse * 0.26
	draw_colored_polygon(tri, fill)
	var outline := tri.duplicate()
	outline.append(tri[0])
	draw_polyline(outline, col, 2.5, true)


## Raw waiting to be smelted, drawn INSIDE the triangle so a starved Forge (one
## pip, waiting forever for its pair) is distinguishable from a busy one.
func _draw_intake(r: float) -> void:
	if kind != Kind.FORGE or intake.is_empty():
		return
	for i in mini(intake.size(), BUFFER_CAP):
		var p := Vector2(-6.0 + 6.0 * float(i % 3), 4.0 + 6.0 * float(i / 3))
		draw_circle(p, 2.0, Palette.RAW)


## Buffered items orbit the node as pips. A backed-up Well wears its congestion.
func _draw_buffer(r: float, col: Color) -> void:
	if buffer.is_empty():
		return
	var n := buffer.size()
	for i in n:
		var a := TAU * (float(i) / float(BUFFER_CAP)) - PI * 0.5
		var p := Vector2(cos(a), sin(a)) * (r + 9.0)
		draw_circle(p, 2.6, Palette.of_res(buffer[i]))
