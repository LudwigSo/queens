# Queens

A mobile-first Godot 4 implementation of the *Queens* logic puzzle: place one
queen in every row, column and colour region, and no two queens may touch.

## How it plays

The home screen offers three cards: **Easier**, **Same** and **Harder**.
Each previews the level it would start, picked so its solver difficulty is
stepped relative to the last game you started, finished or not (see
`scripts/level_picker.gd`). The full level list is under *All levels*, with
a size filter and a leaderboard per level. A level you started stays locked
for seven days (`cooldown_seconds` in `scripts/config.gd`), so a time cannot
be improved by replaying a solution you remember. Giving up counts as a
played game. A first run starts with an interactive tutorial (replayable
from Settings).

On the board: tap a cell to mark it X, tap again for a queen, tap a third
time to clear. Drag across cells to paint or erase X marks in one stroke.
Long-press an empty cell to place a queen straight away. There is no undo
button: a tap takes a queen back and *Clear* wipes the board.
Placing a queen automatically X-marks its row, column, region and the
cells around it. A queen on a wrong cell flashes red (switchable in
Settings); two queens that attack each other shake and stay red.

**Hints** (the bulb in the actions bar) never place a wrong queen. They
try, in order: point at a wrong queen, point at a wrong X, find a row,
column or region with only one spot left and place the queen there, find a
region confined to one row or column and X the rest of it, and finally
reveal the queen of the most constrained row (`scripts/hint_finder.gd`).
Hints are free but cost score (see below) and the Flawless badge.

### Energy

Starting a game costs one energy; giving up does not refund it. A fresh
install has 10. Tapping the energy counter on the home screen opens a panel
where a rewarded ad adds 10 energy and a one-time purchase (2.99 EUR)
switches to unlimited energy for good. All numbers live in
`scripts/config.gd`. In the editor and in tests the ad and the store are
fakes (`scripts/providers/fake_*.gd`) that always succeed after a short
delay; the real AdMob and Google Play Billing providers are only used on
Android when their plugins are installed.

### Score

Every solved game gets a score (`scripts/scoring.gd`):

```
base     = 60 + 10 * size + 200 * (difficulty / 20)^1.6
par      = 30 + 3 * difficulty + 0.5 * size^2   seconds
accuracy = max(1 / (1 + 0.5 * wrong placements), 0.1)   the dominant factor
speed    = clamp((par / time)^0.631, 0.5, 2)
hint     = clamp(1 - 0.2 * hints, 0.1, 1)
score    = round(base * accuracy * speed * hint)
```

The base points are shown on the win panel next to time, par and mistakes.
They grow faster than the difficulty does (exponent 1.6) but far slower
than an exponential, so the level list spans 149 points for the easiest
board to 1351 for the hardest: a hard board is worth about nine easy ones,
while the flat part keeps an easy board from feeling pointless.

A wrong placement is a queen put on a cell that is not part of the
solution; it counts the moment it is placed, so marking with X first and
placing queens only when sure is the rewarded style. Giving up scores 0.
The level overview shows the best score per level.

### League and leaderboards

Every solved game also counts for the league. Each tier plays in rounds:
three days in Bronze, a calendar week (Monday to Sunday, UTC) everywhere
else. Your round score is the sum of your best 15 games of the round, so
grinding beyond that only helps by replacing a weaker game. Up to Platinum
you play in a group of up to 30 players of the same tier. From Gold on, the
end of the round moves the top share up a tier and, from Platinum on, the
bottom share down. Bronze and Silver promote by *tier points* instead:

| Tier | round | up | down | round without a game |
| --- | --- | --- | --- | --- |
| Bronze | 3 days | 3000 tier points, at once | none | stay |
| Silver | week | 10000 tier points, at once | none | stay |
| Gold | week | 20 % | never | stay |
| Platinum | week | 15 % | 25 % | relegate |
| Diamond | week | open Challenger slots | 20 % | relegate |
| Challenger | week | – | bottom half | relegate |

Bronze and Silver are the on-ramp. Every solved game adds its score to
your tier points; the moment they reach the threshold you move up, on the
spot, into the round of the next tier that is already running, and the
counter restarts at 0 (it also restarts on every other tier change). Their
rounds are a leaderboard for company: the standings and the timer are
there, but nobody moves at the end of one, and there is no way down. The
thresholds are `promo_score` per tier in `scripts/config.gd`. Gold is a
floor: once you are Gold you are never relegated, not
even for an idle week. Platinum and Diamond are where skill decides and
players move in both directions. Diamond is one global standing of everyone
in the tier and has no cap. Because nobody ever drops below Gold, the tiers
above it fill up as the player base matures, so the Diamond population
grows slowly over time.

