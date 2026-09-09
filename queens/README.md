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
