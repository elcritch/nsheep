import std/[osproc, strutils]

let (hash, exitCode) = execCmdEx("git rev-parse --short HEAD")
if exitCode != 0:
  quit("Failed to get git hash")
let h = hash.strip()

var html = readFile("public/index.html")
html = html.replace("?v=GIT_HASH", "?v=" & h)
writeFile("public/index.html", html)
