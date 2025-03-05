import std / [sets, paths, dirs, files, tables, os, strutils, streams, json, jsonutils, algorithm]

import basic/[deptypes, depgraphtypes, osutils, context, gitops, reporters, nimbleparser, pkgurls, versions]
import dependencies, runners 

import std/[json, jsonutils]

export depgraphtypes

when defined(nimAtlasBootstrap):
  import ../dist/sat/src/sat/[sat, satvars]
else:
  import sat/[sat, satvars]

proc expand*(graph: var DepGraph; nimbleCtx: NimbleContext; mode: TraversalMode) =
  ## Expand the graph by adding all dependencies.
  # trace "expand", "nodes: " & $graph.nodes
  if context().dumpGraphs:
    dumpJson(graph, "graph-expand-input.json")
  var processed = initHashSet[PkgUrl]()
  var i = 0
  while i < graph.nodes.len:
    if not processed.containsOrIncl(graph[i].pkg):
      let (dest, todo) = pkgUrlToDirname(graph, graph[i])

      debug "expand", "todo: " & $todo & " pkg: " & graph[i].pkg.projectName & " dest: " & $dest
      # important: the ondisk path set here!
      graph[i].ondisk = dest

      case todo
      of DoClone:
        let (status, msg) =
          if graph[i].pkg.isFileProtocol:
            copyFromDisk(graph[i], dest)
          else:
            cloneUrl(graph[i].pkg, dest, false)
        if status == Ok:
          graph[i].state = Found
        else:
          graph[i].state = Error
          graph[i].errors.add $status & ":" & msg
      of DoNothing:
        if graph[i].ondisk.dirExists():
          graph[i].state = Found
        else:
          graph[i].state = Error
          graph[i].errors.add "ondisk location missing"

      if graph[i].state == Found:
        traverseDependency(nimbleCtx, graph, i, mode)
    inc i
  if context().dumpGraphs:
    dumpJson(graph, "graph-expanded.json")

iterator mvalidVersions*(pkg: var Dependency; graph: var DepGraph): var DepVersion =
  for ver in mitems pkg.versions:
    if graph.reqs[ver.req].status == Normal: yield ver

type
  SatVarInfo* = object # attached information for a SAT variable
    pkg: PkgUrl
    commit: string
    version: Version
    index: int

  Form* = object
    formula: Formular
    mapping: Table[VarId, SatVarInfo]
    idgen: int32

proc toFormular*(graph: var DepGraph; algo: ResolutionAlgorithm): Form =
  result = Form()
  var builder = Builder()
  builder.openOpr(AndForm)

  for pkg in mitems(graph.nodes):
    if pkg.versions.len == 0: continue

    pkg.versions.sort(sortDepVersions)

    var verIdx = 0
    for ver in mitems pkg.versions:
      ver.vid = VarId(result.idgen)
      result.mapping[ver.vid] = SatVarInfo(pkg: pkg.pkg, commit: ver.commit, version: ver.version, index: verIdx)
      inc result.idgen
      inc verIdx

    doAssert pkg.state != NotInitialized

    if pkg.state == Error:
      builder.openOpr(AndForm)
      for ver in mitems pkg.versions: builder.addNegated ver.vid
      builder.closeOpr # AndForm
    elif pkg.isRoot:
      builder.openOpr(ExactlyOneOfForm)
      for ver in mitems pkg.versions: builder.add ver.vid
      builder.closeOpr # ExactlyOneOfForm
    else:
      builder.openOpr(ZeroOrOneOfForm)
      for ver in mitems pkg.versions: builder.add ver.vid
      builder.closeOpr # ExactlyOneOfForm

  for pkg in mitems(graph.nodes):
    for ver in mvalidVersions(pkg, graph):
      if isValid(graph.reqs[ver.req].vid):
        continue
      let eqVar = VarId(result.idgen)
      graph.reqs[ver.req].vid = eqVar
      inc result.idgen

      if graph.reqs[ver.req].deps.len == 0: continue

      let beforeEq = builder.getPatchPos()

      builder.openOpr(OrForm)
      builder.addNegated eqVar
      if graph.reqs[ver.req].deps.len > 1: builder.openOpr(AndForm)
      var elementCount = 0
      for dep, query in items graph.reqs[ver.req].deps:
        let queryVer = if algo == SemVer: toSemVer(query) else: query
        let commit = extractSpecificCommit(queryVer)
        let availVer = graph[findDependencyForDep(graph, dep)]
        if availVer.versions.len == 0: continue

        let beforeExactlyOneOf = builder.getPatchPos()
        builder.openOpr(ExactlyOneOfForm)
        inc elementCount
        var matchCount = 0

        if commit.len > 0:
          for verIdx in countup(0, availVer.versions.len-1):
            if queryVer.matches(availVer.versions[verIdx].version) or commit == availVer.versions[verIdx].commit:
              builder.add availVer.versions[verIdx].vid
              inc matchCount
              break
        elif algo == MinVer:
          for verIdx in countup(0, availVer.versions.len-1):
            if queryVer.matches(availVer.versions[verIdx].version):
              builder.add availVer.versions[verIdx].vid
              inc matchCount
        else:
          for verIdx in countdown(availVer.versions.len-1, 0):
            if queryVer.matches(availVer.versions[verIdx].version):
              builder.add availVer.versions[verIdx].vid
              inc matchCount
        builder.closeOpr # ExactlyOneOfForm
        if matchCount == 0:
          builder.resetToPatchPos beforeExactlyOneOf
          builder.add falseLit()

      if graph.reqs[ver.req].deps.len > 1: builder.closeOpr # AndForm
      builder.closeOpr # EqForm
      if elementCount == 0:
        builder.resetToPatchPos beforeEq

  for pkg in mitems(graph.nodes):
    for ver in mvalidVersions(pkg, graph):
      if graph.reqs[ver.req].deps.len > 0:
        builder.openOpr(OrForm)
        builder.addNegated ver.vid
        builder.add graph.reqs[ver.req].vid
        builder.closeOpr # OrForm

  builder.closeOpr # AndForm
  result.formula = toForm(builder)

