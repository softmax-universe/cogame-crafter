## Bounded orders and legality on the scripted baselines, the driver and the
## reply validator — design note §Tests items 19..25.

import std/[json, random, sets, unicode, unittest]
import crafter/[sim, driver, directives, baselines, decide]
import helpers

const Verbs = block:
  var names: seq[string]
  for kind in ActionKind:
    names.add($kind)
  names

proc pseudoStates(count: int): seq[SimServer] =
  ## `count` pseudo-random world states across both variants, day and night,
  ## every vitals combination, empty and full inventories, and adjacent to
  ## lava, water and hostiles.
  var rng = initRand(20260828)
  for i in 0 ..< count:
    let variant = if i mod 2 == 0: "standard" else: "longnight"
    var sim = startedSim(testConfig(variant, seed = 100 + i))
    sim.tickCount = sim.gameStartTick + rng.rand(0 .. 1300)
    sim.randomKnownMap(rng, rng.rand(5 .. 95))
    for vital in Vital:
      sim.cog.vitals[vital] = rng.rand(0 .. VitalMax)
    for resource in Resource:
      sim.cog.inventory[resource] =
        if i mod 3 == 0: 0 elif i mod 3 == 1: InventoryMax
        else: rng.rand(0 .. InventoryMax)
    for tool in Tool:
      sim.cog.tools[tool] = rng.rand(0 .. 1) == 1
    sim.cog.facing = Facings[rng.rand(0 .. 3)]
    ## Put lava, water and a hostile right next to the cog on every third
    ## state, so the "never suicide" rule is actually exercised.
    if i mod 3 == 0:
      sim.world.setAt(sim.cog.x + 1, sim.cog.y, tLava)
      sim.world.setAt(sim.cog.x - 1, sim.cog.y, tWater)
      sim.world.setAt(sim.cog.x, sim.cog.y - 1, tLava)
      sim.terrainHash = sim.world.terrainDigest()
      discard sim.knownMap.mergeVisible(sim.world, sim.cog.x, sim.cog.y,
                                        sim.tickCount)
      sim.herd.list.add(Creature(kind: ckZombie, x: sim.cog.x + 2,
                                 y: sim.cog.y + 1, hp: 5, alive: true))
      sim.herd.list.add(Creature(kind: ckSkeleton, x: sim.cog.x - 2,
                                 y: sim.cog.y - 2, hp: 3, alive: true))
    if i mod 5 == 0:
      sim.herd.list.add(Creature(kind: ckCow, x: sim.cog.x + 3,
                                 y: sim.cog.y, hp: 3, alive: true))
    result.add(sim)

