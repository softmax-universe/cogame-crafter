# Actions and the reply format

Reply with **one JSON object and nothing else**, either bare JSON or inside a
single ordinary outer Markdown code fence (` ```json ` or ` ``` `). Surrounding
prose, multiple objects, non-object JSON, legacy field aliases, and invalid
actions are **rejected** (retried once, then surfaced as a player failure — no
silent substitution or fallback moves).

```json
{"actions": [{"act": "goto", "x": 35, "y": 25},
             {"act": "do", "n": 4},
             {"act": "make_stone_sword"}],
 "say": "stone ridge is five cells NE; mining it then arming up before the zombies find me",
 "notes": "table (29,26). coal (39,24). after stone sword: furnace, then hunt iron in the cave."}
```

| Field | Type | Cap / domain |
|---|---|---|
| `actions` | array | **required**, ordered action objects. Empty array `[]` = 24 `noop` ticks. Missing, non-array, non-object entries, or > 12 entries are rejected |
| `actions[].act` | string | **required**; exact canonical name of one of the **17 primitives** or **2 macros** (`goto`, `move`) |
| `actions[].x`, `.y` | integer | required iff `act == "goto"`; integer in `0..63`; non-integer, absent, or out-of-bounds values are rejected |
| `actions[].dir` | string | required iff `act == "move"`; exact canonical direction `up | down | left | right`; anything else is rejected |
| `actions[].n` | integer | optional on `move` (`1..12`), `do` (`1..12`), and `sleep` (`1..24`), defaulting to `1`; non-integer, out-of-range, or use on any other verb is rejected |
| `say` | string | optional, **<= 160 runes** — the cog thinking out loud; drawn in the spectator feed and in the replay, never fed back to the seat |
| `notes` | string | optional, **<= 400 runes** — private scratchpad, echoed to this seat only next turn |
| whole reply | bytes | **<= 4096** read from the provider before parsing |
| `PLAYER_PROMPT` | string | **<= 4000 runes** at registration |

**Invalid replies are rejected, never rewritten or silently repaired.** Turning
a malformed `goto` into a `move_down` or substituting a fallback move hides
model defects, so invalid replies fail validation and trigger the failure
path.

Every string that lands in the replay — `say`, `notes`, the policy label,
`stopDetail`, recorded error text — is truncated on **rune boundaries**, never
by byte index.

## The seventeen primitives

`noop` `move_left` `move_right` `move_up` `move_down` `do` `sleep`
`place_stone` `place_table` `place_furnace` `place_plant`
`make_wood_pickaxe` `make_stone_pickaxe` `make_iron_pickaxe`
`make_wood_sword` `make_stone_sword` `make_iron_sword`

- **`move_<dir>`** sets the facing **and** steps one cell if that cell is
  walkable and creature-free; if it is not, the cog only **turns**. Stepping
  into lava sets health to 0 on that tick.
- **`do`** acts on the cell the cog faces: a **creature** there is attacked;
  else the terrain's mining rule applies (a `do` on grass yields a sapling on a
  1-in-10 draw); else nothing.
- **`sleep`** adds 1 energy and keeps the cog asleep for consecutive `sleep`
  primitives only. Any other primitive wakes it, and so does taking damage.
- **`place_stone`** costs 1 stone and covers `grass | sand | path | water |
  lava`. **Placing over lava is how you cross it.**
- **`place_table`** costs 1 wood, **`place_furnace`** 1 stone; both need the
  faced cell to be `grass | sand | path`. **`place_plant`** costs 1 sapling and
  needs grass.
- **Crafting** requires a `table` within Chebyshev 1, and the two iron recipes a
  `furnace` within 1 as well.

| Recipe | Costs | Also needs |
|---|---|---|
| `make_wood_pickaxe` | 1 wood | table |
| `make_wood_sword` | 1 wood | table |
| `make_stone_pickaxe` | 1 wood + 1 stone | table |
| `make_stone_sword` | 1 wood + 1 stone | table |
| `make_iron_pickaxe` | 1 wood + 1 coal + 1 iron | table **and** furnace |
| `make_iron_sword` | 1 wood + 1 coal + 1 iron | table **and** furnace |

**An inapplicable primitive is a no-op that still costs its tick.** There is no
error, no repair and no free retry: that is the whole cost model of the game.

## The two macros

- **`{"act":"goto","x":35,"y":25}`** — the shortest path through ground you have
  **already seen**. It refuses `?`, water, lava, rock, trees, tables, furnaces
  and plants, and it refuses a cell holding a hostile you can see. It stops
  **on** the target if you can stand there, otherwise **next to it, facing it**
  — which is exactly what you want before `do`. An unreachable target yields
  **zero** primitives and is reported back as `unreachable`.
- **`{"act":"move","dir":"up","n":4}`** — up to four `move_up` primitives.
  `move` also **turns**: moving into a wall just turns you to face it.

## What you get each turn

```json
{"you": "Alpha", "turn": 23, "tick": 541,
 "world": {"size": 64, "view": 9, "region": 16, "legend": {"...": "..."}},
 "time": {"day": 3, "phase": "night", "ticks_to_phase_change": 37,
          "ticks_left": 803, "turns_left": 33},
 "agent": {"x": 30, "y": 27, "facing": "down", "asleep": false,
           "health": 6, "food": 4, "drink": 7, "energy": 3,
           "ahead": {"glyph": "T", "what": "tree", "x": 30, "y": 28}},
 "inventory": {"wood": 3, "stone": 5, "coal": 1, "iron": 0, "diamond": 0, "sapling": 1},
 "tools": {"wood_pickaxe": true, "...": false},
 "near": {"table": true, "furnace": false},
 "view": ["nine rows", "of nine glyphs", "..."],
 "region": ["sixteen rows", "of sixteen glyphs", "..."],
 "nearest": {"tree": {"x": 30, "y": 28, "d": 1}, "iron": null, "...": null},
 "landmarks": [{"what": "stone", "x": 35, "y": 25, "d": 5, "seen_tick": 498}],
 "threats": [{"what": "zombie", "x": 31, "y": 30, "d": 3}],
 "achievements": {"count": 11, "of": 22, "unlocked": ["..."], "locked": ["..."]},
 "last_plan": {"executed": ["move_down", "do"], "truncated": false,
               "dropped": 0, "unreachable": 0, "interrupted": "hurt_by_zombie"},
 "notes": "your own scratchpad, echoed back"}
```

**Hidden:** the episode `seed`; every cell never observed; every noise-field
value and generator threshold; creature HP, spawn schedule and future moves; the
1-in-10 sapling draw; the cog's own **score**; `parAchievements`; and its own
real player name. Nothing about identity ever reaches a prompt.
