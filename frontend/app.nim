import karax / [vdom, kdom, karax, karaxdsl, jjson, kajax, localstorage, vstyles]
import strutils, jsffi, algorithm

# --- Types ---

type
  View = enum
    vHome, vPackage, vHelp, vStats, vNotFound

  SortOrder = enum
    soUpdatedDesc, soPublishedDesc

  PackageSummary = object
    name: string
    description: string
    author: string
    latestVersion: string
    createdAt: int
    updatedAt: int
    latestVersionPublishedAt: int
    tags: seq[string]

  VersionInfo = object
    version: string
    size: int
    checksum: string
    publishedAt: int

  ValidationResult = object
    version: string
    success: bool
    testedAt: int

  PackageDetail = object
    name: string
    description: string
    author: string
    license: string
    url: string
    tags: seq[string]
    versions: seq[VersionInfo]

  TopDownloaded = object
    name: string
    downloads: int

  TopAuthor = object
    name: string
    packageCount: int

  LicenseItem = object
    license: string
    count: int

  HostItem = object
    host: string
    count: int

  TagItem = object
    tag: string
    count: int

  BarItem = object
    label: string
    count: int

  FailedPkg = object
    name: string
    url: string

  LargestPkg = object
    name: string
    url: string
    totalSize: int
    versionCount: int

  StatsData = object
    totalPackages: int
    totalAuthors: int
    totalDownloads: int
    topDownloaded: seq[TopDownloaded]
    topAuthors: seq[TopAuthor]
    licenses: seq[LicenseItem]
    hosts: seq[HostItem]
    topTags: seq[TagItem]
    repoNotFoundCount: int
    repoNotFound: seq[FailedPkg]
    largestPackages: seq[LargestPkg]

proc sortParam(so: SortOrder): string =
  case so
  of soUpdatedDesc: "updated_desc"
  of soPublishedDesc: "published_desc"

# --- State ---

const pageSize = 50

var
  summaries: seq[PackageSummary] = @[]
  filtered: seq[PackageSummary] = @[]
  detail: PackageDetail
  validations: seq[ValidationResult] = @[]
  currentView = vHome
  currentPkgName = ""
  loading = true
  searchQuery = ""
  activeAuthor = ""
  activeTag = ""
  copyFeedback = ""
  patchCopyFeedback = ""
  darkMode = false
  readmeContent = ""
  readmeFilename = ""
  totalDownloads = 0
  displayedCount = 0
  searchTimer: JsObject = nil
  dropdownTimer: JsObject = nil
  searchSuggestions: seq[PackageSummary] = @[]
  showDropdown = false
  errorMessage = ""
  currentSort = soPublishedDesc
  totalPackages = 0
  currentPage = 1
  statsData: StatsData

# --- Forward Declarations ---

proc fetchSummaries(page: int = 1)
proc fetchSearchSuggestions(q: string)
proc fetchDetail(name: string)
proc fetchValidations(name: string)
proc fetchReadme(name: string)
proc fetchDownloads(name: string)
proc fetchStats()
proc applyFilters()
proc clearAllFilters()

# --- Routing ---

proc parsePath(): View =
  let p = $kdom.window.location.pathname
  if p == "" or p == "/":
    result = vHome
  elif p.startsWith("/package/"):
    result = vPackage
    currentPkgName = p[9..^1]
  elif p == "/help":
    result = vHelp
  elif p == "/stats":
    result = vStats
  else:
    result = vNotFound

proc updateRoute() =
  currentView = parsePath()

proc navigateTo(path: cstring) =
  let hist = cast[JsObject](kdom.window)["history"]
  if hist != nil:
    let pushState = hist["pushState"]
    if pushState != nil:
      discard pushState.call(hist, jsNull, cstring(""), path)
  updateRoute()
  case currentView
  of vHome:
    if summaries.len == 0:
      fetchSummaries()
    else:
      redraw()
  of vPackage:
    fetchDetail(currentPkgName)
  of vStats:
    fetchStats()
  of vHelp:
    loading = false
    redraw()
  of vNotFound:
    loading = false
    redraw()

proc onPopState(ev: Event) =
  updateRoute()
  case currentView
  of vHome:
    if summaries.len == 0:
      fetchSummaries()
    else:
      redraw()
  of vPackage:
    fetchDetail(currentPkgName)
  of vStats:
    fetchStats()
  of vHelp:
    loading = false
    redraw()
  of vNotFound:
    loading = false
    redraw()

proc onLinkClick(ev: Event) =
  ## Intercept clicks on internal links to use history API instead of full reload
  var el = cast[Element](ev.target)
  while el != nil and el.nodeName != cstring"A":
    el = el.parentElement
  if el == nil:
    return
  let href = $(el.getAttribute("href"))
  if href.len == 0 or not href.startsWith("/"):
    return
  # Skip API, direct download, and static file links
  if href.startsWith("/api/") or href.startsWith("/download/") or href == "/packages.json" or href == "/llm.txt":
    return
  ev.preventDefault()
  navigateTo(cstring(href))

