##
## In-memory tarball stripper - filter out non-essential files/directories
## Pure Nim, no external tools. Uses zippy for gzip + manual tar parsing.
##

import std/[os, strutils]
import zippy
import minhash

const
  NumMinHashSeeds = 128
  MinHashShingleSize = 3

  MinHashSeeds = block:
    var seeds: array[NumMinHashSeeds, uint32]
    var state = 123456789u64
    for i in 0..<NumMinHashSeeds:
      state += 0x9e3779b97f4a7c15u64
      var z = state
      z = (z xor (z shr 30)) * 0xbf58476d1ce4e5b9u64
      z = (z xor (z shr 27)) * 0x94d049bb133111ebu64
      seeds[i] = uint32(z xor (z shr 31))
    seeds

const
  BlockSize = 512

  DefaultExcludedPrefixes* = [
    # Test data (often the largest contributor to tarball size)
    "tests/",
    "test/",
    "t/",
    # CI/config directories
    ".github/",
    ".gitlab/",
    ".circleci/",
    # Documentation
    "docs/",
    "doc/",
    # Benchmarks
    "benchmarks/",
    "bench/",
    # Examples (kept source, removed examples dir if separate)
    "examples/",
    "experiments/",
    # Dotfiles
    ".gitignore",
    ".gitattributes",
    ".gitmodules",
    ".editorconfig",
    ".pre-commit-config.yaml",
    # CI configs at root
    ".travis.yml",
    ".appveyor.yml",
    ".builds.yml",
    # Build files
    "Makefile",
    "makefile",
    "Dockerfile",
    "docker-compose.yml",
  ]

proc shouldExclude*(path: string, excludedPrefixes: openArray[string] = DefaultExcludedPrefixes): bool =
  for prefix in excludedPrefixes:
    # Match at path start (no leading directory) or after any '/' (with leading directory)
    if path.startsWith(prefix):
      return true
    let needle = "/" & prefix
    if path.find(needle) >= 0:
      return true
  # macOS extended attribute files
  if path.contains("/._") or path.startsWith("._"):
    return true
  false

proc parseTarOct(s: openArray[char]): int =
  var i = 0
  while i < s.len and s[i] == ' ':
    inc i
  while i < s.len and s[i] in {'0'..'7'}:
    result = result * 8 + (s[i].ord - '0'.ord)
    inc i

type ReadmeExtract* = object
  filename*: string
  content*: string

proc extractReadmeFromTarball*(input: seq[byte], maxSize: int = 1_048_576): ReadmeExtract =
  ## Scan a tarball for README-like files and return the filename + content of the first match.
  ## Searches for files whose basename starts with "readme" (case-insensitive).
  ## Returns empty result if no README is found or tarball is invalid.

  if input.len == 0:
    return ReadmeExtract()

  var uncompressed: string
  try:
    uncompressed = uncompress(cast[string](input), dfGzip)
  except:
    return ReadmeExtract()

  if uncompressed.len == 0:
    return ReadmeExtract()

  var pos = 0
  while pos < uncompressed.len:
    if pos + BlockSize > uncompressed.len:
      break

    # Check for end-of-archive
    var allZero = true
    for i in 0..<BlockSize:
      if uncompressed[pos + i] != '\0':
        allZero = false
        break
    if allZero:
      pos += BlockSize
      continue

    let size = parseTarOct(uncompressed.toOpenArray(pos + 124, pos + 135))
    let typeflag = uncompressed[pos + 156]

    var path = $cast[cstring](addr uncompressed[pos])
    let magic = cast[cstring](addr uncompressed[pos + 257])
    if ($magic).startsWith("ustar"):
      let prefix = $cast[cstring](addr uncompressed[pos + 345])
      if prefix.len > 0:
        path = prefix / path
    if path.startsWith("./"):
      path = path[2..^1]

    let dataBlocks = ((size + BlockSize - 1) div BlockSize) * BlockSize

    # Check if basename starts with "readme" (case-insensitive)
    let basename = if '/' in path: path.split('/')[^1] else: path
    if basename.len > 0 and basename.toLowerAscii().startsWith("readme"):
      # Only extract regular files (typeflag '0' or '\0')
      if typeflag == '\0' or typeflag == '0':
        let readSize = min(size, maxSize)
        if readSize > 0 and pos + BlockSize + readSize <= uncompressed.len:
          return ReadmeExtract(
            filename: basename,
            content: uncompressed[pos + BlockSize ..< pos + BlockSize + readSize]
          )
        return ReadmeExtract(filename: basename)

    pos += BlockSize + dataBlocks

