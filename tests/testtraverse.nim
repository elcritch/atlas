# Small program that runs the test cases

import std / [strutils, os, uri, jsonutils, json, sets, tables, sequtils, algorithm, strformat, unittest]
import std/terminal
import basic/[sattypes, context, reporters, pkgurls, compiledpatterns, versions]
import basic/[deptypes, nimblecontext]
import dependencies, depgraphs
import testerutils

# if not dirExists("tests/ws_testtraverse/buildGraph"):
ensureGitHttpServer()

# proc createGraph*(s: PkgUrl): DepGraph =
#   result = DepGraph(nodes: @[], reqs: defaultReqs())
#   result.packageToDependency[s] = result.nodes.len
#   result.nodes.add Package(pkg: s, versions: @[], isRoot: true, isTopLevel: true, activeRelease: -1)


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

template testRequirements(sp: Package,
                          projTags: seq[VersionTag],
                          vers: openArray[(string, string)];
                          skipCount = false) =
  checkpoint "Checking Requirements: " & astToStr(sp)
  if not skipCount:
    check sp.versions.len() == vers.len()

  for idx, vt in projTags:
    # let vt = projTags[idx]
    let vt = vt.toPkgVer
    checkpoint "Checking requirements item: " & $vers[idx] & " version: " & $vt
    check idx < vers.len()
    let (url, ver) = vers[idx]
    check sp.state == Processed
    checkpoint "Checking sp versions: " & $sp.versions.keys.toSeq.mapIt(it.vtag)
    check vt in sp.versions
    if vt in sp.versions:
      check sp.versions[vt].status == Normal
      if not skipCount:
        check sp.versions[vt].requirements.len() == 1

      if url != "":
        check $sp.versions[vt].requirements[0][0] == url
      if ver != "":
        check $sp.versions[vt].requirements[0][1] == ver

