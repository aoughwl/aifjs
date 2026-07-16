## emitjs.nim — the aifjs emitter: walk a typed `.s.nif` `Cursor` and append the
## equivalent JavaScript. This is `aifi`'s interpreter dispatch with every "run
## it" replaced by "print it", reusing aifi's front-end (nifcursors + the tag
## model + the literal pool).
##
## Built with the aifi build paths (see webtest_js.sh):
##   -p:nimony/src/{lib,nimony,models,gear2}  -p:aifi/src/nifi
##
## STATUS: the computational core compiles + transpiles end-to-end (procs,
## params/result, var/let/const, asgn, if/elif/else, while, ret, arithmetic &
## comparisons with calls, echo, int/string/char literals). The fuller coverage
## (seq/obj/tuple/set/case/generics/var-params/shims) is being ported from the
## JS reference impl (aoughwl/aifjs-js), which is already language-complete.

when defined(nimony):
  {.feature: "lenientnils".}

import std/[strutils, sets, tables]
import nifcursors, nifstreams, nimony_model
import tags

type
  JsEmitter = object
    js: string

## enum value (mangled) -> its ordinal, filled by scanEnums before emission.
## (parallel seqs, not a Table: nimony's Table `[]=` is `.raises`.)
var enumKeys: seq[string] = @[]
var enumVals: seq[string] = @[]
proc enumLookup(nm: string): string =
  for i in 0 ..< enumKeys.len:
    if enumKeys[i] == nm: return enumVals[i]
  return ""

proc emit(e: var JsEmitter; s: string) = e.js.add s

## a nimony symbol -> a stable, valid JS identifier.
proc mangle(name: string): string =
  result = "v_"
  for ch in name:
    if ch in {'A'..'Z', 'a'..'z', '0'..'9', '_'}: result.add ch
    else: result.add '_'

## bare callee/operator name — everything before the first `.<digit>`.
proc opName(name: string): string =
  var i = 0
  while i + 1 < name.len:
    if name[i] == '.' and name[i+1] in {'0'..'9'}: return name[0 ..< i]
    inc i
  result = name.strip(leading = false, chars = {'.'})

proc jsString(s: string): string =
  result = "\""
  for ch in s:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    of '\r': result.add "\\r"
    else: result.add ch
  result.add "\""

# forward decls (same shape as interp.nim)
proc emitStmt(e: var JsEmitter; n: var Cursor)
proc emitExpr(e: var JsEmitter; n: var Cursor)
proc exprToStr(n: var Cursor): string
proc emitCase(e: var JsEmitter; n: var Cursor; asExpr: bool)

## the JS operator for a binary-arithmetic/comparison tag, or "" if not one.
proc binOp(t: TagEnum): string =
  if t == AddTagId: " + "
  elif t == SubTagId: " - "
  elif t == MulTagId: " * "
  elif t == LtTagId: " < "
  elif t == LeTagId: " <= "
  elif t == EqTagId: " === "
  elif t == NeqTagId: " !== "
  else: ""

proc isCallTag(t: TagEnum): bool =
  t == CallTagId or t == CmdTagId or t == InfixTagId or t == PrefixTagId or t == HcallTagId

proc joinList(xs: seq[string]; sep: string): string =
  result = ""
  var first = true
  for x in xs:
    if not first: result.add sep
    first = false
    result.add x

proc emitStmts(e: var JsEmitter; n: var Cursor) =
  inc n
  while n.kind != ParRi: emitStmt(e, n)
  consumeParRi n

proc emitBinop(e: var JsEmitter; n: var Cursor; op: string) =
  ## (op TYPE a b) — skip the result-type child, emit (a op b).
  inc n
  skip n                          # the type node
  e.emit("(")
  emitExpr(e, n); e.emit(op); emitExpr(e, n)
  e.emit(")")
  consumeParRi n

