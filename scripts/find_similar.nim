# Find similar Nim packages using pre-computed MinHash + LSH
# Reads version_hashes from SQLite, builds LSH index, finds duplicates.
#
# Usage:
#   nim c scripts/find_similar.nim
#   ./scripts/find_similar
#
# Output: JSON array of { "a": pkg1, "b": pkg2, "jaccard": 0.85 }

import std/[strutils, sequtils, tables, sets, os, json, algorithm]
import tiny_sqlite
import nsheep/[storage, similarity]

const
  DbPath = "data/nsheep.db"
  NumSeeds = 128
  NumBands = 16
  BandWidth = NumSeeds div NumBands
  MinJaccard = 0.35

type
  SimPair = object
    a: string
    b: string
    jaccard: float

proc main() =
  if not fileExists(DbPath):
    echo "Database not found: ", DbPath
    quit(1)

  let db = openDatabase(DbPath)
  defer: db.close()

  let store = openStorage(DbPath, "data/tarballs")
  defer: store.close()

  let hashes = getVersionHashes(store)
  echo "Loaded ", hashes.len, " version hashes"

  if hashes.len < 2:
    echo "Not enough hashes to compare"
    return

  let lsh = buildLSH(hashes, NumBands, BandWidth)
  let candidates = lshCandidates(lsh)
  echo "LSH candidates: ", candidates.len

  var pairs: seq[SimPair]
  for pair in candidates:
    let fpA = hashes.filterIt(it.pkgName == pair.a)[0].hash
    let fpB = hashes.filterIt(it.pkgName == pair.b)[0].hash
    let j = jaccardEstimate(fpA, fpB)
    if j >= MinJaccard:
      pairs.add(SimPair(a: pair.a, b: pair.b, jaccard: j))

  # Sort by similarity descending
  pairs.sort(proc(x, y: SimPair): int =
    if x.jaccard > y.jaccard: -1
    elif x.jaccard < y.jaccard: 1
    else: 0
  )

  # Output JSON
  var jsonPairs: seq[JsonNode]
  for p in pairs:
    jsonPairs.add(%*{
      "a": p.a,
      "b": p.b,
      "jaccard": p.jaccard
    })

  let output = %jsonPairs
  echo output.pretty()

when isMainModule:
  main()
