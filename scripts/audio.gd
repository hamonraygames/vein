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
const BED_AT := [0.0, 0.34, 0.70]

const FADE := 1.6
const MUSIC_DB := -9.0
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


func _on_beat(_i: int) -> void:
	# The heart is the metronome, and it is the loudest thing in the mix.
	var key := "beat_fast" if Beat.state != Beat.State.HEALTHY or intensity > 0.5 else "beat_slow"
	play(key, -4.0)


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


## The Heart swallowing something. Pitch rises with how full it is, so a healthy
## network plays UP and a starving one sags — the mix tells you the state before
## you look.
func swallow(res_kind: int, fullness: float) -> void:
	match res_kind:
		2, 3:
			play("corrupt", -5.0, 0.72)
		1:
			play("refined", -11.0, lerpf(0.86, 1.18, fullness))
		_:
			play("raw", -14.0, lerpf(0.82, 1.26, fullness))
