## The reply schema: what a policy (LLM or scripted) may say, and strict
## validation of a single JSON reply object.
##
## Both policy kinds emit the SAME object through the SAME validator, which is
## what makes the bounded-orders test in `tests/test_crafter_driver.nim`
## meaningful.
##
## INVALID REPLIES ARE REJECTED, NEVER REWRITTEN OR SILENTLY REPAIRED.
##
## RUNE DISCIPLINE. Every cap in this file is measured in RUNES and every
## truncation lands on a rune boundary. Slicing a string by BYTE index
## anywhere on the path to the replay is forbidden: a byte-truncated
## multi-byte character renders fine in a browser and then fails a strict
## UTF-8 parser.

import std/[json, strutils, unicode]
import sim_types, driver

type
  DirectiveSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  Directive* = object
    ## One seat's whole plan for one turn.
    actions*: seq[Action]
    say*: string               ## <= MaxSayRunes, sanitised on rune boundaries
    notes*: string             ## <= MaxNoteRunes, echoed to this seat only
    source*: DirectiveSource
    latencyMs*: int
    dropped*: int              ## entries that did not validate
    overCap*: int              ## entries past maxActionsPerTurn

  DirectiveError* = object of ValueError

proc unwrapSingleCodeFence(text: string): string =
  ## Unwraps at most ONE ordinary outer Markdown code fence (plain ``` or
  ## JSON-tagged ```json, case-insensitive). Rejects unclosed fences,
  ## non-JSON language tags, or surrounding prose outside the fence.
  let trimmed = text.strip()
  if not trimmed.startsWith("```"):
    return trimmed
  let firstNewline = trimmed.find('\n')
  if firstNewline < 0:
    raise newException(DirectiveError, "unclosed markdown code fence")
  let tag = trimmed[3 ..< firstNewline].strip().toLowerAscii()
  if tag.len > 0 and tag != "json":
    raise newException(DirectiveError, "unsupported markdown code fence: " & tag)
  let body = trimmed[firstNewline + 1 .. ^1]
  let closeIdx = body.rfind("```")
  if closeIdx < 0:
    raise newException(DirectiveError, "unclosed markdown code fence")
  if body[closeIdx + 3 .. ^1].strip().len > 0:
    raise newException(DirectiveError, "unexpected text after markdown code fence")
  let lineStart =
    if closeIdx == 0: -1
    else: body.rfind('\n', last = closeIdx - 1)
  let beforeClose =
    if closeIdx == 0: ""
    elif lineStart < 0: body[0 ..< closeIdx]
    else: body[lineStart + 1 ..< closeIdx]
  if beforeClose.strip(chars = {' ', '\t', '\r'}).len > 0:
    raise newException(DirectiveError,
      "closing markdown code fence must be on its own line")
  body[0 ..< closeIdx].strip()

proc extractJsonObject*(text: string): JsonNode =
  ## Extracts exactly one JSON object from a model reply, either bare or inside
  ## a single ordinary outer Markdown code fence (JSON-tagged or plain).
  ## Rejects surrounding prose, extra objects, and non-object JSON values.
  let inner = unwrapSingleCodeFence(text)
  if inner.len == 0:
    raise newException(DirectiveError, "empty reply")
  try:
    result = parseJson(inner)
  except CatchableError as error:
    raise newException(DirectiveError, "invalid JSON reply: " & error.msg)
  if result.kind != JObject:
    raise newException(DirectiveError, "reply is not a JSON object")

proc parseDirective*(payload: JsonNode): Directive =
  ## Strictly turns one parsed reply object into a legal plan. Raises
  ## DirectiveError on any schema violation, unknown verb, legacy alias,
  ## out-of-range field, or over-cap action list. Genuine optional fields
  ## (`say`, `notes`, and `n` on repeatable actions) keep their defaults.
  if payload.isNil or payload.kind != JObject:
    raise newException(DirectiveError, "reply is not a JSON object")
  result.source = dsLlm
  if payload.hasKey("say") and payload["say"].kind != JNull:
    if payload["say"].kind != JString:
      raise newException(DirectiveError, "field \"say\" must be a string")
    result.say = sanitizeSay(payload["say"].getStr())
  if payload.hasKey("notes") and payload["notes"].kind != JNull:
    if payload["notes"].kind != JString:
      raise newException(DirectiveError, "field \"notes\" must be a string")
    result.notes = sanitizeNote(payload["notes"].getStr())
  if not payload.hasKey("actions") or payload["actions"].kind != JArray:
    raise newException(DirectiveError,
      "reply must include an \"actions\" array")
  let entries = payload["actions"]
  for i in 0 ..< entries.len:
    let entry = entries[i]
    if entry.kind != JObject:
      raise newException(DirectiveError,
        "actions[" & $i & "] must be a JSON object")
    if not entry.hasKey("act") or entry["act"].kind != JString:
      raise newException(DirectiveError,
        "actions[" & $i & "] must include string field \"act\"")
    let actName = entry["act"].getStr()
    let parsed = parseActionKind(actName)
    if not parsed.ok:
      raise newException(DirectiveError,
        "actions[" & $i & "] unknown action: " & actName.truncateRunes(32))
    var action = Action(kind: parsed.kind, n: 1)
    case parsed.kind
    of akGoto:
      if not entry.hasKey("x") or entry["x"].kind != JInt or
          not entry.hasKey("y") or entry["y"].kind != JInt:
        raise newException(DirectiveError,
          "actions[" & $i & "] goto requires integer \"x\" and \"y\"")
      let
        gx = entry["x"].getBiggestInt()
        gy = entry["y"].getBiggestInt()
      if gx < 0 or gx >= WorldSize or gy < 0 or gy >= WorldSize:
        raise newException(DirectiveError,
          "actions[" & $i & "] goto coordinates out of bounds: (" &
          $gx & "," & $gy & ")")
      action.x = int(gx)
      action.y = int(gy)
    of akMove:
      if not entry.hasKey("dir") or entry["dir"].kind != JString:
        raise newException(DirectiveError,
          "actions[" & $i & "] move requires string \"dir\"")
      let dirName = entry["dir"].getStr()
      let dir = parseFacing(dirName)
      if not dir.ok:
        raise newException(DirectiveError,
          "actions[" & $i & "] invalid move dir: " & dirName.truncateRunes(16))
      action.dir = dir.dir
    else: discard
    let repeat = repeatable(parsed.kind)
    if entry.hasKey("n") and entry["n"].kind != JNull:
      if not repeat.ok:
        raise newException(DirectiveError,
          "actions[" & $i & "] action \"" & $parsed.kind &
          "\" does not accept \"n\"")
      if entry["n"].kind != JInt:
        raise newException(DirectiveError,
          "actions[" & $i & "] \"n\" must be an integer")
      let count = entry["n"].getBiggestInt()
      if count < 1 or count > repeat.limit:
        raise newException(DirectiveError,
          "actions[" & $i & "] \"n\" out of range 1.." & $repeat.limit &
          ": " & $count)
      action.n = int(count)
    result.actions.add(action)

