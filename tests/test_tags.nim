import std/json
import unittest
import nsheep/fetcher

suite "parseTags":
  test "extracts tags from valid array":
    let pkg = %*{ "name": "jester", "tags": ["web", "framework", "http"] }
    let tags = parseTags(pkg)
    check tags.len == 3
    check tags[0] == "web"
    check tags[1] == "framework"
    check tags[2] == "http"

  test "returns empty seq when tags field is missing":
    let pkg = %*{ "name": "jester" }
    let tags = parseTags(pkg)
    check tags.len == 0

  test "returns empty seq when tags is null":
    let pkg = parseJson("""{"name":"jester","tags":null}""")
    let tags = parseTags(pkg)
    check tags.len == 0

  test "returns empty seq when tags is not an array":
    let pkg = %*{ "name": "jester", "tags": "web,framework" }
    let tags = parseTags(pkg)
    check tags.len == 0

  test "skips non-string entries in tags array":
    let pkg = parseJson("""{"name":"jester","tags":["web",123,null,"framework"]}""")
    let tags = parseTags(pkg)
    check tags.len == 2
    check tags[0] == "web"
    check tags[1] == "framework"

  test "trims whitespace from tag strings":
    let pkg = parseJson("""{"name":"jester","tags":["  web  ","framework"]}""")
    let tags = parseTags(pkg)
    check tags.len == 2
    check tags[0] == "web"
    check tags[1] == "framework"

  test "skips empty strings after trimming":
    let pkg = parseJson("""{"name":"jester","tags":["web","","  ","framework"]}""")
    let tags = parseTags(pkg)
    check tags.len == 2
    check tags[0] == "web"
    check tags[1] == "framework"

  test "handles empty tags array":
    let pkg = %*{ "name": "jester", "tags": [] }
    let tags = parseTags(pkg)
    check tags.len == 0
