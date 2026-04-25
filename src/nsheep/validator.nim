##
## Package validator - compiles packages in Docker to verify they work
## Tests default branch + latest 2 tagged versions
##

import std/[os, osproc, strutils, tempfiles, times, algorithm]
import chronicles
import nsheep/[config, storage]

export config.ValidatorConfig

const
  DefaultDockerImage = "nimlang/nim:latest"
  BuildTimeout = 300  # 5 minutes per build
  MaxVersionsToTest = 2  # Latest 2 tagged versions + default branch

type
  BuildResult* = object
    version*: string      # "default" or tag name
    success*: bool
    output*: string       # Build output (stdout+stderr)
    durationMs*: int

  ValidationResult* = object
    repo*: string         # owner/repo
    defaultBranch*: BuildResult
    versions*: seq[BuildResult]
    overallSuccess*: bool

proc defaultValidatorConfig*(): ValidatorConfig =
  ValidatorConfig(
    enabled: true,
    dockerImage: DefaultDockerImage,
    timeout: BuildTimeout,
    required: false
  )

proc runDockerBuild(repoUrl, tag, dockerImage: string, timeout: int): BuildResult =
  ## Run a single build in Docker
  result.version = tag
  
  let tempDir = createTempDir("nsheep-build", "")
  defer: removeDir(tempDir)
  
  let srcDir = tempDir / "src"
  
  # Clone specific tag/branch
  let cloneCmd = if tag == "default":
    "git clone --depth 1 " & repoUrl & " " & srcDir
  else:
    "git clone --depth 1 --branch " & tag & " " & repoUrl & " " & srcDir
  
  var startTime = getTime()
  
  # Run clone
  let (cloneOut, cloneExit) = execCmdEx(cloneCmd)
  if cloneExit != 0:
    result.success = false
    result.output = "Clone failed: " & cloneOut
    result.durationMs = int((getTime() - startTime).inMilliseconds)
    return
  
  # Find .nimble file to get package name
  var nimbleFile = ""
  var pkgName = ""
  for file in walkFiles(srcDir / "*.nimble"):
    nimbleFile = file.extractFilename
    pkgName = nimbleFile.replace(".nimble", "")
    break
  
  if nimbleFile == "":
    result.success = false
    result.output = "No .nimble file found"
    result.durationMs = int((getTime() - startTime).inMilliseconds)
    return
  
  # Run Docker validation: nimble c <pkgname>
  # This compiles the package's entry point defined in the .nimble file
  let dockerCmd = "docker run --rm " &
    "-v " & srcDir & ":/src:ro " &
    "-w /src " &
    dockerImage & " " &
    "nimble c " & pkgName & " 2>&1"
  
  let (buildOut, buildExit) = execCmdEx(dockerCmd)
  
  result.durationMs = int((getTime() - startTime).inMilliseconds)
  result.success = buildExit == 0
  result.output = buildOut

proc getLatestTags(repoUrl: string, count: int): seq[string] =
  ## Get latest N tags from git repository
  let tempDir = createTempDir("nsheep-tags", "")
  defer: removeDir(tempDir)
  
  # Shallow clone to get tags
  let cmd = "git clone --depth 1 --no-checkout " & repoUrl & " " & tempDir & " 2>&1 && cd " & tempDir & " && git tag -l 2>/dev/null | sort -V | tail -" & $count
  let (output, exitCode) = execCmdEx(cmd)
  
  if exitCode == 0:
    for line in output.splitLines():
      let tag = line.strip()
      if tag.len > 0:
        result.add(tag)
  
  result.reverse()  # Latest first

proc validatePackage*(
  s: DbStorage,
  repoUrl, repoName: string,
  config: ValidatorConfig = defaultValidatorConfig()
): ValidationResult =
  ## Validate a package by building default branch + latest tags, store results in DB
  result.repo = repoName
  result.overallSuccess = true
  
  if not config.enabled:
    result.overallSuccess = true
    return
  
  info "Starting validation", repo = result.repo
  
  # Build default branch
  info "Building default branch", repo = result.repo
  result.defaultBranch = runDockerBuild(repoUrl, "default", config.dockerImage, config.timeout)
  
  # Store default branch result
  s.storeValidationResult(
    repoName,
    "default",
    result.defaultBranch.success,
    result.defaultBranch.output,
    result.defaultBranch.durationMs
  )
  
  if not result.defaultBranch.success:
    result.overallSuccess = false
    warn "Default branch build failed", repo = result.repo
  else:
    info "Default branch build succeeded", repo = result.repo, duration = result.defaultBranch.durationMs
  
  # Get and build latest tags
  let tags = getLatestTags(repoUrl, MaxVersionsToTest)
  info "Found tags", repo = result.repo, tags = tags
  
  for tag in tags:
    info "Building tagged version", repo = result.repo, tag = tag
    let buildResult = runDockerBuild(repoUrl, tag, config.dockerImage, config.timeout)
    result.versions.add(buildResult)
    
    # Store version result
    s.storeValidationResult(
      repoName,
      tag,
      buildResult.success,
      buildResult.output,
      buildResult.durationMs
    )
    
    if not buildResult.success:
      result.overallSuccess = false
      warn "Tagged build failed", repo = result.repo, tag = tag
    else:
      info "Tagged build succeeded", repo = result.repo, tag = tag, duration = buildResult.durationMs
  
  info "Validation complete", repo = result.repo, overallSuccess = result.overallSuccess

proc isDockerAvailable*(): bool =
  ## Check if Docker is installed and running
  let (_, exitCode) = execCmdEx("docker ps")
  return exitCode == 0

proc validateOrSkip*(s: DbStorage, repoUrl, repoName: string, config: ValidatorConfig): bool =
  ## Validate if enabled and Docker available, otherwise return true (skip)
  if not config.enabled:
    return true
  
  if not isDockerAvailable():
    warn "Docker not available, skipping validation", repo = repoName
    return true
  
  let res = validatePackage(s, repoUrl, repoName, config)
  return res.overallSuccess
