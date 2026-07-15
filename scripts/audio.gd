extends Node
## All sound. Autoload, subscribed to Beat like everything else.
##
## Playtest, twice: "the sound doesn't progress, it should progress as the game
## progresses." The first version deserved that — three tracks hard-switched at
## two fixed thresholds, silent between switches. That is a slideshow, not
## progression. This version has no discrete stages left in it at all: every
## input (intensity, tension, corruption) is a continuous 0..1 signal read every
## frame, and every bed volume/pitch is a continuous function of those signals,
## recomputed every frame in `_process`. There is no event that "starts" the
## next phase of the mix — it just always is what the run currently is.
##
## Three continuous layers:
## 1. MUSIC BEDS, blended (not switched) by a moving weight curve over
##    intensity, so two adjacent tracks are usually both partially audible and
##    the crossover is a smear, not a cut. Pitch climbs continuously with
##    intensity too.
## 2. A CORRUPTION DRONE, volume tracking the live fraction of rotted Wells —
##    the mix should sicken exactly as fast as the board does, not on a timer.
## 3. BEAT-SYNCED ONE-SHOTS, whose density (not just volume) scales with
##    intensity and combo TENSION — a fat, skillfully-played network is
##    audibly busier than a thin one, continuously, beat to beat.
##
## Everything here is real recorded CC0 material (see assets/CREDITS.md).
## Nothing is synthesised — filtered-noise "audio" has been rejected on this
## project before and it is not worth re-litigating.

const MUSIC := {
	"calm": "res://assets/audio/megawall.mp3",
	"driving": "res://assets/audio/cyberpunk_sonata.mp3",
	"frantic": "res://assets/audio/fight.ogg",
}

const SFX := {
	"beat_slow": "res://assets/audio/heartbeat_slow.wav",
	"beat_fast": "res://assets/audio/heartbeat_fast.wav",
	"raw": "res://assets/audio/note_raw.ogg",
	"refined": "res://assets/audio/note_refined.ogg",
	"rupture": "res://assets/audio/rupture.ogg",
	"corrupt": "res://assets/audio/corrupt.ogg",
}

## Where each bed sits on the 0..1 intensity axis. Blending is a triangular
## weight around each centre (see _bed_weight), so at intensity 0.3 — between
## calm's 0.0 and driving's 0.45 — BOTH are audible at partial volume, not one
## or the other. Nothing about the mix ever jumps.
const BED_ORDER := ["calm", "driving", "frantic"]
const BED_CENTRE := [0.0, 0.45, 1.0]

const MUSIC_DB := -15.0
const BLEND_RATE := 1.4      ## how fast volume chases its (constantly moving) target
const PITCH_RATE := 0.6
## One-shots are pooled: a busy network fires a lot of notes per beat and
## allocating players per note would stutter on a mid-range phone.
const VOICES := 16

## Corruption drone: a low, quiet, looped use of the same "corrupt" hit,
## pitched far down into a sustained sick tone rather than a stab.
const DRONE_DB := -22.0
const DRONE_PITCH := 0.28

var intensity := 0.0
var tension := 0.0     ## 0..1, from the combo streak — see set_tension
var corruption := 0.0  ## 0..1, live fraction of rotted Wells — see set_corruption

var _beds: Array[AudioStreamPlayer] = []
var _bed_volumes: Array[float] = []   ## current (smoothed) volume_db per bed
var _drone: AudioStreamPlayer
var _drone_volume := -80.0
var _voices: Array[AudioStreamPlayer] = []
var _next_voice := 0
var _streams := {}
var _ready_ok := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	for key in SFX:
		var s: AudioStream = load(SFX[key])
		if s == null:
			push_warning("audio: missing %s" % SFX[key])
			continue
		_streams[key] = s

	for i in BED_ORDER.size():
		var p := AudioStreamPlayer.new()
		var path: String = MUSIC[BED_ORDER[i]]
		var st: AudioStream = load(path)
		if st == null:
			push_warning("audio: missing %s" % path)
			continue
		_set_loop(st)
		p.stream = st
		p.volume_db = -80.0
		p.bus = "Master"
		add_child(p)
		_beds.append(p)
		_bed_volumes.append(-80.0)

	if _streams.has("corrupt"):
		_drone = AudioStreamPlayer.new()
		var dst: AudioStream = _streams["corrupt"]
		_set_loop(dst)
		_drone.stream = dst
		_drone.volume_db = -80.0
		_drone.pitch_scale = DRONE_PITCH
		_drone.bus = "Master"
		add_child(_drone)

	for i in VOICES:
		var v := AudioStreamPlayer.new()
		v.bus = "Master"
		add_child(v)
		_voices.append(v)

	_ready_ok = _beds.size() > 0
	Beat.beat.connect(_on_beat)
	set_process(true)


