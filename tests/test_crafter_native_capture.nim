## Full native episodes through a loopback provider, with capture on/off parity.
import std/[json, os, osproc, streams, strutils, tempfiles]
import crafter/[sim, decide, prompts, training]

proc run(variant: string, destination: string, mode = "complete"): string =
  let provider = startProcess("python3", args = [
    currentSourcePath().parentDir() / "native_capture_provider.py", mode],
    options = {poUsePath, poStdErrToStdOut})
  defer:
    provider.terminate()
    discard provider.waitForExit(5000)
    provider.close()
  let port = provider.outputStream.readLine()
  putEnv("COWORLD_LLM_ENDPOINT", "http://127.0.0.1:" & port)
  putEnv("COWORLD_LLM_MODEL", "native-capture-fixture")
  putEnv("COWORLD_EPISODE_ID", "native-capture-" & variant & "-" & mode)
  putEnv("COWORLD_GAME_VERSION", "capture-fixture")
  putEnv("COWORLD_SOURCE_REVISION", repeat('a', 40))
  if destination.len > 0:
    putEnv("COGAME_SAVE_TRAJECTORY_URI", "file://" & destination)
  else:
    delEnv("COGAME_SAVE_TRAJECTORY_URI")
  var config = defaultGameConfig()
  let manifest = parseFile(currentSourcePath().parentDir().parentDir() /
    "coworld_manifest_template.json")
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      config.update($entry["game_config"])
  config.seed = 42
  config.variant = variant
  # Remove only wall pacing for deterministic CPU integration. Rules, horizon,
  # parser, retries, rate guard, simulator and scores remain the native ones.
  config.turnSpacingMs = 0
  config.validate()
  var game = initSimServer(config)
  game.phase = Playing
  game.startRun()
  let selection = promptSelection(newJObject())
  var engine = initDecisionEngine(game, selection)
  engine.seats[0] = SeatPolicy(isLlm: true, registered: true,
    label: "fixture-policy", prompt: "Keep private notes.")
  while game.phase != GameOver:
    if game.waitingForPlan():
      if not game.beginTurn(): break
      let turn = game.turnsPlayed + 1
      let privateView = game.observationJson(includeNotes = true)
      let publicView = game.observationJson(includeNotes = false)
      let decision = engine.turn(game, turn, 0)
      if not decision.ok:
        engine.trajectory.recordRejectedDecision(turn, privateView, selection,
          engine.seats[0].prompt, engine.nativeAttempts)
        if isPlayerDefect(decision.failureCause):
          game.deadSeats[0] = true
        game.applyStop(edFault,
          decision.failureCause & ": " & decision.failureDetail)
        break
      let applied = game.applyDirective(decision.directive, publicView)
      doAssert "PRIVATE_CAPTURE_SENTINEL" notin applied
      engine.trajectory.recordAppliedDecision(turn, privateView, selection,
        engine.seats[0].prompt, game, decision.directive, applied,
        engine.nativeAttempts, engine.seats[0].label)
    game.step()
  if mode in ["reject", "provider_error"]:
    doAssert game.endReason == erFault
    doAssert game.endRule == edFault
    if mode == "reject":
      doAssert game.deadSeats[0]
      doAssert game.stopDetail.startsWith("parse_error:")
    else:
      doAssert not game.deadSeats[0]
      doAssert game.stopDetail.startsWith("provider_error:")
  else:
    doAssert game.endReason == erComplete
  engine.trajectory.finishNativeTrajectory(game)
  result = if game.endReason == erComplete: game.runResultsJson()
           else: $(%*{"reason": $game.endReason, "endRule": $game.endRule,
                      "stopDetail": game.stopDetail})
  if destination.len > 0:
    let lines = readFile(destination).strip().splitLines()
    if mode in ["reject", "provider_error"]:
      doAssert lines.len == 2
      let rejected = parseJson(lines[0])
      doAssert rejected["action_status"].getStr() == "rejected"
      doAssert rejected["selected_attempt_id"].kind == JNull
      doAssert rejected["executed_action"].kind == JNull
      doAssert rejected["attempts"].len == 1
      doAssert not rejected["attempts"][0]["accepted"].getBool()
      let terminal = parseJson(lines[^1])
      doAssert terminal["status"].getStr() == "failed"
      doAssert not terminal["outcome"].hasKey("scores")
      doAssert not terminal["outcome"].hasKey("win")
      doAssert not terminal["outcome"].hasKey("winner")
      doAssert terminal["outcome"]["reason"].getStr() == "fault"
      doAssert terminal["outcome"]["endRule"].getStr() == "fault"
      doAssert terminal["participant_outcomes"] == newJObject()
      return
    doAssert lines.len > 3
    let first = parseJson(lines[0])
    doAssert first["attempts"].len == 1
    let accepted = first["attempts"][0]
    doAssert accepted["accepted"].getBool()
    doAssert accepted["prompt"][^1]["role"].getStr() == "user"
    doAssert accepted["request"]["messages"][^1] == accepted["prompt"][^1]
    doAssert accepted["response"].getStr().startsWith("{")
    doAssert parseJson(accepted["raw_response"].getStr())["content"][0]["text"] == accepted["response"]
    doAssert accepted["platform_call_id"].getStr().len == 36
    doAssert accepted["behavior_logprobs"].kind == JNull
    let promptAttempts = first["observation"]["prompt_attempts"]
    doAssert promptAttempts.len == 1
    doAssert promptAttempts[0]["attempt_id"] == accepted["attempt_id"]
    doAssert promptAttempts[0]["prompt_template"] == selection.promptMetadata(
      accepted["request"]["system"].getStr(),
      accepted["request"]["messages"][0]["content"].getStr())
    let fencedTurn = parseJson(lines[1])
    doAssert fencedTurn["action_status"].getStr() == "accepted"
    doAssert fencedTurn["attempts"].len == 1
    doAssert fencedTurn["attempts"][0]["accepted"].getBool()
    doAssert fencedTurn["executed_action"]["actions"] == %*[{"act": "noop"}]
    let terminal = parseJson(lines[^1])
    doAssert terminal["status"].getStr() == "completed"
    doAssert terminal["outcome"] == parseJson(result)
    doAssert terminal["seed_family"].getStr() == "crafter-42"
    doAssert (getFilePermissions(destination) * {fpOthersRead, fpGroupRead}) == {}

let output = createTempDir("crafter-native-capture-", "")
for variant in ["standard", "longnight"]:
  let captured = run(variant, output / (variant & ".jsonl"))
  let ordinary = run(variant, "")
  doAssert captured == ordinary, "capture changed ordinary native game outcomes"
  let rejectedCaptured = run(variant, output / (variant & "-reject.jsonl"), "reject")
  let rejectedOrdinary = run(variant, "", "reject")
  doAssert rejectedCaptured == rejectedOrdinary, "capture changed rejected native game outcomes"
  let providerCaptured = run(variant, output / (variant & "-provider.jsonl"), "provider_error")
  let providerOrdinary = run(variant, "", "provider_error")
  doAssert providerCaptured == providerOrdinary, "capture changed provider-error native game outcomes"
echo "complete native episodes: complete plain/fenced replies/rejections/provider-errors/private capture and outcome parity passed"
