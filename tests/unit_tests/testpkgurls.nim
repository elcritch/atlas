
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
    setupDepsAndGraph("https://github.com/elcritch/apatheia.git")
    check $u == "https://github.com/elcritch/apatheia.git"
    check u.projectName == "apatheia"

  test "basic url no git":
    setupDepsAndGraph("https://github.com/elcritch/apatheia")
    check $u == "https://github.com/elcritch/apatheia"
    check u.projectName == "apatheia"

  test "basic url prefix":
    setupDepsAndGraph("https://github.com/elcritch/nim-apatheia")
    check $u == "https://github.com/elcritch/nim-apatheia"
    check u.projectName == "nim-apatheia"

suite "nimble stuff":
  setup:
    setupDepsAndGraph("https://github.com/elcritch/apatheia")
    osutils.filesContext.currDir = "/workspace/"
    osutils.filesContext.absPaths["/workspace/fakeDeps/apatheia/*.nimble"] = "/workspace/fakeDeps/apatheia.nimble"
    osutils.filesContext.walkDirs["/workspace/fakeDeps/apatheia/*.nimble"] = @["/workspace/fakeDeps/apatheia.nimble"]

  test "basic nimble path":
    let dir = "/workspace/fakeDeps/apatheia"
    let res = findNimbleFile(c, u, dir)
    check res == some("/workspace/fakeDeps/apatheia.nimble")
    echo "nimble res: ", res

  test "basic nimble path using currdir":
    osutils.filesContext.currDir = "/workspace/fakeDeps/apatheia"
    let res = findNimbleFile(c, u)
    check res == some("/workspace/fakeDeps/apatheia.nimble")
    echo "nimble res: ", res


suite "tests":
  test "basic":

    setupDepsAndGraph("https://github.com/codex-storage/apatheia.git")
    echo "U: ", u
    # echo "G: ", g.toJson().pretty()



