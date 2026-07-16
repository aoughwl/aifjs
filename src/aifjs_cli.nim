## nifjs_cli — transpile a .s.nif file to JavaScript on stdout.
when defined(nimony):
  {.feature: "lenientnils".}
import std/[syncio, os]
import nifcursors, programs
import emitjs

proc main =
  var src = ""
  try:
    src = readFile(paramStr(1))
  except:
    write stderr, "aifjs: cannot read file\n"
    quit 1
  setupProgramForTesting("", "cli", ".s.nif")
  var buf = parseFromBuffer(src, "cli")
  var root = beginRead(buf)
  write stdout, emitModule(root)

main()
