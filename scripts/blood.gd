extends Node2D
## The death screen's blood burst, spawned once from game.gd's _on_stopped.
##
## Droplets erupt outward from where the Heart sat, arc under a light pull
## back down, and fade — "a particle effect that the heart blows blood out
## of it," not rain falling from the top of the screen with no source.
## Bursts repeat on a very short interval — close enough together that they
## read as one continuous fountain rather than separate periodic spurts —
## and each burst is big enough to fling shards clear to the screen edges
## rather than staying huddled around the Heart.
##
## Self-contained and self-freeing like BurstScene/FloatText — the caller
## just spawns it and forgets it; game.gd frees it on replay.

const COL := Color(0.56, 0.04, 0.06)

const BURST_INTERVAL := 0.1
const BURST_COUNT := 18
const GRAVITY := 90.0

var _origin := Vector2(270.0, 515.0)
var _rng := RandomNumberGenerator.new()

var _drops: Array[Dictionary] = []
var _burst_t := 0.0


func start(heart_pos: Vector2, run_seed: int) -> void:
	_origin = heart_pos
	z_index = 60
	_rng.seed = run_seed
	_burst_t = BURST_INTERVAL   # fire the first burst immediately


## Jagged shards, not round droplets — "cartoonish, not harsh" was the exact
## complaint, and a soft-glow circle drifting on a graceful arc IS cartoon
## particle language. A few sharp, irregular points per shard, generated
## once at spawn (not regenerated every frame — that would flicker instead
## of reading as a solid fragment), snappier lifetimes and harder gravity
## so the whole burst feels sudden and violent rather than a lazy spray.
func _spawn_burst() -> void:
	for i in BURST_COUNT:
		var a := _rng.randf() * TAU
		# Slower than the shard size suggests — big, heavy chunks that drift
		# rather than shoot, but live long enough to still drift clear to the
		# screen edges from the Heart's position.
		var speed := _rng.randf_range(90.0, 260.0)
		var n := _rng.randi_range(3, 5)
		var shard := PackedVector2Array()
		for j in n:
			var sa := TAU * float(j) / float(n) + _rng.randf_range(-0.35, 0.35)
			var sr := _rng.randf_range(16.0, 34.0)
			shard.append(Vector2(cos(sa), sin(sa)) * sr)
		_drops.append({
			"p": _origin,
			"v": Vector2(cos(a), sin(a)) * speed,
			"shard": shard,
			"rot": _rng.randf() * TAU,
			"spin": _rng.randf_range(-9.0, 9.0),
			"life": 0.0,
			"max_life": _rng.randf_range(1.4, 2.4),
		})


func _process(delta: float) -> void:
	_burst_t += delta
	if _burst_t >= BURST_INTERVAL:
		_burst_t = 0.0
		_spawn_burst()

	var kept_drops: Array[Dictionary] = []
	for d in _drops:
		d.life += delta
		if d.life >= d.max_life:
			continue
		d.v.y += GRAVITY * delta
		d.p += d.v * delta
		d.rot += d.spin * delta
		kept_drops.append(d)
	_drops = kept_drops

	queue_redraw()


func _draw() -> void:
	for d in _drops:
		var fade: float = 1.0 - d.life / d.max_life
		var c := COL
		c.a = 0.9 * fade
		var pts := PackedVector2Array()
		for p in d.shard:
			pts.append(d.p + p.rotated(d.rot))
		draw_colored_polygon(pts, c)
