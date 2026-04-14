##
## Storage abstraction
## SQLite for metadata, filesystem for tarballs
##

import std/[times, os, strutils, sequtils, json, options]
import tiny_sqlite
import chronicles
import nsheep/types

# --- Errors ---

type
  StorageError* = object of CatchableError
  NotFoundError* = object of StorageError

# --- Database Schema ---

const Schema = """
-- Packages table
CREATE TABLE IF NOT EXISTS packages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE NOT NULL,
    description TEXT,
    author TEXT,
    license TEXT,
    url TEXT NOT NULL,
    tags TEXT,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT DEFAULT CURRENT_TIMESTAMP
);

-- Versions table (metadata only, no tarball blob)
CREATE TABLE IF NOT EXISTS versions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    package_id INTEGER NOT NULL,
    major INTEGER NOT NULL,
    minor INTEGER NOT NULL,
    patch INTEGER NOT NULL,
    tarball_path TEXT NOT NULL,  -- Path to tarball file
    tarball_size INTEGER NOT NULL,
    checksum TEXT NOT NULL,
    published_at TEXT,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (package_id) REFERENCES packages(id) ON DELETE CASCADE,
    UNIQUE(package_id, major, minor, patch)
);

-- Validation results table
CREATE TABLE IF NOT EXISTS validation_results (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    package_name TEXT NOT NULL,
    version TEXT NOT NULL,
    success INTEGER NOT NULL,
    output TEXT,
    duration_ms INTEGER,
    tested_at TEXT DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(package_name, version)
);

-- Download statistics table
CREATE TABLE IF NOT EXISTS download_stats (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    package_name TEXT NOT NULL,
    version TEXT NOT NULL,
    downloads INTEGER DEFAULT 0,
    UNIQUE(package_name, version)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_packages_name ON packages(name);
CREATE INDEX IF NOT EXISTS idx_versions_package ON versions(package_id);
CREATE INDEX IF NOT EXISTS idx_validation_package ON validation_results(package_name);
CREATE INDEX IF NOT EXISTS idx_downloads_package ON download_stats(package_name);
"""

# --- Types ---

type
  DbStorage* = object
    db*: DbConn
    dbPath*: string
    tarballDir*: string  # Filesystem directory for tarballs

# --- Initialization ---

proc initStorage*(dbPath: string, tarballDir: string): DbStorage =
  ## Initialize SQLite storage + filesystem tarball storage
  result.dbPath = dbPath
  result.tarballDir = tarballDir
  result.db = openDatabase(dbPath)
  
  # Create tables
  result.db.execScript(Schema)
  
  # Create tarball directory
  createDir(tarballDir)
  
  info "Storage initialized", dbPath = dbPath, tarballDir = tarballDir

proc close*(s: DbStorage) =
  ## Close database connection
  s.db.close()

# --- Package Operations ---

proc storePackage*(s: DbStorage, pkg: Package) =
  ## Store or update a package
  let tagsJson = "[" & pkg.tags.mapIt("\"" & it & "\"").join(",") & "]"
  
  s.db.exec("""
    INSERT INTO packages (name, description, author, license, url, tags, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, datetime('now'))
    ON CONFLICT(name) DO UPDATE SET
      description = excluded.description,
      author = excluded.author,
      license = excluded.license,
      url = excluded.url,
      tags = excluded.tags,
      updated_at = datetime('now')
  """, pkg.name.string, pkg.description, pkg.author, pkg.license, pkg.url, tagsJson)

proc loadPackage*(s: DbStorage, name: PackageName): Package =
  ## Load package by name
  let row = s.db.one("""
    SELECT name, description, author, license, url, tags, created_at, updated_at
    FROM packages WHERE name = ?
  """, name.string)
  
  if row.isNone:
    raise newException(NotFoundError, "package not found: " & name.string)
  
  let r = row.get()
  result.name = name
  result.description = r[1].strVal
  result.author = r[2].strVal
  result.license = r[3].strVal
  result.url = r[4].strVal
  # Parse tags JSON
  let tagsStr = r[5].strVal
  try:
    let tagsJson = parseJson(tagsStr)
    result.tags = tagsJson.getElems().mapIt(it.getStr())
  except:
    result.tags = @[]
  
  # Parse timestamps
  try:
    result.createdAt = parse(r[6].strVal, "yyyy-MM-dd HH:mm:ss")
  except:
    result.createdAt = now()
  try:
    result.updatedAt = parse(r[7].strVal, "yyyy-MM-dd HH:mm:ss")
  except:
    result.updatedAt = now()
  
  # Load versions
  for vrow in s.db.all("""
    SELECT major, minor, patch, tarball_path, tarball_size, checksum, published_at
    FROM versions
    WHERE package_id = (SELECT id FROM packages WHERE name = ?)
    ORDER BY major DESC, minor DESC, patch DESC
  """, name.string):
    let ver = initSemVer(vrow[0].intVal.int, vrow[1].intVal.int, vrow[2].intVal.int)
    let checksum = initChecksum(vrow[5].strVal)
    let publishedAt = try: parse(vrow[6].strVal, "yyyy-MM-dd HH:mm:ss") except: now()
    result.versions.add(PackageVersion(
      version: ver,
      tarballPath: vrow[3].strVal,
      checksum: checksum,
      size: vrow[4].intVal,
      publishedAt: publishedAt
    ))

