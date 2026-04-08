##
## Main entry point - strict, fail-fast
##

import std/os
import nsheep/config, nsheep/server

proc main() =
  ## NSheep package registry
  
  if paramCount() < 1:
    stderr.writeLine("usage: nsheep <config.json>")
    quit(1)
  
  let configPath = paramStr(1)
  if not fileExists(configPath):
    stderr.writeLine("config file not found: ", configPath)
    quit(1)
  
  let cfg = try:
    loadConfig(configPath)
  except CatchableError as e:
    stderr.writeLine("failed to load config: ", e.msg)
    quit(1)
  
  try:
    runServer(cfg)
  except CatchableError as e:
    stderr.writeLine("server error: ", e.msg)
    quit(1)

main()
