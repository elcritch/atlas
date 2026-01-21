# Small program that runs the test cases

import std / [strutils, os, uri, jsonutils, json, tables, sequtils, sets, unittest]
import std/terminal

import basic/[sattypes, context, reporters, pkgurls, compiledpatterns, versions]
import basic/[deptypes, nimblecontext, deptypesjson]
import basic/configutils
import dependencies
import depgraphs
import integration_test_utils
import atlas, confighandler

ensureGitHttpServer()

proc setupProjTest() =
  withDir "deps" / "proj_a":
    writeFile("proj_a.nimble", dedent"""
    requires "proj_b >= 1.1.0"
    feature "testing":
      requires "proj_feature_dep >= 1.0.0"
    """)
    exec "git commit -a -m \"feat: add proj_a.nimble\""
    exec "git tag v1.2.0"

  removeDir "proj_feature_dep"
  createDir "proj_feature_dep"
  withDir "proj_feature_dep":
    writeFile("proj_feature_dep.nimble", dedent"""
    version "1.0.0"
    """)
    exec "git init"
    exec "git add proj_feature_dep.nimble"
    exec "git commit -m \"feat: add proj_feature_dep.nimble\""
    exec "git tag v1.0.0"

suite "test features":
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
      withDir "tests/ws_features":
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
        # nc.put("proj_feature_dep", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_feature_dep", true))
        nc.put("proj_feature_dep", toPkgUriRaw(parseUri "file://" & (ospaths2.getCurrentDir() / "proj_feature_dep").absolutePath, true))

        check nc.lookup("proj_a").hasShortName
        check nc.lookup("proj_a").projectName == "proj_a"

        let dir = paths.getCurrentDir().absolutePath

        var graph0 = dir.loadWorkspace(nc, AllReleases, onClone=DoClone, doSolve=false)
        writeDepGraph(graph0)

        setupProjTest()

  test "setup and test target project":
      # setAtlasVerbosity(Info)
      setAtlasVerbosity(Trace)
      withDir "tests/ws_features":
        # removeDir("deps")
        project(paths.getCurrentDir())
        context().flags = {ListVersions}
        context().defaultAlgo = SemVer
        context().flags.incl DumpFormular

        expectedVersionWithGitTags()
        var nc = createNimbleContext()
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a", true))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b", true))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c", true))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d", true))
        # nc.put("proj_feature_dep", toPkgUriRaw(parseUri "deps/proj_feature_dep_git", true))
        nc.put("proj_feature_dep", toPkgUriRaw(parseUri "file://" & (ospaths2.getCurrentDir() / "proj_feature_dep").absolutePath, true))

        check nc.lookup("proj_a").hasShortName
        check nc.lookup("proj_a").projectName == "proj_a"

        let dir = paths.getCurrentDir().absolutePath

        var graph = dir.loadWorkspace(nc, AllReleases, onClone=DoClone, doSolve=true)
        writeDepGraph(graph)

        # checkpoint "\tgraph:\n" & $graph.toJson(ToJsonOptions(enumMode: joptEnumString))

        # check false

        # let form = graph.toFormular(SemVer)
        # context().flags.incl DumpGraphs
        # var sol: Solution
        # solve(graph, form)

        check graph.root.active
        check graph.pkgs[nc.createUrl("proj_a")].active
        check graph.pkgs[nc.createUrl("proj_b")].active
        check graph.pkgs[nc.createUrl("proj_c")].active
        check graph.pkgs[nc.createUrl("proj_d")].active
        check graph.pkgs[nc.createUrl("proj_feature_dep")].active

        check $graph.root.activeVersion == "#head@-"
        # check $graph.pkgs[nc.createUrl("proj_a")].activeVersion == $findCommit("proj_a", "1.1.0")
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion.vtag.version == "1.2.0"
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion == $findCommit("proj_b", "1.1.0")
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion == $findCommit("proj_c", "1.2.0")
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion == $findCommit("proj_d", "1.0.0")
        check $graph.pkgs[nc.createUrl("proj_feature_dep")].activeVersion.vtag.version == "1.0.0"

        # let graph2 = loadJson("graph-solved.json")

        let jnRoot = toJson(graph.root)
        var graphRoot: Package
        graphRoot.fromJson(jnRoot)
        echo "graphRoot: ", $graphRoot.toJson(ToJsonOptions(enumMode: joptEnumString))

        # check graph.toJson(ToJsonOptions(enumMode: joptEnumString)) == graph2.toJson(ToJsonOptions(enumMode: joptEnumString))

