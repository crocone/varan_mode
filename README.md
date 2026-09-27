# VaranMod (beta 0.9)

Life simulator: you are a lace monitor in an Australian riverland,
from the moment you break out of the egg until old age. Play alone, or share
one living world with up to 7 other players.

## Run

- **Built game:** `build\VaranMod.exe` (standalone, no install).
- **From source:** `run.bat`. It uses the bundled Godot 4.7.2 in `tools\godot\`,
  or open `game\project.godot` in Godot 4.7.
- **Rebuild the exe:** `export.bat`.

## Controls

| Key | Action |
|---|---|
| W A S D / mouse | crawl, look (wheel = camera distance) |
| Shift | sprint (drains stamina) |
| C / Ctrl | creep (harder to notice) |
| LMB | bite |
| RMB | tail whip |
| Space | dodge; jump off a tree |
| Q (hold) | rear up and hiss (posture) |
| E | eat, drink, dig eggs, climb or leave a tree, court, lay eggs |
| F | taste the air: shows scent trails to food, water and danger |
| R | rest; at night, sleep |
| H | hide the HUD |
| Esc | pause, save, settings |

## Multiplayer

Main menu → **Multiplayer**.

- **Host:** press *Host - hatch a new life* (or *continue your saved life*).
  You can also open a running game from the pause menu: *Open to other players*.
- **Join:** type the host's address (`192.168.1.20`, or `ip:port`) and press *Join*.
- Default port is **UDP 24580**. On the same network use the host's local IP.
  Over the internet the host must forward that UDP port on the router, or everyone
  joins the same virtual LAN (ZeroTier, Radmin VPN, Tailscale).

How it works:

- The host's world is shared: the day cycle, every animal, carcasses, eggs and nests.
- Each player simulates their own lizard, so there is no input lag. Animals see,
  hunt and fight other players exactly like the local one.
- Bites are detected on the attacker's screen and checked by the host.
- Players can fight each other (PvP) and eat each other's carcasses.
- The night only fast-forwards when every living player is asleep.
- Esc does not pause the shared world.
- The host saves as in single player. A joining player's lizard is saved separately
  on their own PC (`net_life.json`) and comes back on the next join.
- Continuing as your offspring is available to the host only. Other players
  hatch again at the nesting mound.

## Developer tests

Screenshots from these runs go to `tools\shots\`.

```
tools\godot\Godot_v4.7.2-stable_win64_console.exe --path game -- --test=<mode>
```

| Mode | What it runs |
|---|---|
| `shots` | screenshot tour |
| `rig` | close-ups of the lizard model |
| `climb` | tree climbing |
| `sim` | ecosystem simulation at 6× speed |
| `play god fast` | a bot plays a whole life |
| `save` | save/load round trip and the UI screens |
| `slope` | checks the body never sinks into the ground |
| `repro` | courtship, eggs and continuing as your offspring |
| `territory` | the resident monitor's territorial behaviour |
| `nethost` + `netjoin` | two-instance multiplayer test: start `nethost` first, then `netjoin` in a second window |
| `mpmenu` | screenshots of the multiplayer menu, online pause and death screens |

Other tools:

- `tools\check.sh` checks every script for parse errors.
- `tools\gen_audio.py` regenerates all sounds, which are synthesised procedurally.
