## The decision layer: the per-turn loop that asks the seat what its cog does
## next, and ALWAYS has an answer.
##
## Cadence: one turn every <= `turnTicks` (24) ticks, at most 56 turns per
## episode. There is exactly ONE seat, so the starter's
## one-parallel-batch-per-turn machinery (`curly.makeRequests`) carries a
## batch of one and is otherwise untouched. THE PER-TURN LLM CALL BUDGET IS
## EXACTLY ONE REQUEST, PLUS AT MOST ONE RETRY — at most 112 provider calls
## per episode, and never more than one in flight.
##
## DEGRADE, NEVER HANG. Every wait here is bounded: attempt 1 gets
## `attempt1Ms`, the single retry gets `retryMs`, and the whole turn is
## wrapped in a monotonic `turnBudgetMs` deadline. A rolling 60 s request
## counter skips the call outright when the sidecar's per-episode cap is in
## reach. On a second failure the seat plays the `forager` scripted plan — the
## SAME PROC the `forager` baseline uses, imported, never duplicated — and a
## `fallback` record names the cause.

import
  std/[json, monotimes, options, os, strutils, times],
  bitworld/decision_trajectory,
  curly,
  sim, driver, directives, baselines, llm, prompts, training

const
  RateGuardWindowSeconds* = 60
  RateGuardMaxRequests* = 28
    ## The sidecar caps 30 requests/minute PER EPISODE. `turnSpacingMs` pins
    ## the steady state at 23 req/min, but a run of retrying turns issues two
    ## each; if issuing the next request would push the trailing-60 s count
    ## above this, the turn skips the call and takes the `forager` plan with
    ## cause `rate_guard`. Bounded, logged, never a sleep on the critical path.

type
  SeatPolicy* = object
    ## What the seat registered as. A seat that registers with neither field —
    ## or never registers at all — is `forager`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    trajectory*: DecisionTrajectory
    nativeAttempts*: seq[DecisionAttempt]
    selection*: PromptSelection
    client*: LlmClient
    seats*: seq[SeatPolicy]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool              ## the budget guard fired; scripted from here on
    requestTimes*: seq[MonoTime]
    records*: seq[string]      ## chat records queued for the replay writer

proc initDecisionEngine*(sim: SimServer, selection: PromptSelection): DecisionEngine =
  result.trajectory = initNativeTrajectory(sim.config)
  result.selection = selection
  result.client = newLlmClient(sim.config)
  result.seats = newSeq[SeatPolicy](sim.seatCount())
  for i in 0 ..< result.seats.len:
    result.seats[i].baseline = blForager
    result.seats[i].label = "forager"

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isLlm:
    "llm"
  else:
    "scripted"

# ---------------------------------------------------------------------------
#  Records
# ---------------------------------------------------------------------------