Challenger is the capped top for the best of the best: one slot per ten
Diamond players, at least 5 and at most 50. Every week the bottom half of
Challenger drops back to Diamond, and Diamond promotes exactly as many
players as slots are then open. As Diamond grows, so do the Challenger
slots, until the cap of 50 is reached.

A promotion always joins the round of the next tier that is already
running. The rules live in `GameConfig.league` (`scripts/config.gd`)
and the maths in `scripts/league_rules.gd`. Each level also has its own
leaderboard (best score per player, plus a "fastest flawless" view),
reachable from the level overview.

There is no server yet. `scripts/backend/backend.gd` is the contract and
`scripts/backend/local_backend.gd` an offline stand-in that fills the group
with deterministic bots anchored to your own scores, simulates the round
rollover on start (with a slowly growing Diamond population and a full
Challenger), and fabricates friends from friend codes. A real backend
(for example Supabase) implements the same contract; the client does not
change.

## Design system and assets

Everything visual is generated from the repository; there is no art
pipeline outside it.

* **Tokens**: `theme/tokens.gd` (`Ui`) holds every colour, radius, spacing
  and font size. Runtime drawing code (the board, list rows) reads the same
  constants. The primary is a forest green (`#1f7f52`) and the neutrals
  carry its hue; the success colour is a mint-teal so it stays distinct.
  The boot splash colour in `project.godot`, the splash scene and the ink
  crown's jewels (`../tools/gen_crowns.py`) repeat the primary by hand.
* **Theme**: `theme/theme.tres` is *generated* by
  `theme/theme_builder.gd` from the tokens; never edit it by hand. It also
  writes the glossy 9-patch button textures under `assets/ui/`. Rebuild
  with:

  ```bash
  godot --headless --path queens --script theme/theme_builder.gd
  ```

  On a clean checkout run it, then `--import`, then run it again so the
  button textures are picked up (the first pass falls back to flat styles).
  Screens use `theme_type_variation` names such as `ButtonPrimary`,
  `ButtonSecondary`, `ButtonGhost`, `ButtonPill`, `ButtonIcon`,
  `ButtonCard`, `LabelTitle`, `LabelCaption`, `Card`, `CardElevated`,
  `RowPanel`, `Chip`, `Sheet`, `ScreenMargin`.
* **Fonts**: Fredoka (display) and Nunito (body), both SIL Open Font
  License, in `assets/fonts/`.
* **Icons**: `../tools/gen_icons.py` writes the line icon set to
  `assets/icons/line/` (64 px, white strokes, tinted by the theme).
  `../tools/gen_crowns.py` writes the three crown sprites to
  `assets/board/`.
* **Sound**: `../tools/gen_sfx.py` synthesizes every effect and
  `../tools/gen_music.py` the ambient loop into `assets/audio/` (numpy
  only). The `Audio` autoload (`scripts/audio_manager.gd`) loads them
  lazily and is a silent no-op for any missing file; scripts call it
  through the static `Sfx` front so headless tests never need it.
