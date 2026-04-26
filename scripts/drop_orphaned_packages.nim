##
## Drop packages from the local DB that are no longer in nimble packages.json
##

import std/[json, os, sets, strutils]
import nsheep/[storage, config, vcs]
import tiny_sqlite
import puppy

const NimblePackagesUrl = "https://raw.githubusercontent.com/nim-lang/packages/master/packages.json"

proc fetchCanonicalNames(): HashSet[string] =
  ## Fetch packages.json and extract all canonical package names
  echo "Fetching packages.json..."
  let response = get(NimblePackagesUrl)
  if response.code != 200:
    raise newException(IOError, "failed to fetch packages.json: HTTP " & $response.code)

  let json = parseJson(response.body)
  if json.kind != JArray:
    raise newException(ValueError, "packages.json is not an array")

  result = initHashSet[string]()
  for pkg in json:
    try:
      if pkg.hasKey("alias"):
        continue
      let name = pkg["name"].getStr().strip()
      if name.len > 0:
        result.incl(name)
    except:
      continue

  echo "Found ", result.len, " packages in packages.json"

proc main() =
  if paramCount() < 1:
    stderr.writeLine("usage: nim c -r scripts/drop_orphaned_packages.nim <cfg.yaml>")
    quit(1)

  let configPath = paramStr(1)
  if not fileExists(configPath):
    stderr.writeLine("config file not found: ", configPath)
    quit(1)

  let cfg = loadConfig(configPath)

  var store = initStorage(cfg.local.dbPath, cfg.local.tarballDir)

  let canonicalNames = fetchCanonicalNames()

  # Query all packages in DB
  let dbPackages = listPackages(store)
  echo "Found ", dbPackages.len, " packages in DB"

  var dropCount = 0
  for pkgName in dbPackages:
    let name = string(pkgName)
    if name notin canonicalNames:
      echo "Dropping orphaned package: ", name
      store.db.exec("DELETE FROM packages WHERE name = ?", name)
      dropCount.inc

  echo "Dropped ", dropCount, " orphaned packages"
  echo "Remaining: ", dbPackages.len - dropCount, " packages"

main()
