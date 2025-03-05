import std / [sets, paths, dirs, files, tables, os, strutils, streams, json, jsonutils, algorithm]

import basic/[deptypes, versions, depgraphtypes, osutils, context, gitops, reporters, nimbleparser, pkgurls, versions]
import dependencies, runners 

import std/[json, jsonutils]

export depgraphtypes

when defined(nimAtlasBootstrap):
  import ../dist/sat/src/sat/[sat, satvars]
else:
  import sat/[sat, satvars]

iterator directDependencies*(graph: DepGraph; d: DepConstraint): lent DepConstraint =
  if d.activeVersion >= 0 and d.activeVersion < d.versions.len:
    let deps {.cursor.} = graph.reqs[d.versions[d.activeVersion].req].release.deps
    for dep in deps:
      let idx = findDependencyForDep(graph, dep[0])
      yield graph.nodes[idx]

iterator mvalidVersions*(pkg: var DepConstraint; graph: var DepGraph): var DepVersion =
  for ver in pkg.versions.mitems():
    if graph.reqs[ver.req].status == Normal:
      yield ver

type
  SatVarInfo* = object # attached information for a SAT variable
    pkg: PkgUrl
    vtag: VersionTag
    index: int

  Form* = object
    formula: Formular
    mapping: Table[VarId, SatVarInfo]
    idgen: int32

proc toFormular*(graph: var DepGraph; algo: ResolutionAlgorithm): Form =
  result = Form()
  var builder = Builder()
  builder.openOpr(AndForm)

  for p in mitems(graph.nodes):
    if p.versions.len == 0: continue

    p.versions.sort(sortDepVersions)

    var verIdx = 0
    for ver in p.versions.mitems():
      ver.vid = VarId(result.idgen)
      result.mapping[ver.vid] = SatVarInfo(
        pkg: p.dep.pkg,
        vtag: ver.vtag,
        index: verIdx
      )
      inc result.idgen
      inc verIdx

    doAssert p.dep.state != NotInitialized

    if p.dep.state == Error:
      builder.openOpr(AndForm)
      for ver in mitems p.versions: builder.addNegated ver.vid
      builder.closeOpr # AndForm
    elif p.dep.isRoot:
      builder.openOpr(ExactlyOneOfForm)
      for ver in mitems p.versions: builder.add ver.vid
      builder.closeOpr # ExactlyOneOfForm
    else:
      builder.openOpr(ZeroOrOneOfForm)
      for ver in mitems p.versions: builder.add ver.vid
      builder.closeOpr # ExactlyOneOfForm

  for pkg in mitems(graph.nodes):
    for ver in mvalidVersions(pkg, graph):
      if isValid(graph.reqs[ver.req].vid):
        continue
      let eqVar = VarId(result.idgen)
      graph.reqs[ver.req].vid = eqVar
      inc result.idgen

      if graph.reqs[ver.req].release.deps.len == 0:
        continue

      let beforeEq = builder.getPatchPos()

      builder.openOpr(OrForm)
      builder.addNegated eqVar
      if graph.reqs[ver.req].release.deps.len > 1:
        builder.openOpr(AndForm)
      var elementCount = 0
      for dep, query in items graph.reqs[ver.req].release.deps:
        let queryVer = if algo == SemVer: toSemVer(query) else: query
        let commit = extractSpecificCommit(queryVer)
        let availVer = graph[findDependencyForDep(graph, dep)]
        if availVer.versions.len == 0: continue

        let beforeExactlyOneOf = builder.getPatchPos()
        builder.openOpr(ExactlyOneOfForm)
        inc elementCount
        var matchCount = 0

        if not commit.isEmpty():
          for verIdx in countup(0, availVer.versions.len-1):
            if queryVer.matches(availVer.versions[verIdx].vtag.version) or
                commit == availVer.versions[verIdx].vtag.commit:
              builder.add availVer.versions[verIdx].vid
              inc matchCount
              break
        elif algo == MinVer:
          for verIdx in countup(0, availVer.versions.len-1):
            if queryVer.matches(availVer.versions[verIdx].vtag.version):
              builder.add availVer.versions[verIdx].vid
              inc matchCount
        else:
          for verIdx in countdown(availVer.versions.len-1, 0):
            if queryVer.matches(availVer.versions[verIdx].vtag.version):
              builder.add availVer.versions[verIdx].vid
              inc matchCount
        builder.closeOpr # ExactlyOneOfForm
        if matchCount == 0:
          builder.resetToPatchPos beforeExactlyOneOf
          builder.add falseLit()

      if graph.reqs[ver.req].release.deps.len > 1: builder.closeOpr # AndForm
      builder.closeOpr # EqForm
      if elementCount == 0:
        builder.resetToPatchPos beforeEq

  for pkg in mitems(graph.nodes):
    for ver in mvalidVersions(pkg, graph):
      if graph.reqs[ver.req].release.deps.len > 0:
        builder.openOpr(OrForm)
        builder.addNegated ver.vid
        builder.add graph.reqs[ver.req].vid
        builder.closeOpr # OrForm

  builder.closeOpr # AndForm
  result.formula = toForm(builder)

