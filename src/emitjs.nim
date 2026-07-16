## emitjs.nim — the nifjs emitter: walk a typed `.s.nif` `Cursor` and append the
## equivalent JavaScript. This is `nifi`'s interpreter dispatch with every "run
## it" replaced by "print it", reusing nifi's front-end (nifcursors + the tag
## model + the literal pool).
##
## Built with the nifi build paths (see webtest_js.sh):
##   -p:nimony/src/{lib,nimony,models,gear2}  -p:nifi/src/nifi
##
## STATUS: the computational core compiles + transpiles end-to-end (procs,
## params/result, var/let/const, asgn, if/elif/else, while, ret, arithmetic &
## comparisons with calls, echo, int/string/char literals). The fuller coverage
## (seq/obj/tuple/set/case/generics/var-params/shims) is being ported from the
## JS reference impl (aoughwl/nifjs-js), which is already language-complete.

when defined(nimony):
  {.feature: "lenientnils".}

import std/[strutils, sets, tables]
import nifcursors, nifstreams, nimony_model
import tags

type
  JsEmitter = object
    js: string

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
  ## (call CALLEE ARGS…) / (cmd …). echo has been lowered to write(stdout, X):
  ## intercept `write.*` -> __w(X).
  inc n
  let callee = if n.kind in {Symbol, SymbolDef}: pool.syms[n.symId] else: ""
  let name = opName(callee)
  if name == "write":
    # args: stdout, value  -> __w(value)
    skip n                        # the callee
    skip n                        # stdout
    e.emit("__w("); emitExpr(e, n); e.emit(")")
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

proc emitExpr(e: var JsEmitter; n: var Cursor) =
  case n.kind
  of IntLit:  e.emit($pool.integers[n.intId]); inc n
  of UIntLit: e.emit($pool.uintegers[n.uintId]); inc n
  of FloatLit: e.emit($pool.floats[n.floatId]); inc n
  of CharLit: e.emit(jsString($n.charLit)); inc n
  of StringLit: e.emit(jsString(pool.strings[n.litId])); inc n
  of Symbol, SymbolDef, Ident: e.emit(mangle(pool.syms[n.symId])); inc n
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
    elif isCallTag(t):
      emitCall(e, n)
    else:
      skip n; e.emit("undefined")   # TODO: seq/obj/tuple/case/set/… from nifjs-js
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
  elif t == BreakTagId: (e.emit("break;"); skip n)
  elif isCallTag(t): (emitCall(e, n); e.emit(";"))
  elif t == ProcTagId or t == FuncTagId: emitProc(e, n)
  else: skip n

proc emitModule*(root: var Cursor): string =
  var e = JsEmitter(js: "")
  e.emit("'use strict';\nlet __out='';\n")
  e.emit("function __w(x){ __out += (x===true?'true':x===false?'false':String(x)); }\n")
  # root is the module `(stmts …)`: procs float up (JS hoists function decls),
  # top-level runs at module scope, then we return the captured output.
  emitStmt(e, root)
  e.emit("\nreturn __out;\n")
  result = e.js