proc extractTextFromTarball*(input: seq[byte], maxTotalSize: int = 200_000): string =
  ## Extract text content from a tarball for similarity hashing.
  ## Includes: .nimble files, README files, and .nim source files.
  ## Excludes: tests/, docs/, deps/, examples/, CI configs, build files, etc.
  ## Returns concatenated lowercase text, truncated to maxTotalSize.

  if input.len == 0:
    return ""

  var uncompressed: string
  try:
    uncompressed = uncompress(cast[string](input), dfGzip)
  except:
    return ""

  if uncompressed.len == 0:
    return ""

  var pos = 0
  result = ""

  while pos < uncompressed.len:
    if pos + BlockSize > uncompressed.len:
      break

    # Check for end-of-archive
    var allZero = true
    for i in 0..<BlockSize:
      if uncompressed[pos + i] != '\0':
        allZero = false
        break
    if allZero:
      pos += BlockSize
      continue

    let size = parseTarOct(uncompressed.toOpenArray(pos + 124, pos + 135))
    let typeflag = uncompressed[pos + 156]

    var path = $cast[cstring](addr uncompressed[pos])
    let magic = cast[cstring](addr uncompressed[pos + 257])
    if ($magic).startsWith("ustar"):
      let prefix = $cast[cstring](addr uncompressed[pos + 345])
      if prefix.len > 0:
        path = prefix / path
    if path.startsWith("./"):
      path = path[2..^1]

    let dataBlocks = ((size + BlockSize - 1) div BlockSize) * BlockSize

    if typeflag == '\0' or typeflag == '0':
      let basename = if '/' in path: path.split('/')[^1] else: path
      let lowerPath = path.toLowerAscii()

      # Determine if we want this file
      var keep = false
      if lowerPath.endsWith(".nimble"):
        keep = true
      elif basename.len > 0 and basename.toLowerAscii().startsWith("readme"):
        keep = true
      elif lowerPath.endsWith(".nim"):
        # Skip if in excluded directories, but keep nimble (handled above)
        if not shouldExclude(path):
          keep = true

      if keep and size > 0 and pos + BlockSize + size <= uncompressed.len:
        let content = uncompressed[pos + BlockSize ..< pos + BlockSize + size]
        if result.len > 0:
          result.add(" ")
        result.add(content)
        if result.len >= maxTotalSize:
          break

    pos += BlockSize + dataBlocks

  if result.len > maxTotalSize:
    result = result[0..<maxTotalSize]

proc extractMinHashFromTarball*(input: seq[byte], maxTotalBytes: int = 200_000): (seq[uint32], int) =
  ## Extract MinHash fingerprint directly from tarball without building intermediate text string.
  ## Returns (fingerprint, totalBytesProcessed).
  ## Processes files independently and merges fingerprints element-wise (min).

  if input.len == 0:
    return (@[], 0)

  var uncompressed: string
  try:
    uncompressed = uncompress(cast[string](input), dfGzip)
  except:
    return (@[], 0)

  if uncompressed.len == 0:
    return (@[], 0)

  var fp = newSeq[uint32](NumMinHashSeeds)
  for i in 0..<NumMinHashSeeds:
    fp[i] = high(uint32)

  var pos = 0
  var totalBytes = 0
  var tmp: array[2, uint32]

  while pos < uncompressed.len:
    if pos + BlockSize > uncompressed.len:
      break

    # Check for end-of-archive
    var allZero = true
    for i in 0..<BlockSize:
      if uncompressed[pos + i] != '\0':
        allZero = false
        break
    if allZero:
      pos += BlockSize
      continue

    let size = parseTarOct(uncompressed.toOpenArray(pos + 124, pos + 135))
    let typeflag = uncompressed[pos + 156]

    var path = $cast[cstring](addr uncompressed[pos])
    let magic = cast[cstring](addr uncompressed[pos + 257])
    if ($magic).startsWith("ustar"):
      let prefix = $cast[cstring](addr uncompressed[pos + 345])
      if prefix.len > 0:
        path = prefix / path
    if path.startsWith("./"):
      path = path[2..^1]

    let dataBlocks = ((size + BlockSize - 1) div BlockSize) * BlockSize

    if typeflag == '\0' or typeflag == '0':
      let basename = if '/' in path: path.split('/')[^1] else: path
      let lowerPath = path.toLowerAscii()

      # Determine if we want this file
      var keep = false
      if lowerPath.endsWith(".nimble"):
        keep = true
      elif basename.len > 0 and basename.toLowerAscii().startsWith("readme"):
        keep = true
      elif lowerPath.endsWith(".nim"):
        if not shouldExclude(path):
          keep = true

      if keep and size > 0 and pos + BlockSize + size <= uncompressed.len:
        let contentStart = pos + BlockSize
        let contentLen = size
        if totalBytes >= maxTotalBytes:
          break
        let remaining = maxTotalBytes - totalBytes
        let processLen = min(contentLen, remaining)
        if processLen >= MinHashShingleSize:
          for i in 0..(processLen - MinHashShingleSize):
            let p = cast[cstring](unsafeAddr uncompressed[contentStart + i])
            for s in 0..<NumMinHashSeeds:
              MurmurHash3_x86_32(p, MinHashShingleSize, MinHashSeeds[s], tmp)
              if tmp[0] < fp[s]:
                fp[s] = tmp[0]
        totalBytes += processLen
        if totalBytes >= maxTotalBytes:
          break

    pos += BlockSize + dataBlocks

  result = (fp, totalBytes)

