# SNAKE — Atari 8-bit

A pixel-art Snake game for the Atari 8-bit family (400/800/XL/XE),
written in 6502 assembly for the **MADS** (Mad Assembler) toolchain.

```
   +----------------------------------------+
   | SCORE: 0042        TIME: 1:47          |
   +----------------------------------------+
   |########################################|
   |#                    *                 #|
   |#        @@@@@>      🍄                #|
   |#                                      #|
   |#              ⏳              🐞      #|
   |#                                      #|
   |#                      *                |
   +----------------------------------------+
```

## Features

- **Scrolling world.** The playfield is 80×46 cells, with a 40×23 viewport
  that scrolls to follow the snake's head.
- **Custom character set** built from a copy of the ROM font so standard
  text still works outside the playfield.
- **ANTIC mode 4 tiles** for the playfield (4 colours per cell, 4×8 pixels).
- **Player/Missile Graphics** used to overlay a forked yellow tongue on
  the snake's head, rotated with the current direction.
- **Countdown timer** — run out of time and the game ends.
- **Bonus mini-game** triggered by catching a wandering bug.
- **High-score table** with 3-letter name entry.
- **Pause** via the space bar.
- PAL / NTSC detection not implemented; timer calibrated for PAL (50 Hz).

## Items on the playfield

| Tile | Name       | Effect                                                 |
|:----:|------------|--------------------------------------------------------|
|  `*` | Apple      | +1 point, **+2 seconds**, grow by 1, speeds up every 10 |
|  🍄 | Mushroom   | **−20 seconds** (dangerous, but no longer instant death) |
|  ⏳ | Hourglass  | **+15 seconds**, no growth, respawns elsewhere          |
|  🐞 | Bug        | Triggers a bonus menu — choose one of three random rewards |
|  `#` | Wall       | Instant death                                           |

Every time you eat an apple, **2 new apples + 1 new mushroom** are spawned,
so the playfield gets more crowded (and more dangerous) the longer you live.

## Bonus menu choices

When you catch a bug, the game pauses and offers three random bonuses from:

- **+10 POINTS** — free score bump
- **+25 POINTS** — bigger score bump
- **SHRINK -2** — trim two segments off your tail
- **SLOW DOWN** — makes the snake easier to control for a while
- **CLEAR POISON** — wipes all mushrooms from the map
- **+3 APPLES** — spawns three extra apples

## Controls

| Input                  | Action                                         |
|------------------------|------------------------------------------------|
| Joystick (port 1)      | Change direction (no 180-degree reversals)    |
| Fire button            | Start / restart / confirm (in menus)          |
| Space bar              | Pause / resume                                 |
| Stick up/down in menus | Cycle letter or highlight bonus                |

## Scoring

- Score is 4-digit BCD shown top-left.
- Timer is `M:SS` shown top-right, capped at `9:59`.
- Speed increases every 10 apples (to a floor of 2 frames per move).
- The game ends when you hit a wall, hit yourself, or the clock hits `0:00`.
- Two distinct game-over banners: `GAME OVER!` (collision) vs. `TIME'S UP!` (timeout).
- Beating the 5th high-score entry lets you enter a 3-letter name.

## Technical layout

| Region          | Address   | Purpose                                    |
|-----------------|-----------|--------------------------------------------|
| Code & tables   | `$2000`   | Game code, text strings, tile data, LUTs   |
| Display list    | `$3000`   | Custom DL: 1 line of mode 2, 23 of mode 4  |
| Character set   | `$3400`   | 1 KB RAM font (1K-aligned)                 |
| PM graphics     | `$3800`   | 1 KB player/missile area (1K-aligned)      |
| Map storage     | `$4000`   | 80 × 46 = 3680 bytes of cell data          |

Zero-page variables are allocated from `$80` upwards via MADS's `.zpvar`
directive.

## Building

```sh
./mads snake.asm -o:snake.xex
```

Load `snake.xex` in your favourite Atari 8-bit emulator (Altirra,
Atari800, ...) or transfer it to real hardware via SIO2SD / Fujinet.

## Known limitations

- Timer runs roughly 20% faster on NTSC; no runtime PAL/NTSC detection.
- No persistence for high scores — they reset when the machine is cold-booted.
- The bonus menu only appears immediately after eating a bug.
