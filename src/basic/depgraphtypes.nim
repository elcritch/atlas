
import std / [sets, paths, files, dirs, tables, os, strutils, streams, json, jsonutils, algorithm]

import sattypes, context, deptypes, gitops, reporters, nimbleparser, pkgurls, versions


type
  DepGraph* = object
    nodes*: seq[DepConstraint]
    reqs*: seq[Requirements]
    packageToDependency*: Table[PkgUrl, int]

  DepConstraint* = object
    dep*: Package
    activeVersion*: int
    active*: bool
    versions*: seq[DepVersion]

proc `[]`*(g: DepGraph, idx: int): DepConstraint =
  g.nodes[idx]

proc `[]`*(g: var DepGraph, idx: int): var DepConstraint =
  g.nodes[idx]

proc status*(r: Requirements): ReleaseStatus =
  r.release.status

# proc commit*(d: DepConstraint): CommitHash =
#   result =
#     if d.activeVersion >= 0 and d.activeVersion < d.releases.len:
#       d.releases[d.activeVersion].vtag.commit()
#     else:
#       CommitHash(h: "")

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
  let emptyReq = Requirements(release: NimbleRelease(deps: @[]), vid: NoVar)
  let unknownReq = Requirements(release: NimbleRelease(status: HasUnknownNimbleFile), vid: NoVar)
  result = @[emptyReq, unknownReq]

proc toJsonHook*(d: DepGraph, opt: ToJsonOptions): JsonNode =
  result = newJObject()
  result["nodes"] = toJson(d.nodes, opt)
  result["reqs"] = toJson(d.reqs, opt)
  result["packageToDependency"] = toJson(d.packageToDependency, opt)
    # result["reqsByDeps"] = toJson(d.reqsByDeps)

proc sortDepVersions*(a, b: DepVersion): int =
  (if a.vtag.v < b.vtag.v: 1
  elif a.vtag.v == b.vtag.v: 0
  else: -1)

proc initDepVersion*(version: Version, commit: CommitHash, req = EmptyReqs, vid = NoVar): DepVersion =
  result = DepVersion(vtag: VersionTag(c: commit, v: version), reqIdx: req, vid: vid)

proc enrichVersionsViaExplicitHash*(releases: var seq[DepVersion]; x: VersionInterval) =
  let commit = extractSpecificCommit(x)
  if not commit.isEmpty():
    for ver in releases:
      if ver.vtag.commit() == commit:
        return
    releases.add initDepVersion(Version"", commit) 

proc dumpJson*(d: DepGraph, filename: string, full = true, pretty = true) =
  let jn = toJson(d, ToJsonOptions(enumMode: joptEnumString))
  if pretty:
    writeFile(filename, pretty(jn))
  else:
    writeFile(filename, $(jn))

proc toDestDir*(g: DepGraph; d: DepConstraint): Path =
  result = d.dep.ondisk

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

proc getCfgPath*(g: DepGraph; d: DepConstraint): lent CfgPath =
  result = CfgPath g.reqs[d.versions[d.activeVersion].reqIdx].release.srcDir

# proc bestNimVersion*(g: DepGraph): Version =
#   result = Version""
#   for n in allNodes(g):
#     if n.active and g.reqs[n.versions[n.activeVersion].req].nimVersion != Version"":
#       let v = g.reqs[n.versions[n.activeVersion].req].nimVersion
#       if v > result: result = v

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
      # result.ondisk[n.url.url] = n.ondisk
      if dirExists(n.dep.ondisk):
        if n.dep.isRoot:
          if not result.packageToDependency.hasKey(n.dep.url):
            result.packageToDependency[n.dep.url] = result.nodes.len
            result.nodes.add DepConstraint(dep: n.dep, activeVersion: -1)
  except:
    warn configFile, "couldn't load graph from: " & $configFile

proc createGraph*(s: PkgUrl): DepGraph =
  result = DepGraph(nodes: @[], reqs: defaultReqs())
  result.packageToDependency[s] = result.nodes.len
  let dep = Package(pkg: s, isRoot: true, isTopLevel: true)
  result.nodes.add DepConstraint(dep: dep, versions: @[], activeVersion: -1)
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
      result.packageToDependency[n.dep.url] = i
  except:
    warn configFile, "couldn't load graph from: " & $configFile
