import std/unittest
import std/options
import nsheep/vcs

suite "parseRepoUrl":
  test "parses plain GitHub URL":
    let r = parseRepoUrl("https://github.com/user/repo")
    check r.isSome
    check r.get().host == vhGitHub
    check r.get().path == "user/repo"
    check r.get().subdir == ""

  test "parses GitHub URL with subdir":
    let r = parseRepoUrl("https://github.com/user/repo?subdir=pkg")
    check r.isSome
    check r.get().host == vhGitHub
    check r.get().path == "user/repo"
    check r.get().subdir == "pkg"

  test "parses GitHub URL with subdir and extra query params":
    let r = parseRepoUrl("https://github.com/user/repo?foo=bar&subdir=pkg")
    check r.isSome
    check r.get().subdir == "pkg"

  test "strips fragment after subdir":
    let r = parseRepoUrl("https://github.com/user/repo?subdir=pkg#readme")
    check r.isSome
    check r.get().subdir == "pkg"
    check r.get().url == "https://github.com/user/repo"

  test "ignores empty subdir":
    let r = parseRepoUrl("https://github.com/user/repo?subdir=")
    check r.isSome
    check r.get().subdir == ""

  test "ignores bare subdir key without value":
    let r = parseRepoUrl("https://github.com/user/repo?subdir")
    check r.isSome
    check r.get().subdir == ""

  test "parses GitLab with subdir":
    let r = parseRepoUrl("https://gitlab.com/user/repo?subdir=lib")
    check r.isSome
    check r.get().host == vhGitLab
    check r.get().subdir == "lib"

  test "returns none for invalid URL":
    let r = parseRepoUrl("not-a-url")
    check r.isNone
