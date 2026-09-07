# Queens

A mobile-first Godot 4 implementation of the *Queens* logic puzzle.

## Rules

* Place exactly one queen in every row, every column and every colour region.
* Queens may not touch each other, not even diagonally.

## Controls

* Tap an empty cell once to mark it with an **X** (cannot hold a queen).
* Tap again to place a **queen**. Tap a queen to remove it.
* Placing a queen automatically X-marks every cell that can no longer hold a
  queen: its row, its column, its colour region and the eight surrounding
  cells. Removing the queen removes those automatic marks again; your own
  manual marks stay.
* Queens that break a rule are drawn in red.
* **Undo** reverts the last tap, **Clear** resets the board.
* The puzzle is solved when all queens are placed without conflicts. Best
  times are stored per level in `user://progress.cfg`.

## Levels

`scripts/levels.gd` holds 10 boards (5x5 up to 9x9). Every board has exactly
one solution, verified both by the generator and by the test suite. Regenerate
them with:

```bash
python tools/gen_boards.py queens/scripts/levels.gd
```

Change the seeds or the `SIZES` list in the script for different boards.

## Project layout

| Path | Purpose |
| --- | --- |
| `scenes/main.tscn` | Level select, game screen and "solved" overlay |
| `scripts/main.gd` | Screen flow, timer, progress saving |
| `scripts/board.gd` | Board rendering, tap handling, auto-marking, conflict and win detection |
| `scripts/levels.gd` | Generated level data |
| `tests/run_tests.gd` | Headless tests (uniqueness of every level, board logic) |
| `tests/screenshot.tscn` | Visual smoke test that writes PNG screenshots |
| `export_presets.cfg` | Android export preset (arm64-v8a, portrait) |

## Running

Open the `queens` folder in Godot 4.7 (or newer) and press Play, or run:

```bash
godot --path queens
```

Tests:

```bash
godot --headless --path queens --script tests/run_tests.gd
```

Screenshots (written to the given directory):

```bash
godot --path queens res://tests/screenshot.tscn -- /path/to/output
```

## Building the Android app

1. In the Godot editor install the export templates
   (**Editor > Manage Export Templates**).
2. Set up the Android SDK and a debug keystore under
   **Editor > Editor Settings > Export > Android** (see the Godot docs
   "Exporting for Android").
3. **Project > Export**, select the *Android* preset and export an APK, or
   from the command line:

```bash
godot --headless --path queens --export-debug Android build/queens.apk
```

The preset targets arm64-v8a only and uses the GL Compatibility renderer, so
it runs on practically any Android device. Change `package/unique_name` in
`export_presets.cfg` before publishing.
