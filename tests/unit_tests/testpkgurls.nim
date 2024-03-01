
import std/unittest
import std/json
import std/options

import context, satvars, sat, gitops, runners, reporters, nimbleparser, pkgurls, cloner, versions
import osutils
import compiledpatterns
import pkgurls
import depgraphs

template setupDepsAndGraph(url: string) =
  var
    p {.inject.} = initPatterns()
    u {.inject.} = createUrl(url, p)
    c {.inject.} = AtlasContext()
    g {.inject.} = createGraph(c, u, readConfig = false)
    d {.inject.} = Dependency()

  c.depsDir = "fakeDeps"
  c.workspace = "/workspace/"
  c.projectDir = "/workspace"

suite "test pkgurls":

  test "basic url":
    setupDepsAndGraph("https://github.com/example/proj.git")
    check $u == "https://github.com/example/proj.git"
    check u.projectName == "proj"

  test "basic url no git":
    setupDepsAndGraph("https://github.com/example/proj")
    check $u == "https://github.com/example/proj"
    check u.projectName == "proj"

  test "basic url prefix":
    setupDepsAndGraph("https://github.com/example/nim-proj")
    check $u == "https://github.com/example/nim-proj"
    check u.projectName == "nim-proj"

suite "nimble stuff":
  setup:
    setupDepsAndGraph("https://github.com/example/nim-proj")
    osutils.filesContext.currDir = "/workspace/"
    osutils.filesContext.walkDirs["/workspace/fakeDeps/apatheia/*.nimble"] = @["/workspace/fakeDeps/apatheia.nimble"]

  test "basic path":
    let dir = "/workspace/fakeDeps/apatheia"
    let res = findNimbleFile(c, u, dir)
    check res == some("/workspace/fakeDeps/apatheia.nimble")

  test "with currdir":
    osutils.filesContext.currDir = "/workspace/fakeDeps/apatheia"
    let res = findNimbleFile(c, u)
    check res == some("/workspace/fakeDeps/apatheia.nimble")

  test "with files":
    let dir = "/workspace/fakeDeps/apatheia"
    osutils.filesContext.currDir = dir
    let res = findNimbleFile(c, dir)
    check res == some("/workspace/fakeDeps/apatheia.nimble")

  test "missing":
    osutils.filesContext.walkDirs["/workspace/fakeDeps/apatheia/*.nimble"] = @[]
    let res = findNimbleFile(c, u, "/workspace/fakeDeps/apatheia")
    check res == string.none

  test "ambiguous":
    osutils.filesContext.walkDirs["/workspace/fakeDeps/apatheia/*.nimble"] = @[
      "/workspace/fakeDeps/apatheia.nimble",
      "/workspace/fakeDeps/nim-apatheia.nimble"
    ]
    let res = findNimbleFile(c, u, "/workspace/fakeDeps/apatheia")
    check res == string.none
    check c.errors == 1

  test "check module name recovery":
    osutils.filesContext.walkDirs["/workspace/fakeDeps/apatheia/*.nimble"] = @[
      "/workspace/fakeDeps/apatheia.nimble",
      "/workspace/fakeDeps/nim-apatheia.nimble"
    ]
    let res = findNimbleFile(c, u, "/workspace/fakeDeps/apatheia")
    check res == string.none


suite "tests":
  test "basic":

    setupDepsAndGraph("https://github.com/codex-storage/apatheia.git")
    echo "U: ", u
    # echo "G: ", g.toJson().pretty()