# --- Data Fetching ---

proc fetchJson(url: cstring, cont: proc(data: JsonNode), errMsg: string = "") =
  let req = newRequest()
  req.open("GET", url, true)
  req.statechange proc() =
    let r = cast[JsObject](req)
    if cast[int](r.readyState) == 4:
      if cast[int](r.status) == 200:
        cont(parse(cast[cstring](r.responseText)))
      else:
        loading = false
        if errMsg != "":
          errorMessage = errMsg
        redraw()
  req.send("")

proc fetchText(url: cstring, cont: proc(text: string)) =
  let req = newRequest()
  req.open("GET", url, true)
  req.statechange proc() =
    let r = cast[JsObject](req)
    if cast[int](r.readyState) == 4:
      if cast[int](r.status) == 200:
        cont($cast[cstring](r.responseText))
      else:
        cont("")
  req.send("")

proc fetchSummaries(page: int = 1) =
  loading = true
  errorMessage = ""
  var url = "/api/v1/packages?page=" & $page & "&limit=" & $pageSize & "&sort=" & sortParam(currentSort)
  if searchQuery.len > 0:
    url &= "&q=" & searchQuery
  if activeAuthor.len > 0:
    url &= "&author=" & activeAuthor
  if activeTag.len > 0:
    url &= "&tag=" & activeTag
  fetchJson(cstring(url),
    proc (data: JsonNode) =
    loading = false
    var newItems: seq[PackageSummary] = @[]
    if data.hasField("packages"):
      for item in data["packages"]:
        newItems.add(PackageSummary(
          name: $item["name"].getStr(),
          description: if item.hasField("description"): $item["description"].getStr() else: "",
          author: if item.hasField("author"): $item["author"].getStr() else: "",
          latestVersion: if item.hasField("latestVersion"): $item["latestVersion"].getStr() else: "",
          createdAt: if item.hasField("createdAt"): item["createdAt"].getInt() else: 0,
          updatedAt: if item.hasField("updatedAt"): item["updatedAt"].getInt() else: 0,
          latestVersionPublishedAt: if item.hasField("latestVersionPublishedAt"): item[
              "latestVersionPublishedAt"].getInt() else: 0,
          tags: if item.hasField("tags"):
              (var ts: seq[string] = @[]; for t in item["tags"]: ts.add($t.getStr()); ts)
            else: @[]
          ))
    if data.hasField("total"):
      totalPackages = data["total"].getInt()
    currentPage = page
    if page == 1:
      summaries = newItems
    else:
      summaries.add(newItems)
    applyFilters()
    redraw(),
    "Failed to load packages. Please try again."
  )

proc fetchSearchSuggestions(q: string) =
  if q.len == 0:
    searchSuggestions = @[]
    showDropdown = false
    redraw()
    return
  let url = "/api/v1/packages?q=" & q & "&limit=20"
  fetchJson(cstring(url),
    proc (data: JsonNode) =
    var items: seq[PackageSummary] = @[]
    if data.hasField("packages"):
      for item in data["packages"]:
        items.add(PackageSummary(
          name: $item["name"].getStr(),
          description: if item.hasField("description"): $item["description"].getStr() else: "",
          author: if item.hasField("author"): $item["author"].getStr() else: "",
          latestVersion: if item.hasField("latestVersion"): $item["latestVersion"].getStr() else: "",
          createdAt: if item.hasField("createdAt"): item["createdAt"].getInt() else: 0,
          updatedAt: if item.hasField("updatedAt"): item["updatedAt"].getInt() else: 0,
          latestVersionPublishedAt: if item.hasField("latestVersionPublishedAt"): item[
              "latestVersionPublishedAt"].getInt() else: 0,
          tags: if item.hasField("tags"):
              (var ts: seq[string] = @[]; for t in item["tags"]: ts.add($t.getStr()); ts)
            else: @[]
          ))
    searchSuggestions = items
    showDropdown = items.len > 0
    redraw(),
    ""
  )

proc fetchValidations(name: string) =
  fetchJson(cstring("/api/v1/packages/" & name & "/validations")) do (data: JsonNode):
    validations = @[]
    for item in data:
      validations.add(ValidationResult(
        version: $item["version"].getStr(),
        success: item["success"].getBool(),
        testedAt: item["testedAt"].getInt()
      ))
    redraw()

proc fetchReadme(name: string) =
  fetchJson(cstring("/api/v1/packages/" & name & "/readme")) do (data: JsonNode):
    readmeFilename = $data["filename"].getStr()
    readmeContent = $data["content"].getStr()
    redraw()

proc fetchDownloads(name: string) =
  fetchJson(cstring("/api/v1/packages/" & name & "/downloads")) do (data: JsonNode):
    totalDownloads = 0
    for item in data:
      totalDownloads += item["downloads"].getInt()
    redraw()

