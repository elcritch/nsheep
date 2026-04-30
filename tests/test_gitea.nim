import std/[unittest, options, times, os]
import nsheep/vcs

suite "Gitea host support":
  let client = initVcsClient("", "", "", "", "", getTempDir() / "nsheep-test-cache")

  test "parseRepoUrl parses generic git URL":
    let r = parseRepoUrl("https://git.envs.net/iacore/minicoro-nim")
    check r.isSome
    check r.get().host == vhGenericGit
    check r.get().path == "iacore/minicoro-nim"
    check r.get().url == "https://git.envs.net/iacore/minicoro-nim"

  test "detectHostType identifies Gitea instance":
    let repo = parseRepoUrl("https://git.envs.net/iacore/minicoro-nim").get()
    check repo.host == vhGenericGit
    let detected = detectHostType(client, repo)
    check detected.host == vhGitea
    check detected.path == "iacore/minicoro-nim"

  test "fetchRepoMeta fetches Gitea repo metadata":
    let repo = detectHostType(client, parseRepoUrl("https://git.envs.net/iacore/minicoro-nim").get())
    check repo.host == vhGitea
    let (desc, updatedAt) = fetchRepoMeta(client, repo)
    check desc == ""
    check updatedAt <= now()
    check updatedAt > now() - initDuration(days = 365 * 10)

  test "fetchVersions fetches Gitea repo tags":
    let repo = detectHostType(client, parseRepoUrl("https://git.envs.net/iacore/minicoro-nim").get())
    check repo.host == vhGitea
    let versions = fetchVersions(client, repo)
    check versions.len > 0

  test "fetchHeadVersion fetches Gitea HEAD commit":
    let repo = detectHostType(client, parseRepoUrl("https://git.envs.net/iacore/minicoro-nim").get())
    check repo.host == vhGitea
    let head = fetchHeadVersion(client, repo)
    check head.isSome
    check head.get().tag == "#head"
    check head.get().tarballUrl != ""