suite "the scripted baselines are bounded and legal":
  let states = pseudoStates(300)

  test "baselines are bounded":
    ## Item 19.
    for kind in [blForager, blWanderer]:
      for sim in states:
        let plan = scriptedPlan(sim, kind)
        check plan.actions.len <= sim.config.maxActionsPerTurn
        check plan.say.len == 0
        check plan.notes.len == 0
        check plan.source == dsScripted
        for action in plan.actions:
          check $action.kind in Verbs
          case action.kind
          of akGoto:
            check action.x in 0 ..< WorldSize
            check action.y in 0 ..< WorldSize
          of akMove:
            check action.n in 1 .. 12
          of akDo:
            check action.n in 1 .. 12
          of akSleep:
            check action.n in 1 .. 24
          else:
            check action.n == 1
        ## The serialised directive stays small.
        let record = $plan.directiveRecord(1, sim.tickCount, 0, seatAlias(0),
          @[], false, 0, 0, "", nil)
        check record.len <= 1024

  test "baselines never suicide, and forager never routes through the unknown":
    ## Item 20.
    for kind in [blForager, blWanderer]:
      for sim in states:
        let plan = scriptedPlan(sim, kind)
        let expansion = expandPlan(sim.knownMap, sim.cog.x, sim.cog.y,
          plan.actions, sim.config.macroPrimitiveCap, sim.config.turnTicks,
          sim.hostileCells())
        var x = sim.cog.x
        var y = sim.cog.y
        for primitive in expansion.primitives:
          let moving = moveFacing(primitive)
          if not moving.ok:
            continue
          let
            nx = x + FacingDx[moving.dir]
            ny = y + FacingDy[moving.dir]
          let entry = sim.knownMap.known(nx, ny)
          ## A step onto a cell the cog KNOWS is lava is suicide.
          check not (entry.seen and entry.terrain == tLava)
          if sim.world.at(nx, ny).walkable():
            x = nx
            y = ny
        ## The BFS the forager's `goto` runs on never crosses `?`.
        for action in plan.actions:
          if action.kind != akGoto:
            continue
          let walk = gotoPrimitives(sim.knownMap, sim.cog.x, sim.cog.y,
            action.x, action.y, sim.config.macroPrimitiveCap)
          var wx = sim.cog.x
          var wy = sim.cog.y
          for primitive in walk.primitives:
            let moving = moveFacing(primitive)
            if not moving.ok:
              continue
            let
              nx = wx + FacingDx[moving.dir]
              ny = wy + FacingDy[moving.dir]
            if sim.knownMap.traversable(nx, ny):
              check sim.knownMap.known(nx, ny).seen
              wx = nx
              wy = ny

  test "the driver never produces an illegal primitive":
    ## Item 21.
    for kind in [blForager, blWanderer]:
      for sim in states:
        let plan = scriptedPlan(sim, kind)
        let expansion = expandPlan(sim.knownMap, sim.cog.x, sim.cog.y,
          plan.actions, sim.config.macroPrimitiveCap, sim.config.turnTicks,
          sim.hostileCells())
        check expansion.primitives.len <= sim.config.turnTicks
        for primitive in expansion.primitives:
          check ord(primitive) in ord(low(Primitive)) .. ord(high(Primitive))
        ## A macro expands to at most macroPrimitiveCap.
        for action in plan.actions:
          if action.kind != akGoto:
            continue
          let walk = gotoPrimitives(sim.knownMap, sim.cog.x, sim.cog.y,
            action.x, action.y, sim.config.macroPrimitiveCap)
          check walk.primitives.len <= sim.config.macroPrimitiveCap
    ## An EMPTY queue yields `noop`, never nothing: a turn is turnTicks ticks.
    var sim = startedSim(testConfig())
    discard sim.beginTurn()
    sim.installPlan(@[], false, 0, 0)
    sim.stepTick()
    check sim.executed == @[pNoop]

  test "parseBaseline accepts only canonical scripted names":
    check tryParseBaseline("forager") == (true, blForager)
    check tryParseBaseline("wanderer") == (true, blWanderer)
    check not tryParseBaseline("wander").ok
    check not tryParseBaseline("unknown").ok
    expect ValueError:
      discard parseBaseline("wander")