proc emitCall(e: var JsEmitter; n: var Cursor) =
  ## (call CALLEE ARGS…) / (cmd …). echo -> write(stdout,X) -> __w(X); the common
  ## seq/string builtins map to native JS; everything else is a plain call.
  inc n
  let callee = if n.kind == Symbol or n.kind == SymbolDef: pool.syms[n.symId] else: ""
  let name = opName(callee)
  if name == "write":
    skip n; skip n                # callee, stdout
    e.emit("__w("); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "len":
    skip n; e.emit("("); emitExpr(e, n); e.emit(".length)")
    while n.kind != ParRi: skip n
  elif name == "[]":
    skip n; e.emit("("); emitExpr(e, n); e.emit("["); emitExpr(e, n); e.emit("])")
    while n.kind != ParRi: skip n
  elif name == "add":
    skip n; e.emit("("); emitExpr(e, n); e.emit(".push("); emitExpr(e, n); e.emit("))")
    while n.kind != ParRi: skip n
  elif name == "$":
    skip n; e.emit("String("); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "inc":
    skip n; e.emit("("); emitExpr(e, n)
    if n.kind != ParRi: (e.emit(" += "); emitExpr(e, n)) else: e.emit(" += 1")
    e.emit(")")
    while n.kind != ParRi: skip n
  elif name == "&":
    skip n; e.emit("("); emitExpr(e, n); e.emit(" + "); emitExpr(e, n); e.emit(")")
    while n.kind != ParRi: skip n
  else:
    e.emit(mangle(callee)); inc n
    e.emit("(")
    var first = true
    while n.kind != ParRi:
      if not first: e.emit(", ")
      first = false
      emitExpr(e, n)
    e.emit(")")
  consumeParRi n

proc emitCase(e: var JsEmitter; n: var Cursor; asExpr: bool) =
  ## (case SEL (of (ranges V…) BODY) … (else BODY)). Emitted as an if-chain over
  ## a once-bound selector; as an expression it's wrapped in an IIFE.
  inc n
  let sel = exprToStr(n)
  if asExpr: e.emit("(function(_s){ ")
  else: e.emit("{ const _s = " & sel & "; ")
  if asExpr: e.emit("")   # selector passed as arg below
  var first = true
  while n.kind != ParRi:
    if n.kind == ParLe and n.tagEnum == OfTagId:
      inc n
      # (ranges V0 V1 (range lo hi) …)
      e.emit(if first: "if(" else: " else if(")
      first = false
      if n.kind == ParLe and n.tagEnum == RangesTagId:
        inc n
        var f2 = true
        while n.kind != ParRi:
          if not f2: e.emit(" || ")
          f2 = false
          if n.kind == ParLe and n.tagEnum == RangeTagId:
            inc n
            e.emit("(_s >= " & exprToStr(n) & " && _s <= " & exprToStr(n) & ")")
            consumeParRi n
          else:
            e.emit("(_s === " & exprToStr(n) & ")")
        consumeParRi n
      e.emit("){ ")
      if asExpr: (e.emit("return "); emitExpr(e, n); e.emit("; }"))
      else: (emitStmt(e, n); e.emit(" }"))
      consumeParRi n
    elif n.kind == ParLe and n.tagEnum == ElseTagId:
      inc n
      e.emit(" else { ")
      if asExpr: (e.emit("return "); emitExpr(e, n); e.emit("; }"))
      else: (emitStmt(e, n); e.emit(" }"))
      consumeParRi n
    else:
      skip n
  if asExpr: e.emit(" })(" & sel & ")")
  else: e.emit(" }")
  consumeParRi n

