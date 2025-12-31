# Small program that runs the test cases

import std / [strutils, os, uri, jsonutils, json, sets, tables, sequtils, strformat, unittest]
import std/terminal
import basic/[sattypes, context, reporters, pkgurls, compiledpatterns, versions]
import basic/[deptypes, nimblecontext, repocache]
import dependencies
import depgraphs
import testerutils

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

suite "graph solve":
  setup:
    # setAtlasVerbosity(Warning)
    # setAtlasVerbosity(Trace)
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().flags.incl DumbProxy
    context().depsDir = Path "deps"
    setAtlasErrorsColor(fgMagenta)


  test "expand using http urls":
      # setAtlasVerbosity(Info)
      withDir "tests/ws_semver_unit":
        removeDir("deps")
        project(paths.getCurrentDir())
        context().flags = {KeepWorkspace, ListVersions}
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

        var graph = dir.expandGraph(nc, AllReleases, onClone=DoClone)

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

        let formMinVer = graph.toFormular(MinVer)
        context().flags.incl DumpGraphs
        var solMinVer: Solution
        solve(graph, formMinVer)

        check $graph.root.activeVersion == "#head@-"
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion == $findCommit("proj_a", "1.0.0")
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion == $findCommit("proj_b", "1.0.0")
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion == $findCommit("proj_c", "1.2.0")
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion == $findCommit("proj_d", "1.0.0")

        check graph.validateDependencyGraph()
        let topo = graph.toposorted()

        check topo[0].url.projectName == "proj_d"
        check topo[1].url.projectName == "proj_c"
        check topo[2].url.projectName == "proj_b"
        check topo[3].url.projectName == "proj_a"

        for pkg in topo:
          echo "PKG: ", pkg.url.projectName

  test "ws_semver_unit with patterns":
      ## Supporting Patterns suck, so here's a test to ensure they work
      # setAtlasVerbosity(Trace)
      withDir "tests/ws_semver_unit":
        removeDir("deps")
        project(paths.getCurrentDir())
        context().flags = {KeepWorkspace, ListVersions}
        context().defaultAlgo = SemVer
        discard context().nameOverrides.addPattern("proj$+", "https://example.com/buildGraph/proj$#")

        expectedVersionWithGitTags()
        var nc = createNimbleContext()

        let dir = paths.getCurrentDir().absolutePath

        var graph = dir.expandGraph(nc, AllReleases, onClone=DoClone)

        let sp = graph.pkgs.values().toSeq()

        doAssert sp.len() == 5

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

        let formMinVer = graph.toFormular(MinVer)
        context().flags.incl DumpGraphs
        var solMinVer: Solution
        solve(graph, formMinVer)


        check $graph.root.activeVersion == "#head@-"
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion == $findCommit("proj_a", "1.0.0")
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion == $findCommit("proj_b", "1.0.0")
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion == $findCommit("proj_c", "1.2.0")
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion == $findCommit("proj_d", "1.0.0")

        check graph.validateDependencyGraph()
        let topo = graph.toposorted()

        check topo[0].url.projectName == "proj_d.buildGraph.example.com"
        check topo[1].url.projectName == "proj_c.buildGraph.example.com"
        check topo[2].url.projectName == "proj_b.buildGraph.example.com"
        check topo[3].url.projectName == "proj_a.buildGraph.example.com"

        for pkg in topo:
          echo "PKG: ", pkg.url.projectName

