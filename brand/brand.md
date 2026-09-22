# Deck — brand sheet (Murmur's identity, carried over)

Deck wears Murmur's brand: the same mark, icon, palette and tone. Murmur was the dictation app;
Deck is the same object with Alexa added. Nothing "techy-cyan" — warm, quiet, one accent.

**Icon.** Murmur's icon (`Resources/AppIcon.icns`, preview `brand/icon-murmur-256.png`).
The generated card-stack icon is parked at `brand/alt-icon-cards-1024.png`, unused.

**Mark.** The decay mark (`Resources/Art/HudMark@2x.png`) leads every HUD state; the menu bar
shows the template glyph (`MenuGlyph@2x.png`), monochrome, following the bar.

## Colour

| Token | Hex | Use |
|---|---|---|
| Char | `#17151A` | backgrounds, HUD cards, widget top |
| Char 2 | `#221F27` | widget bottom, lifted surfaces |
| Sand | `#EFEAE2` | all primary text |
| Ember | `#D9724E` | the one accent: buttons, recording light, active tiles, rings |
| Stone | `#7C7480` | secondary text, dividers |
| Good / Warn / Bad | `#6BB857` / `#D99E47` / `#E36166` | states |

Tiles keep muted device colours (AC `#8FB4C4`, Mirror `#B8A99A`, Neon ember) so a glance still
tells rooms apart; nothing saturated.

## Type

SF Rounded for headings, buttons and tile labels; SF Mono for timers and pills; body SF at
11–13 pt in Sand at 40–62 %.

## Surfaces

Cards on `white @ 5.5 %` with a `white @ 9 %` hairline, radius 16. HUD bubbles: Char at 86–96 %
over `.ultraThinMaterial`, radius 16–18, ember rim while listening. Widgets: Char gradient with an
ember radial glow top-left.

## Keys

| Chord | Does |
|---|---|
| ⌃⌥A | Ask Alexa (push-to-talk, stops on silence) |
| ⌃⌥Z (hold) | Dictate; release to transcribe and paste |
| ⌃⌥Z, then Z again with ⌃⌥ still held | Lock dictation hands-free |
| ⌃⌥. | Cycle dictation language EN → AR → AUTO |
| Esc | Cancel |

Reserved by macOS: ⌃Space / ⌃⌥Space (input sources).