proc fallbackRecord*(turn, attempt: int, cause, detail: string): string =
  $(%*{
    "k": "fallback",
    "turn": turn,
    "attempt": attempt,
    "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc registerRecord*(slot: int, alias, policy, kind, baseline: string): string =
  ## The REDACTED registration record. The seat's prompt is NEVER written:
  ## only the policy label, the kind, and which baseline a scripted seat
  ## picked.
  $(%*{
    "k": "register",
    "slot": slot,
    "alias": alias,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc budgetGuardRecord*(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

proc stopRecord*(tick: int, rule: EndRule, detail: string): string =
  ## The load-bearing wall-clock/fault stop. A wall-clock fact cannot be
  ## re-derived from sim state, so it is written as ONE record applied by the
  ## SAME proc (`sim.applyStop`) on record and on playback.
  $(%*{"k": "stop", "tick": tick, "endRule": $rule,
       "detail": detail.truncateRunes(MaxStopDetailRunes)})

proc resultRecord*(sim: SimServer): string =
  ## The episode's whole results document, written once into the replay chat
  ## stream at episode end. It is what makes the replay SELF-SUFFICIENT. The
  ## document is already valid JSON, so it is embedded verbatim rather than
  ## re-parsed: nothing on the path to the artifact writes may raise.
  "{\"k\":\"result\",\"results\":" & sim.runResultsJson() & "}"

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

type
  TurnDecision* = object
    ok*: bool
    directive*: Directive
    failureCause*: string
    failureDetail*: string
    records*: seq[string]

proc rateGuardBlocked(engine: var DecisionEngine): bool =
  let now = getMonoTime()
  var kept: seq[MonoTime]
  for stamp in engine.requestTimes:
    if (now - stamp).inSeconds.int < RateGuardWindowSeconds:
      kept.add(stamp)
  engine.requestTimes = kept
  engine.requestTimes.len >= RateGuardMaxRequests

proc noteRequest*(engine: var DecisionEngine) =
  engine.requestTimes.add(getMonoTime())

proc isPlayerDefect*(cause: string): bool =
  ## Distinguishes model-generated invalid/unparseable replies from
  ## infrastructure/provider/budget failures.
  cause == "parse_error"

proc turn*(engine: var DecisionEngine, sim: var SimServer, turnIndex,
           elapsedSeconds: int): TurnDecision =
  ## Runs ONE decision turn for the single seat and returns its plan plus the
  ## replay chat records the turn produced. Never inserts a fallback move when
  ## an LLM seat fails; returns `ok = false` with `failureCause` and
  ## `failureDetail` so the server can record evidence and terminate cleanly.
  let
    seat = 0
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
    turnStart = getMonoTime()
  engine.nativeAttempts.setLen(0)
  ## Throttle state is PER TURN: a 429 on turn k says nothing about turn k+1.
  engine.client.throttled = false

  # --- budget guard: fail cleanly rather than overrun or substitute --------
  if not engine.llmOff:
    let turnSeconds = (sim.config.turnBudgetMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.records.add(budgetGuardRecord(turnIndex,
        max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "crafter: budget guard fired at turn ", turnIndex,
        "; wall-clock budget exhausted for LLM turns"

  # --- a scripted seat computes locally, instantly, and consumes no request -
  if not engine.seats[seat].isLlm:
    result.ok = true
    result.directive = scriptedPlan(sim, engine.seats[seat].baseline)
    return

  var blockedCause = ""
  if engine.client.disabled or engine.client.transport == ltNone:
    blockedCause = "no_credentials"
  elif engine.llmOff:
    blockedCause = "budget_guard"
  elif engine.rateGuardBlocked():
    blockedCause = "rate_guard"
  if blockedCause.len > 0:
    result.ok = false
    result.failureCause = blockedCause
    result.failureDetail = "LLM unavailable for this turn (" & blockedCause & ")"
    result.records.add(fallbackRecord(turnIndex, 1, blockedCause,
      result.failureDetail))
    echo "crafter llm: seat ", seat, " failed (", blockedCause,
      ") on turn ", turnIndex
    return

  # --- the rate floor ------------------------------------------------------
  if engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  engine.lastBatchStart = getMonoTime()
  engine.batchStarted = true

  let observation = sim.observationJson(includeNotes = true)
  var attempt = 0
  var open = true
  var lastCause = ""
  var lastDetail = ""
  while open and attempt < 2:
    if engine.client.disabled:
      break
    let remainingMs = (budget - (getMonoTime() - turnStart)).inMilliseconds.int
    if remainingMs <= 0:
      lastCause = "timeout"
      lastDetail = "per-turn budget exhausted before attempt " & $(attempt + 1)
      result.records.add(fallbackRecord(turnIndex, attempt + 1, "timeout",
        lastDetail))
      break
    ## turnBudgetMs is a monotonic deadline around the WHOLE turn, the
    ## turnSpacingMs rate floor included, so an attempt is given the SMALLER of
    ## its configured deadline and the time the turn has left.
    let deadlineMs = min(
      (if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs),
      remainingMs)
    var user = $observation
    if attempt > 0:
      user.add("\n\nYour previous reply was rejected (" &
        lastDetail.truncateRunes(120) &
        "). Reply with ONLY one valid JSON object containing an \"actions\" array.")
    let request = engine.client.requestFor(
      systemPrompt(engine.selection), userMessage(engine.seats[seat].prompt, user), seat)
    ## ONE seat, so this is a batch of ONE through the starter's unchanged
    ## batching path. Never a sequential per-cog loop.
    var batch: RequestBatch
    batch.post(request.url, request.headers, request.body, $seat)
    let started = getMonoTime()
    engine.noteRequest()
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var evidence: DecisionAttempt
    if not engine.trajectory.isNil:
      evidence = nativeAttempt(engine.seats[seat].label, turnIndex,
        attempt, request.body)
    try:
      if not engine.trajectory.isNil:
        evidence.receiveNativeResponse(responses[0].response,
          responses[0].error, latency)
      let text = engine.client.textOf(
        responses[0].response, responses[0].error, batch[0].url)
      var directive = parseDirective(
        extractJsonObject(text), sim.config.maxActionsPerTurn)
      directive.source = dsLlm
      directive.latencyMs = latency
      if not engine.trajectory.isNil:
        evidence.parsedAction = directive.directiveAction()
        evidence.accepted = true
      result.ok = true
      result.directive = directive
      open = false
    except DirectiveError as error:
      if not engine.trajectory.isNil:
        evidence.rejectionReason = some(error.msg)
      lastCause = "parse_error"
      lastDetail = error.msg
      result.records.add(
        fallbackRecord(turnIndex, attempt + 1, lastCause, error.msg))
      if attempt == 0:
        echo "crafter llm: seat ", seat, " attempt 1 failed, will retry: ",
          error.msg
      else:
        echo "crafter llm: seat ", seat, " attempt 2 failed: ", error.msg
    except CatchableError as error:
      if not engine.trajectory.isNil:
        evidence.rejectionReason = some(error.msg)
      let cause =
        if responses[0].error.len > 0:
          if "timeout" in responses[0].error.toLowerAscii():
            "timeout" else: "transport_error"
        elif error.msg.startsWith("llm throttled"):
          "throttled"
        elif error.msg.startsWith("llm auth failed"):
          "auth_error"
        else:
          "provider_error"
      lastCause = cause
      lastDetail = error.msg
      result.records.add(
        fallbackRecord(turnIndex, attempt + 1, cause, error.msg))
      if attempt == 0:
        echo "crafter llm: seat ", seat, " attempt 1 failed, will retry: ",
          error.msg
      else:
        echo "crafter llm: seat ", seat, " attempt 2 failed: ", error.msg
    if not engine.trajectory.isNil:
      engine.nativeAttempts.add(evidence)
    inc attempt
    if engine.client.throttled and open:
      echo "crafter llm: provider throttled on turn ", turnIndex
      break

  if open:
    result.ok = false
    let cause =
      if lastCause.len > 0: lastCause
      elif engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif engine.client.throttled: "throttled"
      else: "provider_error"
    result.failureCause = cause
    result.failureDetail =
      if lastDetail.len > 0: lastDetail else: "no usable reply"
    echo "crafter llm: seat ", seat, " rejected (", cause,
      ") on turn ", turnIndex, ": ", result.failureDetail

proc applyDirective*(sim: var SimServer, directive: Directive,
                     view: JsonNode): string =
  ## Turn steps 5 and 6: expand the plan against the known map as of turn
  ## start, truncate it to `turnTicks`, install it, and return the replay
  ## `directive` record.
  let expansion = expandPlan(sim.knownMap, sim.cog.x, sim.cog.y,
    directive.actions, sim.config.macroPrimitiveCap, sim.config.turnTicks,
    sim.hostileCells())
  ## An entry that fails validation is counted ONCE, in `repliesRepaired`;
  ## `actionsDropped` counts the entries past `maxActionsPerTurn` and nothing
  ## else (design note §Turn structure 6a/6b). The same number rides the
  ## `directive` record's `dropped` slot, which is what playback feeds back
  ## into `installPlan`, so the two counters agree live and in replay.
  sim.repliesRepaired += directive.dropped
  sim.notes = directive.notes
  let turn = sim.turnsPlayed + 1
  let interrupted = sim.lastInterrupted
  sim.installPlan(expansion.primitives, expansion.truncated,
    directive.overCap, expansion.unreachable)
  case directive.source
  of dsLlm: inc sim.llmTurns
  of dsFallback: inc sim.fallbackTurns
  else: discard
  if directive.say.len > 0:
    sim.pending.add(SimEvent(kind: evSay, tick: sim.tickCount,
      a: directive.say))
  boundedDirectiveRecord(directive, turn, sim.tickCount, 0, seatAlias(0),
    expansion.primitives, expansion.truncated,
    directive.overCap, expansion.unreachable, interrupted, view)

proc applyRecordedDirective*(sim: var SimServer, record: JsonNode) {.used.} =
  ## PLAYBACK. The `directive` record's `executed` array IS this game's input
  ## log: it installs the identical primitive queue, so re-simulation is
  ## exact. Everything else in the record is non-hashed feed state.
  let primitives = parseRecordedActions(record{"executed"})
  sim.notes = ""
  sim.installPlan(primitives, record{"truncated"}.getBool(),
    record{"dropped"}.getInt(), record{"unreachable"}.getInt())
  case record{"source"}.getStr()
  of "llm": inc sim.llmTurns
  of "fallback": inc sim.fallbackTurns
  else: discard
  let say = record{"say"}.getStr()
  if say.len > 0:
    sim.pending.add(SimEvent(kind: evSay, tick: sim.tickCount, a: say))
