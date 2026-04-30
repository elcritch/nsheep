import std/[json, times, options]
import nsheep/vcs

proc main() =
  let client = initVcsClient("", "", "", "", "", "/tmp/nsheep-cache")
  let repo = parseRepoUrl("https://gitlab.com/pmetras/nim0").get()
  try:
    let (desc, updatedAt) = fetchRepoMeta(client, repo)
    echo "Description: ", desc
    echo "UpdatedAt: ", updatedAt
  except CatchableError as e:
    echo "Error: ", e.msg

main()
