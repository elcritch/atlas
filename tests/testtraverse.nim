# Small program that runs the test cases

import std / [strutils, os, osproc, tables, sequtils, strformat, unittest]
import basic/[sattypes, context, gitops, reporters, nimbleparser, pkgurls, versions]
import basic/depgraphtypes
import depgraphs
import testerutils

if not dirExists("tests/ws_testtraverse/buildGraph"):
  ensureGitHttpServer()

proc createGraph*(s: PkgUrl): DepGraph =
  result = DepGraph(nodes: @[],
    reqs: defaultReqs())
  result.packageToDependency[s] = result.nodes.len
  result.nodes.add Dependency(pkg: s, versions: @[], isRoot: true, isTopLevel: true, activeVersion: -1)

proc setupGraph* =
  if not dirExists("buildGraph"):
    createDir "buildGraph"
    withDir "buildGraph":
      exec "git clone http://localhost:4242/buildGraph/proj_a"
      exec "git clone http://localhost:4242/buildGraph/proj_b"
      exec "git clone http://localhost:4242/buildGraph/proj_c"
      exec "git clone http://localhost:4242/buildGraph/proj_d"

proc setupGraphNoGitTags* =
  if not dirExists("buildGraphNoGitTags"):
    createDir "buildGraphNoGitTags"
    withDir "buildGraphNoGitTags":
      exec "git clone http://localhost:4242/buildGraphNoGitTags/proj_a"
      exec "git clone http://localhost:4242/buildGraphNoGitTags/proj_b"
      exec "git clone http://localhost:4242/buildGraphNoGitTags/proj_c"
      exec "git clone http://localhost:4242/buildGraphNoGitTags/proj_d"

suite "basic repo tests":
  test "tests/ws_testtraverse":
      withDir "tests/ws_testtraverse":
        setupGraph()
        var graph = createGraph(createUrlSkipPatterns(ospaths2.getCurrentDir()))

        dumpJson graph
        check graph[0].pkg.projectName == "ws_testtraverse"
        check endsWith($(graph[0].pkg), "atlas/tests/ws_testtraverse")
        # expand(g, nc, TraversalMode.AllReleases)
        

  test "tests/ws_testtraverse":
      withDir "tests/ws_testtraverse":
        setupGraphNoGitTags()
        

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