proc fetchStats() =
  loading = true
  errorMessage = ""
  fetchJson(cstring("/api/v1/stats"),
    proc (data: JsonNode) =
    loading = false
    var topDl: seq[TopDownloaded] = @[]
    if data.hasField("topDownloaded"):
      for item in data["topDownloaded"]:
        topDl.add(TopDownloaded(
          name: $item["name"].getStr(),
          downloads: item["downloads"].getInt()
        ))

    var authors: seq[TopAuthor] = @[]
    if data.hasField("topAuthors"):
      for item in data["topAuthors"]:
        authors.add(TopAuthor(
          name: $item["name"].getStr(),
          packageCount: item["packageCount"].getInt()
        ))

    var licenses: seq[LicenseItem] = @[]
    if data.hasField("licenses"):
      for item in data["licenses"]:
        licenses.add(LicenseItem(
          license: $item["license"].getStr(),
          count: item["count"].getInt()
        ))

    var hosts: seq[HostItem] = @[]
    if data.hasField("hosts"):
      for item in data["hosts"]:
        hosts.add(HostItem(
          host: $item["host"].getStr(),
          count: item["count"].getInt()
        ))

    var tags: seq[TagItem] = @[]
    if data.hasField("topTags"):
      for item in data["topTags"]:
        tags.add(TagItem(
          tag: $item["tag"].getStr(),
          count: item["count"].getInt()
        ))

    var repoNotFound: seq[FailedPkg] = @[]
    if data.hasField("repoNotFound"):
      for item in data["repoNotFound"]:
        repoNotFound.add(FailedPkg(
          name: $item["name"].getStr(),
          url: if item.hasField("url"): $item["url"].getStr() else: ""
        ))

    var largestPackages: seq[LargestPkg] = @[]
    if data.hasField("largestPackages"):
      for item in data["largestPackages"]:
        largestPackages.add(LargestPkg(
          name: $item["name"].getStr(),
          url: if item.hasField("url"): $item["url"].getStr() else: "",
          totalSize: if item.hasField("totalSize"): item["totalSize"].getInt() else: 0,
          versionCount: if item.hasField("versionCount"): item["versionCount"].getInt() else: 0
        ))

    statsData = StatsData(
      totalPackages: if data.hasField("totalPackages"): data["totalPackages"].getInt() else: 0,
      totalAuthors: if data.hasField("totalAuthors"): data["totalAuthors"].getInt() else: 0,
      totalDownloads: if data.hasField("totalDownloads"): data["totalDownloads"].getInt() else: 0,
      topDownloaded: topDl,
      topAuthors: authors,
      licenses: licenses,
      hosts: hosts,
      topTags: tags,
      repoNotFoundCount: if data.hasField("repoNotFoundCount"): data["repoNotFoundCount"].getInt() else: 0,
      repoNotFound: repoNotFound,
      largestPackages: largestPackages
    )
    redraw(),
    "Failed to load stats. Please try again."
  )

proc fetchDetail(name: string) =
  loading = true
  errorMessage = ""
  detail = PackageDetail() # clear old
  validations = @[]
  readmeContent = ""
  totalDownloads = 0
  fetchJson(cstring("/api/v1/packages/" & name),
    proc (data: JsonNode) =
    loading = false
    var versions: seq[VersionInfo] = @[]
    if data.hasField("versions"):
      for v in data["versions"]:
        versions.add(VersionInfo(
          version: $v["version"].getStr(),
          size: v["size"].getInt(),
          checksum: $v["checksum"].getStr(),
          publishedAt: v["publishedAt"].getInt()
        ))
    var tags: seq[string] = @[]
    if data.hasField("tags"):
      for t in data["tags"]:
        tags.add($t.getStr())
    detail = PackageDetail(
      name: $data["name"].getStr(),
      description: if data.hasField("description"): $data["description"].getStr() else: "",
      author: if data.hasField("author"): $data["author"].getStr() else: "",
      license: if data.hasField("license"): $data["license"].getStr() else: "",
      url: if data.hasField("url"): $data["url"].getStr() else: "",
      tags: tags,
      versions: versions
    )
    fetchValidations(name)
    fetchReadme(name)
    fetchDownloads(name)
    redraw(),
    "Failed to load package details. Please try again."
  )

# --- Filtering & Sorting ---

proc sortFiltered() =
  case currentSort
  of soPublishedDesc:
    algorithm.sort(filtered) do (a, b: PackageSummary) -> int:
      cmp(b.createdAt, a.createdAt)
  of soUpdatedDesc:
    algorithm.sort(filtered) do (a, b: PackageSummary) -> int:
      cmp(b.updatedAt, a.updatedAt)

proc applyFilters() =
  filtered = summaries
  displayedCount = filtered.len

# --- Event Handlers ---

proc onSearchInput(ev: Event; target: VNode) =
  let val = cast[JsObject](ev.target)["value"]
  searchQuery = $cast[cstring](val)
  if searchTimer != nil:
    discard cast[JsObject](kdom.window).clearTimeout(searchTimer)
  searchTimer = cast[JsObject](kdom.window.setTimeout(proc() =
    summaries = @[]
    filtered = @[]
    displayedCount = 0
    fetchSummaries(1)
    searchTimer = nil
  , 300))
  if dropdownTimer != nil:
    discard cast[JsObject](kdom.window).clearTimeout(dropdownTimer)
  dropdownTimer = cast[JsObject](kdom.window.setTimeout(proc() =
    fetchSearchSuggestions(searchQuery)
    dropdownTimer = nil
  , 200))

