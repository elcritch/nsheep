# Package

version       = "0.1.0"
author        = "nsheep team"
description   = "A centralized Nim package registry + CDN server"
license       = "MIT"
srcDir        = "src"
bin           = @["nsheep"]
namedBin      = {"nsheep/fetcher": "nsheep-fetcher"}.toTable()

# Dependencies
requires "nim >= 2.0.16"
requires "mummy >= 0.4.0"
requires "puppy >= 2.1.0"
requires "chronicles >= 0.10.0"
requires "yaml >= 2.0.0"
requires "tiny_sqlite >= 0.2.0"
requires "zippy >= 0.10.0"

task frontend, "Build frontend assets":
  exec "nimble install karax -y"
  exec "mkdir -p public"
  exec "nim js -d:release -o:public/app.js frontend/app.nim"
  exec "cp frontend/index.html public/"
  exec "cp frontend/app.css public/"
  exec "cp frontend/robot.svg public/"
  exec "cp frontend/theme.js public/"

task test, "Run tests":
  exec "nim c -r tests/test_tags.nim"
  exec "nim c -r tests/test_nimble_parse.nim"
  exec "nim c -r tests/test_parse_repo_url.nim"
  exec "nim c -r tests/test_gitea.nim"
