
import std/unittest
import std/strutils
import std/os
import std/tempfiles
import std/options

import ../setups

import context, reporters, nimbleparser, pkgurls
import compiledpatterns
import compiledpatterns
import pkgurls
import depgraphs

proc toDirSep(s: string): string =
  result = s.replace("/", $DirSep)

template setupDepsAndGraph(dir: string) =
  var
    p {.inject.} = initPatterns()
    u {.inject.} = createUrl("file://" & dir, p)
    c {.inject.} = AtlasContext()
    g {.inject.} = createGraph(c, u, readConfig = false)
    d {.inject.} = Dependency()

  c.depsDir = "fakeDeps"
  c.workspace = "/workspace/".toDirSep
  c.projectDir = "/workspace".toDirSep

suite "test pkgurls":

  test "basic url":
    withTempTestDir "basic_url":
      buildGraphNoGitTags()
      setupDepsAndGraph(dir)
      let versions = collectNimbleVersions(c, d)
      echo "VERSIONS: ", versions

