
import std / [sets, paths, files, dirs, tables, os, strutils, streams, json, jsonutils, algorithm]

import sattypes, context, deptypes, gitops, reporters, nimbleparser, pkgurls, versions


type
  DepGraph* = object
    nodes*: seq[DepConstraint]
    reqs*: seq[Requirements]
    packageToDependency*: Table[PkgUrl, int]
    ondisk*: OrderedTable[string, Path] # URL -> dirname mapping
    reqsByDeps*: Table[Requirements, int]

  DepConstraint* = object
    dep*: Dependency
    activeVersion*: int
    active*: bool
    versions*: seq[DepVersion]

  Requirements* = object

const
  FileWorkspace* = "file://"

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

type
  PackageAction* = enum
    DoNothing, DoClone

proc pkgUrlToDirname*(dep: Dependency): (Path, PackageAction) =
  # XXX implement namespace support here
  # var dest = Path g.ondisk.getOrDefault(d.pkg.url)
  var dest = Path ""
  if dep.isTopLevel:
    trace dep.pkg.projectName, "pkgUrlToDirName topLevel= " & $dep.isTopLevel
    dest = context().workspace
  else:
    let depsDir = context().workspace / context().depsDir
    dest = depsDir / Path(dep.pkg.projectName)
    trace dep.pkg.projectName, "pkgUrlToDirName depsDir:", $depsDir, "projectName:", dep.pkg.projectName
  dest = dest.absolutePath
  result = (dest, if dirExists(dest): DoNothing else: DoClone)

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
      if dirExists(n.dep.ondisk):
        if n.dep.isRoot:
          if not result.packageToDependency.hasKey(n.dep.pkg):
            result.packageToDependency[n.dep.pkg] = result.nodes.len
            result.nodes.add DepConstraint(dep: n.dep, activeVersion: -1)
  except:
    warn configFile, "couldn't load graph from: " & $configFile

proc createGraph*(s: PkgUrl): DepGraph =
  result = DepGraph(nodes: @[], reqs: defaultReqs())
  result.packageToDependency[s] = result.nodes.len
  let dep = Dependency(pkg: s, isRoot: true, isTopLevel: true)
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
      result.packageToDependency[n.dep.pkg] = i
  except:
    warn configFile, "couldn't load graph from: " & $configFile

proc copyFromDisk*(dep: Dependency; destDir: Path): (CloneStatus, string) =
  var dir = Path dep.pkg.url
  if dir.string.startsWith(FileWorkspace):
    dir = context().workspace / Path(dir.string.substr(FileWorkspace.len))
  #template selectDir(a, b: string): string =
  #  if dirExists(a): a else: b

  #let dir = selectDir(u & "@" & w.commit, u)
  if dep.isTopLevel:
    trace dir, "copyFromDisk isTopLevel", $dir
    result = (Ok, $dir)
  elif dirExists(dir):
    trace dir, "copyFromDisk cloning:", $dir
    copyDir($dir, $destDir)
    result = (Ok, "")
  else:
    warn dir, "copyFromDisk not found:", $dir
    result = (NotFound, $dir)
  #writeFile destDir / ThisVersion, w.commit
  #echo "WRITTEN ", destDir / ThisVersion
