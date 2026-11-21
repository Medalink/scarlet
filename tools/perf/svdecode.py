"""svdecode.py <Scarlet.lua SavedVariables> <out file>: writes the chunks as plain text for the perf harness.

Read only: the SavedVariables file is never changed. The output holds real player data (names, places),
so it goes to a temp folder and is never committed. Run it as `python -I svdecode.py ...`.

Output: for each chunk a header line "@@<TAB>q<TAB>c<TAB>s<TAB>t<TAB>n<TAB>r" and then the chunk's lines.
The open buffer (db.buf) is not written: it holds the last session's tail and the harness has its own.
"""
import base64
import re
import sys
import zlib

CHUNK = re.compile(r'\{([^{}]*?\["z"\]\s*=\s*"[^"]*"[^{}]*?)\}')
FIELD = re.compile(r'\["(\w+)"\]\s*=\s*("(?:[^"\\]|\\.)*"|-?[\d.eE+]+|true|false)')


def fields(body):
    out = {}
    for key, raw in FIELD.findall(body):
        if raw.startswith('"'):
            out[key] = raw[1:-1]
        elif raw in ("true", "false"):
            out[key] = raw == "true"
        else:
            out[key] = float(raw) if ("." in raw or "e" in raw.lower()) else int(raw)
    return out


def inflate(data):
    try:
        return zlib.decompress(data, -15)  # raw DEFLATE first, as docs/FORMAT.md says
    except zlib.error:
        return zlib.decompress(data)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    start = text.find('["chunks"]')
    if start < 0:
        sys.exit("no chunks table in " + src)
    chunks = 0
    lines = 0
    with open(dst, "w", encoding="utf-8", newline="\n") as out:
        for m in CHUNK.finditer(text, start):
            f = fields(m.group(1))
            if "z" not in f:
                continue
            if f.get("e") == "d64":
                body = inflate(base64.b64decode(f["z"])).decode("utf-8", errors="replace")
            else:
                body = f["z"].encode("utf-8").decode("unicode_escape") if "\\" in f["z"] else f["z"]
            out.write("@@\t%s\t%s\t%s\t%s\t%s\t%s\n" % (f.get("q", 0), f.get("c", "?"), f.get("s", 0),
                                                       f.get("t", 0), f.get("n", 0), 1 if f.get("r") else 0))
            out.write(body)
            if not body.endswith("\n"):
                out.write("\n")
            chunks += 1
            lines += body.count("\n") + 1
    print("%d chunks, %d lines" % (chunks, lines))


main()