proc clickAuthor(author: string) =
  activeAuthor = author
  summaries = @[]
  filtered = @[]
  displayedCount = 0
  navigateTo(cstring"/")

proc clickTag(tag: string) =
  activeTag = tag
  summaries = @[]
  filtered = @[]
  displayedCount = 0
  navigateTo(cstring"/")

proc clearAuthor() =
  activeAuthor = ""
  summaries = @[]
  filtered = @[]
  displayedCount = 0
  fetchSummaries(1)

proc clearTag() =
  activeTag = ""
  summaries = @[]
  filtered = @[]
  displayedCount = 0
  fetchSummaries(1)

proc clearAllFilters() =
  searchQuery = ""
  activeAuthor = ""
  activeTag = ""
  searchSuggestions = @[]
  showDropdown = false
  summaries = @[]
  filtered = @[]
  displayedCount = 0
  fetchSummaries(1)

proc closeDropdown() =
  showDropdown = false
  redraw()

# --- Keyboard Navigation ---

proc onKeyDown(ev: Event) =
  let k = cast[KeyboardEvent](ev)
  if k.ctrlKey or k.metaKey or k.altKey:
    return
  case $k.key
  of "/":
    let tag = $cast[cstring](cast[JsObject](ev.target)["tagName"])
    if tag.toLowerAscii() notin ["input", "textarea", "select"]:
      ev.preventDefault()
      let el = kdom.document.querySelector(cstring"#search-input")
      if el != nil:
        discard cast[JsObject](el).focus()
  of "Escape":
    if showDropdown:
      closeDropdown()
      return
    if searchQuery != "" or activeAuthor != "" or activeTag != "":
      clearAllFilters()
      let el = kdom.document.querySelector(cstring"#search-input")
      if el != nil:
        discard cast[JsObject](el).focus()
  of "ArrowDown", "ArrowUp":
    if currentView == vHome:
      let list = kdom.document.getElementById(cstring"package-list")
      if list != nil:
        let links = cast[JsObject](list).querySelectorAll(cstring"a")
        let len = cast[int](cast[JsObject](links)["length"])
        if len == 0: return
        let active = cast[JsObject](kdom.document.activeElement)
        var currentIdx = -1
        for i in 0..<len:
          if cast[JsObject](links[i]) == active:
            currentIdx = i
            break
        var nextIdx = currentIdx
        if $k.key == "ArrowDown":
          nextIdx = if currentIdx < len - 1: currentIdx + 1 else: 0
        else:
          nextIdx = if currentIdx > 0: currentIdx - 1 else: len - 1
        if nextIdx >= 0 and nextIdx < len:
          discard cast[JsObject](links[nextIdx]).focus()
          ev.preventDefault()
  else:
    discard

# --- Views ---