proc actionsJson*(actions: seq[Action]): JsonNode =
  result = newJArray()
  for action in actions:
    var item = %*{"act": $action.kind}
    case action.kind
    of akGoto:
      item["x"] = %action.x
      item["y"] = %action.y
    of akMove:
      item["dir"] = %($action.dir)
      item["n"] = %action.n
    else:
      if repeatable(action.kind).ok:
        item["n"] = %action.n
    result.add(item)

proc primitivesJson*(primitives: seq[Primitive]): JsonNode =
  result = newJArray()
  for primitive in primitives:
    result.add(%($primitive))

proc directiveRecord*(directive: Directive, turn, tick, slot: int,
                      alias: string, executed: seq[Primitive],
                      truncated: bool, dropped, unreachable: int,
                      interrupted: string, view: JsonNode): JsonNode =
  ## The replay chat record for one turn. Re-applied at playback to install
  ## the SAME primitive queue and to drive the broadcast feed and
  ## `tools/replay_summary.py`.
  %*{
    "k": "directive",
    "turn": turn,
    "tick": tick,
    "slot": slot,
    "alias": alias,
    "source": $directive.source,
    "latency_ms": directive.latencyMs,
    "actions": actionsJson(directive.actions),
    "executed": primitivesJson(executed),
    "truncated": truncated,
    "dropped": dropped,
    "unreachable": unreachable,
    "interrupted": interrupted,
    "say": directive.say,
    "view": (if view.isNil: newJNull() else: view)
  }

proc boundedDirectiveRecord*(directive: Directive, turn, tick, slot: int,
                             alias: string, executed: seq[Primitive],
                             truncated: bool, dropped, unreachable: int,
                             interrupted: string, view: JsonNode): string =
  ## The serialized record, guaranteed <= MaxDirectiveRunes. `say` is the only
  ## unbounded-in-practice field, so it is what shrinks, and the cut still
  ## lands on a RUNE boundary. NEVER cut the SERIALIZED string — that would
  ## emit broken JSON, which is the exact failure the rune rule exists to
  ## prevent.
  ##
  ## `view` IS THE LAST THING TO GO, not the first: the note's whole reason for
  ## mirroring the observation into the record is that "the replay explains
  ## every decision", and a record with `"view": null` explains nothing. The
  ## cap is sized so a whole observation plus a full-cap `say` fits, so this
  ## shrinks `say` to nothing before it will drop the view at all.
  var trimmed = directive
  result = $trimmed.directiveRecord(turn, tick, slot, alias, executed,
    truncated, dropped, unreachable, interrupted, view)
  if result.runeLen <= MaxDirectiveRunes:
    return
  var guard = 0
  while result.runeLen > MaxDirectiveRunes and trimmed.say.len > 0 and
      guard < 12:
    inc guard
    trimmed.say = trimmed.say.truncateRunes(
      max(0, trimmed.say.runeLen - max(8, trimmed.say.runeLen div 2)))
    result = $trimmed.directiveRecord(turn, tick, slot, alias, executed,
      truncated, dropped, unreachable, interrupted, view)
  if result.runeLen <= MaxDirectiveRunes:
    return
  ## Only now: an observation so large that the record cannot hold it even
  ## with no `say` at all.
  result = $trimmed.directiveRecord(turn, tick, slot, alias, executed,
    truncated, dropped, unreachable, interrupted, nil)

proc parseRecordedActions*(node: JsonNode): seq[Primitive] =
  ## Playback: the `executed` array of a `directive` record, back into the
  ## primitive queue. This game's ENTIRE input log.
  if node.isNil or node.kind != JArray:
    return @[]
  for item in node:
    if item.kind != JString:
      continue
    let parsed = parsePrimitive(item.getStr())
    if parsed.ok:
      result.add(parsed.primitive)
