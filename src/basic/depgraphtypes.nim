
import std / [sets, paths, files, dirs, tables, os, strutils, streams, json, jsonutils, algorithm]

import sattypes, context, dependencies, gitops, reporters, nimbleparser, pkgurls, versions


type
  DepGraph* = object
    nodes*: seq[DepConstraint]
    reqs*: seq[Requirements]
    packageToDependency*: Table[PkgUrl, int]
    ondisk*: OrderedTable[string, Path] # URL -> dirname mapping
    reqsByDeps*: Table[Requirements, int]

type
  TraversalMode* = enum
    AllReleases,
    CurrentCommit

const
  FileWorkspace* = "file://./"

proc `[]`*(g: DepGraph, idx: int): DepConstraint =
  g.nodes[idx]

proc `[]`*(g: var DepGraph, idx: int): var DepConstraint =
  g.nodes[idx]

proc toJsonHook*(vid: VarId): JsonNode = toJson($(int(vid)))
proc toJsonHook*(p: Path): JsonNode = toJson($(p))

proc toJsonHook*(t: Table[PkgUrl, int]): JsonNode =
  result = newJObject()
  for k, v in t: result[$k] = % v

proc toJsonHook*(t: Table[Requirements, int], opt: ToJsonOptions): JsonNode =
  result = newJArray()
  for k, v in t:
    # result.add(%* {"req": toJson(k), "idx": toJson(v) })
    result.add(%* [toJson(k, opt), toJson(v, opt)] )

proc defaultReqs*(): seq[Requirements] =
  @[Requirements(deps: @[], vid: NoVar), Requirements(status: HasUnknownNimbleFile, vid: NoVar)]

proc toJsonHook*(d: DepGraph, opt: ToJsonOptions): JsonNode =
  result = newJObject()
  result["nodes"] = toJson(d.nodes, opt)
  result["reqs"] = toJson(d.reqs, opt)
  result["packageToDependency"] = toJson(d.packageToDependency, opt)
    # result["reqsByDeps"] = toJson(d.reqsByDeps)

proc dumpJson*(d: DepGraph, filename: string, full = true, pretty = true) =
  let jn = toJson(d, ToJsonOptions(enumMode: joptEnumString))
  if pretty:
    writeFile(filename, pretty(jn))
  else:
    writeFile(filename, $(jn))

proc findNimbleFile*(nimbleFile: Path): seq[Path] =
  if fileExists(nimbleFile):
    result.add nimbleFile

proc findNimbleFile*(dir: Path, projectName: string): seq[Path] =
  var nimbleFile = dir / Path(projectName & ".nimble")
  result = findNimbleFile(nimbleFile)
  if result.len() == 0:
    for file in walkFiles($dir / "*.nimble"):
      result.add Path(file)
  debug "findNimbleFile:search:", " name: " & projectName & " found: " & $result

proc findNimbleFile*(dep: DepConstraint | Dependency): seq[Path] =
  doAssert(dep.info.ondisk.string != "", "Package ondisk must be set before findNimbleFile can be called! Package: " & $(dep))
  result = findNimbleFile(dep.info.ondisk, dep.pkg.projectName & ".nimble")

type
  PackageAction* = enum
    DoNothing, DoClone

proc pkgUrlToDirname*(g: var DepGraph; d: DepConstraint): (Path, PackageAction) =
  # XXX implement namespace support here
  # var dest = Path g.ondisk.getOrDefault(d.pkg.url)
  var dest = Path ""
  if dest.string.len == 0:
    if d.info.isTopLevel:
      dest = context().workspace
    else:
      let depsDir =
        if d.info.isRoot: context().workspace
        else: context().depsDir
      dest = depsDir / Path d.pkg.projectName
  result = (dest, if dirExists(dest): DoNothing else: DoClone)

proc toDestDir*(g: DepGraph; d: DepConstraint): Path =
  result = d.info.ondisk

proc enrichVersionsViaExplicitHash*(versions: var seq[DepVersion]; x: VersionInterval) =
  let commit = extractSpecificCommit(x)
  if not commit.isEmpty():
    for ver in versions:
      if ver.vtag.commit() == commit:
        return
    versions.add initDepVersion(Version"", commit) 

iterator allNodes*(g: DepGraph): lent DepConstraint =
  for i in 0 ..< g.nodes.len: yield g.nodes[i]

iterator allActiveNodes*(g: DepGraph): lent DepConstraint =
  for i in 0 ..< g.nodes.len:
    if g.nodes[i].active:
      yield g.nodes[i]

iterator toposorted*(g: DepGraph): lent DepConstraint =
  for i in countdown(g.nodes.len-1, 0):
    yield g.nodes[i]

proc findDependencyForDep*(g: DepGraph; dep: PkgUrl): int {.inline.} =
  assert g.packageToDependency.hasKey(dep), $(dep, g.packageToDependency)
  result = g.packageToDependency.getOrDefault(dep)