proc renderHome(): VNode =
  buildHtml(tdiv(class = "page home")):
    tdiv(class = "search-wrap"):
      tdiv(class = "search-box"):
        input(class = "search", id = "search-input", `type` = "text", placeholder = "Search packages…",
            value = cstring(searchQuery)):
          proc oninput(ev: Event; target: VNode) = onSearchInput(ev, target)
          proc onkeydown(ev: Event; target: VNode) =
            let k = cast[KeyboardEvent](ev)
            if $k.key == "Enter" and searchSuggestions.len > 0:
              navigateTo(cstring("/package/" & searchSuggestions[0].name))
              closeDropdown()
        if showDropdown and searchSuggestions.len > 0:
          tdiv(class = "search-dropdown"):
            for i in 0 ..< searchSuggestions.len:
              let s = searchSuggestions[i]
              a(href = cstring("/package/" & s.name), class = "search-dropdown-item"):
                proc onclick(ev: Event; target: VNode) =
                  ev.preventDefault()
                  navigateTo(cstring("/package/" & s.name))
                  closeDropdown()
                tdiv(class = "search-dropdown-name"): text s.name
                if s.description.len > 0:
                  tdiv(class = "search-dropdown-desc"): text s.description
      tdiv(class = "sort-segment"):
        button(class = cstring("sort-btn " & (if currentSort == soPublishedDesc: "sort-active" else: "")),
            onclick = proc() =
          currentSort = soPublishedDesc
          summaries = @[]
          filtered = @[]
          displayedCount = 0
          fetchSummaries(1)
        ): text "Recent published"
        button(class = cstring("sort-btn " & (if currentSort == soUpdatedDesc: "sort-active" else: "")), onclick = proc() =
          currentSort = soUpdatedDesc
          summaries = @[]
          filtered = @[]
          displayedCount = 0
          fetchSummaries(1)
        ): text "Recently updated"
    if activeAuthor != "" or activeTag != "":
      tdiv(class = "active-filters"):
        if activeAuthor != "":
          span(class = "filter-badge author-badge"):
            text ("Author: " & activeAuthor)
            button(class = "clear-btn", onclick = proc() = clearAuthor()): text "×"
        if activeTag != "":
          span(class = "filter-badge tag-badge"):
            text ("Tag: " & activeTag)
            button(class = "clear-btn", onclick = proc() = clearTag()): text "×"
        if activeAuthor != "" or activeTag != "":
          button(class = "clear-all", onclick = proc() = clearAllFilters()): text "Clear all"
    if loading:
      tdiv(class = "home-skeleton"):
        tdiv(class = "search-wrap"):
          tdiv(class = "skeleton sk-search")
        tdiv(class = "package-list"):
          for i in 1..5:
            article(class = "package-item"):
              header(class = "package-header"):
                tdiv(class = "skeleton sk-title")
                tdiv(class = "skeleton sk-badge")
              tdiv(class = "package-desc"):
                tdiv(class = "skeleton sk-desc")
              tdiv(class = "package-meta"):
                tdiv(class = "skeleton sk-meta")
    elif errorMessage != "":
      tdiv(class = "error-status"):
        p: text errorMessage
        button(class = "retry-btn", onclick = proc() = fetchSummaries()): text "Retry"
    elif filtered.len == 0:
      tdiv(class = "status"): text "No packages found."
    else:
      tdiv(class = "package-list", id = "package-list"):
        for i in 0..<displayedCount:
          let s = filtered[i]
          article(class = "package-item"):
            header(class = "package-header"):
              h2:
                a(href = cstring("/package/" & s.name)): text s.name
              if s.latestVersion != "":
                span(class = "version-badge"): text s.latestVersion
            if s.description != "":
              p(class = "package-desc"): text s.description
            if s.author != "":
              p(class = "package-meta"):
                text "By "
                let author = s.author
                a(href = "/", class = "inline-link", onclick = proc() = clickAuthor(author)): text author
      if summaries.len < totalPackages:
        tdiv(class = "load-more-wrap"):
          button(class = "load-more-btn", disabled = loading, onclick = proc() =
            fetchSummaries(currentPage + 1)
          ):
            if loading:
              text "Loading..."
            else:
              text ("Load more (" & $summaries.len & " of " & $totalPackages & ")")

proc formatSize(bytes: int): string =
  if bytes < 1024:
    result = $bytes & " B"
  elif bytes < 1024 * 1024:
    result = $(bytes div 1024) & " KB"
  else:
    result = $(bytes div (1024 * 1024)) & " MB"

proc jsDate(ts: float): JsObject {.importjs: "new Date(#)".}
proc toLocaleString(d: JsObject): cstring {.importjs: "#.toLocaleString()".}

proc formatTimestamp(ts: int): string =
  if ts <= 0: return ""
  result = $toLocaleString(jsDate(float(ts * 1000)))

proc copyInstallCommand(cmd: string) =
  let w = cast[JsObject](kdom.window)
  let nav = w["navigator"]
  let cb = cast[JsObject](nav)["clipboard"]
  if cb != nil:
    discard cb.writeText(cstring(cmd))
  copyFeedback = "Copied!"
  redraw()
  discard kdom.window.setTimeout(proc() =
    copyFeedback = ""
    redraw()
  , 1500)

proc copyPatchCommand(cmd: string) =
  let w = cast[JsObject](kdom.window)
  let nav = w["navigator"]
  let cb = cast[JsObject](nav)["clipboard"]
  if cb != nil:
    discard cb.writeText(cstring(cmd))
  patchCopyFeedback = "Copied!"
  redraw()
  discard kdom.window.setTimeout(proc() =
    patchCopyFeedback = ""
    redraw()
  , 1500)

proc loadTheme() =
  let storedItem = localstorage.getItem(cstring"nimpack-theme")
  let stored = if storedItem != nil: $storedItem else: ""
  if stored == "dark":
    darkMode = true
  elif stored == "light":
    darkMode = false
  else:
    try:
      let mq = kdom.window.matchMedia(cstring"(prefers-color-scheme: dark)")
      darkMode = mq.matches
    except:
      darkMode = false
  kdom.document.documentElement.setAttribute("data-theme",
    if darkMode: cstring"dark" else: cstring"light")

proc toggleDarkMode() =
  darkMode = not darkMode
  let theme = if darkMode: cstring"dark" else: cstring"light"
  localstorage.setItem(cstring"nimpack-theme", theme)
  kdom.document.documentElement.setAttribute("data-theme", theme)
  redraw()