proc emitExpr(e: var JsEmitter; n: var Cursor) =
  case n.kind
  of IntLit:  e.emit($pool.integers[n.intId]); inc n
  of UIntLit: e.emit($pool.uintegers[n.uintId]); inc n
  of FloatLit: e.emit($pool.floats[n.floatId]); inc n
  of CharLit: e.emit(jsString($n.charLit)); inc n
  of StringLit: e.emit(jsString(pool.strings[n.litId])); inc n
  of Symbol, SymbolDef, Ident:
    let nm = mangle(pool.syms[n.symId])
    let eo = enumLookup(nm)
    if eo.len > 0: e.emit(eo)                  # enum value -> its ordinal
    else: e.emit(nm)
    inc n
  of ParLe:
    let t = n.tagEnum
    let bop = binOp(t)
    if bop.len > 0: emitBinop(e, n, bop)
    elif t == DivTagId:
      inc n; skip n; e.emit("(Math.trunc("); emitExpr(e, n); e.emit(" / "); emitExpr(e, n); e.emit("))"); consumeParRi n
    elif t == ModTagId:
      inc n; skip n; e.emit("("); emitExpr(e, n); e.emit(" % "); emitExpr(e, n); e.emit(")"); consumeParRi n
    elif t == AndTagId:
      inc n; e.emit("("); emitExpr(e, n); e.emit(" && "); emitExpr(e, n); e.emit(")"); consumeParRi n
    elif t == OrTagId:
      inc n; e.emit("("); emitExpr(e, n); e.emit(" || "); emitExpr(e, n); e.emit(")"); consumeParRi n
    elif t == NotTagId:
      inc n; e.emit("(!"); emitExpr(e, n); e.emit(")"); consumeParRi n
    elif t == HderefTagId or t == HaddrTagId:
      inc n; emitExpr(e, n)
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == ConvTagId or t == HconvTagId:
      inc n; skip n; emitExpr(e, n)            # (conv TYPE VALUE) -> VALUE
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == SufTagId:
      inc n; emitExpr(e, n)                     # (suf VALUE TYPE) -> VALUE
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == AconstrTagId:
      inc n; skip n                             # (aconstr TYPE e0 e1 …) -> [e0,e1,…]
      e.emit("[")
      var first = true
      while n.kind != ParRi:
        if not first: e.emit(", ")
        first = false
        emitExpr(e, n)
      e.emit("]"); consumeParRi n
    elif t == PrefixTagId:
      inc n                                     # (prefix OP X) — @seq / $tostring
      let opsym = if n.kind == Symbol or n.kind == Ident: pool.syms[n.symId] else: ""
      let op = opName(opsym)
      inc n
      if op == "$": (e.emit("String("); emitExpr(e, n); e.emit(")"))
      else: emitExpr(e, n)                      # `@` on an array literal -> the array
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == AtTagId or t == ArratTagId:
      inc n; e.emit("("); emitExpr(e, n); e.emit("["); emitExpr(e, n); e.emit("])")
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == ExprTagId:
      inc n; emitExpr(e, n)                     # (expr VALUE) -> VALUE
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == OconstrTagId:
      inc n; skip n                             # (oconstr TYPE (kv f v) …) -> {f:v,…}
      e.emit("({")
      var first = true
      while n.kind != ParRi:
        if n.kind == ParLe and n.tagEnum == KvTagId:
          if not first: e.emit(", ")
          first = false
          inc n
          e.emit(mangle(pool.syms[n.symId]) & ": "); inc n
          emitExpr(e, n)
          while n.kind != ParRi: skip n
          consumeParRi n
        else: skip n
      e.emit("})"); consumeParRi n
    elif t == DotTagId:
      inc n; emitExpr(e, n)                     # (dot OBJ FIELD idx "name")
      e.emit("." & mangle(pool.syms[n.symId])); inc n
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == TupconstrTagId:
      inc n; skip n                             # (tupconstr TYPE v… | (kv f v)…) -> [v…]
      e.emit("[")
      var first = true
      while n.kind != ParRi:
        if not first: e.emit(", ")
        first = false
        if n.kind == ParLe and n.tagEnum == KvTagId:
          inc n; skip n; emitExpr(e, n)
          while n.kind != ParRi: skip n
          consumeParRi n
        else: emitExpr(e, n)
      e.emit("]"); consumeParRi n
    elif t == TupatTagId:
      inc n; e.emit("("); emitExpr(e, n); e.emit("["); emitExpr(e, n); e.emit("])")
      while n.kind != ParRi: skip n
      consumeParRi n
    elif t == CaseTagId:
      emitCase(e, n, true)
    elif isCallTag(t):
      emitCall(e, n)
    else:
      skip n; e.emit("undefined")   # TODO: sets/generics/var-params from aifjs-js
  else:
    inc n; e.emit("undefined")