proc stripTarballBytes*(
  input: seq[byte],
  excludedPrefixes: openArray[string] = DefaultExcludedPrefixes
): seq[byte] {.raises: [].} =
  ## Strip non-essential files from a tarball in memory.
  ## Returns the filtered tarball bytes (gzip-compressed).

  if input.len == 0:
    return input

  # Decompress gzip
  var uncompressed: string
  try:
    uncompressed = uncompress(cast[string](input), dfGzip)
  except:
    return input # Fallback: return original if not valid gzip

  if uncompressed.len == 0:
    return input

  var output = ""
  output.setLen(uncompressed.len) # Pre-allocate, will shrink later
  var outPos = 0
  var pos = 0
  var entriesSkipped = 0

  while pos < uncompressed.len:
    if pos + BlockSize > uncompressed.len:
      break

    # Check for end-of-archive (all zeros)
    var allZero = true
    for i in 0..<BlockSize:
      if uncompressed[pos + i] != '\0':
        allZero = false
        break
    if allZero:
      pos += BlockSize
      continue

    # Parse header fields
    let name = cast[cstring](addr uncompressed[pos])
    let size = parseTarOct(uncompressed.toOpenArray(pos + 124, pos + 135))
    let typeflag = uncompressed[pos + 156]

    var path = $name
    let magic = cast[cstring](addr uncompressed[pos + 257])
    if ($magic).startsWith("ustar"):
      let prefix = $cast[cstring](addr uncompressed[pos + 345])
      if prefix.len > 0:
        path = prefix / path

    if path.startsWith("./"):
      path = path[2..^1]

    let dataBlocks = ((size + BlockSize - 1) div BlockSize) * BlockSize

    if shouldExclude(path, excludedPrefixes):
      pos += BlockSize + dataBlocks
      inc entriesSkipped
    else:
      # Copy header
      if outPos + BlockSize > output.len:
        output.setLen(max(output.len * 2, outPos + BlockSize + 65536))
      copyMem(addr output[outPos], addr uncompressed[pos], BlockSize)
      outPos += BlockSize

      # Copy data
      if outPos + dataBlocks > output.len:
        output.setLen(max(output.len * 2, outPos + dataBlocks + 65536))
      copyMem(addr output[outPos], addr uncompressed[pos + BlockSize], dataBlocks)
      outPos += dataBlocks

      pos += BlockSize + dataBlocks

  # Add end-of-archive markers (two zero blocks)
  if outPos + 2 * BlockSize > output.len:
    output.setLen(outPos + 2 * BlockSize)
  zeroMem(addr output[outPos], 2 * BlockSize)
  outPos += 2 * BlockSize

  output.setLen(outPos)

  if entriesSkipped == 0:
    return input # Nothing was stripped, return original to avoid recompression

  # Compress output with gzip
  try:
    result = cast[seq[byte]](compress(output, BestSpeed, dfGzip))
  except:
    return input # Fallback
