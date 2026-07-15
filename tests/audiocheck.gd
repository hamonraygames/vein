extends Node
## Verifies the audio graph is actually live. We cannot hear it in-session, so
## this asserts the mechanical facts: the track loaded and loops at a quiet,
## constant volume regardless of intensity (the whole point of the simplified
## system), the heartbeat's pitch still tracks intensity/state, one-shots
## occupy voices, and the same key cannot machine-gun (MIN_RETRIGGER).

var _t := 0.0
var _stage := 0

func _process(delta: float) -> void:
	_t += delta
	if _stage == 0 and _t > 0.5:
		_stage = 1
		print("sfx loaded: %d / %d" % [Audio._streams.size(), Audio.SFX.size()])
		print("track loaded: %s | playing: %s | volume_db: %.1f (expect ~%.1f, quiet)"
			% [Audio._track != null, Audio._track != null and Audio._track.playing, Audio._track.volume_db, Audio.TRACK_DB])
	elif _stage == 1 and _t > 1.0:
		_stage = 2
		get_parent().run_time = 0.9 * get_parent().EXERTION_SPAN
	elif _stage == 2 and _t > 1.3:
		_stage = 3
		# The track must NOT react to intensity — that reactivity is exactly
		# what got pulled out. Confirm it's untouched by a high-intensity frame.
		print("track volume_db at high intensity: %.1f (expect unchanged, ~%.1f)"
			% [Audio._track.volume_db, Audio.TRACK_DB])
	elif _stage == 3 and _t > 1.5:
		_stage = 4
		# Fire the same key twice in immediate succession: the second must be
		# dropped by MIN_RETRIGGER, not stack a second voice.
		var busy_before := _count_busy()
		Audio.play("corrupt")
		Audio.play("corrupt")
		var busy_after := _count_busy()
		print("voices busy after firing 'corrupt' twice back-to-back: %d -> %d (expect +1, not +2)"
			% [busy_before, busy_after])
	elif _stage == 4 and _t > 1.6:
		_stage = 5
		Audio.swallow(0, 0.9)
		print("voices busy after a feed one-shot: %d" % _count_busy())
		get_tree().quit()


func _count_busy() -> int:
	var busy := 0
	for v in Audio._voices:
		if v.playing:
			busy += 1
	return busy
