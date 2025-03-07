# Small program that runs the test cases

import std / [strutils, os, uri, jsonutils, json, tables, sequtils, strformat, unittest]
import basic/[sattypes, context, reporters, pkgurls, compiledpatterns, versions]
import basic/deptypes
import dependencies
import depgraphs
import testerutils

if not dirExists("tests/ws_testtraverse/buildGraph"):
  ensureGitHttpServer()

# proc createGraph*(s: PkgUrl): DepGraph =
#   result = DepGraph(nodes: @[], reqs: defaultReqs())
#   result.packageToDependency[s] = result.nodes.len
#   result.nodes.add Package(pkg: s, versions: @[], isRoot: true, isTopLevel: true, activeRelease: -1)

proc setupGraph*(): seq[string] =
  let projs = @["proj_a", "proj_b", "proj_c", "proj_d"]
  if not dirExists("buildGraph"):
    createDir "buildGraph"
    withDir "buildGraph":
      for proj in projs:
        exec("git clone http://localhost:4242/buildGraph/$1" % [proj])
  for proj in projs:
    result.add(ospaths2.getCurrentDir() / "buildGraph" / proj)

proc setupGraphNoGitTags*(): seq[string] =
  let projs = @["proj_a", "proj_b", "proj_c", "proj_d"]
  if not dirExists("buildGraphNoGitTags"):
    createDir "buildGraphNoGitTags"
    withDir "buildGraphNoGitTags":
      for proj in projs:
        exec("git clone http://localhost:4242/buildGraphNoGitTags/$1" % [proj])
  for proj in projs:
    result.add(ospaths2.getCurrentDir() / "buildGraphNoGitTags" / proj)

template testRequirements(sp: Package,
                          projTags: seq[VersionTag],
                          vers: openArray[(string, string)];
                          skipCount = false) =
  echo "Checking Requirements: " & astToStr(sp)
  if not skipCount:
    check sp.versions.len() == vers.len()

  for idx, vt in projTags:
    # let vt = projTags[idx]
    let vt = vt.toPkgVer
    echo "Checking requirements item: " & $vers[idx] & " version: " & $vt
    check idx < vers.len()
    let (url, ver) = vers[idx]
    check sp.state == Processed
    check vt in sp.versions
    if vt in sp.versions:
      check sp.versions[vt].status == Normal
      if not skipCount:
        check sp.versions[vt].requirements.len() == 1

      if url != "":
        check $sp.versions[vt].requirements[0][0] == url
      if ver != "":
        check $sp.versions[vt].requirements[0][1] == ver


suite "graph solve":
  setup:
    setAtlasVerbosity(Debug)
    context().overrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().dumbProxy = true
    context().depsDir = Path "deps"

  test "ws_semver_unit traverseDependency":
      # setAtlasVerbosity(Info)
      withDir "tests/ws_semver_unit":
        removeDir("deps")
        context().workspace = paths.getCurrentDir()
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer

        var nc = createNimbleContext()
        nc.nameToUrl["proj_a"] = toPkgUri(parseUri "https://example.com/buildGraph/proj_a")
        nc.nameToUrl["proj_b"] = toPkgUri(parseUri "https://example.com/buildGraph/proj_b")
        nc.nameToUrl["proj_c"] = toPkgUri(parseUri "https://example.com/buildGraph/proj_c")
        nc.nameToUrl["proj_d"] = toPkgUri(parseUri "https://example.com/buildGraph/proj_d")

        let dir = paths.getCurrentDir().absolutePath

        var graph: DepGraph = expand(nc, AllReleases, dir)

        let sp = graph.pkgs.values().toSeq()
        let sp0: Package = sp[0] # proj ws_testtraversal
        let vt = toVersionTag
        testRequirements(sp0, @[vt"#head@-"], [
          ("file://./buildGraph/proj_a", "*"),
        ])

        echo "\tspec:\n", graph.toJson(ToJsonOptions(enumMode: joptEnumString))

        ## TODO: Figure out how to handle semver properly!
        ## maybe need to select versions before hand?
        ## 

        let form = graph.toFormular(SemVer)

        context().dumpGraphs = true
        var sol: Solution

        let expForm = "(&(1==v0) (1>=v1 v2) (1>=v3 v4) (1>=v5) (1>=v6 v7) (|(~v0) v0) (|(~v1) v0) (|(~v2) v0) (|(~v3) v0) (|(~v4) v0) (|(~v5) v0))"

        solve(graph, form)
