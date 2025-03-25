# Small program that runs the test cases

import std / [strutils, os, uri, jsonutils, json, tables, sequtils, unittest]
import std/terminal

import basic/[sattypes, context, reporters, pkgurls, compiledpatterns, versions]
import basic/[deptypes, nimblecontext, deptypesjson]
import dependencies
import depgraphs
import testerutils
import atlas, confighandler

ensureGitHttpServer()

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
        exec("git clone http://localhost:4242/buildGraphNoGitTags/$1" % [proj])
  for proj in projs:
    result.add(ospaths2.getCurrentDir() / "buildGraphNoGitTags" / proj)

suite "test link integration":
  setup:
    # setAtlasVerbosity(Trace)
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().flags.incl DumbProxy
    context().depsDir = Path "deps"
    setAtlasErrorsColor(fgMagenta)

  test "setup and test target project":
      # setAtlasVerbosity(Info)
      setAtlasVerbosity(Error)
      withDir "tests/ws_link_semver":
        removeDir("deps")
        project(paths.getCurrentDir())
        context().flags = {ListVersions}
        context().defaultAlgo = SemVer

        expectedVersionWithGitTags()
        var nc = createNimbleContext()
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a", true))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b", true))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c", true))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d", true))

        check nc.lookup("proj_a").hasShortName
        check nc.lookup("proj_a").projectName == "proj_a"

        let dir = paths.getCurrentDir().absolutePath

        var graph = dir.loadWorkspace(nc, AllReleases, onClone=DoClone, doSolve=true)
        writeDepGraph(graph)

        checkpoint "\tgraph:\n" & $graph.toJson(ToJsonOptions(enumMode: joptEnumString))

        let form = graph.toFormular(SemVer)
        context().flags.incl DumpGraphs
        var sol: Solution
        solve(graph, form)

        check graph.root.active
        check graph.pkgs[nc.createUrl("proj_a")].active
        check graph.pkgs[nc.createUrl("proj_b")].active
        check graph.pkgs[nc.createUrl("proj_c")].active
        check graph.pkgs[nc.createUrl("proj_d")].active

        check $graph.root.activeVersion == "#head@-"
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion == $findCommit("proj_a", "1.1.0")
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion == $findCommit("proj_b", "1.1.0")
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion == $findCommit("proj_c", "1.2.0")
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion == $findCommit("proj_d", "1.0.0")

        # let graph2 = loadJson("graph-solved.json")

        let jnRoot = toJson(graph.root)
        var graphRoot: Package
        graphRoot.fromJson(jnRoot)
        echo "graphRoot: ", $graphRoot.toJson(ToJsonOptions(enumMode: joptEnumString))

        # check graph.toJson(ToJsonOptions(enumMode: joptEnumString)) == graph2.toJson(ToJsonOptions(enumMode: joptEnumString))

  test "expand using http urls with link files":
      setAtlasVerbosity(Warning)
      withDir "tests/ws_link_integration":
        removeDir("deps")
        project(paths.getCurrentDir())
        context().flags = {ListVersions}
        context().defaultAlgo = SemVer

        createDir("deps")
        writeFile("deps" / "atlas.config", dedent"""
        {
          "deps": "deps",
          "nameOverrides": {
            "proj_a": "https://example.com/buildGraph/proj_a",
            "proj_b": "https://example.com/buildGraph/proj_b",
            "proj_c": "https://example.com/buildGraph/proj_c",
            "proj_d": "https://example.com/buildGraph/proj_d"
          }
        }
        """)

        expectedVersionWithGitTags()
        let dir = paths.getCurrentDir().absolutePath

        check project() == paths.getCurrentDir()
        atlasRun(@["link", "../ws_link_semver"])

  test "expand using link files part 2":
      setAtlasVerbosity(Warning)
      withDir "tests/ws_link_integration":
        project(paths.getCurrentDir())
        context().flags = {ListVersions}
        context().defaultAlgo = SemVer

        expectedVersionWithGitTags()
        readConfig()

        var nc = createNimbleContext()
        var graph = project().loadWorkspace(nc, AllReleases, onClone=DoClone, doSolve=true)

        checkpoint "\tgraph:\n" & $graph.toJson(ToJsonOptions(enumMode: joptEnumString))

        let config = readConfigFile(getProjectConfig())
        echo "config: ", $config
        check project() == paths.getCurrentDir()
        check config.nameOverrides.len == 5
        check config.nameOverrides["ws_link_semver"] == toWindowsFileUrl("link://" & $absolutePath($project() /../ "ws_link_semver" / "ws_link_semver.nimble"))

        # let form = graph.toFormular(SemVer)
        # context().flags.incl DumpGraphs
        # var sol: Solution
        # solve(graph, form)

        check graph.root.active
        check graph.pkgs[nc.createUrl("proj_a")].active
        check graph.pkgs[nc.createUrl("proj_b")].active
        check graph.pkgs[nc.createUrl("proj_c")].active
        check graph.pkgs[nc.createUrl("proj_d")].active

        check $graph.root.activeVersion == "#head@-"
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion == $findCommit("proj_a", "1.1.0")
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion == $findCommit("proj_b", "1.1.0")
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion == $findCommit("proj_c", "1.2.0")
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion == $findCommit("proj_d", "1.0.0")


