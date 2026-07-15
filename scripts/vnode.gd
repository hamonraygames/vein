extends Node2D
class_name VNode
## A node in the circulatory diagram: the Heart, or a Well that feeds it.
##
## Shape is the type. Motion is the throughput. Nothing here is ever labelled.

enum Kind { HEART, WELL, FORGE, LOOM }
enum Res { RAW, REFINED, CLOTH }

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

## 0..1, decays. Drives the swell when the node emits or consumes.
var pulse := 0.0

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
	queue_redraw()


func take(kind_in: int) -> bool:
	if buffer.size() >= BUFFER_CAP:
		return false
	buffer.append(kind_in)
	pulse = maxf(pulse, 0.6)
	return true


## Round-robin so a node with two downhill veins splits its output between them
## instead of starving one.
func next_out(count: int) -> int:
	_round_robin = (_round_robin + 1) % maxi(count, 1)
	return _round_robin


func _draw() -> void:
	var col := Palette.HEART if kind == Kind.HEART else Palette.of_res(produces)
	var r := radius() * (1.0 + pulse * (0.16 if kind == Kind.HEART else 0.10))

	if kind == Kind.HEART:
		_draw_hex(r, col)
	else:
		_draw_ring(r, col)

	_draw_buffer(r, col)


func _draw_hex(r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 6:
		var a := TAU * (float(i) / 6.0) - PI * 0.5
		pts.append(Vector2(cos(a), sin(a)) * r)
	pts.append(pts[0])
	# Inner glow scales with the swell — a full heart looks lit from inside.
	var fill := col
	fill.a = 0.10 + pulse * 0.30
	draw_colored_polygon(pts, fill)
	draw_polyline(pts, col, 3.0, true)


func _draw_ring(r: float, col: Color) -> void:
	var fill := col
	fill.a = 0.10 + pulse * 0.22
	draw_circle(Vector2.ZERO, r, fill)
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 32, col, 2.5, true)


## Buffered items orbit the node as pips. A backed-up Well wears its congestion.
func _draw_buffer(r: float, col: Color) -> void:
	if buffer.is_empty():
		return
	var n := buffer.size()
	for i in n:
		var a := TAU * (float(i) / float(BUFFER_CAP)) - PI * 0.5
		var p := Vector2(cos(a), sin(a)) * (r + 9.0)
		draw_circle(p, 2.6, Palette.of_res(buffer[i]))
