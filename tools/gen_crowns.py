"""Generates the glossy crown sprites (SVG) in the three board states.

Run: python tools/gen_crowns.py
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "queens", "assets", "board")

VARIANTS = {
    # name: (top, bottom, outline, jewel)
    "crown_ink": ("#4a4670", "#1f1b3a", "#12102a", "#5fbf8a"),
    "crown_red": ("#ff8a8e", "#d63c42", "#8f2227", "#ffe0e2"),
    "crown_gold": ("#ffe082", "#f2a20c", "#a86a00", "#fff6d5"),
}

TEMPLATE = """<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">
<defs>
<linearGradient id="b" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient>
<linearGradient id="s" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffffff" stop-opacity="0.55"/><stop offset="1" stop-color="#ffffff" stop-opacity="0"/></linearGradient>
</defs>
<path d="M22 100V44l20 18 22-36 22 36 20-18v56z" fill="#000000" fill-opacity="0.22" transform="translate(0 7)"/>
<path d="M22 100V44l20 18 22-36 22 36 20-18v56z" fill="url(#b)" stroke="{outline}" stroke-width="5" stroke-linejoin="round"/>
<rect x="22" y="86" width="84" height="14" fill="{outline}" fill-opacity="0.35"/>
<path d="M30 48l12 12 22-34 22 34 12-12v16H30z" fill="url(#s)"/>
<circle cx="64" cy="26" r="7" fill="{jewel}" stroke="{outline}" stroke-width="3"/>
<circle cx="22" cy="44" r="6" fill="{jewel}" stroke="{outline}" stroke-width="3"/>
<circle cx="106" cy="44" r="6" fill="{jewel}" stroke="{outline}" stroke-width="3"/>
<circle cx="64" cy="76" r="8" fill="{jewel}" stroke="{outline}" stroke-width="3"/>
<ellipse cx="60" cy="82" rx="18" ry="4" fill="#ffffff" fill-opacity="0.18"/>
</svg>
"""


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, (top, bottom, outline, jewel) in VARIANTS.items():
        with open(os.path.join(OUT, name + ".svg"), "w", encoding="utf-8") as fh:
            fh.write(TEMPLATE.format(top=top, bottom=bottom, outline=outline, jewel=jewel))
    print("wrote", len(VARIANTS), "crowns")


if __name__ == "__main__":
    main()