## Godot does not loop mp3/ogg by default, and a bed that stops 90 seconds in
## reads as "the audio broke", not as design.
func _set_loop(st: AudioStream) -> void:
	if st is AudioStreamMP3:
		st.loop = true
	elif st is AudioStreamOggVorbis:
		st.loop = true


func start() -> void:
	if not _ready_ok:
		return
	intensity = 0.0
	tension = 0.0
	corruption = 0.0
	for i in _beds.size():
		if not _beds[i].playing:
			_beds[i].play()
		_beds[i].volume_db = -80.0
		_bed_volumes[i] = -80.0
	if _drone != null:
		if not _drone.playing:
			_drone.play()
		_drone.volume_db = -80.0
		_drone_volume = -80.0


func stop_all() -> void:
	for p in _beds:
		p.stop()
	if _drone != null:
		_drone.stop()


## 0..1 from the game's escalation clock. This is the master "how crazy is it
## right now" signal — everything else in the mix reads it.
func set_intensity(v: float) -> void:
	intensity = clampf(v, 0.0, 1.0)


## 0..1 from the live combo streak. A clean run under skillful play should
## sound MORE alive, not just louder — tension nudges the blend toward the
## next bed up and thickens the one-shot layer, so playing well is something
## you hear, beat to beat, not just something the score records.
func set_tension(v: float) -> void:
	tension = clampf(v, 0.0, 1.0)


## 0..1, live fraction of Wells currently rotted. Drives the corruption drone
## continuously — the mix sickens exactly as fast as the board does.
func set_corruption(v: float) -> void:
	corruption = clampf(v, 0.0, 1.0)


## Triangular weight: 1.0 exactly at this bed's centre, falling linearly to 0.0
## at the neighbouring centres. Two adjacent beds are audible simultaneously
## everywhere except exactly on a centre, which is what makes the crossfade a
## continuous smear instead of a switch.
func _bed_weight(i: int, blend: float) -> float:
	var c: float = BED_CENTRE[i]
	var lo: float = BED_CENTRE[i - 1] if i > 0 else -1.0
	var hi: float = BED_CENTRE[i + 1] if i < BED_CENTRE.size() - 1 else 2.0
	if blend <= c:
		return 1.0 if lo < -0.5 else clampf((blend - lo) / (c - lo), 0.0, 1.0)
	return 1.0 if hi > 1.5 else clampf(1.0 - (blend - c) / (hi - c), 0.0, 1.0)


func _process(delta: float) -> void:
	if not _ready_ok:
		return

	# Tension pulls the blend point ahead of the clock — playing a hot streak
	# should visibly (audibly) drag the mix toward the next stage, then relax
	# back as the clock's own intensity resumes control.
	var blend := clampf(intensity + tension * 0.22, 0.0, 1.0)

	for i in _beds.size():
		var target := MUSIC_DB + linear_to_db(maxf(_bed_weight(i, blend), 0.0001))
		_bed_volumes[i] = _approach(_bed_volumes[i], target, BLEND_RATE, delta)
		_beds[i].volume_db = _bed_volumes[i]
		var pitch_target := 1.0 + blend * 0.08 + tension * 0.05
		_beds[i].pitch_scale = _approach(_beds[i].pitch_scale, pitch_target, PITCH_RATE, delta)

	if _drone != null:
		var drone_target := -80.0 if corruption <= 0.001 \
			else DRONE_DB + linear_to_db(corruption)
		_drone_volume = _approach(_drone_volume, drone_target, 1.1, delta)
		_drone.volume_db = _drone_volume
		_drone.pitch_scale = DRONE_PITCH + corruption * 0.1