proc renderPackage(): VNode =
  buildHtml(tdiv(class = "page package-detail")):
    a(href = "/", class = "back-link"): text "← All packages"
    if loading:
      tdiv(class = "package-skeleton"):
        tdiv(class = "back-link"):
          tdiv(class = "skeleton sk-back")
        header(class = "detail-header"):
          tdiv(class = "skeleton sk-header-title")
          tdiv(class = "skeleton sk-badge")
        tdiv(class = "install-command"):
          tdiv(class = "skeleton sk-install-code")
          tdiv(class = "skeleton sk-install-btn")
        tdiv(class = "detail-desc"):
          tdiv(class = "skeleton sk-line")
          tdiv(class = "skeleton sk-line sk-mt05")
        dl(class = "detail-meta"):
          for i in 1..3:
            dt: tdiv(class = "skeleton sk-meta-label")
            dd: tdiv(class = "skeleton sk-meta-value")
        tdiv(class = "tags"):
          for i in 1..3:
            tdiv(class = "skeleton sk-pill")
        section(class = "versions"):
          h2:
            tdiv(class = "skeleton sk-title sk-w80")
          for i in 1..4:
            tdiv(class = "version-row"):
              tdiv(class = "skeleton sk-version-name")
              tdiv(class = "skeleton sk-version-size")
              tdiv(class = "skeleton sk-version-badge")
              tdiv(class = "skeleton sk-download")
    elif errorMessage != "":
      tdiv(class = "error-status"):
        p: text errorMessage
        button(class = "retry-btn", onclick = proc() = fetchDetail(currentPkgName)): text "Retry"
    else:
      header(class = "detail-header"):
        h1: text detail.name
        if detail.versions.len > 0:
          span(class = "version-badge"): text detail.versions[0].version
        if totalDownloads > 0:
          span(class = "download-count"): text ($totalDownloads & " downloads")
      tdiv(class = "install-command"):
        code: text ("nimble install " & detail.name)
        button(class = "copy-btn", onclick = proc() = copyInstallCommand("nimble install " & detail.name)):
          if copyFeedback != "" and detail.name == currentPkgName:
            text copyFeedback
          else:
            text "Copy"
      if detail.description != "":
        p(class = "detail-desc"): text detail.description
      dl(class = "detail-meta"):
        if detail.author != "":
          dt: text "Author"
          dd:
            let author = detail.author
            a(href = "/", class = "inline-link", onclick = proc() = clickAuthor(author)): text author
        if detail.license != "":
          dt: text "License"
          dd: text detail.license
        if detail.url != "":
          dt: text "URL"
          dd:
            a(href = cstring(detail.url), target = "_blank", rel = "noopener"): text detail.url
      if detail.tags.len > 0:
        tdiv(class = "tags"):
          for t in detail.tags:
            let tagName = t
            a(href = "/", class = "tag", onclick = proc() = clickTag(tagName)): text tagName
      section(class = "versions"):
        h2: text "Versions"
        for v in detail.versions:
          tdiv(class = "version-row"):
            span(class = "version-name"): text v.version
            span(class = "version-size"): text formatSize(v.size)
            var vstatus = ""
            var vclass = ""
            for val in validations:
              if val.version == v.version:
                vstatus = if val.success: "Passed" else: "Failed"
                vclass = if val.success: "val-pass" else: "val-fail"
                break
            if vstatus != "":
              span(class = cstring("validation-badge " & vclass)): text vstatus
            a(
              href = cstring("/download/" & detail.name & "/" & v.version.replace("#", "")),
              class = "download-link",
              download = ""
            ): text "Download"
      if readmeContent != "":
        section(class = "readme"):
          h2: text "README"
          tdiv(class = "readme-content", id = "readme-content")

proc renderNotFound(): VNode =
  buildHtml(tdiv(class = "page notfound")):
    h1: text "404"
    p: text "Page not found."
    a(href = "/"): text "Return home"

proc renderHelp(): VNode =
  buildHtml(tdiv(class = "page help-page")):
    a(href = "/", class = "back-link"): text "← All packages"
    tdiv(class = "help-content"):
      h1: text "Using NimPack with Nimble"
      p:
        text "NimPack exposes a nimble-compatible package list at "
        code: text "/packages.json"
        text ". Point your nimble client at this server to install packages directly from NimPack."

      h2: text "1. Configure Nimble"
      p:
        text "Add the following to your nimble config file (typically "
        code: text "~/.config/nimble/nimble.ini"
        text " on macOS/Linux or "
        code: text "%APPDATA%\nimble\nimble.ini"
        text " on Windows):"

      pre:
        code(class = "language-ini"): text """[PackageList]
name = "nimpack"
url = "https://nimpack.org/packages.json""""

      p:
        text "Replace "
        code: text "https://nimpack.org"
        text " with the actual URL of your NimPack instance. You can add multiple "
        code: text "url"
        text " lines if the server is reachable from different addresses."

      h2: text "2. Install Packages"
      p:
        text "Once configured, install packages as usual. Nimble will discover them through NimPack:"

      pre:
        code(class = "language-bash"): text "nimble install karax"

      p:
        text "NimPack serves pre-built tarballs, so installs are fast and do not depend on GitHub availability."

      h2: text "3. Verify the Endpoint"
      p:
        text "You can inspect the raw package list at any time:"

      pre:
        code(class = "language-bash"): text "curl https://nimpack.org/packages.json | head -n 20"

      h2: text "4. Package List Format"
      p:
        text "The "
        code: text "/packages.json"
        text " endpoint returns the standard nimble package list format. Each entry uses "
        code: text "method: \"download\""
        text " with a URL pointing back to this server's "
        code: text "/download/:name/:version"
        text " endpoint."

      h2: text "Tips"
      ul:
        li: text "Nimble merges package lists, so you can keep the official list alongside NimPack if desired."
        li: text "Set a GitHub token in cfg.yaml to increase rate limits for the background fetcher."
        li: text "Use the download endpoint directly to fetch specific versions without nimble."