suite "test global features":
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
      withDir "tests/ws_features_global":
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
        # nc.put("proj_feature_dep", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_feature_dep", true))
        nc.put("proj_feature_dep", toPkgUriRaw(parseUri "file://" & (ospaths2.getCurrentDir() / "proj_feature_dep").absolutePath, true))

        check nc.lookup("proj_a").hasShortName
        check nc.lookup("proj_a").projectName == "proj_a"

        let dir = paths.getCurrentDir().absolutePath

        var graph0 = dir.loadWorkspace(nc, AllReleases, onClone=DoClone, doSolve=false)
        writeDepGraph(graph0)

        setupProjTest()

  test "setup and test target project":
      # setAtlasVerbosity(Info)
      setAtlasVerbosity(Trace)
      withDir "tests/ws_features_global":
        # removeDir("deps")
        project(paths.getCurrentDir())
        context().flags = {ListVersions}
        context().defaultAlgo = SemVer
        context().flags.incl DumpFormular
        context().features.incl "feature.proj_a.testing"

        expectedVersionWithGitTags()
        var nc = createNimbleContext()
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a", true))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b", true))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c", true))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d", true))
        # nc.put("proj_feature_dep", toPkgUriRaw(parseUri "deps/proj_feature_dep_git", true))
        nc.put("proj_feature_dep", toPkgUriRaw(parseUri "file://" & (ospaths2.getCurrentDir() / "proj_feature_dep").absolutePath, true))

        check nc.lookup("proj_a").hasShortName
        check nc.lookup("proj_a").projectName == "proj_a"

        let dir = paths.getCurrentDir().absolutePath

        var graph = dir.loadWorkspace(nc, AllReleases, onClone=DoClone, doSolve=true)
        writeDepGraph(graph)

        # checkpoint "\tgraph:\n" & $graph.toJson(ToJsonOptions(enumMode: joptEnumString))

        # check false

        # let form = graph.toFormular(SemVer)
        # context().flags.incl DumpGraphs
        # var sol: Solution
        # solve(graph, form)

        check graph.root.active
        check graph.pkgs[nc.createUrl("proj_a")].active
        check graph.pkgs[nc.createUrl("proj_b")].active
        check graph.pkgs[nc.createUrl("proj_c")].active
        check graph.pkgs[nc.createUrl("proj_d")].active
        check nc.createUrl("proj_feature_dep") in graph.pkgs
        check graph.pkgs[nc.createUrl("proj_feature_dep")].active

        check $graph.root.activeVersion == "#head@-"
        # check $graph.pkgs[nc.createUrl("proj_a")].activeVersion == $findCommit("proj_a", "1.1.0")
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion.vtag.version == "1.2.0"
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion == $findCommit("proj_b", "1.1.0")
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion == $findCommit("proj_c", "1.2.0")
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion == $findCommit("proj_d", "1.0.0")
        check $graph.pkgs[nc.createUrl("proj_feature_dep")].activeVersion.vtag.version == "1.0.0"

        # let graph2 = loadJson("graph-solved.json")

        let jnRoot = toJson(graph.root)
        var graphRoot: Package
        graphRoot.fromJson(jnRoot)
        echo "graphRoot: ", $graphRoot.toJson(ToJsonOptions(enumMode: joptEnumString))

        # check graph.toJson(ToJsonOptions(enumMode: joptEnumString)) == graph2.toJson(ToJsonOptions(enumMode: joptEnumString))

