import std / [paths, tables, streams, json, jsonutils]

import sattypes, context, deptypes, reporters, nimblecontext, pkgurls, versions


type 
  VisitState = enum
    NotVisited, InProgress, Visited

proc toposorted*(graph: DepGraph): seq[Package] =
  ## Returns a sequence of packages in topological order
  ## Packages that are depended upon come before packages that depend on them
  result = @[]
  var visited = initTable[PkgUrl, VisitState]()
  
  # Initialize all packages as not visited
  for url, pkg in graph.pkgs:
    visited[url] = NotVisited
  
  # DFS-based topological sort
  proc visit(pkg: Package): seq[Package] =
    if visited[pkg.url] == Visited:
      return
    if visited[pkg.url] == InProgress:
      # This means we have a cycle, which shouldn't happen in a valid dependency graph
      # But we'll handle it gracefully
      return
    
    visited[pkg.url] = InProgress
    
    # Get the active release to check its dependencies
    let release = pkg.activeNimbleRelease()
    if not release.isNil:
      # Visit all dependencies first
      for (depUrl, _) in release.requirements:
        if depUrl in graph.pkgs:
          let depPkg = graph.pkgs[depUrl]
          result.add visit(depPkg)
    
    # Mark as visited and add to result
    visited[pkg.url] = Visited
    result.add(pkg)
  
  # Start with root package
  if not graph.root.isNil:
    result.add visit(graph.root)
  
  # Visit any remaining packages (disconnected or not reachable from root)
  for url, pkg in graph.pkgs:
    if visited[url] == NotVisited:
      result.add visit(pkg)

proc validateDependencyGraph*(graph: DepGraph): bool =
  ## Checks if the dependency graph is valid (no cycles)
  var visited = initTable[PkgUrl, VisitState]()
  
  # Initialize all packages as not visited
  for url, pkg in graph.pkgs:
    visited[url] = NotVisited
  
  proc checkCycles(pkg: Package): bool =
    if visited[pkg.url] == Visited:
      return true
    if visited[pkg.url] == InProgress:
      # Cycle detected
      return false
    
    visited[pkg.url] = InProgress
    
    # Check all dependencies
    let release = pkg.activeNimbleRelease()
    if not release.isNil:
      for (depUrl, _) in release.requirements:
        if depUrl in graph.pkgs:
          let depPkg = graph.pkgs[depUrl]
          if not checkCycles(depPkg):
            return false
    
    visited[pkg.url] = Visited
    return true
  
  # Check from all possible starting points
  for url, pkg in graph.pkgs:
    if visited[url] == NotVisited:
      if not checkCycles(pkg):
        return false
  
  return true

proc toJsonHook*(vid: VarId): JsonNode = toJson($(int(vid)))
proc toJsonHook*(p: Path): JsonNode = toJson($(p))

proc fromJsonHook*(a: var VarId; b: JsonNode; opt = Joptions()) =
  a = VarId(int(b.getInt()))

proc fromJsonHook*(a: var Path; b: JsonNode; opt = Joptions()) =
  a = Path(b.getStr())

proc toJsonGraph*(d: DepGraph): JsonNode =
  result = toJson(d, ToJsonOptions(enumMode: joptEnumString))

proc dumpJson*(d: DepGraph, filename: string, pretty = true) =
  let jn = toJsonGraph(d)
  if pretty:
    writeFile(filename, pretty(jn))
  else:
    writeFile(filename, $(jn))

proc loadJson*(nc: var NimbleContext, json: JsonNode): DepGraph =
  result.fromJson(json, Joptions(allowMissingKeys: true, allowExtraKeys: true))
  var pkgs = result.pkgs
  result.pkgs.clear()

  for url, pkg in pkgs:
    let url2 = nc.createUrl($pkg.url)
    echo "restoring url: ", $pkg.url, " to ", $url2.projectName()
    pkg.url = url2
    result.pkgs[url2] = pkg
  
  let rootUrl = nc.createUrl($result.root.url)
  result.root = result.pkgs[rootUrl]

proc loadJson*(nc: var NimbleContext, filename: string): DepGraph =
  let jn = parseJson(filename)
  result = loadJson(nc, jn)

proc toDestDir*(g: DepGraph; d: Package): Path =
  result = d.ondisk

iterator allNodes*(g: DepGraph): Package =
  for pkg in values(g.pkgs):
    yield pkg

iterator allActiveNodes*(g: DepGraph): Package =
  for pkg in values(g.pkgs):
    if pkg.active and not pkg.activeVersion.isNil:
      doAssert pkg.state == Processed
      yield pkg

proc getCfgPath*(g: DepGraph; d: Package): lent CfgPath =
  result = CfgPath g.pkgs[d.url].activeNimbleRelease().srcDir

proc bestNimVersion*(g: DepGraph): Version =
  result = Version""
  for pkg in allNodes(g):
    if pkg.active and pkg.activeNimbleRelease().nimVersion != Version"":
      let v = pkg.activeNimbleRelease().nimVersion
      if v > result: result = v

proc createGraphFromWorkspace*(): DepGraph =
  # TODO: fixme?
  result = DepGraph()
  let configFile = getProjectConfig()
  var f = newFileStream($configFile, fmRead)
  if f == nil:
    error configFile, "could not open project config:", $configFile
    return
  try:
    let j = parseJson(f, $configFile)
    # let g = j["graph"]
    # result.nodes = jsonTo(g["nodes"], typeof(result.nodes))
    # result.reqs = jsonTo(g["reqs"], typeof(result.reqs))
    # for i, n in mpairs(result.nodes):
    #   result.packageToDependency[n.dep.url] = i
  except:
    warn configFile, "couldn't load graph from: " & $configFile