* **Motion**: `scripts/ui/motion.gd` holds the durations and tween
  helpers. `Motion.instant` (tests) and `Motion.reduced` (the "Reduce
  motion" setting) collapse every animation.
* **Brand**: `tools/brand_render.gd` renders the adaptive launcher icon,
  the boot splash, the wordmark and the store feature graphic into
  `assets/brand/` with the real fonts (needs a window):

  ```bash
  godot --path queens res://tools/brand_render.tscn -- queens/assets/brand
  ```

  `tools/store_shots.gd` composes 1080x1920 store screenshots from the
  screenshot suite's output (`-- <screenshot_dir> <out_dir>`).

The app name is still a placeholder ("Queens"); the wordmark, icon and
package name (`export_presets.cfg`) change together once it is chosen.

## Languages

The game ships in English and German. On a fresh install it follows the
device language (German on a German device, English everywhere else);
Settings has a flag row that overrides that, and the choice is stored in the
save file under `settings.language` (`""` means "follow the device").

Every user-visible string lives in **`i18n/strings.csv`**, one row per string
and one column per language:

```
key,en,de
SETTINGS_TITLE,Settings,Einstellungen
HOME_STREAK,%d day streak,%d Tage in Folge
```

Edit that file to change any wording; no code, no rebuild, no re-import.
Rules for the file: UTF-8 without a byte order mark, a field containing a
comma or a quote must be wrapped in double quotes, `%%` is a literal percent
sign, and a row whose key starts with `#` is a section comment. The
placeholders (`%s`, `%d`) must appear in the same order in every language.

`scripts/loc.gd` (`Loc`) parses the file at startup and registers one
translation per column, so scene text is a key (`text = "SETTINGS_TITLE"`,
which Godot translates on its own and re-translates when the language
changes) and code uses `Loc.t("KEY")`, `Loc.f("KEY", [args])` or
`Loc.plural("BASE", n)` (which picks `BASE_ONE` or `BASE_OTHER`). Keys are
`AREA_WHAT` in upper snake case. League tier ids stay English in the save
file and in backend payloads; only their `TIER_*` display names are
translated.

`i18n/strings.csv.import` marks the file `importer="keep"` so the editor does
not also import it as a translation resource. Do not delete it, or the
strings end up registered twice.

To add a language: add a column to the CSV, its code to `Loc.SUPPORTED` and
`Loc.NAMES`, and a flag button to the language row in
`scenes/settings_screen.tscn`. The test suite then requires a value in the
new column for every key.

The test suite checks that every key used by a script or a scene exists in
the file, that no key in the file is unused, that no English text is left in
a scene, and that the placeholders match between the languages.

## Running locally

Requires Godot 4.7 or newer. Open the `queens` folder in the editor and press
Play, or from the command line:

```bash
godot --path queens
```

Tests (the first command refreshes the `.godot/` class cache, which the
headless runner needs after a clean checkout or after adding scripts):

```bash
godot --headless --path queens --import
```

```bash
godot --headless --path queens --script tests/run_tests.gd
```

The screenshot suite drives the real scene tree through `main.debug`
(`scripts/debug_api.gd`) with animations disabled and writes one PNG per
screen and state (home, board with conflicts, pause menu, hint, solved,
win overlay, shop, level overview, league, settings, tutorial, round
summary). It needs a window:

```bash
godot --path queens res://tests/screenshot.tscn -- build/shots
```

Pass a language as a second argument to shoot the same set in it (the files
get a `_de` suffix), which is how the German layout is checked:

```bash
godot --path queens res://tests/screenshot.tscn -- build/shots de
```

Progress is stored in `user://save.json` (see `scripts/save_data.gd`); a
`progress.cfg` from older builds is imported on first start.

Levels live in `levels/queens.json` and are produced by the tools in
`../tools` (see `tools/README.md`).

## Building the Android APK

One-time setup in the Godot editor:

1. Install the export templates (**Editor > Manage Export Templates**).
2. Point the editor to your Android SDK and Java under
   **Editor > Editor Settings > Export > Android** (see the Godot docs
   "Exporting for Android").

The *Android* preset in `export_presets.cfg` targets arm64-v8a, portrait, GL
Compatibility, so it runs on practically any device.

### Ads and purchases (plugins)

The Android build uses two plugins that are not part of this repository:

* **AdMob** by Poing Studios (`godot-admob-plugin`, Godot 4.2+). Install
  the addon into `queens/addons/admob/`, enable it under **Project >
  Project Settings > Plugins**, and enter your AdMob App ID under
  **Project Settings > Admob**. The rewarded ad unit id is
  `admob_rewarded_unit_id` in `scripts/config.gd`; it ships with Google's
  test unit, replace it for release.
* **Google Play Billing** (`godot-google-play-billing`, Godot 4.2+).
  Install the addon into `queens/addons/GodotGooglePlayBilling/` and enable
  it under **Plugins**. Create a non-consumable product with the id
  `queens_unlimited_energy` (see `unlimited_product_id`) in the Play
  Console and add license testers to try it without paying.

Both plugins need the Gradle build (`gradle_build/use_gradle_build=true`
in the preset, already set; install the build template via **Project >
Install Android Build Template**) and the INTERNET permission (set).
Without the addons the game falls back to the fake providers, also on
Android, so a debug APK still runs. `scripts/providers/admob_ads_provider.gd`
and `play_billing_provider.gd` look the plugin classes up at runtime and
print which provider was chosen at start. For the store, switch the
preset's `gradle_build/export_format` to AAB and make sure
`package/unique_name` matches your Play Console app.

### Debug build

Uses the debug keystore Godot creates for you:

```bash
godot --headless --path queens --export-debug Android build/queens.apk
```

### Release build

A release APK must be signed with your own key. Generate one yourself (once,
outside this repository) and keep it safe; the store will only accept updates
signed with the same key:

```bash
keytool -genkeypair -v -keystore queens-release.keystore -alias queens -keyalg RSA -keysize 2048 -validity 10000
```

Do not commit the keystore (`*.keystore` and `*.jks` are ignored by git). Hand
it to the exporter either in the editor under the preset's **Keystore >
Release**, **Release User** and **Release Password** fields, or via
environment variables so the preset file stays free of secrets:

```bash
export GODOT_ANDROID_KEYSTORE_RELEASE_PATH=/path/to/queens-release.keystore
```

```bash
export GODOT_ANDROID_KEYSTORE_RELEASE_USER=queens
```

```bash
export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD=your-password
```

Then export the release APK:

```bash
godot --headless --path queens --export-release Android build/queens-release.apk
```

Before publishing, bump `version/code` and `version/name` in
`export_presets.cfg` and change `package/unique_name` to your own domain.