suite "test expand with no git tags":
  setup:
    setAtlasVerbosity(Warning)
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().flags.incl DumbProxy
    context().depsDir = Path "deps"
    setAtlasErrorsColor(fgMagenta)

  test "expand using buildGraphNoGitTags":
      # setAtlasVerbosity(Info)
      withDir "tests/ws_semver_unit":
        removeDir("deps")
        project(paths.getCurrentDir())
        context().flags = {KeepWorkspace, ListVersions}
        context().defaultAlgo = SemVer

        expectedVersionWithNoGitTags()

        var nc = createNimbleContext()
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraphNoGitTags/proj_a", true))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraphNoGitTags/proj_b", true))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraphNoGitTags/proj_c", true))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraphNoGitTags/proj_d", true))

        let dir = paths.getCurrentDir().absolutePath

        var graph = dir.expandGraph(nc, AllReleases, onClone=DoClone)

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
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion.version == "1.1.0"
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion.version == "1.1.0"
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion.version == "1.2.0"
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion.version == "1.0.0"

        let formMinVer = graph.toFormular(MinVer)
        context().flags.incl DumpGraphs
        var solMinVer: Solution
        solve(graph, formMinVer)

        check $graph.root.activeVersion == "#head@-"
        check $graph.pkgs[nc.createUrl("proj_a")].activeVersion.version == "1.0.0"
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion.version == "1.0.0"
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion.version == "1.2.0"
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion.version == "1.0.0"

        check graph.validateDependencyGraph()
        let topo = graph.toposorted()

        check topo[0].url.projectName == "proj_d"
        check topo[1].url.projectName == "proj_c"
        check topo[2].url.projectName == "proj_b"
        check topo[3].url.projectName == "proj_a"

        for pkg in topo:
          echo "PKG: ", pkg.url.projectName


  test "expand using buildGraphNoGitTags with explicit versions":
      # setAtlasVerbosity(Trace)
      withDir "tests/ws_testtraverse_explicit":
        removeDir("deps")
        project(paths.getCurrentDir())
        context().flags = {KeepWorkspace, ListVersions}
        context().defaultAlgo = SemVer

        expectedVersionWithGitTags()

        let projAexplicit = projAnimbles[2]
        echo "projAnimbles: ", projAnimbles
        echo "projAexplicit: ", projAexplicit

        writeFile("ws_testtraverse_explicit.nimble", "requires \"proj_a#$1\"\n" % [$projAexplicit.commit.short()])

        var nc = createNimbleContext()
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a"))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b"))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c"))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d"))

        let dir = paths.getCurrentDir().absolutePath

        var graph = dir.expandGraph(nc, AllReleases, onClone=DoClone)

        checkpoint "\tgraph:\n" & $graph.toJson(ToJsonOptions(enumMode: joptEnumString))

        echo "explicit versions: "
        for pkgUrl, commits in nc.explicitVersions.pairs:
          echo "\tversions: ", pkgUrl, " commits: ", commits.toSeq().mapIt($it).join("; ")

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
        check graph.pkgs[nc.createUrl("proj_a")].activeVersion.version.string.startsWith("#")
        check $graph.pkgs[nc.createUrl("proj_b")].activeVersion.version == "1.1.0"
        check $graph.pkgs[nc.createUrl("proj_c")].activeVersion.version == "1.2.0"
        check $graph.pkgs[nc.createUrl("proj_d")].activeVersion.version == "1.0.0"


        check $graph.root.activeVersion == "#head@-"


suite "sat solver head selection":
  setup:
    context().flags = {}
    context().features = initHashSet[string]()
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().defaultAlgo = SemVer

  test "prefers tagged releases over #head from cached versions":
    var nc = createUnfilledNimbleContext()
    nc.put("root", toPkgUriRaw(parseUri "https://example.com/root"))
    nc.put("dep", toPkgUriRaw(parseUri "https://example.com/dep"))

    let rootUrl = nc.createUrl("root")
    let depUrl = nc.createUrl("dep")

    var root = Package(url: rootUrl, isRoot: true, state: Processed)
    var dep = Package(url: depUrl, state: Processed)

    root.versions = initOrderedTable[PackageVersion, NimbleRelease]()
    dep.versions = initOrderedTable[PackageVersion, NimbleRelease]()

    var err = false
    let depReq = parseVersionInterval(">= 1.0.0", 0, err)
    doAssert not err

    let rootTag = VersionTag(v: Version"0.1.0", c: initCommitHash("root", FromNone))
    let rootRelease = NimbleRelease(
      version: Version"0.1.0",
      status: Normal,
      requirements: @[(depUrl, depReq)],
      reqsByFeatures: initTable[PkgUrl, HashSet[string]](),
      features: initTable[string, seq[(PkgUrl, VersionInterval)]](),
      featureVars: initTable[string, VarId]()
    )
    root.versions[rootTag.toPkgVer] = rootRelease

    let cachePath = Path(getTempDir()) / Path("atlas-cache-head-" & $getCurrentProcessId() & ".json")
    let cacheJson = %*{
      "cacheVersion": RepoCacheFormatVersion,
      "repo": %*{},
      "nimbleFiles": %*[],
      "git": %*{},
      "versions": %*[
        %*{
          "version": "1.0.0",
          "versionTag": "1.0.0@rel",
          "isTip": false,
          "commit": "rel",
          "status": "Normal",
          "hasInstallHooks": false,
          "requirements": %*[],
          "features": %*{},
          "featureFlags": %*{}
        },
        %*{
          "version": "#head",
          "versionTag": "#head@head",
          "isTip": true,
          "commit": "head",
          "status": "Normal",
          "hasInstallHooks": false,
          "releaseVersion": "1.0.0",
          "requirements": %*[],
          "features": %*{},
          "featureFlags": %*{}
        }
      ],
      "packageErrors": %*[]
    }
    writeFile($cachePath, $cacheJson)
    check loadVersionsFromArchiveCache(nc, dep, cachePath)
    dep.state = Processed
    var hasHead = false
    for ver, rel in dep.versions:
      if ver.vtag.v.isHead:
        hasHead = true

    var graph = DepGraph(root: root)
    initSharedOrderedTable(graph.pkgs)
    graph.pkgs[rootUrl] = root
    graph.pkgs[depUrl] = dep

    let form = graph.toFormular(SemVer)
    solve(graph, form)

    check not graph.pkgs[depUrl].activeVersion.vtag.v.isHead
    check graph.pkgs[depUrl].activeVersion.version == Version"1.0.0"


infoNow "tester", "All tests run successfully"
