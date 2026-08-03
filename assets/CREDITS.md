# Credits

All audio in VEIN is **real recorded/produced CC0 material**, mostly sourced
from [OpenGameArt](https://opengameart.org) with the voice lines from
[Kenney](https://kenney.nl). Nothing here is synthesised in-engine — that is
a deliberate standing constraint on this project, not an accident.

Every asset below is **CC0 1.0 (public domain dedication)**, which imposes no
attribution requirement. This file exists anyway: knowing where a sample came
from is what makes it replaceable later.

## Music

**In use:** `audio/ambient_dark.ogg` only. It is a DRONE, not a song —
deliberately. VEIN already has a rhythm section (the heartbeat), so a
background piece with its own percussion fights it for the same job; the
composed tracks below all did, which is what "there's a drum sound I don't
like" was about.

| File | Source | Author | License | Status |
|---|---|---|---|---|
| `audio/ambient_dark.ogg` | [Dark Place (loop)](https://opengameart.org/content/dark-place-loop) | Brandon Morris | CC0 | **in use** |
| `audio/megawall.mp3` | [Awake (megaWall 10)](https://opengameart.org/content/awake-megawall-10) | Alexandr Zhelanov | CC0 | unused |
| `audio/cyberpunk_sonata.mp3` | [Cyberpunk Moonlight Sonata](https://opengameart.org/content/cyberpunk-moonlight-sonata) | Joth | CC0 | unused |
| `audio/fight.ogg` | [Fast Fight Battle Music](https://opengameart.org/content/fast-fight-battle-music) | Sirkoto51 | CC0 | unused |

## Heartbeat

| File | Source | Author | License |
|---|---|---|---|
| `audio/heartbeat_slow.wav` | [Heartbeat Sounds](https://opengameart.org/content/heartbeat-sounds) | Mrthenoronha | CC0 |
| `audio/heartbeat_fast.wav` | [Heartbeat Sounds](https://opengameart.org/content/heartbeat-sounds) | Mrthenoronha | CC0 |

## One-shots

Feed sounds are bells played near their NATURAL pitch. The old ones were metal
dings dragged down to 0.44-0.68 pitch, which turns a ring into a dull thump —
the other half of the "drum sound" complaint. Don't pitch a percussive sample
far from where it was recorded.

| File | Source | Author | License | Status |
|---|---|---|---|---|
| `audio/feed_soft.wav` | [Bell Dings/Chimes](https://opengameart.org/content/bell-dingschimes) (`bell_ding3`) | Kenney / dermotte | CC0 | **in use** (RAW feed) |
| `audio/feed_rich.wav` | [Bell Dings/Chimes](https://opengameart.org/content/bell-dingschimes) (`bell_ding1`) | Kenney / dermotte | CC0 | **in use** (REFINED/CLOTH feed) |
| `audio/rupture.ogg` | [10 Impact/Shield Blocks](https://opengameart.org/content/10-impactshield-blocks) (`impact.1`) | StarNinjas | CC0 | **in use** |
| `audio/corrupt.ogg` | [10 Impact/Shield Blocks](https://opengameart.org/content/10-impactshield-blocks) (`impact.8`) | StarNinjas | CC0 | **in use** |
| `audio/note_raw.ogg` | [4 Metal Dings/Rings](https://opengameart.org/content/4-metal-dingsrings) (`ding.1`) | StarNinjas | CC0 | unused |
| `audio/note_refined.ogg` | [4 Metal Dings/Rings](https://opengameart.org/content/4-metal-dingsrings) (`ding.3`) | StarNinjas | CC0 | unused |

## Voice (callouts)

None. Milestone callouts (see `scripts/callout.gd`) are text-only.

They used to pair the on-screen text pop with a spoken CC0 voice-over clip
(Kenney's [Voiceover Pack](https://kenney.nl/assets/voiceover-pack): "new
high score", "power up", "level up", "congratulations"). Those were removed
as annoying, and the clips deleted rather than left unreferenced — this
project exports with `export_filter="all_resources"`, so an orphaned `.ogg`
still ships inside the `.pck` and costs every web player the download.

## Fonts

Monospace everywhere, by explicit direction. Wired project-wide via
`assets/theme.tres` (`project.godot`'s `gui/theme/custom`) for every
Label/Button, and directly via `Palette.MONO_FONT` for the custom-drawn
readouts (score_hud.gd, leaderboard_panel.gd, ranks_strip.gd,
float_text.gd) that draw_string outside the Control theme system.

| File | Source | Author | License | Status |
|---|---|---|---|---|
| `fonts/SpaceMono-Regular.ttf` | [Space Mono](https://github.com/googlefonts/spacemono) | The Space Mono Project Authors | SIL OFL 1.1 (`fonts/OFL.txt`) | **in use** |
