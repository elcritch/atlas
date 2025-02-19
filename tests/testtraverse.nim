# Small program that runs the test cases

import std / [strutils, os, osproc, tables, sequtils, strformat, unittest]
import basic/[sattypes, context, gitops, reporters, nimbleparser, pkgurls, versions]
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
  let projs = @["proj_a", "proj_c", "proj_c", "proj_d"]
  if not dirExists("buildGraph"):
    createDir "buildGraph"
    withDir "buildGraph":
      for proj in projs:
        exec("git clone http://localhost:4242/buildGraph/$1" % [proj])
  for proj in projs:
    result.add(ospaths2.getCurrentDir() / "buildGraph" / proj)

proc setupGraphNoGitTags*(): seq[string] =
  let projs = @["proj_a", "proj_c", "proj_c", "proj_d"]
  if not dirExists("buildGraphNoGitTags"):
    createDir "buildGraphNoGitTags"
    withDir "buildGraphNoGitTags":
      for proj in projs:
        exec("git clone http://localhost:4242/buildGraph/$1" % [proj])
  for proj in projs:
    result.add(ospaths2.getCurrentDir() / "buildGraphNoGitTags" / proj)

suite "basic repo tests":
  setup:
    context().verbosity = 3
  test "tests/ws_testtraverse":
      withDir "tests/ws_testtraverse":
        let deps = setupGraph()
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
          let nv = collectNimbleVersions(nc, graph[i])
          echo "collectNimbleVersions(nc, graph[$1]) == " % [$i], nv
        echo "\n"

        # These will change if atlas-tests is regnerated!
        check collectNimbleVersions(nc, graph[1]) == @["f2796032bf264fde834a141f0372f60eba17a90d", "05446e3b3c8a043704bd1321fc75459c701840b1"]
        check collectNimbleVersions(nc, graph[2]) == @["5cfac43f580c103e79005f21b25c82ee34707e54", "aa61b1d5eed8ba9d2ef0afcf05bb7de1f9cede5d"]
        check collectNimbleVersions(nc, graph[3]) == @["5cfac43f580c103e79005f21b25c82ee34707e54", "aa61b1d5eed8ba9d2ef0afcf05bb7de1f9cede5d"]
        check collectNimbleVersions(nc, graph[4]) == @["6809134018d7b61fdbef1becd9e3c077a3be1c68", "f351cd520bdbe59d13babef63613d8e7fd11e667"]

        for i in 0..<graph.nodes.len():
          traverseDependency(nc, graph, i, TraversalMode.AllReleases)

        echo "\nGRAPH:POST:"
        dumpJson graph

  test "tests/ws_testtraverse":
      withDir "tests/ws_testtraverse":
        let deps = setupGraphNoGitTags()
        

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
