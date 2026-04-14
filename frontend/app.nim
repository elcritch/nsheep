import karax / [vdom, kdom, karax, karaxdsl, vstyles, jjson, kajax]
import strutils, jsffi

# --- Types ---

type
  View = enum
    vHome, vPackage, vNotFound

  PackageSummary = object
    name: string
    description: string
    author: string
    latestVersion: string
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

# --- Forward Declarations ---

proc fetchSummaries()
proc fetchDetail(name: string)
proc fetchValidations(name: string)
proc applyFilters()

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

proc fetchJson(url: cstring, cont: proc(data: JsonNode)) =
  let req = newRequest()
  req.open("GET", url, true)
  req.statechange proc() =
    let r = cast[JsObject](req)
    if cast[int](r.readyState) == 4:
      if cast[int](r.status) == 200:
        cont(parse(cast[cstring](r.responseText)))
      else:
        loading = false
        redraw()
  req.send("")

proc fetchSummaries() =
  loading = true
  fetchJson(cstring"/api/v1/packages") do (data: JsonNode):
    loading = false
    summaries = @[]
    for item in data:
      summaries.add(PackageSummary(
        name: $item["name"].getStr(),
        description: if item.hasField("description"): $item["description"].getStr() else: "",
        author: if item.hasField("author"): $item["author"].getStr() else: "",
        latestVersion: if item.hasField("latestVersion"): $item["latestVersion"].getStr() else: "",
        tags: if item.hasField("tags"):
          (var ts: seq[string] = @[]; for t in item["tags"]: ts.add($t.getStr()); ts)
        else: @[]
      ))
    applyFilters()
    redraw()

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

proc fetchDetail(name: string) =
  loading = true
  detail = PackageDetail()  # clear old
  validations = @[]
  fetchJson(cstring("/api/v1/packages/" & name)) do (data: JsonNode):
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
    redraw()

# --- Event Handlers ---

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

proc onSearchInput(ev: Event; target: VNode) =
  let val = cast[JsObject](ev.target)["value"]
  searchQuery = $cast[cstring](val)
  applyFilters()
  redraw()

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

# --- Views ---

proc renderHome(): VNode =
  buildHtml(tdiv(class="page home")):
    tdiv(class="search-wrap"):
      input(class="search", `type`="text", placeholder="Search packages…", value=cstring(searchQuery)):
        proc oninput(ev: Event; target: VNode) = onSearchInput(ev, target)
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
      tdiv(class="status"): text "Loading…"
    elif filtered.len == 0:
      tdiv(class="status"): text "No packages found."
    else:
      tdiv(class="package-list"):
        for s in filtered:
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

proc renderPackage(): VNode =
  buildHtml(tdiv(class="page package-detail")):
    a(href="#/", class="back-link"): text "← All packages"
    if loading:
      tdiv(class="status"): text "Loading…"
    else:
      header(class="detail-header"):
        h1: text detail.name
        if detail.versions.len > 0:
          span(class="version-badge"): text detail.versions[0].version
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
    main(class="site-main"):
      case currentView
      of vHome: renderHome()
      of vPackage: renderPackage()
      of vNotFound: renderNotFound()

# --- Helpers ---

# --- Bootstrap ---

setRenderer render
kdom.window.addEventListener("hashchange", onHashChange)
updateRoute()
case currentView
of vHome:
  fetchSummaries()
of vPackage:
  fetchDetail(currentPkgName)
of vNotFound:
  discard