## Exponential approach — used for both volume_db and pitch_scale. In dB space
## this makes a fade sound like a constant-rate fade throughout instead of
## front-loaded, which is the reason it is not a plain lerp.
func _approach(from: float, to: float, rate: float, delta: float) -> float:
	return lerpf(from, to, 1.0 - exp(-rate * maxf(delta, 0.0)))


## The heart is the anchor of the mix and must always be the loudest thing in it.
## It also has to TELL you it is dying without a single visual: as the state
## degrades the beat drops in pitch and gets heavier, so a heart in trouble
## sounds laboured and wrong long before you read the board. The rate itself
## already slows (Beat.RATE_BY_STATE); this is the timbre on top of that.
const BEAT_BY_STATE := {
	Beat.State.HEALTHY: {"key": "beat_slow", "db": -1.5, "pitch": 1.0},
	Beat.State.STRAINED: {"key": "beat_fast", "db": -0.5, "pitch": 1.1},
	Beat.State.DYING: {"key": "beat_slow", "db": 0.0, "pitch": 0.66},
	Beat.State.STOPPED: {"key": "beat_slow", "db": 0.0, "pitch": 0.5},
}


func _on_beat(_i: int) -> void:
	var cfg: Dictionary = BEAT_BY_STATE.get(Beat.state, BEAT_BY_STATE[Beat.State.HEALTHY])
	var pitch: float = cfg.pitch
	# A racing heart late in a healthy run tightens up rather than staying calm,
	# and a hot streak tightens it further still — the beat itself carries
	# tension, continuously, not just the bed underneath it.
	if Beat.state == Beat.State.HEALTHY:
		pitch = lerpf(1.0, 1.16, intensity) + tension * 0.05
	play(cfg.key, cfg.db, pitch)
	# Each beat is a fresh budget of note voices — see `swallow`. The budget
	# itself grows with intensity: a calm heart should sound sparse, a racing
	# one should sound busy, continuously, not in three fixed steps.
	_notes_this_beat = 0
	_notes_budget = NOTES_PER_BEAT_BASE + int(round((intensity + tension * 0.4) * NOTES_PER_BEAT_MAX_BONUS))


## Fire a one-shot. `pitch` lets callers detune — starvation should sound wrong.
func play(key: String, db: float = -8.0, pitch: float = 1.0) -> void:
	if not _streams.has(key):
		return
	var v := _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	v.stream = _streams[key]
	v.volume_db = db
	v.pitch_scale = pitch
	v.play()


## The Heart swallowing something.
##
## Playtest: "the dots hitting the heart sound is annoying." It was — every
## single arrival fired a bright metal ding at -14dB, so a healthy network
## machine-gunned the mix and drowned out the heartbeat, which is supposed to be
## the anchor. Three fixes, all needed:
##   - Pitched DOWN into a soft thud rather than a ring, and cut way back in
##     level so it sits under the heart instead of over it.
##   - Rate-limited per beat: a fat network should sound busy, not like a
##     stuck buzzer. Extra arrivals still land, they just don't all speak.
##   - Poison keeps its full voice. A VOID hit is rare and must always cut
##     through — that one is meant to alarm you.
##
## The per-beat budget is no longer fixed at 2 — it scales continuously with
## intensity and tension (set in _on_beat), so the density of the mix itself
## is part of the progression, not just its volume.
const NOTES_PER_BEAT_BASE := 1
const NOTES_PER_BEAT_MAX_BONUS := 4

var _notes_budget := NOTES_PER_BEAT_BASE

var _notes_this_beat := 0


func swallow(res_kind: int, fullness: float) -> void:
	if res_kind == VNode.Res.VOID:
		play("corrupt", -6.0, 0.66)
		return

	if _notes_this_beat >= _notes_budget:
		return
	_notes_this_beat += 1

	if res_kind == VNode.Res.CLOTH:
		play("refined", -20.0, lerpf(0.38, 0.50, fullness))
	elif res_kind == VNode.Res.REFINED:
		play("refined", -22.0, lerpf(0.52, 0.68, fullness))
	else:
		play("raw", -26.0, lerpf(0.44, 0.58, fullness))


func sync_hit(combo: int, perfect: bool) -> void:
	var pitch := 0.70 + float(combo) * 0.045
	var db := -18.0 + minf(float(combo), 8.0) * 0.8
	play("refined" if perfect else "raw", db, pitch)