proc renderBar(items: seq[BarItem], maxVal: int, colorClass: string): VNode =
  result = buildHtml(tdiv(class = "bar-chart")):
    for it in items:
      let pct = if maxVal > 0: int(it.count.float / maxVal.float * 100.0) else: 0
      tdiv(class = "bar-row"):
        tdiv(class = "bar-label"):
          text it.label
        tdiv(class = "bar-track"):
          tdiv(class = cstring("bar-fill " & colorClass), style = style(width, cstring($pct & "%")))
        tdiv(class = "bar-value"):
          text $it.count

proc buildBars(downloads: seq[TopDownloaded]): (seq[BarItem], int) =
  var maxVal = 1
  for it in downloads:
    if it.downloads > maxVal: maxVal = it.downloads
  var bars: seq[BarItem] = @[]
  for it in downloads:
    bars.add(BarItem(label: it.name, count: it.downloads))
  result = (bars, maxVal)

proc buildBars(authors: seq[TopAuthor]): (seq[BarItem], int) =
  var maxVal = 1
  for it in authors:
    if it.packageCount > maxVal: maxVal = it.packageCount
  var bars: seq[BarItem] = @[]
  for it in authors:
    bars.add(BarItem(label: it.name, count: it.packageCount))
  result = (bars, maxVal)

proc buildBars(licenses: seq[LicenseItem]): (seq[BarItem], int) =
  var maxVal = 1
  for it in licenses:
    if it.count > maxVal: maxVal = it.count
  var bars: seq[BarItem] = @[]
  for it in licenses:
    bars.add(BarItem(label: it.license, count: it.count))
  result = (bars, maxVal)

proc buildBars(hosts: seq[HostItem]): (seq[BarItem], int) =
  var maxVal = 1
  for it in hosts:
    if it.count > maxVal: maxVal = it.count
  var bars: seq[BarItem] = @[]
  for it in hosts:
    bars.add(BarItem(label: it.host, count: it.count))
  result = (bars, maxVal)

proc renderStats(): VNode =
  result = buildHtml(tdiv):
    tdiv(class = "stats-container"):
      h1: text "Registry Statistics"

      tdiv(class = "stats-metrics"):
        tdiv(class = "stat-card"):
          tdiv(class = "stat-number"):
            text $statsData.totalPackages
          tdiv(class = "stat-label"):
            text "Packages"
        tdiv(class = "stat-card"):
          tdiv(class = "stat-number"):
            text $statsData.totalAuthors
          tdiv(class = "stat-label"):
            text "Authors"
        tdiv(class = "stat-card"):
          tdiv(class = "stat-number"):
            text $statsData.totalDownloads
          tdiv(class = "stat-label"):
            text "Downloads"

      tdiv(class = "stats-grid"):
        tdiv(class = "stats-panel"):
          h2: text "Top Downloaded"
          if statsData.topDownloaded.len == 0:
            p(class = "empty-text"): text "No download data yet."
          else:
            let (bars, maxDl) = buildBars(statsData.topDownloaded)
            renderBar(bars, maxDl, "bar-downloads")

        tdiv(class = "stats-panel"):
          h2: text "Top Authors"
          if statsData.topAuthors.len == 0:
            p(class = "empty-text"): text "No author data yet."
          else:
            let (bars, maxAuth) = buildBars(statsData.topAuthors)
            renderBar(bars, maxAuth, "bar-authors")

        tdiv(class = "stats-panel"):
          h2: text "Licenses"
          if statsData.licenses.len == 0:
            p(class = "empty-text"): text "No license data yet."
          else:
            let (bars, maxLic) = buildBars(statsData.licenses)
            renderBar(bars, maxLic, "bar-licenses")

        tdiv(class = "stats-panel"):
          h2: text "Hosts"
          if statsData.hosts.len == 0:
            p(class = "empty-text"): text "No host data yet."
          else:
            let (bars, maxHost) = buildBars(statsData.hosts)
            renderBar(bars, maxHost, "bar-hosts")

        tdiv(class = "stats-panel stats-panel-wide"):
          h2: text "Top Tags"
          if statsData.topTags.len == 0:
            p(class = "empty-text"): text "No tag data yet."
          else:
            tdiv(class = "tag-cloud"):
              for it in statsData.topTags:
                span(class = "tag-pill"):
                  text it.tag & " (" & $it.count & ")"

        tdiv(class = "stats-panel stats-panel-wide"):
          h2: text "Largest Packages"
          if statsData.largestPackages.len == 0:
            p(class = "empty-text"): text "No package size data yet."
          else:
            p(class = "help-text"):
              text "Packages sorted by total tarball size across all versions. Large tarballs often indicate bundled binaries, vendored third-party dependencies, or test data not kept under a tests/ directory — all worth investigating."
            tdiv(class = "largest-packages-list"):
              for it in statsData.largestPackages:
                tdiv(class = "largest-package-item"):
                  a(href = cstring(it.url), class = "largest-package-name", target = cstring"_blank"):
                    text it.name
                  span(class = "largest-package-meta"):
                    text formatSize(it.totalSize) & " · " & $it.versionCount & " version" & (if it.versionCount >
                        1: "s" else: "")

        tdiv(class = "stats-panel stats-panel-wide"):
          h2: text "Repo Not Found (" & $statsData.repoNotFoundCount & ")"
          if statsData.repoNotFound.len == 0:
            p(class = "empty-text"): text "All repositories are reachable."
          else:
            p(class = "help-text"):
              text "These packages reference repositories that no longer exist. A patch is available to remove them from the upstream packages.json."
            tdiv(class = "failed-packages-list"):
              for it in statsData.repoNotFound:
                tdiv(class = "failed-package-item"):
                  a(href = cstring(it.url), class = "failed-package-link", target = cstring"_blank"):
                    text it.name
            tdiv(class = "patch-section"):
              p(class = "patch-label"): text "Apply patch to packages.json:"
              tdiv(class = "patch-command"):
                code: text "curl -sL https://nimpack.org/packages.json.patch | git apply"
                button(class = "copy-btn", onclick = proc() = copyPatchCommand(
                    "curl -sL https://nimpack.org/packages.json.patch | git apply")):
                  text "Copy"
                if patchCopyFeedback != "":
                  span(class = "copy-feedback"): text patchCopyFeedback

