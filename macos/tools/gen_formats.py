#!/usr/bin/env python3
"""Generate the file format catalog used by the macOS app from the
PhotoRec sources: src/file_list.c gives the formats compiled in, each
src/file_*.c gives extension, description and default state."""
import json, re, sys, pathlib

src = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "src")
out = sys.argv[2] if len(sys.argv) > 2 else "-"

listed = re.findall(r"&file_hint_(\w+)\s*\}", (src / "file_list.c").read_text(errors="replace"))
hints = {}
block_re = re.compile(r"const file_hint_t file_hint_(\w+)\s*=\s*\{(.*?)\};", re.S)
for path in src.glob("file_*.c"):
    for name, body in block_re.findall(path.read_text(errors="replace")):
        ext = re.search(r'\.extension\s*=\s*"([^"]*)"', body)
        desc = re.search(r'\.description\s*=\s*"([^"]*)"', body)
        enable = re.search(r"\.enable_by_default\s*=\s*(\d)", body)
        hints[name] = {
            "id": name,
            "extension": ext.group(1) if ext else name,
            "description": desc.group(1) if desc else "",
            "enabledByDefault": bool(enable and enable.group(1) == "1"),
        }
formats = [hints[n] for n in listed if n in hints]
data = json.dumps(formats, indent=1, ensure_ascii=False)
if out == "-":
    print(data)
else:
    pathlib.Path(out).write_text(data + "\n")
    print(f"{len(formats)} formats -> {out}", file=sys.stderr)
