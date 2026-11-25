#!/usr/bin/env python3
"""Arrange Hyprland monitors and save the layout to ~/.config/hypr/monitors.lua.

Usage:
  arrange.py layout
      Print the enabled monitors as JSON (logical size and position).
  arrange.py place <monitor> <left|right|above|below> [<anchor>]
      Put <monitor> next to <anchor> (default: the laptop screen, or the first
      other monitor), centred along the shared edge. Other monitors keep their
      place relative to the anchor. The result is written into monitors.lua and
      Hyprland is reloaded; if the reload reports errors the file is restored.

Used by the Monitor Arrangement bar widget; also handy from a terminal.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

MONITORS_LUA = os.path.expanduser("~/.config/hypr/monitors.lua")
BACKUP = MONITORS_LUA + ".arrange-bak"
SAFE_NAME = re.compile(r"^[A-Za-z0-9._-]+$")
INTERNAL = re.compile(r"^(eDP|LVDS|DSI)-")
DIRECTIONS = ("left", "right", "above", "below")


def die(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def hyprctl_json(*args):
    out = subprocess.run(["hyprctl", *args, "-j"], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def monitors():
    result = []
    for m in hyprctl_json("monitors"):
        if m.get("disabled"):
            continue
        scale = float(m.get("scale") or 1) or 1
        w, h = m["width"], m["height"]
        if int(m.get("transform", 0)) % 2 == 1:  # 90/270 degree rotations
            w, h = h, w
        result.append({
            "name": m["name"],
            "description": m.get("description", ""),
            "x": int(m["x"]),
            "y": int(m["y"]),
            "w": round(w / scale),
            "h": round(h / scale),
            "scale": scale,
            "internal": bool(INTERNAL.match(m["name"])),
            "focused": bool(m.get("focused")),
        })
    result.sort(key=lambda d: (d["x"], d["y"]))
    return result


def fmt_scale(scale):
    return ("%.4f" % scale).rstrip("0").rstrip(".")


def place(mons, name, direction, anchor_name=None):
    by_name = {m["name"]: m for m in mons}
    if name not in by_name:
        die("Unknown or disabled monitor: %s" % name)
    if direction not in DIRECTIONS:
        die("Direction must be one of: %s" % ", ".join(DIRECTIONS))
    if anchor_name is None:
        others = [m for m in mons if m["name"] != name]
        if not others:
            die("Only one monitor is enabled; nothing to arrange.")
        internal = [m for m in others if m["internal"]]
        anchor_name = (internal or others)[0]["name"]
    if anchor_name not in by_name or anchor_name == name:
        die("Anchor must be a different enabled monitor.")

    target, anchor = by_name[name], by_name[anchor_name]
    # Everything is placed relative to the anchor at the origin.
    pos = {m["name"]: (m["x"] - anchor["x"], m["y"] - anchor["y"]) for m in mons}
    if direction == "left":
        x, y = -target["w"], (anchor["h"] - target["h"]) // 2
    elif direction == "right":
        x, y = anchor["w"], (anchor["h"] - target["h"]) // 2
    elif direction == "above":
        x, y = (anchor["w"] - target["w"]) // 2, -target["h"]
    else:
        x, y = (anchor["w"] - target["w"]) // 2, anchor["h"]
    pos[name] = (x, y)

    # Shift so the layout starts at 0x0.
    min_x = min(p[0] for p in pos.values())
    min_y = min(p[1] for p in pos.values())
    return {n: (p[0] - min_x, p[1] - min_y) for n, p in pos.items()}


RULE = re.compile(r'^\s*hl\.monitor\(\{.*\}\)\s*(--.*)?$')
OUTPUT = re.compile(r'output\s*=\s*"([^"]*)"')
POSITION = re.compile(r'(position\s*=\s*)"[^"]*"')


def rewrite(text, mons, positions):
    lines = text.split("\n")
    done = set()
    catch_all = None
    for i, line in enumerate(lines):
        if not RULE.match(line):
            continue
        out = OUTPUT.search(line.split("--", 1)[0])
        if not out:
            continue
        value = out.group(1)
        if value == "" and catch_all is None:
            catch_all = i
            continue
        for m in mons:
            if value in (m["name"], "desc:" + m["description"]) and POSITION.search(line):
                x, y = positions[m["name"]]
                lines[i] = POSITION.sub(r'\g<1>"%dx%d"' % (x, y), line, count=1)
                done.add(m["name"])

    new_rules = []
    for m in mons:
        if m["name"] in done:
            continue
        if not SAFE_NAME.match(m["name"]):
            die("Refusing unsafe monitor name: %r" % m["name"])
        x, y = positions[m["name"]]
        new_rules.append('hl.monitor({ output = "%s", mode = "preferred", position = "%dx%d", scale = %s })'
                         % (m["name"], x, y, fmt_scale(m["scale"])))
    if new_rules:
        at = catch_all + 1 if catch_all is not None else len(lines)
        lines[at:at] = new_rules
    return "\n".join(lines)


def save_and_reload(new_text):
    target = os.path.realpath(MONITORS_LUA)
    shutil.copy2(target, BACKUP)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target), prefix=".monitors.lua.")
    with os.fdopen(fd, "w") as f:
        f.write(new_text)
    shutil.copymode(target, tmp)
    os.replace(tmp, target)  # one atomic write, so Hyprland reloads once

    subprocess.run(["hyprctl", "reload"], capture_output=True)
    errors = subprocess.run(["hyprctl", "configerrors"], capture_output=True, text=True).stdout.strip()
    if errors and errors.lower() not in ("", "no errors", "[]"):
        shutil.copy2(BACKUP, target)
        subprocess.run(["hyprctl", "reload"], capture_output=True)
        die("Hyprland rejected the new layout, restored the previous one:\n" + errors)


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    mons = monitors()
    if argv[1] == "layout":
        print(json.dumps(mons))
        return 0
    if argv[1] == "place" and len(argv) in (4, 5):
        positions = place(mons, argv[2], argv[3], argv[4] if len(argv) == 5 else None)
        with open(MONITORS_LUA) as f:
            text = f.read()
        save_and_reload(rewrite(text, mons, positions))
        print(json.dumps(monitors()))
        return 0
    die(__doc__.strip(), 2)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