proc postRender() =
  if readmeContent != "":
    let el = kdom.document.getElementById(cstring"readme-content")
    if el != nil:
      let lowerName = readmeFilename.toLowerAscii()
      # Default to Markdown for empty filenames (legacy data before filename tracking)
      let isMarkdown = readmeFilename.len == 0 or
                       lowerName.endsWith(".md") or lowerName.endsWith(".markdown") or
                       lowerName.endsWith(".mkd") or lowerName.endsWith(".mdown")
      let purify = cast[JsObject](kdom.window)["DOMPurify"]

      if isMarkdown:
        let marked = cast[JsObject](kdom.window)["marked"]
        if marked != nil and purify != nil:
          let rawHtml = marked.parse(cstring(readmeContent))
          let safeHtml = purify.sanitize(rawHtml)
          cast[JsObject](el)["innerHTML"] = safeHtml
          let prism = cast[JsObject](kdom.window)["Prism"]
          if prism != nil:
            discard prism.highlightAllUnder(el)
      else:
        # Plain text / RST / unknown format — render as preformatted text
        let escaped = readmeContent.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        let note = if lowerName.endsWith(".rst"):
          "<p class=\"readme-note\">Note: reStructuredText rendering is not fully supported. Displaying as plain text.</p>"
        else:
          ""
        cast[JsObject](el)["innerHTML"] = cstring(note & "<pre class=\"readme-plain\"><code>" & escaped & "</code></pre>")

proc render(): VNode =
  buildHtml(tdiv(class = "app")):
    header(class = "site-header"):
      tdiv(class = "header-inner"):
        a(href = "/", class = "logo"): text "NimPack"
        nav(class = "header-nav"):
          a(href = "/stats", class = "nav-link"): text "Stats"
          a(href = "/help", class = "nav-link"): text "Help"
          a(href = "/llm.txt", class = "nav-link"):
            img(src = cstring"/robot.svg", alt = cstring"llm.txt", width = cstring"16", height = cstring"16")
            text "llm.txt"
          a(href = "https://github.com/nim-community/nsheep", class = "github-link", target = cstring"_blank"):
            svg(viewBox = cstring"0 0 16 16", width = cstring"20", height = cstring"20", fill = cstring"currentColor"):
              path(d = cstring"M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z")
          button(class = "theme-toggle", ariaLabel = cstring(
              if darkMode: "Switch to light mode" else: "Switch to dark mode"), onclick = proc() = toggleDarkMode()):
            text (if darkMode: "☀" else: "☾")
    main(class = "site-main"):
      case currentView
      of vHome: renderHome()
      of vPackage: renderPackage()
      of vHelp: renderHelp()
      of vStats: renderStats()
      of vNotFound: renderNotFound()

# --- Helpers ---

# --- Bootstrap ---

setRenderer render, cstring"ROOT", postRender
loadTheme()
kdom.window.addEventListener("popstate", onPopState)
kdom.document.addEventListener("click", onLinkClick)
kdom.document.addEventListener("keydown", onKeyDown)
updateRoute()
case currentView
of vHome:
  fetchSummaries()
of vPackage:
  fetchDetail(currentPkgName)
of vHelp:
  discard
of vStats:
  fetchStats()
of vNotFound:
  discard