proc listPackages*(s: DbStorage): seq[PackageName] =
  ## List all package names
  for row in s.db.all("SELECT name FROM packages ORDER BY name"):
    result.add(initPackageName(row[0].strVal))

# --- Summary Operations ---

type
  PackageSummary* = object
    name*: string
    description*: string
    author*: string
    license*: string
    url*: string
    tags*: seq[string]
    latestVersion*: string
    createdAt*: string
    updatedAt*: string
    latestVersionPublishedAt*: string

proc listPackageSummaries*(s: DbStorage): seq[PackageSummary] =
  ## List all packages with metadata and latest version
  for row in s.db.all("""
    SELECT p.name, p.description, p.author, p.license, p.url, p.tags, p.created_at, p.updated_at,
           v.major, v.minor, v.patch, v.published_at
    FROM packages p
    LEFT JOIN versions v ON v.id = (
      SELECT id FROM versions
      WHERE package_id = p.id
      ORDER BY major DESC, minor DESC, patch DESC
      LIMIT 1
    )
    ORDER BY p.name
  """):
    var tags: seq[string] = @[]
    let tagsStr = row[5].strVal
    try:
      let tagsJson = parseJson(tagsStr)
      tags = tagsJson.getElems().mapIt(it.getStr())
    except:
      discard

    var latestVersion = ""
    if row[7].kind != sqliteNull:
      latestVersion = $row[7].intVal & "." & $row[8].intVal & "." & $row[9].intVal

    result.add(PackageSummary(
      name: row[0].strVal,
      description: row[1].strVal,
      author: row[2].strVal,
      license: row[3].strVal,
      url: row[4].strVal,
      tags: tags,
      latestVersion: latestVersion,
      updatedAt: row[6].strVal,
      latestVersionPublishedAt: if row[10].kind != sqliteNull: row[10].strVal else: ""
    ))

proc listPackageSummariesPaged*(s: DbStorage, offset, limit: int): seq[PackageSummary] =
  ## List packages with metadata and latest version, paginated
  for row in s.db.all("""
    SELECT p.name, p.description, p.author, p.license, p.url, p.tags, p.updated_at,
           v.major, v.minor, v.patch, v.published_at
    FROM packages p
    LEFT JOIN versions v ON v.id = (
      SELECT id FROM versions
      WHERE package_id = p.id
      ORDER BY major DESC, minor DESC, patch DESC
      LIMIT 1
    )
    ORDER BY p.name
    LIMIT ? OFFSET ?
  """, limit.int64, offset.int64):
    var tags: seq[string] = @[]
    let tagsStr = row[5].strVal
    try:
      let tagsJson = parseJson(tagsStr)
      tags = tagsJson.getElems().mapIt(it.getStr())
    except:
      discard

    var latestVersion = ""
    if row[7].kind != sqliteNull:
      latestVersion = $row[7].intVal & "." & $row[8].intVal & "." & $row[9].intVal

    result.add(PackageSummary(
      name: row[0].strVal,
      description: row[1].strVal,
      author: row[2].strVal,
      license: row[3].strVal,
      url: row[4].strVal,
      tags: tags,
      latestVersion: latestVersion,
      updatedAt: row[6].strVal,
      latestVersionPublishedAt: if row[10].kind != sqliteNull: row[10].strVal else: ""
    ))

proc countPackages*(s: DbStorage): int =
  ## Return total number of packages
  let row = s.db.one("SELECT COUNT(*) FROM packages")
  if row.isSome:
    result = row.get()[0].intVal.int
  else:
    result = 0

# --- Version/Tarball Operations ---

proc tarballPath*(s: DbStorage, pkgName: PackageName, ver: SemVer): string =
  ## Get filesystem path for tarball
  let versionStr = $ver.major & "." & $ver.minor & "." & $ver.patch
  s.tarballDir / $pkgName & "-" & versionStr & ".tar.gz"

proc storeVersion*(
  s: DbStorage,
  pkgName: PackageName,
  ver: SemVer,
  tarball: seq[byte],
  checksum: Checksum,
  publishedAt: DateTime
) =
  ## Store a version - tarball to filesystem, metadata to SQLite
  # Get package id
  let pkgRow = s.db.one("SELECT id FROM packages WHERE name = ?", pkgName.string)
  if pkgRow.isNone:
    raise newException(NotFoundError, "package not found: " & pkgName.string)
  
  let pkgId = pkgRow.get()[0].intVal
  
  # Write tarball to filesystem
  let tarPath = s.tarballPath(pkgName, ver)
  createDir(tarPath.parentDir)
  
  var f: File
  if open(f, tarPath, fmWrite):
    defer: close(f)
    if tarball.len > 0:
      discard f.writeBuffer(unsafeAddr tarball[0], tarball.len)
  else:
    raise newException(StorageError, "cannot write tarball: " & tarPath)
  
  # Store metadata in SQLite
  s.db.exec("""
    INSERT INTO versions (package_id, major, minor, patch, tarball_path, tarball_size, checksum, published_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(package_id, major, minor, patch) DO UPDATE SET
      tarball_path = excluded.tarball_path,
      tarball_size = excluded.tarball_size,
      checksum = excluded.checksum
  """, pkgId, ver.major.int64, ver.minor.int64, ver.patch.int64, tarPath, tarball.len.int64, $checksum, $publishedAt)

