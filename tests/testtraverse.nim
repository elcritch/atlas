# Small program that runs the test cases

import std / [strutils, os, osproc, jsonutils, json, tables, sequtils, strformat, unittest]
import basic/[sattypes, context, gitops, reporters, nimbleparser, pkgurls, compiledpatterns, versions]
import basic/deptypes
import dependencies
import testerutils

if not dirExists("tests/ws_testtraverse/buildGraph"):
  ensureGitHttpServer()

# proc createGraph*(s: PkgUrl): DepGraph =
#   result = DepGraph(nodes: @[], reqs: defaultReqs())
#   result.packageToDependency[s] = result.nodes.len
#   result.nodes.add Dependency(pkg: s, versions: @[], isRoot: true, isTopLevel: true, activeVersion: -1)

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
        exec("git clone http://localhost:4242/buildGraph/$1" % [proj])
  for proj in projs:
    result.add(ospaths2.getCurrentDir() / "buildGraphNoGitTags" / proj)

suite "basic repo tests":
  setup:
    setAtlasVerbosity(Warning)

  test "ws_testtraverse collect nimbles":
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer
        discard context().overrides.addPattern("$+", "file://./buildGraph/$#")

        let dir = ospaths2.getCurrentDir()
        # writeFile("ws_testtraverse.nimble", "requires \"proj_a\"\n")

        let deps = setupGraph()
        var nc = NimbleContext()
        # var graph = DepGraph(nodes: @[], reqs: defaultReqs())
        let pkg = nc.createUrl(dir, projectName = "ws_testtraverse")

        var dep0 = Dependency(pkg: pkg, isRoot: true, isTopLevel: true)
        var dep1 = Dependency(pkg: nc.createUrl("file://./buildGraph/proj_a"), isRoot: true)
        var dep2 = Dependency(pkg: nc.createUrl("file://./buildGraph/proj_b"), isRoot: true)
        var dep3 = Dependency(pkg: nc.createUrl("file://./buildGraph/proj_c"), isRoot: true)
        var dep4 = Dependency(pkg: nc.createUrl("file://./buildGraph/proj_d"), isRoot: true)

        nc.loadDependency(dep0)
        nc.loadDependency(dep1)
        nc.loadDependency(dep2)
        nc.loadDependency(dep3)
        nc.loadDependency(dep4)

        # These will change if atlas-tests is regnerated!
        # To update run and use commits not adding a proj_x.nim file
        #    curl http://localhost:4242/buildGraph/ws_generated-logs.txt
        check collectNimbleVersions(nc, dep0) == newSeq[VersionTag]()
        let vtags1 = dedent"""
        e479b438015e734bea67a9c63d783e78cab5746e
        7ca5581cd5355f6b5461a23f9683f19378bd268a
        fb3804df03c3c414d98d1f57deeb44c8a223ba44
        """.parseTaggedVersions(false)
        check collectNimbleVersions(nc, dep1) == vtags1

        let vtags2 = dedent"""
        af4275109d60caaeacf2912a37c2339aca40a922
        cd3ad76043e5f983f704be6bf61e57d187fe070f
        ee875baecee161ed053b87b583b2f08526838bd6
        """.parseTaggedVersions(false)
        let vtags3 = dedent"""
        c7540297c01dc57a98cb1fce7660ab6f2a0cee5f
        9331e14f3fa20ed75b7d5c0ab93aa5fb0293192f
        """.parseTaggedVersions(false)
        let vtags4 = dedent"""
        0dec9c9733129919972416f04e73b1fb2cbf3bd3
        dd98f775ae33d450dc7f936f850e247e820e31ad
        """.parseTaggedVersions(false)

        check collectNimbleVersions(nc, dep2) == vtags2
        check collectNimbleVersions(nc, dep3) == vtags3
        check collectNimbleVersions(nc, dep4) == vtags4

  test "ws_testtraverse traverseDependency":
      setAtlasVerbosity(Info)
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        context().workspace = paths.getCurrentDir()
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer

        var nc = NimbleContext()
        discard nc.overrides.addPattern("$+", "file://buildGraph/$#")

        let deps = setupGraph()
        let dir = ospaths2.getCurrentDir()
        writeFile("ws_testtraverse.nimble", "requires \"proj_a\"\n")

        let pkg = nc.createUrl(dir, projectName = "ws_testtraverse")

        let specs: DependencySpecs = expand(nc, AllReleases, pkg)

        echo "\tspec:\n", specs.toJson()
        let sp = specs.depsToSpecs.pairs().toSeq()

        check $sp[0][0] == "file://ws_testtraverse"
        check $sp[1][0] == "file://buildGraph/proj_a"
        check $sp[2][0] == "file://buildGraph/proj_b"
        check $sp[3][0] == "file://buildGraph/proj_c"
        check $sp[4][0] == "file://buildGraph/proj_d"

  test "ws_testtraverse collectNimble no git tags":
    when false:
      withDir "tests/ws_testtraverse":
        let deps = setupGraphNoGitTags()
        var nc = NimbleContext()
        var graph = createGraph(createUrlSkipPatterns(ospaths2.getCurrentDir()))
        graph[0].ondisk = paths.getCurrentDir()
        graph[0].state = Found

        for dep in deps:
          let url = createUrlSkipPatterns(dep)
          graph.nodes.add Dependency(
            pkg: url, versions: @[], isRoot: false, isTopLevel: false, activeVersion: -1,
            ondisk: Path(dep),
            state: Found
          )

        dumpJson graph
        check graph[0].pkg.projectName == "ws_testtraverse"
        check endsWith($(graph[0].pkg), "atlas/tests/ws_testtraverse")
        check graph[0].isRoot == true
        check graph[0].isTopLevel == true

        for i in 0..<graph.nodes.len():
          traverseDependency(nc, graph, i, TraversalMode.AllReleases)

        check graph[0].versions.len() == 1
        check graph[1].versions.len() == 2

        echo "\nGRAPH:POST:"
        dumpJson graph


infoNow "tester", "All tests run successfully"

# if failures > 0: quit($failures & " failures occurred.")

# Normal: create or remotely cloning repos
# nim c -r   1.80s user 0.71s system 60% cpu 4.178 total
# shims/nim c -r   32.00s user 25.11s system 41% cpu 2:18.60 total
# nim c -r   30.83s user 24.67s system 40% cpu 2:17.17 total

# Local repos:
# nim c -r   1.59s user 0.60s system 88% cpu 2.472 total
# w/integration: nim c -r   23.86s user 18.01s system 71% cpu 58.225 total
# w/integration: nim c -r   32.00s user 25.11s system 41% cpu 1:22.80 total