proc collectParams(e: var JsEmitter; n: var Cursor): seq[string] =
  ## (params (param :x . . TYPE .) …) -> the mangled param names.
  result = @[]
  inc n
  while n.kind != ParRi:
    if n.kind == ParLe and n.tagEnum == ParamTagId:
      inc n
      result.add mangle(pool.syms[n.symId])   # the param's symbol def
      inc n
      while n.kind != ParRi: skip n
      consumeParRi n
    else:
      skip n
  consumeParRi n

proc emitProc(e: var JsEmitter; n: var Cursor) =
  ## (proc :name … (params …) RETTYPE … (stmts BODY))
  inc n
  let name = mangle(pool.syms[n.symId]); inc n
  var params: seq[string] = @[]
  while n.kind != ParRi:
    if n.kind == ParLe and n.tagEnum == ParamsTagId:
      params = collectParams(e, n)
    elif n.kind == ParLe and n.tagEnum == StmtsTagId:
      e.emit("function " & name & "(" & joinList(params, ", ") & "){\n")
      emitStmts(e, n)
      e.emit("\n}\n")
    else:
      skip n
  consumeParRi n

proc emitLocal(e: var JsEmitter; n: var Cursor) =
  ## (var/let/const/result NAME EXPORT PRAGMAS TYPE VALUE) — fixed positional
  ## shape (like interp's execLocal): after the name come export, pragmas, type,
  ## then the initializer (a `.` dot if none).
  inc n
  let nm = mangle(pool.syms[n.symId]); inc n
  skip n            # export marker
  skip n            # pragmas
  skip n            # type
  e.emit("let " & nm)
  if n.kind == ParRi or n.kind == DotToken:
    e.emit(" = 0")           # uninitialised — JS-safe default
    if n.kind == DotToken: inc n
  else:
    e.emit(" = "); emitExpr(e, n)
  e.emit(";")
  while n.kind != ParRi: skip n
  consumeParRi n

proc emitAsgn(e: var JsEmitter; n: var Cursor) =
  inc n
  emitExpr(e, n); e.emit(" = "); emitExpr(e, n); e.emit(";")
  consumeParRi n

proc emitIf(e: var JsEmitter; n: var Cursor) =
  inc n
  var first = true
  while n.kind != ParRi:
    if n.kind == ParLe and n.tagEnum == ElifTagId:
      inc n
      e.emit(if first: "if(" else: " else if(")
      emitExpr(e, n); e.emit("){\n"); emitStmt(e, n); e.emit("\n}")
      consumeParRi n; first = false
    elif n.kind == ParLe and n.tagEnum == ElseTagId:
      inc n
      e.emit(" else {\n"); emitStmt(e, n); e.emit("\n}")
      consumeParRi n
    else: skip n
  consumeParRi n

proc emitWhile(e: var JsEmitter; n: var Cursor) =
  inc n
  e.emit("while("); emitExpr(e, n); e.emit("){\n"); emitStmt(e, n); e.emit("\n}")
  consumeParRi n

proc emitRet(e: var JsEmitter; n: var Cursor) =
  inc n
  if n.kind == ParRi: e.emit("return;")
  else:
    e.emit("return "); emitExpr(e, n); e.emit(";")
  consumeParRi n

proc exprToStr(n: var Cursor): string =
  ## emit one expression into a fresh buffer (for building loop headers).
  var tmp = JsEmitter(js: "")
  emitExpr(tmp, n)
  result = tmp.js

proc collExpr(n: var Cursor): string =
  ## dig a for-iterable down to its collection: nimony lowers `for x in xs` to
  ## `items(toOpenArray(xs))` wrapped in hderef; unwrap to `xs`.
  if n.kind == ParLe:
    let t = n.tagEnum
    if t == HderefTagId or t == HaddrTagId:
      inc n
      result = collExpr(n)
      while n.kind != ParRi: skip n
      consumeParRi n
      return
    if t == CallTagId or t == HcallTagId:
      inc n
      let callee = if n.kind == Symbol or n.kind == SymbolDef: pool.syms[n.symId] else: ""
      let name = opName(callee)
      if name == "items" or name == "mitems" or name == "pairs" or name == "toOpenArray":
        inc n
        result = collExpr(n)
        while n.kind != ParRi: skip n
        consumeParRi n
        return
  result = exprToStr(n)

