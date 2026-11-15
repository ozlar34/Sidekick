#!/usr/bin/env python3
"""Driver for the Sidekick DebugHarness (see README "Debug harness"). Usage:
  sk.py sweep <note title>     geometric caret sweep: click every glyph, compare caret
  sk.py state
"""
import json, sys, urllib.request

BASE = "http://127.0.0.1:4567"

def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)

def state(): return call("GET", "/state")
def glyphs(): return call("GET", "/glyphs")
def open_note(title): return call("POST", "/open", {"title": title})
def click(x, y, **kw): return call("POST", "/click", {"x": x, "y": y, **kw})
def select(loc, length=0): return call("POST", "/select", {"location": loc, "length": length})
def shot(path, region="panel"): return call("POST", "/screenshot", {"path": path, "region": region})

def sweep(title, reset_to=None):
    open_note(title)
    import time; time.sleep(0.4)
    g = glyphs()
    text = state()["editor"]["text"]
    items = g["glyphs"]
    n = g["length"]
    mismatches = []
    # Group by line fragment to also test right-edge clicks.
    frags = {}
    for it in items:
        if "fragment" not in it: continue
        key = (it["fragment"]["y"], it["fragment"]["x"])
        frags.setdefault(key, []).append(it)
    for it in items:
        if "fragment" not in it or it["hidden"]: continue
        if it["char"] == "\n": continue
        i = it["index"]
        fr = it["fragment"]
        # Glyph extent = [this glyph's x, next visible glyph's x on the same
        # fragment). boundingRect is unreliable on heading lines.
        x0 = it["x"]
        nxt = next((j for j in items[i+1:] if "fragment" in j and j["fragment"] == fr and not j["hidden"] and j["x"] > x0), None)
        if nxt is None: continue
        w = nxt["x"] - x0
        if w <= 0: continue
        y = fr["y"] + fr["h"] / 2
        # click in the LEFT third of the glyph → expect caret before it (i)
        xl = x0 + min(1.5, w / 4)
        # reset caret somewhere neutral first so `previous` is stable
        select(reset_to if reset_to is not None else n)
        r = click(xl, y)
        got = r["selection"]
        if got["length"] != 0 or got["location"] != i:
            mismatches.append(("left", i, repr(it["char"]), it["markers"], got, (round(xl,1), round(y,1))))
        # click in the RIGHT third of the glyph → expect caret after it (i+1)
        xr = x0 + w - min(1.5, w / 4)
        select(reset_to if reset_to is not None else 0)
        r = click(xr, y)
        got = r["selection"]
        if got["length"] != 0 or got["location"] != i + 1:
            mismatches.append(("right", i, repr(it["char"]), it["markers"], got, (round(xr,1), round(y,1))))
    # right-edge-of-line clicks: expect caret at end of the fragment's visible chars
    for key, its in sorted(frags.items(), key=lambda kv: -kv[0][0]):
        fr = its[0]["fragment"]
        last = max(it["index"] for it in its)
        # expected: index after the last non-newline char in this fragment
        chars = [it for it in its if it["char"] != "\n"]
        exp = (max(it["index"] for it in chars) + 1) if chars else its[0]["index"]
        y = fr["y"] + fr["h"] / 2
        select(0)
        r = click(fr["x"] + fr["w"] - 2, y)
        got = r["selection"]
        if got["length"] != 0 or got["location"] != exp:
            mismatches.append(("lineend", exp, repr(text[exp-1:exp+1]), [m for it in its for m in it["markers"]][:3], got, (round(fr["x"]+fr["w"]-2,1), round(y,1))))
    print(f"== {title}: {n} chars, {len(mismatches)} mismatches")
    for m in mismatches:
        side, i, ch, markers, got, pt = m
        ctx = text[max(0,i-6):i] + "|" + text[i:i+6]
        print(f"  {side:7} idx={i:3} ch={ch:6} got={got['location']:3}/{got['length']} markers={markers} at={pt} ctx={ctx!r}")
    return mismatches

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "sweep":
        for t in sys.argv[2:]:
            sweep(t)
    elif cmd == "state":
        print(json.dumps(state(), indent=1)[:3000])
