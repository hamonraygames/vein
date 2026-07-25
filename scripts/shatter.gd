extends Node2D
## The death screen's wreckage field, spawned once from game.gd's _on_stopped.
##
## Replaces the old blood-fountain particle effect: instead of an abstract
## spray unrelated to what was actually on the board, every node that was
## still alive when the Heart stopped — the Heart itself, every Well, every
## tool — breaks apart into pieces of its OWN shape and colour, from its OWN
## position. The board doesn't bleed, it shatters.
##
## Built once from a snapshot at death (see start()), not live VNodes — the
## real nodes are hidden by game.gd the instant this spawns, so there is
## never a shattered copy sitting on top of an intact one.
##
## Self-contained and self-freeing like BurstScene/FloatText — the caller
## just spawns it and forgets it; game.gd frees it on replay.

const CIRCLE_SIDES := 14

var _rng := RandomNumberGenerator.new()
var _bits: Array[Dictionary] = []


func start(snapshots: Array[Dictionary], run_seed: int) -> void:
	# Behind the death screen's UI (headline/score/buttons all sit at the
	# default z_index 0) — the wreckage reads as a backdrop, not something
	# blocking the controls. Same convention the old blood fountain used.
	z_index = -1
	_rng.seed = run_seed
	for snap in snapshots:
		_shatter_one(snap.pos, snap.color, snap.radius, snap.kind)


## Fan-triangulates the shape's own outline from its centre — each shard IS a
## slice of the real silhouette, not a generic jagged chunk. Shards are drawn
## slightly SHRUNK toward their own midpoint (see SHARD_SHRINK below) so gaps
## open between them the instant they start moving, reading as a break rather
## than a shape that merely split into a pie chart.
const SHARD_SHRINK := 0.86

func _shatter_one(pos: Vector2, col: Color, r: float, kind: int) -> void:
	var outline := _shape_points(kind, r)
	var n := outline.size()
	for i in n:
		var a: Vector2 = outline[i]
		var b: Vector2 = outline[(i + 1) % n]
		var mid := (Vector2.ZERO + a + b) / 3.0
		# Each shard is the {centre, a, b} wedge, pulled toward its own
		# midpoint by SHARD_SHRINK — shrinking in local (mid-relative) space
		# is what opens a visible gap between shards without changing where
		# the shard's centre sits in the shape.
		var poly := PackedVector2Array([
			(Vector2.ZERO - mid) * SHARD_SHRINK,
			(a - mid) * SHARD_SHRINK,
			(b - mid) * SHARD_SHRINK,
		])
		# Radiate outward from the shape's own centre, blended with a little
		# pure randomness so a shape with only a few big shards (a triangle,
		# a square) doesn't fly apart in three perfectly even directions.
		var out_dir := mid.normalized() if mid.length() > 0.001 else Vector2.RIGHT.rotated(_rng.randf() * TAU)
		var rand_dir := Vector2.RIGHT.rotated(_rng.randf() * TAU)
		var dir := (out_dir.lerp(rand_dir, 0.25)).normalized()
		var speed := _rng.randf_range(70.0, 200.0)
		_bits.append({
			"p": pos + mid,
			"local": poly,
			"v": dir * speed,
			"rot": _rng.randf() * TAU,
			"spin": _rng.randf_range(-7.0, 7.0),
			"col": col,
			"life": 0.0,
			"max_life": _rng.randf_range(2.4, 3.8),
		})


## Local-space outline, matching each shape's real silhouette in vnode.gd
## (see _draw_tri/_draw_square/_draw_pentagon/_draw_hexagon/_draw_ring and
## _heart_points there) closely enough to read as the same object breaking —
## exact corner-rounding on the Heart isn't worth duplicating here, the
## shards are about to fly apart anyway.
func _shape_points(kind: int, r: float) -> PackedVector2Array:
	match kind:
		VNode.Kind.HEART:
			return _heart_outline(r)
		VNode.Kind.FORGE:
			return _regular_poly(3, r * 1.25)
		VNode.Kind.LOOM:
			var half := r * 0.825
			return PackedVector2Array([
				Vector2(-half, -half), Vector2(half, -half),
				Vector2(half, half), Vector2(-half, half),
			])
		VNode.Kind.KILN:
			return _regular_poly(5, r * 1.35)
		VNode.Kind.CRUCIBLE:
			return _regular_poly(6, r * 1.28)
		_:
			return _regular_poly(CIRCLE_SIDES, r)


func _regular_poly(sides: int, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in sides:
		var a := TAU * float(i) / float(sides) - PI * 0.5
		pts.append(Vector2(cos(a), sin(a)) * r)
	return pts


## Same fourteen hand-placed, straight-edged vertices and horizontal stretch
## as VNode.HEART_POINTS/HEART_WIDTH_MULT — the Heart has no curve left to
## sample, so its shattered pieces are wedges of this polygon like every
## other shape here (see _shatter_one's fan triangulation).
const HEART_POINTS: Array[Vector2] = [
	Vector2(0.00, -0.48), Vector2(0.22, -0.82), Vector2(0.55, -0.85), Vector2(0.88, -0.55),
	Vector2(1.00, -0.15), Vector2(0.75, 0.43), Vector2(0.46, 0.72), Vector2(0.00, 1.05),
	Vector2(-0.46, 0.72), Vector2(-0.75, 0.43), Vector2(-1.00, -0.15), Vector2(-0.88, -0.55),
	Vector2(-0.55, -0.85), Vector2(-0.22, -0.82),
]
const HEART_WIDTH_MULT := 1.18

func _heart_outline(r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for p in HEART_POINTS:
		pts.append(Vector2(p.x * HEART_WIDTH_MULT, p.y) * r)
	return pts


func _process(delta: float) -> void:
	var kept: Array[Dictionary] = []
	for b in _bits:
		b.life += delta
		if b.life >= b.max_life:
			continue
		b.p += b.v * delta
		b.rot += b.spin * delta
		kept.append(b)
	_bits = kept
	queue_redraw()


func _draw() -> void:
	for b in _bits:
		var fade: float = 1.0 - b.life / b.max_life
		var c: Color = b.col
		c.a = 0.55 * fade
		var pts := PackedVector2Array()
		for p in b.local:
			pts.append(b.p + p.rotated(b.rot))
		draw_colored_polygon(pts, c)