iterator directDependencies*(g: DepGraph; d: DepConstraint): lent DepConstraint =
  if d.activeVersion >= 0 and d.activeVersion < d.versions.len:
    let deps {.cursor.} = g.reqs[d.versions[d.activeVersion].req].deps
    for dep in deps:
      let idx = findDependencyForDep(g, dep[0])
      yield g.nodes[idx]

proc getCfgPath*(g: DepGraph; d: DepConstraint): lent CfgPath =
  result = CfgPath g.reqs[d.versions[d.activeVersion].req].srcDir

proc bestNimVersion*(g: DepGraph): Version =
  result = Version""
  for n in allNodes(g):
    if n.active and g.reqs[n.versions[n.activeVersion].req].nimVersion != Version"":
      let v = g.reqs[n.versions[n.activeVersion].req].nimVersion
      if v > result: result = v

proc readOnDisk(result: var DepGraph) =
  let configFile = context().workspace / AtlasWorkspace
  var f = newFileStream($configFile, fmRead)
  if f == nil:
    return
  try:
    let j = parseJson(f, $configFile)
    let g = j["graph"]
    let n = g.getOrDefault("nodes")
    if n.isNil: return
    let nodes = jsonTo(n, typeof(result.nodes))
    for n in nodes:
      # result.ondisk[n.pkg.url] = n.ondisk
      if dirExists(n.info.ondisk):
        if n.info.isRoot:
          if not result.packageToDependency.hasKey(n.pkg):
            result.packageToDependency[n.pkg] = result.nodes.len
            let info = DependencyInfo(isRoot: true, isTopLevel: n.info.isTopLevel)
            result.nodes.add DepConstraint(pkg: n.pkg, info: info, activeVersion: -1)
  except:
    warn configFile, "couldn't load graph from: " & $configFile

proc createGraph*(s: PkgUrl): DepGraph =
  result = DepGraph(nodes: @[],
    reqs: defaultReqs())
  result.packageToDependency[s] = result.nodes.len
  let info = DependencyInfo(isRoot: true, isTopLevel: true)
  result.nodes.add DepConstraint(pkg: s, versions: @[], info: info, activeVersion: -1)
  readOnDisk(result)

proc createGraphFromWorkspace*(): DepGraph =
  result = DepGraph(nodes: @[], reqs: defaultReqs())
  let configFile = context().workspace / AtlasWorkspace
  var f = newFileStream($configFile, fmRead)
  if f == nil:
    error configFile, "cannot open: " & $configFile
    return

  try:
    let j = parseJson(f, $configFile)
    let g = j["graph"]

    result.nodes = jsonTo(g["nodes"], typeof(result.nodes))
    result.reqs = jsonTo(g["reqs"], typeof(result.reqs))

    for i, n in mpairs(result.nodes):
      result.packageToDependency[n.pkg] = i
  except:
    warn configFile, "couldn't load graph from: " & $configFile

proc copyFromDisk*(w: DepConstraint; destDir: Path): (CloneStatus, string) =
  var dir = w.pkg.url
  if dir.startsWith(FileWorkspace):
    dir = $context().workspace / dir.substr(FileWorkspace.len)
  #template selectDir(a, b: string): string =
  #  if dirExists(a): a else: b

  #let dir = selectDir(u & "@" & w.commit, u)
  if w.info.isTopLevel:
    result = (Ok, "")
  elif dirExists(dir):
    info destDir, "cloning: " & dir
    copyDir(dir, $destDir)
    result = (Ok, "")
  else:
    result = (NotFound, dir)
  #writeFile destDir / ThisVersion, w.commit
  #echo "WRITTEN ", destDir / ThisVersion

