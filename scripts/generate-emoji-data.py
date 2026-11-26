#!/usr/bin/env python3
"""Generates OpenRay/Resources/EmojiCatalog.json from public Unicode data.

Inputs (download them yourself; this script never touches the network):

  * emoji-test.txt             https://unicode.org/Public/emoji/latest/emoji-test.txt
  * CLDR annotations (en)      https://github.com/unicode-org/cldr-json
                               cldr-json/cldr-annotations-full/annotations/en/annotations.json
  * CLDR derived annotations   cldr-json/cldr-annotations-derived-full/annotationsDerived/en/annotations.json

Symbol names come from Python's bundled `unicodedata`, preferring CLDR's short
name when CLDR has one. All inputs are covered by the Unicode License V3
(https://www.unicode.org/license.txt).

Usage:

  python3 -I scripts/generate-emoji-data.py \\
      --emoji-test path/to/emoji-test.txt \\
      --annotations path/to/annotations.json \\
      --derived path/to/annotationsDerived.json \\
      --output OpenRay/Resources/EmojiCatalog.json

Output shape, kept compact because the app ships it:

  {"source": "...", "categories": [
      {"id": "smileys-emotion", "title": "Smileys & Emotion", "items": [
          {"e": "😀", "n": "grinning face", "k": ["face", "grin"]},
          {"e": "👍", "n": "thumbs up", "k": [...], "t": ["👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"]}]}]}

`t` lists the five uniform skin-tone variants, light to dark, when Unicode
defines all of them. Keywords that only repeat a word of the name are dropped.
"""

import argparse
import json
import re
import sys
import unicodedata

EMOJI_GROUPS = [
    ("Smileys & Emotion", "smileys-emotion"),
    ("People & Body", "people-body"),
    ("Animals & Nature", "animals-nature"),
    ("Food & Drink", "food-drink"),
    ("Travel & Places", "travel-places"),
    ("Activities", "activities"),
    ("Objects", "objects"),
    ("Symbols", "symbols"),
    ("Flags", "flags"),
]

TONES = ["light", "medium-light", "medium", "medium-dark", "dark"]

LINE = re.compile(
    r"^(?P<points>[0-9A-F ]+?)\s*;\s*(?P<status>[a-z-]+)\s*#\s*(?P<emoji>\S+)\s+E(?P<version>\d+\.\d+)\s+(?P<name>.+)$"
)


def ranges(*spans):
    for span in spans:
        if isinstance(span, tuple):
            yield from range(span[0], span[1] + 1)
        else:
            yield span


# Symbol categories: (id, title, code points). Order inside a category follows the list.
SYMBOL_CATEGORIES = [
    (
        "arrows",
        "Arrows",
        list(ranges((0x2190, 0x21FF), (0x27F0, 0x27FF), (0x2B00, 0x2B11), (0x2B60, 0x2B69))),
    ),
    (
        "math",
        "Math",
        list(
            ranges(
                0x00B1, 0x00D7, 0x00F7, 0x00AC, 0x00B0, 0x00B5, 0x2030, 0x2031, 0x2032, 0x2033,
                (0x00BC, 0x00BE), (0x2150, 0x215E),
                0x00B9, 0x00B2, 0x00B3, (0x2070, 0x2071), (0x2074, 0x207F), (0x2080, 0x208E),
                (0x2200, 0x22FF), (0x2308, 0x230B),
                0x0391, 0x0392, 0x0393, 0x0394, 0x0398, 0x039B, 0x039E, 0x03A0, 0x03A3, 0x03A6, 0x03A8, 0x03A9,
                (0x03B1, 0x03C9),
            )
        ),
    ),
    (
        "currency",
        "Currency",
        list(ranges(0x0024, 0x00A2, 0x00A3, 0x00A4, 0x00A5, 0x058F, 0x0E3F, 0x17DB, (0x20A0, 0x20C0), 0xFDFC)),
    ),
    (
        "punctuation",
        "Punctuation",
        list(
            ranges(
                (0x2010, 0x2027), (0x2034, 0x205E), 0x00A1, 0x00BF, 0x00A7, 0x00B6, 0x00B7, 0x00AB, 0x00BB,
                0x00A6, 0x00A8, 0x00AF, 0x00B4, 0x02DC, 0x2E18, 0x2E2E, 0x3003, 0x301C,
            )
        ),
    ),
    (
        "letterlike",
        "Letterlike",
        list(ranges(0x00A9, 0x00AE, (0x2100, 0x214F), 0x2117, 0x2120, 0x2122)),
    ),
    (
        "keyboard",
        "Keyboard",
        list(
            ranges(
                0x2318, 0x2325, 0x21E7, 0x2303, 0x21EA, 0x238B, 0x23CE, 0x21A9, 0x232B, 0x2326, 0x21E5, 0x21E4,
                0x23CF, 0x233D, 0x2423, 0x2324, 0x2305, 0x2386, 0x2327, 0x23FB, 0x23FC, 0x23FD, 0x2B58, 0x21DE,
                0x21DF, 0x2196, 0x2198, 0x2191, 0x2193, 0x2190, 0x2192, 0x2387, 0x2388, 0x2389, 0x238C,
            )
        ),
    ),
    (
        "shapes",
        "Shapes",
        list(ranges((0x25A0, 0x25FF), 0x2605, 0x2606, (0x2713, 0x2718), (0x2726, 0x272F), (0x2B1B, 0x2B2F))),
    ),
]

