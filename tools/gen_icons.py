"""Generates the line icon set as SVG files.

Run:  python tools/gen_icons.py
Icons: 64x64 viewBox, 5px round strokes, white, no fill, so the Godot theme
can tint them (Button icon colours, TextureRect modulate).
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "queens", "assets", "icons", "line")

S = 'fill="none" stroke="#fff" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"'
F = 'fill="#fff" stroke="none"'

ICONS = {
    "bolt": f'<path {F} d="M36 4 14 36h16l-4 24 24-34H34z"/>',
    "infinity": f'<path {S} d="M32 32c-6-8-10-12-16-12a12 12 0 0 0 0 24c6 0 10-4 16-12s10-12 16-12a12 12 0 0 1 0 24c-6 0-10-4-16-12z"/>',
    "crown": f'<path {S} d="M10 48V22l12 10 10-18 10 18 12-10v26z"/><path {S} d="M10 48h44"/>',
    "star": f'<path {S} d="M32 6l7.6 16.4L57 24.6 44 36.8 47.4 54 32 45.6 16.6 54 20 36.8 7 24.6l17.4-2.2z"/>',
    "star_fill": f'<path {F} d="M32 4l8.4 18.2L60 24.6 45.4 38.2 49 58 32 48.6 15 58l3.6-19.8L4 24.6l19.6-2.4z"/>',
    "heart": f'<path {S} d="M32 54S8 40 8 23a12 12 0 0 1 24-4 12 12 0 0 1 24 4c0 17-24 31-24 31z"/>',
    "heart_fill": f'<path {F} d="M32 56S6 41 6 23a13 13 0 0 1 26-5 13 13 0 0 1 26 5c0 18-26 33-26 33z"/>',
    "undo": f'<path {S} d="M22 18H10v12"/><path {S} d="M10 30a24 24 0 1 1 8 20"/>',
    "eraser": f'<path {S} d="M38 10 54 26 32 48H20L10 38z"/><path {S} d="M20 48h34"/><path {S} d="M22 22l20 20"/>',
    "lightbulb": f'<path {S} d="M32 6a16 16 0 0 0-9 29c2 2 3 4 3 7h12c0-3 1-5 3-7a16 16 0 0 0-9-29z"/><path {S} d="M26 50h12M28 57h8"/>',
    "gear": f'<path {S} d="M32 8l5 4 6-1 3 6 6 3-1 6 4 5-4 5 1 6-6 3-3 6-6-1-5 4-5-4-6 1-3-6-6-3 1-6-4-5 4-5-1-6 6-3 3-6 6 1z"/><circle {S} cx="32" cy="33" r="8"/>',
    "chevron_left": f'<path {S} d="M40 10 18 32l22 22"/>',
    "chevron_right": f'<path {S} d="M24 10l22 22-22 22"/>',
    "chevron_up": f'<path {S} d="M10 40 32 18l22 22"/>',
    "chevron_down": f'<path {S} d="M10 24 32 46l22-22"/>',
    "close": f'<path {S} d="M14 14l36 36M50 14 14 50"/>',
    "lock": f'<rect {S} x="12" y="28" width="40" height="28" rx="6"/><path {S} d="M20 28v-8a12 12 0 0 1 24 0v8"/><circle {F} cx="32" cy="42" r="4"/>',
    "clock": f'<circle {S} cx="32" cy="32" r="24"/><path {S} d="M32 16v16l10 6"/>',
    "trophy": f'<path {S} d="M18 8h28v14a14 14 0 0 1-28 0z"/><path {S} d="M18 14H8v4a10 10 0 0 0 10 8M46 14h10v4a10 10 0 0 1-10 8"/><path {S} d="M32 36v10M22 54h20M26 46h12v8H26z"/>',
    "play": f'<path {F} d="M18 8v48l38-24z"/>',
    "share": f'<circle {S} cx="48" cy="12" r="6"/><circle {S} cx="16" cy="32" r="6"/><circle {S} cx="48" cy="52" r="6"/><path {S} d="M21 29l22-14M21 35l22 14"/>',
    "volume_on": f'<path {S} d="M8 24h10l14-12v40L18 40H8z"/><path {S} d="M40 22a14 14 0 0 1 0 20M46 14a24 24 0 0 1 0 36"/>',
    "volume_off": f'<path {S} d="M8 24h10l14-12v40L18 40H8z"/><path {S} d="M40 24l14 16M54 24 40 40"/>',
    "music": f'<path {S} d="M24 50V14l28-6v34"/><circle {S} cx="17" cy="50" r="7"/><circle {S} cx="45" cy="42" r="7"/>',
    "vibrate": f'<rect {S} x="20" y="8" width="24" height="48" rx="5"/><path {S} d="M10 22v20M54 22v20M4 28v8M60 28v8"/>',
    "podium": f'<path {S} d="M22 56V30h20v26M8 56V40h14M56 56V36H42"/><path {S} d="M4 56h56"/><path {S} d="M32 8l3 6 6 1-4 4 1 6-6-3-6 3 1-6-4-4 6-1z"/>',
    "check": f'<path {S} d="M12 34l12 12 28-28"/>',
    "warning": f'<path {S} d="M32 8 4 56h56z"/><path {S} d="M32 26v14"/><circle {F} cx="32" cy="48" r="3"/>',
    "plus": f'<path {S} d="M32 12v40M12 32h40"/>',
    "user": f'<circle {S} cx="32" cy="22" r="12"/><path {S} d="M8 58a24 24 0 0 1 48 0"/>',
    "copy": f'<rect {S} x="22" y="22" width="32" height="32" rx="5"/><path {S} d="M42 22v-6a6 6 0 0 0-6-6H16a6 6 0 0 0-6 6v20a6 6 0 0 0 6 6h6"/>',
    "flag": f'<path {S} d="M14 58V8"/><path {S} d="M14 10h34l-8 12 8 12H14"/>',
    "grid": f'<rect {S} x="8" y="8" width="20" height="20" rx="4"/><rect {S} x="36" y="8" width="20" height="20" rx="4"/><rect {S} x="8" y="36" width="20" height="20" rx="4"/><rect {S} x="36" y="36" width="20" height="20" rx="4"/>',
    "refresh": f'<path {S} d="M54 32a22 22 0 1 1-6-15"/><path {S} d="M54 8v12H42"/>',
    "video": f'<rect {S} x="6" y="16" width="36" height="32" rx="6"/><path {S} d="M42 28l16-8v24l-16-8"/>',
    "cart": f'<path {S} d="M6 10h8l6 30h30l6-20H18"/><circle {F} cx="24" cy="52" r="4"/><circle {F} cx="46" cy="52" r="4"/>',
    "pattern": f'<rect {S} x="8" y="8" width="48" height="48" rx="6"/><path {S} d="M8 24l16-16M8 40 40 8M8 56 56 8M24 56l32-32M40 56l16-16"/>',
    "info": f'<circle {S} cx="32" cy="32" r="24"/><path {S} d="M32 30v14"/><circle {F} cx="32" cy="21" r="3"/>',
    "pause": f'<rect {F} x="14" y="10" width="12" height="44" rx="4"/><rect {F} x="38" y="10" width="12" height="44" rx="4"/>',
    "flame": f'<path {S} d="M32 6c2 10 12 14 12 26a12 12 0 0 1-24 0c0-6 4-9 4-9s0 6 4 6c2-6-2-12 4-23z"/>',
    "hint_x": f'<path {S} d="M18 18l28 28M46 18 18 46"/>',
    "menu": f'<path {S} d="M10 18h44M10 32h44M10 46h44"/>',
    "medal": f'<circle {S} cx="32" cy="40" r="16"/><path {S} d="M22 26 14 6h12l6 12 6-12h12l-8 20"/>',
    "arrow_right": f'<path {S} d="M10 32h44M36 14l18 18-18 18"/>',
    "sparkle": f'<path {F} d="M32 4l5 17 17 5-17 5-5 17-5-17-17-5 17-5z"/><path {F} d="M50 40l2.5 7.5L60 50l-7.5 2.5L50 60l-2.5-7.5L40 50l7.5-2.5z"/>',
}


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, body in ICONS.items():
        svg = (
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">'
            f"{body}</svg>\n"
        )
        with open(os.path.join(OUT, f"{name}.svg"), "w", encoding="utf-8") as fh:
            fh.write(svg)
    print(f"wrote {len(ICONS)} icons to {os.path.abspath(OUT)}")


if __name__ == "__main__":
    main()
