# Queens

A mobile-first Godot 4 implementation of the *Queens* logic puzzle: place one
queen in every row, column and colour region, and no two queens may touch.

## How it plays

The home screen offers three buttons: **Easier**, **Same** and **Harder**.
Each picks a level whose solver difficulty is stepped relative to the last
game you started, finished or not (see `scripts/level_picker.gd`). The full
level list is still available under *All levels*. A level you started stays
locked for seven days (`cooldown_seconds` in `scripts/config.gd`), so a time
cannot be improved by replaying a solution you remember. Giving up counts as
a played game.

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
base     = 10 * difficulty + 10 * size
par      = 30 + 3 * difficulty + 0.5 * size^2   seconds
accuracy = 1 / (1 + 0.4 * wrong placements)     the dominant factor
speed    = clamp(0.5 + 0.5 * par / time, 0.5, 1.25)
undo     = clamp(1 - 0.01 * undos, 0.85, 1)
score    = round(base * accuracy * speed * undo)
```

A wrong placement is a queen put on a cell that is not part of the
solution; it counts the moment it is placed, so marking with X first and
placing queens only when sure is the rewarded style. Giving up scores 0.
The level overview shows the best score per level.

### League and leaderboards

Every solved game also counts for the weekly league (Monday to Sunday,
UTC). Your weekly score is the sum of your best 15 games of the week, so
grinding beyond that only helps by replacing a weaker game. You play in a
group of up to 30 players of the same tier; at the end of the week the top
share moves up a tier and, from Silver on, the bottom share moves down:

| Tier | up | down | week without a game |
| --- | --- | --- | --- |
| Bronze | 30 % | 0 % | stay |
| Silver | 25 % | 10 % | stay |
| Gold | 20 % | 20 % | relegate |
| Platinum | 15 % | 30 % | relegate |
| Diamond | 0 % | 40 % | relegate |

Diamond is one global standing. The rules live in `GameConfig.league`
(`scripts/config.gd`) and the maths in `scripts/league_rules.gd`. Each
level also has its own leaderboard (best score per player, plus a "fastest
flawless" view), reachable from the level overview.

There is no server yet. `scripts/backend/backend.gd` is the contract and
`scripts/backend/local_backend.gd` an offline stand-in that fills the group
with deterministic bots anchored to your own scores, simulates the weekly
rollover on start, and fabricates friends from friend codes. A real backend
(for example Supabase) implements the same contract; the client does not
change.

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
