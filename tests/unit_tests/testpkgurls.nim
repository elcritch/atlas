
import std/unittest

import context, satvars, sat, gitops, runners, reporters, nimbleparser, pkgurls, cloner, versions
import compiledpatterns
import pkgurls
import depgraphs

suite "tests":
  test "basic":
    let
      p = initPatterns()
      u = createUrl("https://github.com/codex-storage/apatheia.git", p)
    var
      c: AtlasContext
      g = createGraph(c, u)
    let
      d = Dependency()


