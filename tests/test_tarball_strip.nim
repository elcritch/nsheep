##
## Unit test for tarstrip.nim
##

import std/[os, sequtils, osproc, strutils]
import nsheep/tarstrip

proc main() =
  # Create a test tarball in memory
  # We'll use a real package tarball for testing
  let testTarballPath = paramStr(1)

  if not fileExists(testTarballPath):
    stderr.writeLine("Usage: test_tarball_strip <tarball.tar.gz>")
    quit(1)

  # Read original
  var original: seq[byte]
  var f: File
  if open(f, testTarballPath, fmRead):
    let size = getFileSize(testTarballPath)
    original = newSeq[byte](size)
    discard f.readBuffer(addr original[0], size)
    close(f)
  else:
    stderr.writeLine("Cannot read: ", testTarballPath)
    quit(1)

  echo "Original size: ", original.len, " bytes"

  # Strip
  let stripped = stripTarballBytes(original)

  echo "Stripped size: ", stripped.len, " bytes"
  echo "Reduction: ", (100.0 - (stripped.len.float / original.len.float) * 100.0).formatFloat(ffDecimal, 1), "%"

  # Verify stripped tarball is valid by writing to temp and listing
  let tempOut = getTempDir() / "test-stripped.tar.gz"
  var outf: File
  if open(outf, tempOut, fmWrite):
    discard outf.writeBuffer(unsafeAddr stripped[0], stripped.len)
    close(outf)

    # Extract and verify with tar (macOS tar may warn about PAX headers, that's ok)
    let extractDir = getTempDir() / "test-stripped-contents"
    removeDir(extractDir)
    createDir(extractDir)
    let (_, extractExit) = execCmdEx("tar -xzf " & tempOut.quoteShell & " -C " & extractDir.quoteShell & " 2>&1")
    if extractExit != 0 and extractExit != 1:
      stderr.writeLine("FAILED: tar extract failed with exit code ", extractExit)
      quit(1)

    # Walk extracted files
    var fileCount = 0
    var foundExcluded = false
    for path in walkDirRec(extractDir):
      let relPath = path.relativePath(extractDir)
      inc fileCount
      if shouldExclude(relPath):
        stderr.writeLine("FAILED: found excluded path: ", relPath)
        foundExcluded = true
    if foundExcluded:
      quit(1)

    echo "Entries in stripped tarball: ", fileCount
    echo "SUCCESS: tarball stripped and validated"
    removeDir(extractDir)
    removeFile(tempOut)
  else:
    stderr.writeLine("Cannot write temp file")
    quit(1)

main()