suite "reply validation":
  test "the validator accepts canonical replies and optional defaults":
    let payload = parseJson("""{"actions":[
      {"act":"goto","x":35,"y":25},
      {"act":"do","n":4},
      {"act":"do"},
      {"act":"make_stone_sword"},
      {"act":"move_up"},
      {"act":"move","dir":"up","n":12},
      {"act":"move","dir":"left"},
      {"act":"sleep","n":24}],
      "say":"planning","notes":"scratch"}""")
    let directive = parseDirective(payload, 12)
    check directive.dropped == 0
    check directive.overCap == 0
    let kinds = block:
      var names: seq[string]
      for action in directive.actions:
        names.add($action.kind)
      names
    check kinds == @["goto", "do", "do", "make_stone_sword", "move_up",
                     "move", "move", "sleep"]
    check directive.actions[1].n == 4
    check directive.actions[2].n == 1
    check directive.actions[5].n == 12
    check directive.actions[5].dir == fUp
    check directive.actions[6].n == 1
    check directive.actions[6].dir == fLeft
    check directive.actions[7].n == 24
    ## Empty actions array with optional say/notes omitted is valid.
    let idle = parseDirective(parseJson("""{"actions":[]}"""), 12)
    check idle.actions.len == 0
    check idle.say == ""
    check idle.notes == ""

  test "extractJsonObject accepts bare or single outer fence and rejects prose or extra objects":
    let bare = extractJsonObject("""  {"actions":[{"act":"noop"}]}  """)
    check bare["actions"].len == 1
    let jsonFence = extractJsonObject(
      "```json\n{\"actions\":[{\"act\":\"do\"}]}\n```")
    check jsonFence["actions"].len == 1
    let plainFence = extractJsonObject(
      "```\n{\"actions\":[{\"act\":\"sleep\",\"n\":2}]}\n```")
    check plainFence["actions"].len == 1
    for bad in [
      "no braces at all",
      "[]",
      "here you go:\n```json\n{\"actions\":[]}\n```\nok",
      "Sure! {\"actions\":[]}",
      "{\"actions\":[]} thanks",
      "{\"actions\":[]} {\"actions\":[{\"act\":\"do\"}]}",
      "```json\n{\"actions\":[]}\n```\n```json\n{\"actions\":[]}\n```",
      "```json\n{\"actions\":[]}\n{\"actions\":[]}\n```",
      "```python\n{\"actions\":[]}\n```",
      "```json\n{\"actions\":[]}"
    ]:
      expect DirectiveError:
        discard extractJsonObject(bad)

  test "strict parseDirective rejects shims, aliases, out-of-range fields, and over-cap lists":
    for bad in [
      "[]",
      """{"say":"thinking"}""",
      """{"actions":"do"}""",
      """{"actions":["do"]}""",
      """{"actions":[{"do":"do"}]}""",
      """{"actions":[{"act":"MOVE-UP"}]}""",
      """{"actions":[{"act":"move","dir":"N","n":4}]}""",
      """{"actions":[{"act":"move","dir":"north"}]}""",
      """{"actions":[{"act":"move","dir":"UP"}]}""",
      """{"actions":[{"act":"move","dir":"sideways"}]}""",
      """{"actions":[{"act":"move","dir":"up","n":13}]}""",
      """{"actions":[{"act":"move","dir":"up","n":0}]}""",
      """{"actions":[{"act":"move","dir":"up","n":"4"}]}""",
      """{"actions":[{"act":"sleep","n":25}]}""",
      """{"actions":[{"act":"noop","n":2}]}""",
      """{"actions":[{"act":"goto","y":3}]}""",
      """{"actions":[{"act":"goto","x":"3","y":4}]}""",
      """{"actions":[{"act":"goto","x":3.5,"y":4}]}""",
      """{"actions":[{"act":"goto","x":-1,"y":4}]}""",
      """{"actions":[{"act":"goto","x":4,"y":64}]}""",
      """{"actions":[{"act":"teleport"}]}""",
      """{"actions":[],"say":123}""",
      """{"actions":[],"notes":["x"]}"""
    ]:
      expect DirectiveError:
        discard parseDirective(parseJson(bad), 12)
    var overCap = newJArray()
    for i in 0 .. 12:
      overCap.add(%*{"act": "do"})
    expect DirectiveError:
      discard parseDirective(%*{"actions": overCap}, 12)

  test "say and notes truncate on RUNE boundaries with 4-byte emoji on the cap":
    ## Item 23's rune clause. A byte slice would cut a codepoint in half and
    ## the replay would then fail a strict UTF-8 parser.
    let emoji = "\u{1F9E9}"                     ## a 4-byte codepoint
    var say = ""
    for i in 0 ..< MaxSayRunes + 40:
      say.add(emoji)
    var notes = ""
    for i in 0 ..< MaxNoteRunes + 40:
      notes.add(emoji)
    let directive = parseDirective(%*{"actions": [], "say": say, "notes": notes}, 12)
    check directive.say.runeLen == MaxSayRunes
    check directive.notes.runeLen == MaxNoteRunes
    check directive.say.len == MaxSayRunes * 4  ## whole codepoints, every one
    check directive.notes.validateUtf8() == -1
    check directive.say.validateUtf8() == -1

  test "truncated, dropped, unreachable and interrupted are reported back":
    var sim = startedSim(testConfig())
    sim.clearAroundForTest()
    var directive = Directive(source: dsLlm)
    for i in 0 .. 29:
      directive.actions.add(Action(kind: akDo, n: 1))
    directive.actions.add(Action(kind: akGoto, x: 2, y: 2, n: 1))
    directive.dropped = 2
    directive.overCap = 3
    sim.lastInterrupted = "hurt_by_zombie"
    let record = parseJson(sim.applyDirective(directive, nil))
    check record["truncated"].getBool()
    check record["unreachable"].getInt() == 1
    check record["dropped"].getInt() == 3
    check record["interrupted"].getStr() == "hurt_by_zombie"
    check sim.repliesRepaired == 2
    let observation = sim.observationJson(includeNotes = true)
    check observation["last_plan"]["truncated"].getBool()
    check observation["last_plan"]["unreachable"].getInt() == 1

  test "the record keeps the observation even with a full-cap say":
    ## The `directive` record carries `view` "so the replay explains every
    ## decision" (design note, §Decisions -> observation). The record cap is
    ## sized for a whole observation plus a full-cap `say`, and `say` — never
    ## the view — is what shrinks when something has to give.
    var sim = startedSim(testConfig())
    var directive = Directive(source: dsLlm)
    directive.actions.add(Action(kind: akDo, n: 1))
    for i in 0 ..< MaxSayRunes:
      directive.say.add("\u{1F9E9}")
    let observation = sim.observationJson(includeNotes = false)
    let record = parseJson(sim.applyDirective(directive, observation))
    check record["view"].kind == JObject
    check record["view"] == observation
    check record["say"].getStr().runeLen == MaxSayRunes
    check ($record).runeLen <= MaxDirectiveRunes


  test "the shipped thresholds equal the swept pick":
    ## Item 24.
    let sweep = parseJson(readRepo("tools/ci/baseline_tuning.json"))
    let pick = sweep["pick"]
    check pick["thirstThreshold"].getInt() == DefaultBaselineParams.thirstThreshold
    check pick["hungerThreshold"].getInt() == DefaultBaselineParams.hungerThreshold
    check pick["shelterStones"].getInt() == DefaultBaselineParams.shelterStones
    check pick["sleepTicks"].getInt() == DefaultBaselineParams.sleepTicks
    check pick["restThreshold"].getInt() == DefaultBaselineParams.restThreshold
    check pick["exploreSteps"].getInt() == DefaultBaselineParams.exploreSteps
    check pick["tieBreakByDistance"].getBool() ==
      DefaultBaselineParams.tieBreakByDistance
    ## The recorded grid is the WHOLE matrix, not a hand-picked row set: every
    ## tunable in `pick` is swept in the grid, and every cell reports every
    ## tunable. A `pick` field that appears in no grid row was never swept.
    check sweep["grid"].len > 100
    for key in ["thirstThreshold", "hungerThreshold", "shelterStones",
                "sleepTicks", "restThreshold", "exploreSteps",
                "tieBreakByDistance"]:
      var values: HashSet[string]
      for cell in sweep["grid"]:
        check cell.hasKey(key)
        values.incl($cell[key])
      check values.len > 1
      ## and the pick's own value is one the sweep actually played
      check $pick[key] in values
    for cell in sweep["grid"]:
      check cell.hasKey("achievements")
      check cell.hasKey("ticks")
      check cell.hasKey("certTicks")

  test "forager beats wanderer, and wanderer is not a zero":
    ## Item 25: over 100 seeds of each variant.
    for variant in ["standard", "longnight"]:
      var forager = 0
      var wanderer = 0
      for seed in 1 .. 100:
        let config = testConfig(variant, seed)
        forager += playScripted(config, blForager).achievementsUnlocked()
        wanderer += playScripted(config, blWanderer).achievementsUnlocked()
      check forager > wanderer
      check wanderer >= 1
