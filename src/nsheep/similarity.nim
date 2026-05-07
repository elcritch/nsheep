##
## Self-contained MinHash similarity utilities.
## No dependency on the minhash nimble package.
##

import std/[tables, sets, sequtils, algorithm]
import ./[storage, types]

type
  SimilarEntry* = tuple[name: string, jaccard: float]

proc jaccardEstimate*(a, b: openArray[uint32]): float =
  ## Set-based Jaccard estimate matching the original minhash library behavior.
  ## Treats each fingerprint as a set of hash values (duplicates are deduplicated).
  if a.len == 0 or b.len == 0:
    return 0.0
  var sa = initHashSet[uint32]()
  for x in a:
    sa.incl(x)
  var sb = initHashSet[uint32]()
  for x in b:
    sb.incl(x)
  var inter = 0
  for x in sa:
    if x in sb:
      inc inter
  let uni = sa.len + sb.len - inter
  if uni == 0:
    return 0.0
  result = inter.float / uni.float

type
  LSHBucket* = TableRef[seq[uint32], HashSet[string]]

proc buildLSH*(hashes: seq[VersionHash], numBands, bandWidth: int): seq[LSHBucket] =
  ## Build LSH buckets from pre-computed MinHash fingerprints.
  ## Each fingerprint is split into `numBands` bands of `bandWidth` hashes.
  result = newSeq[LSHBucket](numBands)
  for i in 0..<numBands:
    result[i] = newTable[seq[uint32], HashSet[string]]()

  for h in hashes:
    if h.hash.len == 0:
      continue
    for b in 0..<numBands:
      let start = b * bandWidth
      var band = newSeq[uint32](bandWidth)
      for i in 0..<bandWidth:
        band[i] = h.hash[start + i]
      if result[b].hasKey(band):
        result[b][band].incl(h.pkgName)
      else:
        result[b][band] = toHashSet([h.pkgName])

proc lshCandidates*(lsh: seq[LSHBucket]): HashSet[tuple[a, b: string]] =
  ## Extract candidate similar pairs from LSH buckets.
  ## Any two documents sharing at least one band bucket are considered candidates.
  for band in lsh:
    for bucket in band.values:
      if bucket.len < 2:
        continue
      let items = toSeq(bucket.items)
      for i in 0..<items.len:
        for j in (i + 1)..<items.len:
          let x = items[i]
          let y = items[j]
          if x < y:
            result.incl((x, y))
          else:
            result.incl((y, x))

proc findSimilarPackages*(store: DbStorage, targetName: string, threshold: float = 0.35, maxResults: int = 20): seq[SimilarEntry] =
  ## Find similar packages to the target package on-demand.
  ## Loads all hashes from DB and computes Jaccard similarities dynamically.
  let allHashes = getVersionHashes(store)
  if allHashes.len < 2:
    return @[]

  var targetSet: HashSet[uint32]
  var sets = newTable[string, HashSet[uint32]]()
  var foundTarget = false

  for h in allHashes:
    if h.hash.len == 0:
      continue
    var s = initHashSet[uint32]()
    for x in h.hash:
      s.incl(x)
    sets[h.pkgName] = s
    if h.pkgName == targetName:
      targetSet = s
      foundTarget = true

  if not foundTarget:
    return @[]

  var results: seq[SimilarEntry] = @[]
  for pkgName, s in sets:
    if pkgName == targetName:
      continue
    var inter = 0
    for x in targetSet:
      if x in s:
        inc inter
    let uni = targetSet.len + s.len - inter
    if uni == 0:
      continue
    let j = inter.float / uni.float
    if j >= threshold:
      results.add((name: pkgName, jaccard: j))

  algorithm.sort(results, proc(x, y: SimilarEntry): int =
    if x.jaccard > y.jaccard: -1
    elif x.jaccard < y.jaccard: 1
    else: 0
  )

  if results.len > maxResults:
    results.setLen(maxResults)
  return results