proc loadTarball*(
  s: DbStorage,
  pkgName: PackageName,
  ver: SemVer
): seq[byte] =
  ## Load tarball bytes from filesystem
  let row = s.db.one("""
    SELECT tarball_path FROM versions v
    JOIN packages p ON v.package_id = p.id
    WHERE p.name = ? AND v.major = ? AND v.minor = ? AND v.patch = ?
  """, pkgName.string, ver.major.int64, ver.minor.int64, ver.patch.int64)
  
  if row.isNone:
    raise newException(NotFoundError, "version not found: " & $pkgName & "@" & $ver)
  
  let tarPath = row.get()[0].strVal
  if not fileExists(tarPath):
    raise newException(NotFoundError, "tarball file not found: " & tarPath)
  
  let fileSize = getFileSize(tarPath)
  result = newSeq[byte](fileSize)
  
  var f: File
  if open(f, tarPath, fmRead):
    defer: close(f)
    if fileSize > 0:
      discard f.readBuffer(addr result[0], fileSize)
  else:
    raise newException(StorageError, "cannot read tarball: " & tarPath)

proc versionExists*(s: DbStorage, pkgName: PackageName, ver: SemVer): bool =
  ## Check if version exists
  let row = s.db.one("""
    SELECT 1 FROM versions v
    JOIN packages p ON v.package_id = p.id
    WHERE p.name = ? AND v.major = ? AND v.minor = ? AND v.patch = ?
  """, pkgName.string, ver.major.int64, ver.minor.int64, ver.patch.int64)
  return row.isSome

# --- Validation Result Operations ---

proc storeValidationResult*(
  s: DbStorage,
  pkgName: string,
  version: string,
  success: bool,
  output: string,
  durationMs: int
) =
  ## Store validation result
  s.db.exec("""
    INSERT INTO validation_results (package_name, version, success, output, duration_ms, tested_at)
    VALUES (?, ?, ?, ?, ?, datetime('now'))
    ON CONFLICT(package_name, version) DO UPDATE SET
      success = excluded.success,
      output = excluded.output,
      duration_ms = excluded.duration_ms,
      tested_at = datetime('now')
  """, pkgName, version, success.int64, output, durationMs.int64)

proc getValidationResult*(s: DbStorage, pkgName, version: string): Option[tuple[success: bool, output: string, durationMs: int]] =
  ## Get validation result
  let row = s.db.one("""
    SELECT success, output, duration_ms FROM validation_results
    WHERE package_name = ? AND version = ?
  """, pkgName, version)
  
  if row.isSome:
    let r = row.get()
    result = some((
      success: r[0].intVal != 0,
      output: r[1].strVal,
      durationMs: r[2].intVal.int
    ))

proc getLatestValidationResults*(s: DbStorage, pkgName: string): seq[tuple[version: string, success: bool, testedAt: DateTime]] =
  ## Get all validation results for a package
  for row in s.db.all("""
    SELECT version, success, tested_at FROM validation_results
    WHERE package_name = ?
    ORDER BY tested_at DESC
  """, pkgName):
    result.add((
      version: row[0].strVal,
      success: row[1].intVal != 0,
      testedAt: parse(row[2].strVal, "yyyy-MM-dd HH:mm:ss")
    ))

proc recordDownload*(s: DbStorage, pkgName: string, version: string) =
  ## Record a download for a package version
  s.db.exec("""
    INSERT INTO download_stats (package_name, version, downloads)
    VALUES (?, ?, 1)
    ON CONFLICT(package_name, version) DO UPDATE SET
      downloads = downloads + 1
  """, pkgName, version)

proc getDownloadStats*(s: DbStorage, pkgName: string): seq[tuple[version: string, downloads: int]] =
  ## Get download statistics for all versions of a package
  for row in s.db.all("""
    SELECT version, downloads FROM download_stats
    WHERE package_name = ?
    ORDER BY version DESC
  """, pkgName):
    result.add((version: row[0].strVal, downloads: row[1].intVal.int))

proc getTotalDownloads*(s: DbStorage, pkgName: string): int =
  ## Get total download count for a package
  let row = s.db.one("""
    SELECT COALESCE(SUM(downloads), 0) FROM download_stats
    WHERE package_name = ?
  """, pkgName)
  if row.isSome:
    result = row.get()[0].intVal.int
  else:
    result = 0
