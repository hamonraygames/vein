extends Node2D
## A knife-slash streak along the actual swipe path that just cut a vein —
## see game.gd's _slice_check ("Fruit-Ninja style: any vein the swipe path
## actually crosses gets cut"). The cut itself already worked with no visual
## call-out; this is purely the "you just sliced that with a blade" read, so
## the gesture teaches itself instead of the player wondering why a line
## disappeared. Same self-contained, self-freeing pattern as burst.gd —
## draws in absolute world coordinates, not relative to `position`.
##
## A bright core over a wider, dimmer glow, both fading fast — reads as a
## flash of motion rather than a static mark.

## Was 0.16 — "the sliding to cut animation should be a little bit longer,
## right now it's hard to see it." At a tenth of a second the streak was
## essentially a single-frame flicker: it fired, and the vein was already
## gone, so the gesture never got to teach itself (which is this whole
## node's reason to exist).
##
## Lengthened with a HOLD rather than by just stretching the linear fade,
## because tripling a straight fade turns a slash into a lingering smear —
## the opposite of the "flash of motion rather than a static mark" this is
## going for. The streak now sits at FULL brightness for the first stretch,
## which is what actually makes it register, then eases out over the rest.
const LIFE := 0.40
## Fraction of LIFE held at full brightness before the fade starts.
const HOLD := 0.3

var _from := Vector2.ZERO
var _to := Vector2.ZERO
var _t := 0.0


func spawn(from: Vector2, to: Vector2) -> void:
	_from = from
	_to = to
	z_index = 22


func _process(delta: float) -> void:
	_t += delta
	if _t >= LIFE:
		queue_free()
		return
	queue_redraw()


func _draw() -> void:
	# smoothstep returns 0 for the whole HOLD window, then eases 0->1 across
	# the remainder, so `fade` is a flat 1.0 and then a soft tail — see LIFE.
	var fade := 1.0 - smoothstep(HOLD, 1.0, clampf(_t / LIFE, 0.0, 1.0))
	var glow := Palette.SCORE
	glow.a = fade * 0.35
	draw_line(_from, _to, glow, 9.0 * fade + 2.0, true)
	var core := Palette.SCORE
	core.a = fade
	draw_line(_from, _to, core, 2.6, true)
