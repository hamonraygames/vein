extends Node
## All sound. Autoload, subscribed to Beat like everything else.
##
## Two layers, because the run needs both halves:
##
## 1. A MUSIC BED that gains intensity as the run escalates — this is the "it
##    starts easy and then gets crazy" channel. Tracks are crossfaded by stage,
##    not restarted, so escalation is felt rather than announced.
## 2. BEAT-SYNCED ONE-SHOTS: the heart itself, and a note per item the Heart
##    swallows. The economy plays over the bed, so a fat network is audibly
##    busier than a thin one.
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

## Stage thresholds on `intensity` (0..1) at which each bed takes over.
const BED_ORDER := ["calm", "driving", "frantic"]
const BED_AT := [0.0, 0.18, 0.46]

const FADE := 0.9
const MUSIC_DB := -15.0
## One-shots are pooled: a busy network fires a lot of notes per beat and
## allocating players per note would stutter on a mid-range phone.
const VOICES := 14

var intensity := 0.0

var _beds: Array[AudioStreamPlayer] = []
## One live fade per bed. Without this, every _select_bed spawns a fresh tween
## per player while the previous one is still running, and the two fight over
## volume_db — the incoming bed measured -75dB (silent) when it should have been
## at -9dB. Stale fades must be killed, not out-voted.
var _fades: Array[Tween] = []
var _bed_idx := -1
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
		_fades.append(null)

	for i in VOICES:
		var v := AudioStreamPlayer.new()
		v.bus = "Master"
		add_child(v)
		_voices.append(v)

	_ready_ok = _beds.size() > 0
	Beat.beat.connect(_on_beat)


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
	_bed_idx = -1
	for p in _beds:
		if not p.playing:
			p.play()
		p.volume_db = -80.0
	_select_bed(0)


func stop_all() -> void:
	for p in _beds:
		p.stop()


## 0..1 from the game's escalation clock. Drives which bed is audible.
func set_intensity(v: float) -> void:
	intensity = clampf(v, 0.0, 1.0)
	var want := 0
	for i in BED_AT.size():
		if intensity >= BED_AT[i]:
			want = i
	if want != _bed_idx:
		_select_bed(want)


func _select_bed(i: int) -> void:
	if i < 0 or i >= _beds.size():
		return
	_bed_idx = i
	for j in _beds.size():
		var target := MUSIC_DB if j == i else -80.0
		if _fades[j] != null and _fades[j].is_valid():
			_fades[j].kill()
		var tw := create_tween()
		_fades[j] = tw
		tw.tween_property(_beds[j], "volume_db", target, FADE)


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
	# A racing heart late in a healthy run tightens up rather than staying calm.
	if Beat.state == Beat.State.HEALTHY:
		pitch = lerpf(1.0, 1.16, intensity)
	play(cfg.key, cfg.db, pitch)
	# Each beat is a fresh budget of note voices — see `swallow`.
	_notes_this_beat = 0


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
const NOTES_PER_BEAT := 2

var _notes_this_beat := 0


func swallow(res_kind: int, fullness: float) -> void:
	if res_kind == VNode.Res.VOID:
		play("corrupt", -6.0, 0.66)
		return

	if _notes_this_beat >= NOTES_PER_BEAT:
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
