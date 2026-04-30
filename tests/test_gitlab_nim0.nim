import std/strutils
import puppy

proc main() =
  let repoPath = "pmetras/nim0"
  let apiBase = "https://gitlab.com"

  echo "=== Test: Manually set URL path ==="
  let baseUrl = parseUrl(apiBase)
  let req = newRequest("https://gitlab.com/api/v4/projects/dummy")
  req.url.path = "/api/v4/projects/" & repoPath.replace("/", "%2F")
  echo "URL: ", req.url
  let resp = fetch(req)
  echo "Status: ", resp.code
  echo "Body: ", resp.body[0..<min(200, resp.body.len)]

main()
