extends Node
## Verifies the audio graph is actually live. We cannot hear it in-session, so
## this asserts the mechanical facts: streams loaded, beds are playing, the
## BLEND moves continuously with intensity/tension (no discrete stage index
## exists any more — see audio.gd's rewrite), the corruption drone tracks
## set_corruption, and one-shots occupy voices.

var _t := 0.0
var _stage := 0

func _process(delta: float) -> void:
	# Real delta, matching what Audio._process sees — the exponential smoothing
	# converges in wall-clock time, so faking the clock here would print numbers
	# that never actually occur in the running game.
	_t += delta
	if _stage == 0 and _t > 0.5:
		_stage = 1
		print("beds loaded: %d / %d" % [Audio._beds.size(), Audio.MUSIC.size()])
		print("sfx loaded:  %d / %d" % [Audio._streams.size(), Audio.SFX.size()])
		var playing := 0
		for p in Audio._beds:
			if p.playing:
				playing += 1
		print("beds playing: %d" % playing)
		print("drone loaded: %s" % (Audio._drone != null))
	elif _stage == 1 and _t > 1.0:
		_stage = 2
		get_parent().run_time = 0.9 * get_parent().EXERTION_SPAN
	elif _stage == 2 and _t > 4.0:
		_stage = 3
		var db := []
		for p in Audio._beds:
			db.append(snappedf(p.volume_db, 0.1))
		print("intensity=%.2f bed volumes (calm/driving/frantic): %s (frantic should dominate)"
			% [Audio.intensity, str(db)])
		var loudest := 0
		for i in db.size():
			if db[i] > db[loudest]:
				loudest = i
		print("loudest bed index: %d (expect 2)" % loudest)
	elif _stage == 3 and _t > 4.2:
		_stage = 4
		# Drive the REAL path again: game.gd calls
		# Audio.set_corruption(_corruption_ratio()) every frame, which would
		# immediately overwrite a direct poke on the next frame (this is exactly
		# the earlier "poking Audio directly gets stomped" bug, recurring for a
		# second continuous input). Corrupt an actual Well instead.
		var game := get_parent()
		var target: VNode = null
		for n in game.nodes:
			if n.kind == VNode.Kind.WELL:
				target = n
				break
		if target != null:
			target.corrupt()
			print("corrupted 1 well; game._corruption_ratio() now: %.2f" % game._corruption_ratio())
		else:
			print("no Well found to corrupt (unexpected)")
	elif _stage == 4 and _t > 6.5:
		_stage = 5
		# Exact target depends on how many OTHER Wells exist by this point (the
		# ratio is corrupted/total live Wells) — the only thing asserted here is
		# that it moved off the silent floor at all.
		print("drone volume_db after corrupting a well: %.1f (expect > -75, was -80 at start)"
			% Audio._drone.volume_db)
		Audio.play("rupture")
		Audio.swallow(0, 0.9)
		var busy := 0
		for v in Audio._voices:
			if v.playing:
				busy += 1
		print("voices busy after 2 one-shots: %d" % busy)
		get_tree().quit()