suite "test expand with git tags":
  setup:
    setAtlasVerbosity(Error)
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().flags.incl DumbProxy
    context().depsDir = Path "deps"
    setAtlasErrorsColor(fgMagenta)

    expectedVersionWithGitTags()

  test "collect nimbles":
      # setAtlasVerbosity(Trace)
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        context().flags = {KeepWorkspace, ListVersions}
        context().defaultAlgo = SemVer
        # discard context().overrides.addPattern("$+", "file://./buildGraph/$#")
        project(paths.getCurrentDir())

        let dir = paths.getCurrentDir()
        # writeFile("ws_testtraverse.nimble", "requires \"proj_a\"\n")

        let deps = setupGraph()
        var nc = createNimbleContext()
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a"))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b"))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c"))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d"))
        # var graph = DepGraph(nodes: @[], reqs: defaultReqs())
        echo "DIR: ", dir
        let url = nc.createUrlFromPath(dir)
        echo "URL: ", url

        check url.toDirectoryPath() == Path(project())

        var dep0 = Package(url: url, isRoot: true)
        var dep1 = Package(url: nc.createUrl("proj_a"))
        var dep2 = Package(url: nc.createUrl("proj_b"))
        var dep3 = Package(url: nc.createUrl("proj_c"))
        var dep4 = Package(url: nc.createUrl("proj_d"))

        nc.loadDependency(dep0)
        nc.loadDependency(dep1)
        nc.loadDependency(dep2)
        nc.loadDependency(dep3)
        nc.loadDependency(dep4)

        check dep0.state == Found
        check dep0.ondisk == Path(project())
        check dep1.state == Found
        check dep1.ondisk == Path(project().string / "deps" / "proj_a")
        check dep2.state == Found
        check dep2.ondisk == Path(project().string / "deps" / "proj_b")
        check dep3.state == Found
        check dep3.ondisk == Path(project().string / "deps" / "proj_c")
        check dep4.state == Found
        check dep4.ondisk == Path(project().string / "deps" / "proj_d")

        check collectNimbleVersions(nc, dep0) == newSeq[VersionTag]()
        proc tolist(tags: seq[VersionTag]): seq[string] = tags.mapIt($VersionTag(v: Version"", c: it.c)).sorted()

        echo "projAnimbles: ", collectNimbleVersions(nc, dep1)
        check collectNimbleVersions(nc, dep1).tolist() == projAnimbles.tolist()
        check collectNimbleVersions(nc, dep2).tolist() == projBnimbles.tolist()
        check collectNimbleVersions(nc, dep3).tolist() == projCnimbles.tolist()
        check collectNimbleVersions(nc, dep4).tolist() == projDnimbles.tolist()

  test "expand from file":
      #setAtlasVerbosity(Trace)
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        project(paths.getCurrentDir())
        context().flags = {KeepWorkspace, ListVersions}
        context().defaultAlgo = SemVer
        discard context().nameOverrides.addPattern("$+", "file://./buildGraph/$#")

        var nc = createNimbleContext()

        let deps = setupGraph()
        let dir = paths.getCurrentDir().absolutePath

        let graph = dir.expandGraph(nc, AllReleases, onClone=DoClone)

        checkpoint "\tgraph:\n" & $graph.toJson(ToJsonOptions(enumMode: joptEnumString))
        let sp = graph.pkgs.values().toSeq()

        check sp.len() == 5
        doAssert sp.len() == 5

        let sp0: Package = sp[0] # proj ws_testtraversal
        let sp1: Package = sp[1] # proj A 
        let sp2: Package = sp[2] # proj B
        let sp3: Package = sp[3] # proj C
        let sp4: Package = sp[4] # proj D

        check $sp0.url.url.scheme == "atlas" and endsWith($sp0.url, "ws_testtraverse.nimble")

        check $sp1.url == toWindowsFileUrl("file://$1/buildGraph/proj_a" % [$dir])  
        check $sp2.url == toWindowsFileUrl("file://$1/buildGraph/proj_b" % [$dir])
        check $sp3.url == toWindowsFileUrl("file://$1/buildGraph/proj_c" % [$dir])
        check $sp4.url == toWindowsFileUrl("file://$1/buildGraph/proj_d" % [$dir])

        let vt = toVersionTag

        testRequirements(sp0, @[vt"#head@-"], [
          (toWindowsFileUrl("file://$1/buildGraph/proj_a" % [$dir]), "*"),
        ])


        # verify that the duplicate releases have been "reduced"
        # check sp1.releases[projAtags[1]] == sp1.releases[projAtags[2]]
        # check cast[pointer](sp1.releases[projAtags[1]]) == cast[pointer](sp1.releases[projAtags[2]])
        testRequirements(sp1, projAtags, [
          (toWindowsFileUrl("file://$1/buildGraph/proj_b" % [$dir]), ">= 1.1.0"),
          (toWindowsFileUrl("file://$1/buildGraph/proj_b" % [$dir]), ">= 1.0.0"),
        ])

        testRequirements(sp2, projBtags, [
          (toWindowsFileUrl("file://$1/buildGraph/proj_c" % [$dir]), ">= 1.1.0"),
          (toWindowsFileUrl("file://$1/buildGraph/proj_c" % [$dir]), ">= 1.0.0"),
        ])

        testRequirements(sp3, projCtags, [
          (toWindowsFileUrl("file://$1/buildGraph/proj_d" % [$dir]), ">= 1.0.0"),
        ])

        testRequirements(sp4, projDtags, [
          (toWindowsFileUrl("file://$1/buildGraph/does_not_exist" % [$dir]), ">= 1.2.0"),
          ("", ""),
        ], true)

  test "expand from http":
      withDir "tests/ws_testtraverse":
        # setAtlasVerbosity(Trace)
        removeDir("deps")
        project(paths.getCurrentDir())
        context().flags = {KeepWorkspace, ListVersions}
        context().defaultAlgo = SemVer
        context().depsDir = Path "deps_http"
        context().nameOverrides = Patterns()

        var nc = createNimbleContext()
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a"))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b"))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c"))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d"))
        # nc.nameToUrl["does_not_exist"] = toPkgUri(parseUri "https://example.com/buildGraph/does_not_exist")

        let pkgA = nc.createUrl("proj_a")

        check $pkgA == "https://example.com/buildGraph/proj_a"

        # let deps = setupGraph()
        let dir = paths.getCurrentDir().absolutePath

        let graph = dir.expandGraph(nc, AllReleases, onClone=DoClone)

        checkpoint "\tgraph:\n" & $graph.toJson(ToJsonOptions(enumMode: joptEnumString))
        let sp = graph.pkgs.values().toSeq()
        let vt = toVersionTag

        check sp.len() == 5
        check $sp[0].url.url.scheme == "atlas" and endsWith($sp[0].url, "ws_testtraverse.nimble")

        check $sp[1].url == "https://example.com/buildGraph/proj_a"
        check $sp[2].url == "https://example.com/buildGraph/proj_b"
        check $sp[3].url == "https://example.com/buildGraph/proj_c"
        check $sp[4].url == "https://example.com/buildGraph/proj_d"

        let sp0: Package = sp[0] # proj ws_testtraversal
        testRequirements(sp0, @[vt"#head@-"], [
          ("https://example.com/buildGraph/proj_a", "*"),
        ])

  test "expand and then enrich with specific versions from requirements":
    # setAtlasVerbosity(Trace)
    withDir "tests//ws_testtraverse_explicit":
      removeDir("deps")
      project(paths.getCurrentDir())
      context().flags = {KeepWorkspace, ListVersions}
      context().defaultAlgo = SemVer

      let projAexplicit = projAnimbles[2]
      echo "projAnimbles: ", projAnimbles
      echo "projAexplicit: ", projAexplicit
      writeFile("ws_testtraverse_explicit.nimble", "requires \"proj_a#$1\"\n" % [$projAexplicit.commit.short()])

      let deps = setupGraph()
      var nc = createNimbleContext()
      nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a"))
      nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b"))
      nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c"))
      nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d"))

      # TODO: add a specific version to the requirements for a to include non-tagged 7ca5581cd
      # TODO: then check that the expanded graph has the correct version
      let graph = project().expandGraph(nc, AllReleases, onClone=DoClone)

      checkpoint "\tgraph:\n" & $graph.toJson(ToJsonOptions(enumMode: joptEnumString))

      let sp = graph.pkgs.values().toSeq()
      doAssert sp.len() == 5
      let sp0: Package = sp[0] # proj ws_testtraversal
      let sp1: Package = sp[1] # proj A
      let sp1Commit = projAnimbles[1].c

      var err = false
      let query = parseVersionInterval("#" & sp1Commit.h[0..7], 0, err)

      let reqs = sp0.versions.pairs().toSeq()[0][1].requirements
      echo "reqs: ", reqs.repr

      var foundMatch = false
      for depVer, relVer in sp1.validVersions():
        let matches = query.matches(depVer)
        echo "MATCHES: ", matches, " ", depVer.version()
        if matches:
          foundMatch = true
          

      check foundMatch
      echo "explicit versions: "
      for pkgUrl, commits in nc.explicitVersions.pairs:
        echo "\tversions: ", pkgUrl, " commits: ", commits.toSeq().mapIt($it).join("; ")

  test "expand from link file":
      withDir "tests/ws_testtraverse":
        setAtlasVerbosity(Error)
        removeDir("deps")
        let deps = setupGraph()

        var nc = createNimbleContext()
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a"))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b"))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c"))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d"))
        # nc.nameToUrl["does_not_exist"] = toPkgUri(parseUri "https://example.com/buildGraph/does_not_exist")

        let pkgA = nc.createUrl("proj_a")

        check $pkgA == "https://example.com/buildGraph/proj_a"

        # let deps = setupGraph()
        let dir = paths.getCurrentDir().absolutePath

        let graph = dir.expandGraph(nc, AllReleases, onClone=DoClone)

      withDir "tests/ws_testtraverselinked":
        setAtlasVerbosity(Warning)
        removeDir("deps")
        project(paths.getCurrentDir())
        context().flags = {KeepWorkspace, ListVersions}
        context().defaultAlgo = SemVer
        context().depsDir = Path "deps"
        context().nameOverrides = Patterns()

        let ws_testtraverse = Path(".." / "ws_testtraverse").absolutePath()
        let deps = Path(".." / "ws_testtraverse" / "deps").absolutePath()
        let proj_a = Path(".." / "ws_testtraverse" / "deps" / "proj_a").absolutePath()
        let proj_b = Path(".." / "ws_testtraverse" / "deps" / "proj_b").absolutePath()
        let proj_c = Path(".." / "ws_testtraverse" / "deps" / "proj_c").absolutePath()
        let proj_d = Path(".." / "ws_testtraverse" / "deps" / "proj_d").absolutePath()

        discard context().nameOverrides.addPattern("ws_testtraverse", toWindowsFileUrl("link://" & $(ws_testtraverse / Path("ws_testtraverse.nimble"))))

        var nc = createNimbleContext()
        nc.put("ws_testtraverse", toPkgUriRaw(parseUri "https://example.com/buildGraph/ws_testtraverse"))
        nc.put("proj_a", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_a"))
        nc.put("proj_b", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_b"))
        nc.put("proj_c", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_c"))
        nc.put("proj_d", toPkgUriRaw(parseUri "https://example.com/buildGraph/proj_d"))

        createNimbleLink(nc.createUrl("ws_testtraverse"), ws_testtraverse / Path("ws_testtraverse.nimble"), ws_testtraverse.CfgPath)
        createNimbleLink(nc.createUrl("proj_a"), proj_a / Path("proj_a.nimble"), proj_a.CfgPath)
        createNimbleLink(nc.createUrl("proj_b"), proj_b / Path("proj_b.nimble"), proj_b.CfgPath)
        createNimbleLink(nc.createUrl("proj_c"), proj_c / Path("proj_c.nimble"), proj_c.CfgPath)
        createNimbleLink(nc.createUrl("proj_d"), proj_d / Path("proj_d.nimble"), proj_d.CfgPath)

        check nc.createUrl("proj_a").toDirectoryPath() == proj_a
        check nc.createUrl("proj_b").toDirectoryPath() == proj_b
        check nc.createUrl("proj_c").toDirectoryPath() == proj_c
        check nc.createUrl("proj_d").toDirectoryPath() == proj_d

        let pkgA = nc.createUrl("proj_a")

        check $pkgA == "https://example.com/buildGraph/proj_a"

        let dir = paths.getCurrentDir().absolutePath

        let graph = dir.expandGraph(nc, AllReleases, onClone=DoClone)

        checkpoint "\tgraph:\n" & $graph.toJson(ToJsonOptions(enumMode: joptEnumString))
        let sp = graph.pkgs.values().toSeq()
        let vt = toVersionTag

        check sp.len() == 6
        check $sp[0].url.url.scheme == "atlas" and endsWith($sp[0].url, "ws_testtraverselinked.nimble")

        check $sp[1].url == toWindowsFileUrl("link://" & $(ws_testtraverse / Path("ws_testtraverse.nimble")))
        check $sp[2].url == "https://example.com/buildGraph/proj_a"
        check $sp[3].url == "https://example.com/buildGraph/proj_b"
        check $sp[4].url == "https://example.com/buildGraph/proj_c"
        check $sp[5].url == "https://example.com/buildGraph/proj_d"

        let sp0: Package = sp[0] # proj ws_testtraversallinked
        testRequirements(sp0, @[vt"#head@-"], [
          (toWindowsFileUrl("link://" & $(ws_testtraverse / Path"ws_testtraverse.nimble")), "*"),
        ])

        let sp2: Package = sp[2] # proj A
        check sp2.url.projectName() == "proj_a"

        echo "sp2: ", sp2
        testRequirements(sp2, projAtags, [
          ("https://example.com/buildGraph/proj_b", ">= 1.1.0"),
          ("https://example.com/buildGraph/proj_b", ">= 1.0.0"),
        ])
      

suite "test expand with no git tags":

  setup:
    setAtlasVerbosity(Warning)
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().flags.incl DumbProxy
    context().depsDir = Path "deps"
    setAtlasErrorsColor(fgMagenta)

    expectedVersionWithNoGitTags()

  test "collect nimbles":
      # setAtlasVerbosity(Trace)
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        project(paths.getCurrentDir())
        context().flags = {KeepWorkspace, ListVersions}
        context().defaultAlgo = SemVer
        discard context().nameOverrides.addPattern("$+", "file://./buildGraphNoGitTags/$#")

        # writeFile("ws_testtraverse.nimble", "requires \"proj_a\"\n")

        let deps = setupGraphNoGitTags()
        var nc = createNimbleContext()
        # var graph = DepGraph(nodes: @[], reqs: defaultReqs())
        let url = nc.createUrlFromPath(project())

        echo "URL: ", url
        var dep0 = Package(url: url, isRoot: true)
        var dep1 = Package(url: nc.createUrl("proj_a"))
        var dep2 = Package(url: nc.createUrl("proj_b"))
        var dep3 = Package(url: nc.createUrl("proj_c"))
        var dep4 = Package(url: nc.createUrl("proj_d"))

        nc.loadDependency(dep0)
        nc.loadDependency(dep1)
        nc.loadDependency(dep2)
        nc.loadDependency(dep3)
        nc.loadDependency(dep4)

        check collectNimbleVersions(nc, dep0) == newSeq[VersionTag]()
        proc tolist(tags: seq[VersionTag]): seq[string] = tags.mapIt($VersionTag(v: Version"", c: it.c)).sorted()

        echo "projAtags: ", collectNimbleVersions(nc, dep1)
        check collectNimbleVersions(nc, dep1).len() == 3
        check collectNimbleVersions(nc, dep1)[2].isTip
        check collectNimbleVersions(nc, dep1).tolist() == projAnimbles.tolist()
        check collectNimbleVersions(nc, dep2).tolist() == projBnimbles.tolist()
        check collectNimbleVersions(nc, dep3).tolist() == projCnimbles.tolist()
        check collectNimbleVersions(nc, dep4).tolist() == projDnimbles.tolist()

  test "expand no git tags":
      # setAtlasVerbosity(Trace)
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        project(paths.getCurrentDir())
        context().flags = {KeepWorkspace, ListVersions}
        context().defaultAlgo = SemVer

        var nc = createNimbleContext()
        discard nc.nameOverrides.addPattern("$+", "file://./buildGraphNoGitTags/$#")

        let deps = setupGraphNoGitTags()
        let dir = paths.getCurrentDir().absolutePath

        let graph = dir.expandGraph(nc, AllReleases, onClone=DoClone)

        checkpoint "\tgraph:\n" & $graph.toJson(ToJsonOptions(enumMode: joptEnumString))
        let sp = graph.pkgs.values().toSeq()
        doAssert sp.len() == 5

        let sp0: Package = sp[0] # proj ws_testtraversal
        let sp1: Package = sp[1] # proj A
        let sp2: Package = sp[2] # proj B
        let sp3: Package = sp[3] # proj C
        let sp4: Package = sp[4] # proj D

        check $sp[0].url.url.scheme == "atlas" and endsWith($sp[0].url, "ws_testtraverse.nimble")

        check $sp[1].url == toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_a" % [$dir])
        check $sp[2].url == toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_b" % [$dir])
        check $sp[3].url == toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_c" % [$dir])
        check $sp[4].url == toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_d" % [$dir])

        let vt = toVersionTag
        proc stripcommits(tags: seq[VersionTag]): seq[VersionTag] = tags.mapIt(VersionTag(v: Version"", c: it.c))

        testRequirements(sp0, @[vt"#head@-"], [
          (toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_a" % [$dir]), "*"),
        ])

        testRequirements(sp1, projAtags, [
          (toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_b" % [$dir]), ">= 1.1.0"),
          (toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_b" % [$dir]), ">= 1.0.0"),
        ])

        testRequirements(sp2, projBtags, [
          (toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_c" % [$dir]), ">= 1.1.0"),
          (toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_c" % [$dir]), ">= 1.0.0"),
        ])

        testRequirements(sp3, projCtags, [
          (toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_d" % [$dir]), ">= 1.0.0"),
          (toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_d" % [$dir]), ">= 1.2.0"),
        ])

        testRequirements(sp4, projDtags, [
          (toWindowsFileUrl("file://$1/buildGraphNoGitTags/does_not_exist" % [$dir]), ">= 1.2.0"),
          ("", ""),
        ], true)

suite "test expand with no git tags and nimble commits max":

  setup:
    setAtlasVerbosity(Error)
    context().nameOverrides = Patterns()
    context().urlOverrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().flags.incl DumbProxy
    context().depsDir = Path "deps"
    setAtlasErrorsColor(fgMagenta)

    expectedVersionWithNoGitTagsMaxVer()

  test "expand no git tags and nimble commits max":
      # setAtlasVerbosity(Trace)
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        project(paths.getCurrentDir())
        context().flags = {NimbleCommitsMax, KeepWorkspace, ListVersions}
        context().defaultAlgo = SemVer

        var nc = createNimbleContext()
        discard nc.nameOverrides.addPattern("$+", "file://./buildGraphNoGitTags/$#")

        let deps = setupGraphNoGitTags()
        let dir = paths.getCurrentDir().absolutePath

        let graph = dir.expandGraph(nc, AllReleases, onClone=DoClone)

        checkpoint "\tgraph:\n" & $graph.toJson(ToJsonOptions(enumMode: joptEnumString))
        let sp = graph.pkgs.values().toSeq()

        doAssert sp.len() == 5

        let sp0: Package = sp[0] # proj ws_testtraversal
        let sp1: Package = sp[1] # proj A
        let sp2: Package = sp[2] # proj B
        let sp3: Package = sp[3] # proj C
        let sp4: Package = sp[4] # proj D

        check $sp[0].url.url.scheme == "atlas" and endsWith($sp[0].url, "ws_testtraverse.nimble")

        check $sp[1].url == toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_a" % [$dir])
        check $sp[2].url == toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_b" % [$dir])
        check $sp[3].url == toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_c" % [$dir])
        check $sp[4].url == toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_d" % [$dir])

        let vt = toVersionTag
        proc stripcommits(tags: seq[VersionTag]): seq[VersionTag] = tags.mapIt(VersionTag(v: Version"", c: it.c))

        testRequirements(sp0, @[vt"#head@-"], [
          (toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_a" % [$dir]), "*"),
        ])

        testRequirements(sp1, projAtags, [
          (toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_b" % [$dir]), ">= 1.1.0"),
          (toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_b" % [$dir]), ">= 1.0.0"),
        ])

        testRequirements(sp2, projBtags, [
          (toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_c" % [$dir]), ">= 1.1.0"),
          (toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_c" % [$dir]), ">= 1.0.0"),
        ])

        testRequirements(sp3, projCtags, [
          (toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_d" % [$dir]), ">= 1.0.0"),
          (toWindowsFileUrl("file://$1/buildGraphNoGitTags/proj_d" % [$dir]), ">= 1.2.0"),
        ])

        testRequirements(sp4, projDtags, [
          (toWindowsFileUrl("file://$1/buildGraphNoGitTags/does_not_exist" % [$dir]), ">= 1.2.0"),
          ("", ""),
        ], true)

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