proc toString(info: SatVarInfo): string =
  "(" & info.pkg.projectName & ", " & $info.vtag & ")"

proc runBuildSteps(graph: var DepGraph) =
  ## execute build steps for the dependency graph
  ##
  ## `countdown` suffices to give us some kind of topological sort:
  ##
  for i in countdown(graph.nodes.len-1, 0):
    if graph[i].active:
      let dep = graph[i].dep
      let pkg = dep.pkg
      tryWithDir $dep.ondisk:
        # check for install hooks
        let activeVersion = graph[i].activeVersion
        let reqIdx = if graph[i].versions.len == 0: -1 else: graph[i].versions[activeVersion].req
        if reqIdx >= 0 and
            reqIdx < graph.reqs.len and
            graph.reqs[reqIdx].release.hasInstallHooks:
          let nimbleFiles = findNimbleFile(dep)
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
      if node.dep.isRoot: node.active = true
    for varIdx in 0 ..< maxVar:
      let vid = VarId varIdx
      if vid in form.mapping:
        let mapInfo = form.mapping[vid]
        info mapInfo.pkg.projectName, "v" & $varIdx & " sat var: " & $solution.getVar(vid).toPretty()

      if solution.isTrue(VarId(varIdx)) and form.mapping.hasKey(VarId varIdx):
        let mapInfo = form.mapping[VarId varIdx]
        let i = findDependencyForDep(graph, mapInfo.pkg)
        graph[i].active = true
        assert graph[i].activeVersion == -1, "too bad: " & graph[i].dep.pkg.url
        graph[i].activeVersion = mapInfo.index
        debug mapInfo.pkg.projectName, "package satisfiable"
        if not mapInfo.vtag.commit.isEmpty() and graph[i].dep.state == Processed:
          assert graph[i].dep.ondisk.string.len > 0, "Missing ondisk location for: " & $(graph[i].dep.pkg, i)
          let res = checkoutGitCommit(graph[i].dep.ondisk, mapInfo.vtag.commit)

    if NoExec notin context().flags:
      runBuildSteps(graph)

    if ListVersions in context().flags:
      info "../resolve", "selected:"
      for node in items graph.nodes:
        if not node.dep.isTopLevel:
          for ver in items(node.versions):
            let item = form.mapping[ver.vid]
            if solution.isTrue(ver.vid):
              info item.pkg.projectName, "[x] " & toString item
            else:
              info item.pkg.projectName, "[ ] " & toString item
      info "../resolve", "end of selection"
  else:
    var notFoundCount = 0
    for node in mitems(graph.nodes):
      if node.dep.isRoot and node.dep.state != Processed:
        error context().workspace, "invalid find package: " & node.dep.pkg.projectName & " in state: " & $node.dep.state & " error: " & $node.dep.errors
        inc notFoundCount
    if notFoundCount > 0:
      return
    error context().workspace, "version conflict; for more information use --showGraph"
    for node in mitems(graph.nodes):
      var usedVersionCount = 0
      for ver in mvalidVersions(node, graph):
        if solution.isTrue(ver.vid): inc usedVersionCount
      if usedVersionCount > 1:
        for ver in mvalidVersions(node, graph):
          if solution.isTrue(ver.vid):
            error node.dep.pkg.projectName, string(ver.vtag.version) & " required"
  if context().dumpGraphs:
    dumpJson(graph, "graph-solved.json")

proc traverseLoop*(nc: var NimbleContext, path: Path): seq[CfgPath] =
  result = @[]
  let specs = expand(nc, TraversalMode.AllReleases, path)
  var graph: DepGraph
  let form = graph.toFormular(context().defaultAlgo)
  solve(graph, form)
  for dep in allActiveNodes(graph):
    result.add CfgPath(toDestDir(graph, dep) / getCfgPath(graph, dep).Path)
