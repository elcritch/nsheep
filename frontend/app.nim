import karax / [vdom, kdom, karax, karaxdsl, jjson, kajax, localstorage]
import strutils, jsffi, algorithm

# --- Types ---

type
  View = enum
    vHome, vPackage, vNotFound

  SortOrder = enum
    soNameAsc, soNameDesc, soUpdatedDesc

  PackageSummary = object
    name: string
    description: string
    author: string
    latestVersion: string
    latestVersionPublishedAt: string
    tags: seq[string]

  VersionInfo = object
    version: string
    size: int
    checksum: string
    publishedAt: string

  ValidationResult = object
    version: string
    success: bool
    testedAt: string

  PackageDetail = object
    name: string
    description: string
    author: string
    license: string
    url: string
    tags: seq[string]
    versions: seq[VersionInfo]

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
  darkMode = false
  readmeContent = ""
  totalDownloads = 0
  displayedCount = 0
  searchTimer: JsObject = nil
  errorMessage = ""
  currentSort = soNameAsc
  totalPackages = 0
  currentPage = 1

# --- Forward Declarations ---

proc fetchSummaries(page: int = 1)
proc fetchDetail(name: string)
proc fetchValidations(name: string)
proc fetchReadme(name: string)
proc fetchDownloads(name: string)
proc applyFilters()
proc clearAllFilters()

# --- Routing ---

proc parseHash(): View =
  let h = $kdom.window.location.hash
  if h == "" or h == "#" or h == "#/":
    result = vHome
  elif h.startsWith("#/package/"):
    result = vPackage
    currentPkgName = h[10..^1]
  else:
    result = vNotFound

proc updateRoute() =
  currentView = parseHash()

proc setHash(hash: cstring) =
  kdom.window.location.hash = hash

proc onHashChange(ev: Event) =
  updateRoute()
  case currentView
  of vHome:
    if summaries.len == 0:
      fetchSummaries()
    else:
      redraw()
  of vPackage:
    fetchDetail(currentPkgName)
  of vNotFound:
    redraw()

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
  let url = "/api/v1/packages?page=" & $page & "&limit=" & $pageSize
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
            latestVersionPublishedAt: if item.hasField("latestVersionPublishedAt"): $item["latestVersionPublishedAt"].getStr() else: "",
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

proc fetchValidations(name: string) =
  fetchJson(cstring("/api/v1/packages/" & name & "/validations")) do (data: JsonNode):
    validations = @[]
    for item in data:
      validations.add(ValidationResult(
        version: $item["version"].getStr(),
        success: item["success"].getBool(),
        testedAt: $item["testedAt"].getStr()
      ))
    redraw()

proc fetchReadme(name: string) =
  fetchText(cstring("/api/v1/packages/" & name & "/readme")) do (text: string):
    readmeContent = text
    redraw()

proc fetchDownloads(name: string) =
  fetchJson(cstring("/api/v1/packages/" & name & "/downloads")) do (data: JsonNode):
    totalDownloads = 0
    for item in data:
      totalDownloads += item["downloads"].getInt()
    redraw()

proc fetchDetail(name: string) =
  loading = true
  errorMessage = ""
  detail = PackageDetail()  # clear old
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
            publishedAt: $v["publishedAt"].getStr()
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
  of soNameAsc:
    algorithm.sort(filtered) do (a, b: PackageSummary) -> int:
      cmp(a.name.toLowerAscii(), b.name.toLowerAscii())
  of soNameDesc:
    algorithm.sort(filtered) do (a, b: PackageSummary) -> int:
      cmp(b.name.toLowerAscii(), a.name.toLowerAscii())
  of soUpdatedDesc:
    algorithm.sort(filtered) do (a, b: PackageSummary) -> int:
      if a.latestVersionPublishedAt == "" and b.latestVersionPublishedAt == "":
        cmp(a.name.toLowerAscii(), b.name.toLowerAscii())
      elif a.latestVersionPublishedAt == "":
        1
      elif b.latestVersionPublishedAt == "":
        -1
      else:
        cmp(b.latestVersionPublishedAt, a.latestVersionPublishedAt)

proc applyFilters() =
  let q = searchQuery.toLowerAscii()
  filtered = @[]
  for s in summaries:
    var matches = true
    if q != "":
      matches = s.name.toLowerAscii().contains(q) or s.description.toLowerAscii().contains(q)
    if matches and activeAuthor != "":
      matches = s.author == activeAuthor
    if matches and activeTag != "":
      var hasTag = false
      for t in s.tags:
        if t == activeTag:
          hasTag = true
          break
      matches = hasTag
    if matches:
      filtered.add(s)
  sortFiltered()
  displayedCount = filtered.len

