#!/usr/bin/env python3
"""Validate the flat XML subset understood by PB626's pinned Matchbox Keyboard 0.1.1."""
from pathlib import Path
import xml.etree.ElementTree as ET

path = Path(__file__).resolve().parents[1] / "display" / "keyboard-us.xml"
root = ET.parse(path).getroot()
if root.tag != "keyboard":
    raise SystemExit("keyboard layout root must be <keyboard>")

allowed = {
    "keyboard": set(),
    "options": set(),
    "layout": {"id"},
    "row": set(),
    "key": {"obey-caps", "width", "fill", "extended"},
    "space": {"width", "extended"},
    "default": {"display", "action"},
    "shifted": {"display", "action"},
    "mod1": {"display", "action"},
    "mod2": {"display", "action"},
    "mod3": {"display", "action"},
}
for element in root.iter():
    if element.tag not in allowed:
        raise SystemExit(f"unsupported element for Matchbox Keyboard 0.1.1: <{element.tag}>")
    unknown = set(element.attrib) - allowed[element.tag]
    if unknown:
        raise SystemExit(f"unsupported attributes on <{element.tag}>: {sorted(unknown)}")

layouts = root.findall("layout")
if len(layouts) != 1:
    raise SystemExit(f"expected exactly one layout, found {len(layouts)}")
rows = layouts[0].findall("row")
if len(rows) < 4:
    raise SystemExit(f"expected at least four keyboard rows, found {len(rows)}")
visible = [
    node
    for row in rows
    for node in list(row)
    if node.tag in {"key", "space"} and node.get("extended") != "true"
]
if len(visible) < 35:
    raise SystemExit(f"layout has too few non-extended keys: {len(visible)}")
for key in (node for node in visible if node.tag == "key"):
    if not any(child.tag in {"default", "shifted", "mod1", "mod2", "mod3"} for child in key):
        raise SystemExit("every visible <key> must define at least one supported face")
# Portrait rows keep mobile letter ordering and retain essential shell actions.
for index, expected in ((1, "qwertyuiop"), (2, "asdfghjkl"), (3, "zxcvbnm")):
    letters = "".join(key.find("default").get("display") for key in rows[index].findall("key")
                      if key.get("obey-caps") == "true")
    assert letters == expected, (index, letters)
faces = [face for key in visible if key.tag == "key" for face in key]
actions = {face.get("action") for face in faces}
assert {"modifier:mod1", "modifier:shift", "modifier:ctrl", "modifier:alt",
        "backspace", "return", "space", "escape", "tab", "home", "end",
        "pageup", "pagedown", "left", "right", "up", "down", "delete"} <= actions
assert {face.get("display") for face in faces} >= set("0123456789[]{}\\\\|`~-_=+;:'\"/?@!#$%^&*()<>")
print(f"Matchbox Keyboard 0.1.1 layout OK: {len(rows)} rows, {len(visible)} visible keys")
