extends Node
## Verifies the audio graph is actually live. We cannot hear it in-session, so
## this asserts the mechanical facts: streams loaded, a bed is playing, the bed
## swaps as intensity rises, and one-shots occupy voices.

var _t := 0.0
var _stage := 0

func _process(delta: float) -> void:
	_t += delta
	if _stage == 0 and _t > 0.5:
		_stage = 1
		print("beds loaded: %d / %d" % [Audio._beds.size(), Audio.MUSIC.size()])
		print("sfx loaded:  %d / %d" % [Audio._streams.size(), Audio.SFX.size()])
		var playing := 0
		for p in Audio._beds:
			if p.playing:
				playing += 1
		print("beds playing: %d (bed_idx=%d)" % [playing, Audio._bed_idx])
		print("bed0 volume_db: %.1f" % Audio._beds[0].volume_db)
	elif _stage == 1 and _t > 1.0:
		_stage = 2
		# Drive the REAL path: the game calls set_intensity(run_time/EXERTION_SPAN)
		# every frame, so poking Audio directly is overwritten on the next frame.
		get_parent().run_time = 0.8 * get_parent().EXERTION_SPAN
		print("run_time->0.8 span, bed_idx=%d (expect 2)" % Audio._bed_idx)
	elif _stage == 2 and _t > 3.2:
		_stage = 3
		print("after fade, bed2 volume_db: %.1f (expect ~%.1f)" % [Audio._beds[2].volume_db, Audio.MUSIC_DB])
		Audio.play("rupture")
		Audio.swallow(0, 0.9)
		var busy := 0
		for v in Audio._voices:
			if v.playing:
				busy += 1
		print("voices busy after 2 one-shots: %d" % busy)
		get_tree().quit()