proc toString(info: SatVarInfo): string =
  "(" & info.pkg.projectName & ", " & $info.version & ")"

proc runBuildSteps(graph: var DepGraph) =
  ## execute build steps for the dependency graph
  ##
  ## `countdown` suffices to give us some kind of topological sort:
  ##
  for i in countdown(graph.nodes.len-1, 0):
    if graph[i].active:
      let pkg = graph[i].pkg
      tryWithDir $graph[i].ondisk:
        # check for install hooks
        let activeVersion = graph[i].activeVersion
        let reqIdx = if graph[i].versions.len == 0: -1 else: graph[i].versions[activeVersion].req
        if reqIdx >= 0 and reqIdx < graph.reqs.len and graph.reqs[reqIdx].hasInstallHooks:
          let nimbleFiles = findNimbleFile(graph[i])
          if nimbleFiles.len() == 1:
            runNimScriptInstallHook nimbleFiles[0], pkg.projectName
        # check for nim script builders
        for pattern in mitems context().plugins.builderPatterns:
          let builderFile = pattern[0] % pkg.projectName
          if fileExists(builderFile):
            runNimScriptBuilder pattern, pkg.projectName

proc debugFormular(graph: var DepGraph; form: Form; solution: Solution) =
  echo "FORM: ", form.formula
  for key, value in pairs(form.mapping):
    echo "v", key.int, ": ", value
  let maxVar = maxVariable(form.formula)
  for varIdx in 0 ..< maxVar:
    if solution.isTrue(VarId(varIdx)):
      echo "v", varIdx, ": T"

proc toPretty*(v: uint64): string = 
  if v == DontCare: "X"
  elif v == SetToTrue: "T"
  elif v == SetToFalse: "F"
  elif v == IsInvalid: "!"
  else: ""

proc solve*(graph: var DepGraph; form: Form) =
  let maxVar = form.idgen
  if context().dumpGraphs:
    dumpJson(graph, "graph-solve-input.json")
  var solution = createSolution(maxVar)
  if context().dumpFormular:
    debugFormular graph, form, solution

  if satisfiable(form.formula, solution):
    for node in mitems graph.nodes:
      if node.isRoot: node.active = true
    for varIdx in 0 ..< maxVar:
      let vid = VarId varIdx
      if vid in form.mapping:
        let mapInfo = form.mapping[vid]
        info mapInfo.pkg.projectName, "v" & $varIdx & " sat var: " & $solution.getVar(vid).toPretty()

      if solution.isTrue(VarId(varIdx)) and form.mapping.hasKey(VarId varIdx):
        let mapInfo = form.mapping[VarId varIdx]
        let i = findDependencyForDep(graph, mapInfo.pkg)
        graph[i].active = true
        assert graph[i].activeVersion == -1, "too bad: " & graph[i].pkg.url
        graph[i].activeVersion = mapInfo.index
        debug mapInfo.pkg.projectName, "package satisfiable"
        if mapInfo.commit != "" and graph[i].state == Processed:
          assert graph[i].ondisk.string.len > 0, "Missing ondisk location for: " & $(graph[i].pkg, i)
          let res = checkoutGitCommit(graph[i].ondisk, mapInfo.commit)

    if NoExec notin context().flags:
      runBuildSteps(graph)

    if ListVersions in context().flags:
      info "../resolve", "selected:"
      for node in items graph.nodes:
        if not node.isTopLevel:
          for ver in items(node.versions):
            let item = form.mapping[ver.vid]
            if solution.isTrue(ver.vid):
              info item.pkg.projectName, "[x] " & toString item
            else:
              info item.pkg.projectName, "[ ] " & toString item
      info "../resolve", "end of selection"
  else:
    var notFoundCount = 0
    for pkg in mitems(graph.nodes):
      if pkg.isRoot and pkg.state != Processed:
        error context().workspace, "invalid find package: " & pkg.pkg.projectName & " in state: " & $pkg.state & " error: " & $pkg.errors
        inc notFoundCount
    if notFoundCount > 0:
      return
    error context().workspace, "version conflict; for more information use --showGraph"
    for pkg in mitems(graph.nodes):
      var usedVersionCount = 0
      for ver in mvalidVersions(pkg, graph):
        if solution.isTrue(ver.vid): inc usedVersionCount
      if usedVersionCount > 1:
        for ver in mvalidVersions(pkg, graph):
          if solution.isTrue(ver.vid):
            error pkg.pkg.projectName, string(ver.version) & " required"
  if context().dumpGraphs:
    dumpJson(graph, "graph-solved.json")

proc traverseLoop*(nc: var NimbleContext; graph: var DepGraph): seq[CfgPath] =
  result = @[]
  expand(graph, nc, TraversalMode.AllReleases)
  let form = toFormular(graph, context().defaultAlgo)
  solve(graph, form)
  for dep in allActiveNodes(graph):
    result.add CfgPath(toDestDir(graph, dep) / getCfgPath(graph, dep).Path)
