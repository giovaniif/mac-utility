"""Turns a CHANGELOG section (bullets, `code`, **bold**) into the HTML that
Sparkle's update window shows. Reads stdin, writes stdout."""
import html
import re
import sys


def inline(text: str) -> str:
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    return re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)


out, in_list = [], False
for line in sys.stdin.read().strip().splitlines():
    bullet = re.match(r"\s*[-*] (.*)", line)
    if bullet:
        if not in_list:
            out.append("<ul>")
            in_list = True
        out.append(f"<li>{inline(bullet.group(1))}</li>")
        continue
    if in_list:
        out.append("</ul>")
        in_list = False
    if line.strip():
        out.append(f"<p>{inline(line.strip())}</p>")
if in_list:
    out.append("</ul>")
print("\n".join(out))
