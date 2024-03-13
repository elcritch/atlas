
import std/unittest
import std/strutils
import std/paths
import std/options

import context, satvars, sat, gitops, runners, reporters, nimbleparser, pkgurls, cloner, versions
import osutils
import compiledpatterns
import pkgurls
import depgraphs

proc toDirSep(s: string): string =
  result = s.replace("/", $DirSep)

template setupDepsAndGraph(url: string) =
  var
    p {.inject.} = initPatterns()
    u {.inject.} = createUrl(url, p)
    c {.inject.} = AtlasContext()
    g {.inject.} = createGraph(c, u, readConfig = false)
    d {.inject.} = Dependency()

  c.depsDir = "fakeDeps"
  c.workspace = "/workspace/".toDirSep
  c.projectDir = "/workspace".toDirSep

suite "test pkgurls":

  test "basic url":
    setupDepsAndGraph("https://github.com/example/proj.git")
    check $u == "https://github.com/example/proj.git"
    check u.projectName == "proj"