proc traverseRelease(dep: var Dependency, nimbleCtx: NimbleContext;
                     origin: CommitOrigin; release: VersionTag;
                     lastNimbleContents: var string):  SecureHash =
  debug "traverseRelease", "name: " & graph[idx].pkg.projectName & " origin: " & $origin & " release: " & $release
  let nimbleFiles = findNimbleFile(graph[idx])
  var packageVer = DepVersion(vtag: release, req: EmptyReqs, vid: NoVar)
  var badNimbleFile = false
  if nimbleFiles.len() != 1:
    trace "traverseRelease", "skipping: nimble file not found or unique"
    packageVer.req = UnknownReqs
  else:
    let nimbleFile = nimbleFiles[0]
    when (NimMajor, NimMinor, NimPatch) == (2, 0, 0):
      var nimbleContents = readFile($nimbleFile)
    else:
      let nimbleContents = readFile($nimbleFile)
    if lastNimbleContents == nimbleContents:
      debug "traverseRelease", "req same as last"
      packageVer.req = graph[idx].versions[^1].req
    else:
      let reqResult = parseNimbleFile(nimbleCtx, nimbleFile, context().overrides)
      if origin == FromNimbleFile and packageVer.version == Version"" and reqResult.version != Version"":
        packageVer.version = reqResult.version
        debug "traverseRelease", "set version: " & $reqResult.version

      let reqIdx = graph.reqsByDeps.getOrDefault(reqResult, -1)
      if reqIdx == -1:
        packageVer.req = graph.reqs.len
        graph.reqsByDeps[reqResult] = packageVer.req
        graph.reqs.add reqResult
        debug "traverseRelease", "add req: " & $reqResult
      else:
        debug "traverseRelease", "set reqIdx: " & $reqIdx
        packageVer.req = reqIdx

      lastNimbleContents = ensureMove nimbleContents

    if graph.reqs[packageVer.req].status == Normal:
      for dep, interval in items(graph.reqs[packageVer.req].deps):
        var depIdx = graph.packageToDependency.getOrDefault(dep, -1)
        if depIdx == -1:
          depIdx = graph.nodes.len
          graph.packageToDependency[dep] = depIdx
          # graph.nodes.add Dependency(pkg: dep, versions: @[], isRoot: idx == 0, activeVersion: -1)
          debug "traverseRelease", "depIdx: " & $depIdx & " adding dep: " & $dep
          graph.nodes.add Dependency(pkg: dep, versions: @[], isRoot: depIdx == 0, activeVersion: -1)
          enrichVersionsViaExplicitHash graph[depIdx].versions, interval
        else:
          graph[depIdx].isRoot = graph[depIdx].isRoot or idx == 0
          enrichVersionsViaExplicitHash graph[depIdx].versions, interval
    else:
      badNimbleFile = true

  if origin == FromNimbleFile and (packageVer.version == Version"" or badNimbleFile):
    discard "not a version we model in the dependency graph"
  else:
    graph[idx].versions.add ensureMove packageVer

proc loadDependency*(
    path: Path,
    mode: TraversalMode;
    versions: seq[VersionTag];
    nimbleCommits: seq[VersionTag]
): Dependency =
  let currentCommit = currentGitCommit(path, Error)
  trace "depgraphs:releases", "currentCommit: " & $currentCommit
  if currentCommit.isEmpty():
    warn "loadDependency", "unable to find git current version at " & $path
    result.versions.add VersionTag(v: Version"#head", c: initCommitHash("", FromHead))
  else:
    case mode
    of AllReleases:
      try:
        var uniqueCommits = initHashSet[CommitHash]()
        for version in versions:
          if version.version == Version"" and
              not version.commit.isEmpty() and
              not uniqueCommits.containsOrIncl(version.commit):
            if checkoutGitCommit(path, version.commit):
              result.versions.add VersionTag(v: Version"", c: version.commit)
              assert version.commit.orig == FromDep, "maybe this needs to be overriden like before"
        let tags = collectTaggedVersions(path)
        for tag in tags:
          if not uniqueCommits.containsOrIncl(tag.c):
            if checkoutGitCommit(path, tag.c):
              result.versions.add tag
              assert tag.commit.orig == FromGitTag, "maybe this needs to be overriden like before"
            else:
              error "loadDependency", "missing tag version " & $tag & " at " & $path
        for tag in nimbleCommits:
          if not uniqueCommits.containsOrIncl(tag.c):
            if checkoutGitCommit(path, tag.c):
              result.versions.add VersionTag(v: Version"", c: tag.c)
              assert tag.commit.orig == FromNimbleFile, "maybe this needs to be overriden like before"
            else:
              error "loadDependency", "missing nimble tag version " & $tag & " at " & $path

        if result.versions.len() == 0:
          info "loadDependency", "no versions found, using default #head" & " at " & $path
          result.versions.add VersionTag(v: Version"", c: initCommitHash("", FromHead))

      finally:
        if not checkoutGitCommit(path, currentCommit, Warning):
          info "loadDependency", "error loading commit: " & $ currentCommit
    of CurrentCommit:
      trace "loadDependency", "only loading current commit"
      result.versions.add VersionTag(v: Version"#head", c: initCommitHash("", FromHead))

proc traverseDependency*(nimbleCtx: NimbleContext;
                         graph: var DepGraph, idx: int, mode: TraversalMode) =
  var lastNimbleContents = "<invalid content>"

  let versions = move graph[idx].versions
  let nimbleVersions = collectNimbleVersions(nimbleCtx, graph[idx])
  debug "traverseDependency", "nimble versions: " & $nimbleVersions

  let mode = if graph[idx].isRoot: CurrentCommit else: mode

  # for (origin, release) in releases(graph[idx].ondisk, mode, versions, nimbleVersions):
  #   traverseRelease(nimbleCtx, graph, idx, origin, release, lastNimbleContents)
  graph[idx].state = Processed