# --- Event Handlers ---

proc onSearchInput(ev: Event; target: VNode) =
  let val = cast[JsObject](ev.target)["value"]
  searchQuery = $cast[cstring](val)
  if searchTimer != nil:
    discard cast[JsObject](kdom.window).clearTimeout(searchTimer)
  searchTimer = cast[JsObject](kdom.window.setTimeout(proc() =
    applyFilters()
    redraw()
    searchTimer = nil
  , 150))

proc clickAuthor(author: string) =
  activeAuthor = author
  applyFilters()
  setHash(cstring"#/")

proc clickTag(tag: string) =
  activeTag = tag
  applyFilters()
  setHash(cstring"#/")

proc clearAuthor() =
  activeAuthor = ""
  applyFilters()
  redraw()

proc clearTag() =
  activeTag = ""
  applyFilters()
  redraw()

proc clearAllFilters() =
  searchQuery = ""
  activeAuthor = ""
  activeTag = ""
  applyFilters()
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
  buildHtml(tdiv(class="page home")):
    tdiv(class="search-wrap"):
      input(class="search", id="search-input", `type`="text", placeholder="Search packages…", value=cstring(searchQuery)):
        proc oninput(ev: Event; target: VNode) = onSearchInput(ev, target)
      select(class="sort-select", onchange=proc(ev: Event; target: VNode) =
        let val = $cast[cstring](cast[JsObject](ev.target)["value"])
        case val
        of "name-desc": currentSort = soNameDesc
        of "updated-desc": currentSort = soUpdatedDesc
        else: currentSort = soNameAsc
        applyFilters()
        redraw()
      ):
        option(value="name-asc", selected=currentSort == soNameAsc): text "Name A–Z"
        option(value="name-desc", selected=currentSort == soNameDesc): text "Name Z–A"
        option(value="updated-desc", selected=currentSort == soUpdatedDesc): text "Recently updated"
    if activeAuthor != "" or activeTag != "":
      tdiv(class="active-filters"):
        if activeAuthor != "":
          span(class="filter-badge author-badge"):
            text ("Author: " & activeAuthor)
            button(class="clear-btn", onclick=proc() = clearAuthor()): text "×"
        if activeTag != "":
          span(class="filter-badge tag-badge"):
            text ("Tag: " & activeTag)
            button(class="clear-btn", onclick=proc() = clearTag()): text "×"
        if activeAuthor != "" or activeTag != "":
          button(class="clear-all", onclick=proc() = clearAllFilters()): text "Clear all"
    if loading:
      tdiv(class="home-skeleton"):
        tdiv(class="search-wrap"):
          tdiv(class="skeleton sk-search")
        tdiv(class="package-list"):
          for i in 1..5:
            article(class="package-item"):
              header(class="package-header"):
                tdiv(class="skeleton sk-title")
                tdiv(class="skeleton sk-badge")
              tdiv(class="package-desc"):
                tdiv(class="skeleton sk-desc")
              tdiv(class="package-meta"):
                tdiv(class="skeleton sk-meta")
    elif errorMessage != "":
      tdiv(class="error-status"):
        p: text errorMessage
        button(class="retry-btn", onclick=proc() = fetchSummaries()): text "Retry"
    elif filtered.len == 0:
      tdiv(class="status"): text "No packages found."
    else:
      tdiv(class="package-list", id="package-list"):
        for i in 0..<displayedCount:
          let s = filtered[i]
          article(class="package-item"):
            header(class="package-header"):
              h2:
                a(href=cstring("#/package/" & s.name)): text s.name
              if s.latestVersion != "":
                span(class="version-badge"): text s.latestVersion
            if s.description != "":
              p(class="package-desc"): text s.description
            if s.author != "":
              p(class="package-meta"):
                text "By "
                let author = s.author
                a(href="#/", class="inline-link", onclick=proc() = clickAuthor(author)): text author
      if summaries.len < totalPackages:
        tdiv(class="load-more-wrap"):
          button(class="load-more-btn", disabled=loading, onclick=proc() =
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

proc loadTheme() =
  let stored = $localstorage.getItem(cstring"nsheep-theme")
  if stored == "dark":
    darkMode = true
  elif stored == "light":
    darkMode = false
  else:
    darkMode = kdom.window.matchMedia(cstring"(prefers-color-scheme: dark)").matches
  kdom.document.documentElement.setAttribute("data-theme",
    if darkMode: cstring"dark" else: cstring"light")

proc toggleDarkMode() =
  darkMode = not darkMode
  let theme = if darkMode: cstring"dark" else: cstring"light"
  localstorage.setItem(cstring"nsheep-theme", theme)
  kdom.document.documentElement.setAttribute("data-theme", theme)
  redraw()

proc renderPackage(): VNode =
  buildHtml(tdiv(class="page package-detail")):
    a(href="#/", class="back-link"): text "← All packages"
    if loading:
      tdiv(class="package-skeleton"):
        tdiv(class="back-link"):
          tdiv(class="skeleton sk-back")
        header(class="detail-header"):
          tdiv(class="skeleton sk-header-title")
          tdiv(class="skeleton sk-badge")
        tdiv(class="install-command"):
          tdiv(class="skeleton sk-install-code")
          tdiv(class="skeleton sk-install-btn")
        tdiv(class="detail-desc"):
          tdiv(class="skeleton sk-line")
          tdiv(class="skeleton sk-line sk-mt05")
        dl(class="detail-meta"):
          for i in 1..3:
            dt: tdiv(class="skeleton sk-meta-label")
            dd: tdiv(class="skeleton sk-meta-value")
        tdiv(class="tags"):
          for i in 1..3:
            tdiv(class="skeleton sk-pill")
        section(class="versions"):
          h2:
            tdiv(class="skeleton sk-title sk-w80")
          for i in 1..4:
            tdiv(class="version-row"):
              tdiv(class="skeleton sk-version-name")
              tdiv(class="skeleton sk-version-size")
              tdiv(class="skeleton sk-version-badge")
              tdiv(class="skeleton sk-download")
    elif errorMessage != "":
      tdiv(class="error-status"):
        p: text errorMessage
        button(class="retry-btn", onclick=proc() = fetchDetail(currentPkgName)): text "Retry"
    else:
      header(class="detail-header"):
        h1: text detail.name
        if detail.versions.len > 0:
          span(class="version-badge"): text detail.versions[0].version
        if totalDownloads > 0:
          span(class="download-count"): text ($totalDownloads & " downloads")
      tdiv(class="install-command"):
        code: text ("nimble install " & detail.name)
        button(class="copy-btn", onclick=proc() = copyInstallCommand("nimble install " & detail.name)):
          if copyFeedback != "" and detail.name == currentPkgName:
            text copyFeedback
          else:
            text "Copy"
      if detail.description != "":
        p(class="detail-desc"): text detail.description
      dl(class="detail-meta"):
        if detail.author != "":
          dt: text "Author"
          dd:
            let author = detail.author
            a(href="#/", class="inline-link", onclick=proc() = clickAuthor(author)): text author
        if detail.license != "":
          dt: text "License"
          dd: text detail.license
        if detail.url != "":
          dt: text "URL"
          dd:
            a(href=cstring(detail.url), target="_blank", rel="noopener"): text detail.url
      if detail.tags.len > 0:
        tdiv(class="tags"):
          for t in detail.tags:
            let tagName = t
            a(href="#/", class="tag", onclick=proc() = clickTag(tagName)): text tagName
      section(class="versions"):
        h2: text "Versions"
        for v in detail.versions:
          tdiv(class="version-row"):
            span(class="version-name"): text v.version
            span(class="version-size"): text formatSize(v.size)
            var vstatus = ""
            var vclass = ""
            for val in validations:
              if val.version == v.version:
                vstatus = if val.success: "Passed" else: "Failed"
                vclass = if val.success: "val-pass" else: "val-fail"
                break
            if vstatus != "":
              span(class=cstring("validation-badge " & vclass)): text vstatus
            a(
              href=cstring("/download/" & detail.name & "/" & v.version),
              class="download-link",
              download=""
            ): text "Download"
      if readmeContent != "":
        section(class="readme"):
          h2: text "README"
          pre: text readmeContent

proc renderNotFound(): VNode =
  buildHtml(tdiv(class="page notfound")):
    h1: text "404"
    p: text "Page not found."
    a(href="#/"): text "Return home"

proc render(): VNode =
  buildHtml(tdiv(class="app")):
    header(class="site-header"):
      tdiv(class="header-inner"):
        a(href="#/", class="logo"): text "NSheep"
        button(class="theme-toggle", ariaLabel=cstring(if darkMode: "Switch to light mode" else: "Switch to dark mode"), onclick=proc() = toggleDarkMode()):
          text (if darkMode: "☀" else: "☾")
    main(class="site-main"):
      case currentView
      of vHome: renderHome()
      of vPackage: renderPackage()
      of vNotFound: renderNotFound()

# --- Helpers ---

# --- Bootstrap ---

setRenderer render
loadTheme()
kdom.window.addEventListener("hashchange", onHashChange)
kdom.document.addEventListener("keydown", onKeyDown)
updateRoute()
case currentView
of vHome:
  fetchSummaries()
of vPackage:
  fetchDetail(currentPkgName)
of vNotFound:
  discard
