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
import minhash
import nsheep/storage

const
  DbPath = "data/nsheep.db"
  NumSeeds = 128
  NumBands = 16
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

  # Build LSH from pre-computed hashes
  # Dummy hasher: num_seeds must match stored hashes, tokenizer is unused
  var dummyHasher = initMinHasher[uint32](NumSeeds, proc(s: string): seq[string] = @[])
  var lsh = initLocalitySensitive(dummyHasher, num_bands = NumBands)

  for h in hashes:
    lsh.add(h.hash, h.pkgName)

  let dupes = lsh.getDuplicates(min_jaccard = MinJaccard)

  var pairs: seq[SimPair]
  for p in dupes:
    let (a, b) = if p.a < p.b: (p.a, p.b) else: (p.b, p.a)
    # Compute exact Jaccard on the stored fingerprints
    let fpA = hashes.filterIt(it.pkgName == a)[0].hash
    let fpB = hashes.filterIt(it.pkgName == b)[0].hash
    let j = dummyHasher.jaccard(fpA, fpB)
    if j >= MinJaccard:
      pairs.add(SimPair(a: a, b: b, jaccard: j))

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
