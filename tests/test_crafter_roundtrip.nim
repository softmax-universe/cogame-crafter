## Public host + player round-trip tests over loopback WebSocket + HTTP.
## Verifies:
##   1. Native LLM player (regular JSON + markdown code fence) completes and
##      writes authoritative results.json + completed trajectory.
##   2. Invalid/ambiguous LLM reply fails cleanly: non-zero server exit, NO
##      results.json, closed-schema player_failure.json (kind=player_error),
##      unscored failed trajectory with rejected attempts.
##   3. Provider/infra failure (HTTP 503) fails cleanly: non-zero server exit,
##      NO results.json, closed-schema player_failure.json
##      (kind=episode_inconclusive), unscored failed trajectory with
##      provider_error stopDetail.
##   4. Explicit offline scripted baseline (forager) completes offline with no
##      credentials and writes authoritative results.json.

import std/[json, net, os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import helpers

proc freePort(): int =
  let sock = newSocket()
  defer: sock.close()
  sock.bindAddr(Port(0), "127.0.0.1")
  let (_, port) = sock.getLocalAddr()
  int(port)

proc compileBinary(source, output: string) =
  let flags = when defined(release): "-d:release " else: ""
  let cmd = "nim c --hints:off " & flags & "--path:" &
    quoteShell(repoRoot() / "src") & " -o:" & quoteShell(output) & " " &
    quoteShell(source)
  let res = execCmdEx(cmd, workingDir = repoRoot())
  doAssert res.exitCode == 0, "failed to compile " & source & ":\n" & res.output

proc baseEnv(): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k notin ["COWORLD_LLM_ENDPOINT", "COWORLD_LLM_MODEL", "ANTHROPIC_API_KEY",
                "ANTHROPIC_API_KEY_URI", "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
                "AWS_BEARER_TOKEN_BEDROCK", "PLAYER_PROMPT", "PLAYER_SCRIPTED",
                "PLAYER_POLICY_LABEL", "COGAME_CONFIG_URI", "COGAME_RESULTS_URI",
                "COGAME_SAVE_REPLAY_URI", "COGAME_PLAYER_FAILURE_URI",
                "COGAME_SAVE_TRAJECTORY_URI", "COGAME_EVENTS_URI"]:
      result[k] = v

proc runRoundTrip(serverBin, playerBin, workDir, scenario: string,
                  playerEnv: seq[(string, string)],
                  providerMode = ""): tuple[serverCode, playerCode: int] =
  createDir(workDir)
  let port = freePort()
  let configPath = workDir / "config.json"
  let resultsPath = workDir / "results.json"
  let replayPath = workDir / "episode.replay"
  let failurePath = workDir / "player_failure.json"
  let trajPath = workDir / "trajectory.jsonl"

  let config = %*{
    "players": [{"name": "Alpha"}],
    "tokens": ["tok-0"],
    "num_agents": 1,
    "minPlayers": 1,
    "seed": 42,
    "turnTicks": 24,
    "maxTurns": 2,
    "maxTicks": 48,
    "turnSpacingMs": 0,
    "lobbyJoinTimeoutTicks": 240,
    "gameOverTicks": 24,
    "fastMode": true
  }
  writeFile(configPath, $config)

  var provider: Process = nil
  var providerPort = ""
  if providerMode.len > 0:
    provider = startProcess("python3", args = [
      currentSourcePath().parentDir() / "native_capture_provider.py", providerMode],
      options = {poUsePath, poStdErrToStdOut})
    providerPort = provider.outputStream.readLine().strip()
  defer:
    if provider != nil:
      provider.terminate()
      discard provider.waitForExit(5000)
      provider.close()

  var sEnv = baseEnv()
  sEnv["COGAME_HOST"] = "127.0.0.1"
  sEnv["COGAME_PORT"] = $port
  sEnv["COGAME_CONFIG_URI"] = "file://" & configPath
  sEnv["COGAME_RESULTS_URI"] = "file://" & resultsPath
  sEnv["COGAME_SAVE_REPLAY_URI"] = "file://" & replayPath
  sEnv["COGAME_PLAYER_FAILURE_URI"] = "file://" & failurePath
  sEnv["COGAME_SAVE_TRAJECTORY_URI"] = "file://" & trajPath
  sEnv["COWORLD_EPISODE_ID"] = "roundtrip-" & scenario
  sEnv["COWORLD_GAME_VERSION"] = "roundtrip-test"
  sEnv["COWORLD_SOURCE_REVISION"] = repeat('b', 40)
  if providerPort.len > 0:
    sEnv["COWORLD_LLM_ENDPOINT"] = "http://127.0.0.1:" & providerPort
    sEnv["COWORLD_LLM_MODEL"] = "native-capture-fixture"

  var pEnv = baseEnv()
  pEnv["COWORLD_PLAYER_WS_URL"] = "ws://127.0.0.1:" & $port & "/player?slot=0&token=tok-0"
  for (k, v) in playerEnv:
    pEnv[k] = v

  let serverProc = startProcess(serverBin, env = sEnv,
    options = {poStdErrToStdOut})
  let playerProc = startProcess(playerBin, env = pEnv,
    options = {poStdErrToStdOut})
  defer:
    if serverProc.running:
      serverProc.terminate()
    if playerProc.running:
      playerProc.terminate()
    serverProc.close()
    playerProc.close()

  let sCode = serverProc.waitForExit(30_000)
  let pCode = playerProc.waitForExit(15_000)
  (sCode, pCode)

suite "public host+player round-trip":
  let tmp = createTempDir("crafter-roundtrip-", "")
  let serverBin = tmp / "crafter"
  let playerBin = tmp / "crafter-player"
  compileBinary(repoRoot() / "src" / "crafter.nim", serverBin)
  compileBinary(repoRoot() / "src" / "crafter_player.nim", playerBin)

  let m = manifest()
  let llmEntry = m["player"][0]
  var llmEnv: seq[(string, string)]
  for k, v in llmEntry["env"]:
    llmEnv.add((k, v.getStr()))
  let foragerEnv = @[
    ("PLAYER_SCRIPTED", "forager"),
    ("PLAYER_POLICY_LABEL", "forager")
  ]

  test "native LLM player completes regular JSON + markdown fence round-trip":
    let dir = tmp / "complete"
    let codes = runRoundTrip(serverBin, playerBin, dir, "complete", llmEnv, "complete")
    check codes.serverCode == 0
    check codes.playerCode == 0
    check fileExists(dir / "results.json")
    check not fileExists(dir / "player_failure.json")
    check fileExists(dir / "trajectory.jsonl")
    let results = parseJson(readFile(dir / "results.json"))
    check results["reason"].getStr() == "complete"
    check results["policyKinds"][0].getStr() == "llm"
    check results["fallbackTurns"].getInt() == 0
    check results["llmTurns"].getInt() == 2
    let trajLines = readFile(dir / "trajectory.jsonl").strip().splitLines()
    let terminal = parseJson(trajLines[^1])
    check terminal["status"].getStr() == "completed"
    check terminal["participant_outcomes"]["0"]["score"] == results["scores"][0]

  test "invalid/ambiguous LLM reply terminates unscored with player_failure.json":
    let dir = tmp / "reject"
    let codes = runRoundTrip(serverBin, playerBin, dir, "reject", llmEnv, "reject")
    check codes.serverCode != 0
    check not fileExists(dir / "results.json")
    check fileExists(dir / "player_failure.json")
    check fileExists(dir / "trajectory.jsonl")
    let failure = parseJson(readFile(dir / "player_failure.json"))
    check failure.len == 3
    check failure["failed_policy_index"].getInt() == 0
    check failure["kind"].getStr() == "player_error"
    check "parse_error" in failure["message"].getStr()
    let trajLines = readFile(dir / "trajectory.jsonl").strip().splitLines()
    check trajLines.len == 2
    let dec = parseJson(trajLines[0])
    check dec["action_status"].getStr() == "rejected"
    check dec["executed_action"].kind == JNull
    check dec["attempts"].len == 1
    let terminal = parseJson(trajLines[^1])
    check terminal["status"].getStr() == "failed"
    check not terminal["outcome"].hasKey("scores")
    check not terminal["outcome"].hasKey("win")
    check not terminal["outcome"].hasKey("winner")
    check terminal["participant_outcomes"] == newJObject()

  test "provider 503 failure terminates unscored with episode_inconclusive player_failure.json":
    let dir = tmp / "provider_503"
    let codes = runRoundTrip(serverBin, playerBin, dir, "provider_503", llmEnv, "provider_503")
    check codes.serverCode != 0
    check not fileExists(dir / "results.json")
    check fileExists(dir / "player_failure.json")
    check fileExists(dir / "trajectory.jsonl")
    let failure = parseJson(readFile(dir / "player_failure.json"))
    check failure.len == 3
    check failure["failed_policy_index"].getInt() == 0
    check failure["kind"].getStr() == "episode_inconclusive"
    check "provider_error" in failure["message"].getStr()
    check "503" in failure["message"].getStr()
    let trajLines = readFile(dir / "trajectory.jsonl").strip().splitLines()
    check trajLines.len == 2
    let dec = parseJson(trajLines[0])
    check dec["action_status"].getStr() == "rejected"
    check dec["executed_action"].kind == JNull
    let terminal = parseJson(trajLines[^1])
    check terminal["status"].getStr() == "failed"
    check not terminal["outcome"].hasKey("scores")
    check not terminal["outcome"].hasKey("win")
    check not terminal["outcome"].hasKey("winner")
    check "provider_error" in terminal["outcome"]["stopDetail"].getStr()
    check terminal["participant_outcomes"] == newJObject()

  test "explicit scripted forager baseline completes offline round-trip":
    let dir = tmp / "forager"
    let codes = runRoundTrip(serverBin, playerBin, dir, "forager", foragerEnv, "")
    check codes.serverCode == 0
    check codes.playerCode == 0
    check fileExists(dir / "results.json")
    check not fileExists(dir / "player_failure.json")
    let results = parseJson(readFile(dir / "results.json"))
    check results["reason"].getStr() == "complete"
    check results["policyKinds"][0].getStr() == "scripted"
    check results["names"][0].getStr() == "forager"

  removeDir(tmp)
