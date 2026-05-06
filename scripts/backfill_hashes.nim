# Backfill version_hashes for existing head versions
# Run on VPS to populate pre-computed MinHash signatures
#
# Usage:
#   nim c scripts/backfill_hashes.nim
#   ./scripts/backfill_hashes

import std/[os, strutils, sequtils]
import tiny_sqlite
import nsheep/[storage, tarstrip, types]

const
  DbPath = "data/nsheep.db"
  TarballDir = "data/tarballs"
  MaxTarballSize = 500_000

proc main() =
  let db = openDatabase(DbPath)
  defer: db.close()

  let store = openStorage(DbPath, TarballDir)
  defer: store.close()

  # Find all head versions
  var heads: seq[tuple[pkgName: string, ver: SemVer, tarPath: string]]
  for row in db.all("""
    SELECT p.name, v.major, v.minor, v.patch, v.tarball_path
    FROM versions v
    JOIN packages p ON p.id = v.package_id
    WHERE v.major = 99999 AND v.minor = 99999 AND v.patch = 99999
  """):
    heads.add((
      pkgName: row[0].strVal,
      ver: SemVer(
        major: row[1].intVal.int,
        minor: row[2].intVal.int,
        patch: row[3].intVal.int
      ),
      tarPath: row[4].strVal
    ))

  echo "Found ", heads.len, " head versions"

  var processed = 0
  var skipped = 0
  var failed = 0

  for h in heads:
    let fullPath = h.tarPath
    if not fileExists(fullPath):
      failed.inc
      continue

    let size = getFileSize(fullPath)
    if size >= MaxTarballSize:
      skipped.inc
      continue

    var f: File
    if not open(f, fullPath, fmRead):
      failed.inc
      continue
    defer: close(f)

    var bytes = newSeq[byte](size)
    if f.readBuffer(addr bytes[0], size) != size:
      failed.inc
      continue

    let (fp, textLen) = extractMinHashFromTarball(bytes)
    if fp.len == 0:
      skipped.inc
      continue

    storeVersionHash(store, h.pkgName, h.ver, fp, textLen)
    processed.inc

    if processed mod 50 == 0:
      echo "Processed ", processed, "/", heads.len

  echo "Done: processed=", processed, " skipped=", skipped, " failed=", failed

when isMainModule:
  main()
