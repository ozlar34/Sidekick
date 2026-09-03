---
name: verify
description: Build, launch, and drive Sidekick through its in-app debug harness to observe an editor change live (caret, selection, screenshots). Use for /verify on this repo.
---

# Verify Sidekick live

Needs an unlocked console (locked → app can't activate, captures are blank).

```bash
swift build -c release
./Scripts/debug-harness/debug-launch.sh "$PWD/Scripts/debug-harness/fixtures" 4567   # scratch bundle, LaunchServices launch, kills any running Sidekick
sleep 3; curl -s -X POST localhost:4567/summon
curl -s localhost:4567/state | python3 -m json.tool | head -60          # notes[] gives ids/titles; editor.text is the live buffer
```

Drive from Python (`Scripts/debug-harness/sk.py` exposes `call/state/glyphs/open_note/click/select/shot`):

```python
import sys, time; sys.path.insert(0, "Scripts/debug-harness"); import sk
sk.call("POST", "/open", {"id": "<note id from /state>"}); time.sleep(0.5)
g = {it["index"]: it for it in sk.glyphs()["glyphs"] if "fragment" in it}   # per-char x + line fragment
x, y = g[21]["x"] + 1.5, g[21]["fragment"]["y"] + g[21]["fragment"]["h"] / 2
sk.click(x, y, mods=["shift"])                 # mods: cmd/shift/opt/ctrl; count=2 for double-click; drag_to={"x":..,"y":..}
sk.shot("/path/out.png")                        # returns inkFraction — 0 means blank editor
```

`/click` returns the resulting `selection`; `/select` sets it. Fixture titles: "Above the rule" (HRs), "Heading one", "Plain paragraph first.", links note (open by id; title is raw line 1).

Gotchas
- `/open` by `title` needs an exact match; use `id`.
- `--debug-port 0` is rejected (harness not started, logged to stderr); always pass a real port. Check the listener with `lsof -a -nP -p $(pgrep -x Sidekick) -iTCP -sTCP:LISTEN`.
- NSLog output from the LaunchServices launch does not reach `log show`; to read harness log lines run `.build/release/Sidekick --debug-port <n> ... 2>&1 | tee` directly.
- Stop with `pkill -x Sidekick`. Debug bundle id is `com.oguzoral.SidekickDebug`, so prefs never touch the real app's domain.