# Extra search words for symbols that CLDR doesn't annotate, or annotates thinly.
SYMBOL_KEYWORDS = {
    "⌘": ["command", "cmd", "mac", "key"],
    "⌥": ["option", "alt", "opt", "key"],
    "⇧": ["shift", "key"],
    "⌃": ["control", "ctrl", "key"],
    "⇪": ["caps lock", "key"],
    "⎋": ["escape", "esc", "key"],
    "⏎": ["return", "enter", "key"],
    "↩": ["return", "enter"],
    "⌫": ["delete", "backspace", "key"],
    "⌦": ["forward delete", "key"],
    "⇥": ["tab", "key"],
    "⇤": ["backtab", "shift tab"],
    "⏏": ["eject", "key"],
    "␣": ["space", "spacebar"],
    "→": ["->", "right"],
    "←": ["<-", "left"],
    "⇒": ["=>", "implies"],
    "≠": ["!=", "not equal"],
    "≈": ["approximately", "approx", "~="],
    "≤": ["<=", "less than or equal"],
    "≥": [">=", "greater than or equal"],
    "±": ["+-", "plus minus"],
    "×": ["times", "multiply"],
    "÷": ["divide", "division"],
    "°": ["degree", "deg"],
    "∞": ["infinity"],
    "√": ["square root", "sqrt"],
    "…": ["...", "dots"],
    "—": ["em dash", "--"],
    "–": ["en dash"],
    "•": ["bullet", "dot"],
    "©": ["copyright"],
    "®": ["registered"],
    "™": ["trademark", "tm"],
    "✓": ["check", "tick", "done"],
    "✗": ["cross", "x"],
    "★": ["star"],
    "☆": ["star", "outline"],
}


def parse_emoji_test(path, max_version):
    groups = {}
    order = []
    tones = {}
    group = None
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if line.startswith("# group:"):
                group = line.split(":", 1)[1].strip()
                continue
            if not line or line.startswith("#"):
                continue
            match = LINE.match(line)
            if not match or match["status"] != "fully-qualified":
                continue
            if group == "Component":
                continue
            version = float(match["version"])
            if version > max_version:
                continue
            emoji = "".join(chr(int(point, 16)) for point in match["points"].split())
            name = match["name"].strip()
            if ": " in name and name.endswith("skin tone"):
                base, tone = name.rsplit(": ", 1)
                tone = tone[: -len(" skin tone")]
                if tone in TONES:
                    tones.setdefault(base, {})[tone] = emoji
                continue
            groups.setdefault(group, []).append((emoji, name))
            order.append(group)
    return groups, tones


def keywords_for(emoji, name, annotations, derived):
    entry = annotations.get(emoji) or annotations.get(emoji.replace("️", "")) or derived.get(emoji) or {}
    words = set(re.findall(r"[\w'+-]+", name.lower()))
    result = []
    for keyword in entry.get("default", []):
        keyword = keyword.lower().strip()
        if not keyword or keyword == name.lower() or keyword in words or keyword in result:
            continue
        if keyword.endswith("skin tone"):
            continue
        result.append(keyword)
    return result


def symbol_name(character, annotations):
    entry = annotations.get(character)
    if entry and entry.get("tts"):
        return entry["tts"][0].lower()
    try:
        return unicodedata.name(character).lower()
    except ValueError:
        return None


def build(args):
    with open(args.annotations, encoding="utf-8") as handle:
        annotations = json.load(handle)["annotations"]["annotations"]
    with open(args.derived, encoding="utf-8") as handle:
        derived = json.load(handle)["annotationsDerived"]["annotations"]
    groups, tones = parse_emoji_test(args.emoji_test, args.max_version)

    categories = []
    emoji_set = set()
    for title, identifier in EMOJI_GROUPS:
        items = []
        for emoji, name in groups.get(title, []):
            emoji_set.add(emoji)
            item = {"e": emoji, "n": name, "k": keywords_for(emoji, name, annotations, derived)}
            variants = tones.get(name, {})
            if len(variants) == len(TONES):
                item["t"] = [variants[tone] for tone in TONES]
            if not item["k"]:
                del item["k"]
            items.append(item)
        categories.append({"id": identifier, "title": title, "items": items})

    for identifier, title, points in SYMBOL_CATEGORIES:
        items = []
        seen = set()
        for point in points:
            character = chr(point)
            if character in seen:
                continue
            category = unicodedata.category(character)
            if category.startswith(("C", "Z", "M")):
                continue
            name = symbol_name(character, annotations)
            if not name:
                continue
            seen.add(character)
            keywords = keywords_for(character, name, annotations, {})
            for extra in SYMBOL_KEYWORDS.get(character, []):
                if extra not in keywords and extra != name:
                    keywords.append(extra)
            item = {"e": character, "n": name}
            if keywords:
                item["k"] = keywords
            items.append(item)
        categories.append({"id": identifier, "title": title, "items": items})

    source = (
        f"Unicode emoji-test.txt (Emoji ≤ {args.max_version}), CLDR en annotations, "
        f"Unicode {unicodedata.unidata_version} names. Unicode License V3."
    )
    return {"source": source, "categories": categories}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--emoji-test", required=True)
    parser.add_argument("--annotations", required=True)
    parser.add_argument("--derived", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument(
        "--max-version", type=float, default=17.0,
        help="Newest emoji version to include. Keep it at what the oldest supported macOS renders.")
    args = parser.parse_args()
    data = build(args)
    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, separators=(",", ":"))
        handle.write("\n")
    counts = ", ".join(f"{c['id']}={len(c['items'])}" for c in data["categories"])
    print(f"Wrote {args.output}: {counts}", file=sys.stderr)


if __name__ == "__main__":
    main()