proc emitFor(e: var JsEmitter; n: var Cursor) =
  ## (for ITER (unpackflat (let :v …)) BODY) — range or collection.
  inc n
  var lo = "0"
  var hi = "0"
  var cmp = " < "
  var isRange = false
  var coll = ""
  if n.kind == ParLe and n.tagEnum == InfixTagId:
    inc n
    let opsym = if n.kind == Symbol or n.kind == Ident: pool.syms[n.symId] else: ""
    let op = opName(opsym)
    inc n
    lo = exprToStr(n)
    hi = exprToStr(n)
    consumeParRi n
    if op == "..<": (cmp = " < "; isRange = true)
    elif op == "..": (cmp = " <= "; isRange = true)
    else: coll = "[]"
  else:
    coll = collExpr(n)          # collection loop -> for..of
  # loop variable(s), from (unpackflat (let :v …) …)
  var v = "v__i"
  if n.kind == ParLe and n.tagEnum == UnpackflatTagId:
    inc n
    if n.kind == ParLe and n.tagEnum == LetTagId:
      inc n
      v = mangle(pool.syms[n.symId]); inc n
      while n.kind != ParRi: skip n
      consumeParRi n
    while n.kind != ParRi: skip n
    consumeParRi n
  else:
    skip n
  if isRange:
    e.emit("for(let " & v & " = " & lo & "; " & v & cmp & hi & "; " & v & "++){\n")
  else:
    e.emit("for(const " & v & " of " & coll & "){\n")
  emitStmt(e, n)
  e.emit("\n}")
  consumeParRi n

proc emitStmt(e: var JsEmitter; n: var Cursor) =
  if n.kind != ParLe:
    inc n
    return
  let t = n.tagEnum
  if t == StmtsTagId: emitStmts(e, n)
  elif t == VarTagId or t == LetTagId or t == ConstTagId or t == GvarTagId or
       t == GletTagId or t == ResultTagId: emitLocal(e, n)
  elif t == AsgnTagId: emitAsgn(e, n)
  elif t == IfTagId: emitIf(e, n)
  elif t == WhileTagId: emitWhile(e, n)
  elif t == RetTagId: emitRet(e, n)
  elif t == CaseTagId: emitCase(e, n, false)
  elif t == ForTagId: emitFor(e, n)
  elif t == BreakTagId: (e.emit("break;"); skip n)
  elif isCallTag(t): (emitCall(e, n); e.emit(";"))
  elif t == ProcTagId or t == FuncTagId: emitProc(e, n)
  else: skip n

proc scanEnums(n: var Cursor) =
  ## walk the tree; for (enum … (efld :val … (tup ORD "name"))) record val->ORD.
  if n.kind != ParLe:
    inc n
    return
  if n.tagEnum == EnumTagId:
    inc n
    while n.kind != ParRi:
      if n.kind == ParLe and n.tagEnum == EfldTagId:
        inc n
        let valName = mangle(pool.syms[n.symId]); inc n
        while n.kind != ParRi:
          if n.kind == ParLe and n.tagEnum == TupTagId:
            inc n
            if n.kind == IntLit: (enumKeys.add valName; enumVals.add $pool.integers[n.intId])
            while n.kind != ParRi: skip n
            consumeParRi n
          else: skip n
        consumeParRi n
      else: skip n
    consumeParRi n
  else:
    inc n
    while n.kind != ParRi: scanEnums(n)
    consumeParRi n

proc emitModule*(root: var Cursor): string =
  var scanCur = root
  scanEnums(scanCur)            # collect enum ordinals from a separate cursor
  var e = JsEmitter(js: "")
  e.emit("'use strict';\nlet __out='';\n")
  e.emit("function __w(x){ __out += (x===true?'true':x===false?'false':String(x)); }\n")
  # root is the module `(stmts …)`: procs float up (JS hoists function decls),
  # top-level runs at module scope, then we return the captured output.
  emitStmt(e, root)
  e.emit("\nreturn __out;\n")
  result = e.js