suite "test feature defines in nim.cfg":
  setup:
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().flags.incl DumbProxy
    context().depsDir = Path "deps"
    setAtlasErrorsColor(fgMagenta)

  test "patchNimCfg writes feature defines to nim.cfg":
      ## Test that patchNimCfg correctly writes --define:feature.* lines
      setAtlasVerbosity(Error)
      withDir "tests/ws_features":
        removeFile("nim.cfg")
        project(paths.getCurrentDir())

        # Call patchNimCfg with test features
        let testFeatures = @["feature.proj_a.testing", "feature.proj_b.debug"]
        patchNimCfg(@[], CfgPath(paths.getCurrentDir()), testFeatures)

        # Read the generated nim.cfg and verify it contains the defines (with quotes)
        let cfgContent = readFile("nim.cfg")
        check "--define:\"feature.proj_a.testing\"" in cfgContent
        check "--define:\"feature.proj_b.debug\"" in cfgContent

        # Clean up
        removeFile("nim.cfg")

  test "--feature:FOO expands to feature.$PROJECT.FOO":
      ## Test that --feature:FOO (without prefix) becomes feature.$ROOT.FOO
      ## and --feature:feature.pkg.bar stays as feature.pkg.bar
      setAtlasVerbosity(Error)
      withDir "tests/ws_features":
        removeFile("nim.cfg")
        project(paths.getCurrentDir())
        context().flags = {ListVersions}
        context().defaultAlgo = SemVer
        context().features.clear()

        # Simulate --feature:myfeature (short form) and --feature:feature.other.bar (full form)
        context().features.incl "myfeature"
        context().features.incl "feature.otherpkg.bar"

        # Create a minimal graph with just a root package
        var graph = DepGraph()
        graph.root = Package(
          url: toPkgUriRaw(parseUri "atlas:///test/ws_features/ws_features.nimble", true),
          state: Processed,
          active: true,
          isRoot: true
        )
        graph.pkgs[graph.root.url] = graph.root

        let (paths, features) = graph.activateGraph()

        # Short form --feature:myfeature should become feature.ws_features.myfeature
        check "feature.ws_features.myfeature" in features

        # Full form --feature:feature.otherpkg.bar should stay as-is
        check "feature.otherpkg.bar" in features

        # Clean up
        context().features.clear()
        removeFile("nim.cfg")

  test "activateGraph returns feature defines for requires syntax":
      ## Test that requires "proj_a[testing]" results in feature defines
      ## This test depends on the "test features" suite having run first
      setAtlasVerbosity(Error)
      withDir "tests/ws_features":
        removeFile("nim.cfg")
        project(paths.getCurrentDir())
        context().flags = {ListVersions}
        context().defaultAlgo = SemVer
        context().features.clear()

        expectedVersionWithGitTags()
        var nc = createNimbleContext()
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a", true))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b", true))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c", true))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d", true))
        nc.put("proj_feature_dep", toPkgUriRaw(parseUri "file://" & (ospaths2.getCurrentDir() / "proj_feature_dep").absolutePath, true))

        let dir = paths.getCurrentDir().absolutePath

        var graph = dir.loadWorkspace(nc, AllReleases, onClone=DoClone, doSolve=true)
        let (paths, features) = graph.activateGraph()

        # Verify the feature defines are returned
        check "feature.proj_a.testing" in features

        # Verify activeFeatures is set on the package
        check "testing" in graph.pkgs[nc.createUrl("proj_a")].activeFeatures

  test "activateGraph returns feature defines for --feature flag (global)":
      ## Test that --feature:testing (via context().features) results in feature defines
      ## This test depends on the "test global features" suite having run first
      setAtlasVerbosity(Error)
      withDir "tests/ws_features_global":
        removeFile("nim.cfg")
        project(paths.getCurrentDir())
        context().flags = {ListVersions}
        context().defaultAlgo = SemVer
        context().features.clear()
        context().features.incl "feature.proj_a.testing"

        expectedVersionWithGitTags()
        var nc = createNimbleContext()
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a", true))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b", true))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c", true))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d", true))
        nc.put("proj_feature_dep", toPkgUriRaw(parseUri "file://" & (ospaths2.getCurrentDir() / "proj_feature_dep").absolutePath, true))

        let dir = paths.getCurrentDir().absolutePath

        var graph = dir.loadWorkspace(nc, AllReleases, onClone=DoClone, doSolve=true)
        let (paths, features) = graph.activateGraph()

        # Verify the feature defines are returned
        check "feature.proj_a.testing" in features

        # Verify activeFeatures is set on the package
        check "testing" in graph.pkgs[nc.createUrl("proj_a")].activeFeatures
