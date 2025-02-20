# Small program that runs the test cases

import std / [strutils, os, osproc, tables, sequtils, strformat, unittest]
import basic/[sattypes, context, gitops, reporters, nimbleparser, pkgurls, compiledpatterns, versions]
import basic/depgraphtypes
import depgraphs
import pkgcache
import testerutils

if not dirExists("tests/ws_testtraverse/buildGraph"):
  ensureGitHttpServer()

proc createGraph*(s: PkgUrl): DepGraph =
  result = DepGraph(nodes: @[], reqs: defaultReqs())
  result.packageToDependency[s] = result.nodes.len
  result.nodes.add Dependency(pkg: s, versions: @[], isRoot: true, isTopLevel: true, activeVersion: -1)

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
    context().verbosity = 2
  test "ws_testtraverse collect nimbles":
      withDir "tests/ws_testtraverse":
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer
        discard context().overrides.addPattern("$+", "file://./buildGraph/$#")
        # {"overrides":{"s":[{"0":"(code: @[(opc: Capture1UntilEnd, arg1: 0, arg2: 0)], usedMatches: 1, error: \"\")","1":"file://./source/$#"}],"t":{},"strings":[]},
        # "defaultAlgo":"SemVer","plugins":{"builderPatterns":[]},"overridesFile":"url.rules","pluginsFile":"","proxy":{"scheme":"","username":"","password":"","hostname":"","port":"","path":"","query":"","anchor":"","opaque":false,"isIpv6":false},"dumbProxy":false,"verbosity":2,"noColors":false,"assertOnError":true,"warnings":0,"errors":0,"messages":[]}

        let deps = setupGraph()
        var nc = NimbleContext()
        # var graph = DepGraph(nodes: @[], reqs: defaultReqs())
        var graph = createGraph(createUrlSkipPatterns(ospaths2.getCurrentDir()))
        graph[0].ondisk = paths.getCurrentDir()
        graph[0].state = Found

        dumpJson graph, "graph-ws_testtraverse-collectnimbles.json"

        for dep in deps:
          let url = createUrlSkipPatterns(dep)
          graph.packageToDependency[url] = graph.nodes.len
          graph.nodes.add Dependency(
            pkg: url, versions: @[], isRoot: false, isTopLevel: false, activeVersion: -1,
            ondisk: Path(dep),
            state: Found
          )

        # dumpJson graph
        check graph[0].isRoot == true
        check graph[0].isTopLevel == true
        check graph[0].pkg.projectName == "ws_testtraverse"
        check graph.nodes.mapIt(it.pkg.projectName) == @["ws_testtraverse", "proj_a", "proj_b", "proj_c", "proj_d"]

        when true:
          context().verbosity = 0
          defer: context().verbosity = 3
          # for i in 0..<graph.nodes.len():
          #   let nv = collectNimbleVersions(nc, graph[i])
          #   echo "check collectNimbleVersions(nc, graph[$1]) == " % [$i], nv
          # echo "\n"

          # These will change if atlas-tests is regnerated!
          check collectNimbleVersions(nc, graph[0]) == newSeq[Commit]()
          check collectNimbleVersions(nc, graph[1]) == @[Commit(h: "c2bd74420ee22f5bf6bfe647b94d86223a1ab6e4"), Commit(h: "78d95ce89be7bf724a975f21ddb709ac2f735f9b"), Commit(h: "34511493b0416904fe8cde9bec96e55ba2a81e88")]
          check collectNimbleVersions(nc, graph[2]) == @[Commit(h: "561acc4524ad5450e9a891db90aec203ec9f8f82"), Commit(h: "0147e2a5e43a4415bfdc4cc94cda1803951e255a"), Commit(h: "c9ca3f58577ee53481d9171ebb6cfec5e512fd39")]
          check collectNimbleVersions(nc, graph[3]) == @[Commit(h: "4dce809c6daead19a9e182519670db7bc29ce89e"), Commit(h: "216d32097a406f7c938bb719b63cc9a6d4ee2aa6")]
          check collectNimbleVersions(nc, graph[4]) == @[Commit(h: "4af5e36a3a77b61ad5ff8122a284b65f37de62f7"), Commit(h: "a5363208fcda8a56fc4138a41d32920245dc03a8")]

        check graph.nodes.mapIt(it.pkg.projectName) == @["ws_testtraverse", "proj_a", "proj_b", "proj_c", "proj_d"]

        # echo "\nGRAPH:POST:"
        # dumpJson graph

  test "ws_testtraverse traverseDependency":
      withDir "tests/ws_testtraverse":
        context().workspace = paths.getCurrentDir()
        context().origDepsDir = paths.getCurrentDir() / Path"buildGraph"
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer
        discard context().overrides.addPattern("$+", "file://buildGraph/$#")

        let deps = setupGraph()
        var nc = NimbleContext()
        var graph = createGraph(createUrlSkipPatterns(ospaths2.getCurrentDir() ))
        graph[0].ondisk = paths.getCurrentDir()
        graph[0].state = Found

        dumpJson graph, "graph-ws_testtraverse-traverseDependency.json"

        var i = 0
        while i < graph.nodes.len:
          for dep in graph.nodes.mitems():
            if dep.state == NotInitialized:
              let (dest, _) = pkgUrlToDirname(graph, dep)
              dep.ondisk = dest
              dep.state = Found

          traverseDependency(nc, graph, i, TraversalMode.AllReleases)
          inc i

        dumpJson graph, "graph-ws_testtraverse-traverseDependency-post.json"

        check graph[0].versions.len() == 1
        check graph.nodes.mapIt(it.pkg.projectName) == @["ws_testtraverse", "proj_a", "proj_b", "proj_c", "proj_d", "does_not_exist"]

        check graph[0].pkg.projectName == "ws_testtraverse"
        check graph[0].ondisk.string.endsWith("ws_testtraverse")
        check graph[1].ondisk.string.endsWith("ws_testtraverse/buildGraph/proj_a")
        check graph[2].ondisk.string.endsWith("ws_testtraverse/buildGraph/proj_b")
        check graph[3].ondisk.string.endsWith("ws_testtraverse/buildGraph/proj_c")
        check graph[4].ondisk.string.endsWith("ws_testtraverse/buildGraph/proj_d")

        check graph[1].versions[0].commit == "34511493b0416904fe8cde9bec96e55ba2a81e88"
        check graph[1].versions[1].commit == "c2bd74420ee22f5bf6bfe647b94d86223a1ab6e4"
        check graph[1].versions.len() == 2
        check graph[2].versions[0].commit == "c9ca3f58577ee53481d9171ebb6cfec5e512fd39"
        check graph[2].versions[1].commit == "561acc4524ad5450e9a891db90aec203ec9f8f82"
        check graph[2].versions.len() == 2
        check graph[3].versions[0].commit == "216d32097a406f7c938bb719b63cc9a6d4ee2aa6"
        # check graph[3].versions[1].commit == "5cfac43f580c103e79005f21b25c82ee34707e54" # no tag
        check graph[3].versions.len() == 1
        check graph[4].versions[0].commit == "a5363208fcda8a56fc4138a41d32920245dc03a8"
        check graph[4].versions[1].commit == "4af5e36a3a77b61ad5ff8122a284b65f37de62f7"
        check graph[4].versions.len() == 2

        echo "\nGRAPH:POST:"
        dumpJson graph, "graph-ws_testtraverse-traverseDependency-post.json"

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

        block:
          context().verbosity = 0
          defer: context().verbosity = 3
          for i in 0..<graph.nodes.len():
            let nv = collectNimbleVersions(nc, graph[i])
            echo "collectNimbleVersions(nc, graph[$1]) == " % [$i], nv
          echo "\n"

          # These will change if atlas-tests is regnerated!
          check collectNimbleVersions(nc, graph[0]) == newSeq[string]()
          check collectNimbleVersions(nc, graph[1]) == @["edbf202081d43bc3d4bbc36847437a40cb0690b9", "06430815095a38ece2ec7653283dd1c00bebed1a"]
          check collectNimbleVersions(nc, graph[2]) == @["a5b4f36f98dafd94fe77571727d4fc4406748f89", "13dcd8b5345f4f3b6f58af49b989958967621266"]
          check collectNimbleVersions(nc, graph[3]) == @["a5b4f36f98dafd94fe77571727d4fc4406748f89", "13dcd8b5345f4f3b6f58af49b989958967621266"]
          check collectNimbleVersions(nc, graph[4]) == @["061b5103bd11cbea1c0b09d17cf1db0bf4402104", "e81373b111eb569d456cd2284fc7222b09224110"]

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
