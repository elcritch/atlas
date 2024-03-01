
import std/unittest
import std/json

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

test "nimble stuff":
  test "basic nimble path":
    setupDepsAndGraph("https://github.com/elcritch/apatheia")
    c.depsDir = "fakeDeps"
    c.workspace = "/workspace/"
    c.projectDir = "/workspace"
    osutils.filesContext.absPaths["apatheia.nimble"] = "/workspace/fakeDeps/apatheia.nimble"
    osutils.filesContext.walkDirs["*.nimble"] = @["/workspace/fakeDeps/apatheia.nimble"]

    let res = findNimbleFile(c, u)
    echo "nimble res: ", res


suite "tests":
  test "basic":

    setupDepsAndGraph("https://github.com/codex-storage/apatheia.git")
    echo "U: ", u
    # echo "G: ", g.toJson().pretty()



