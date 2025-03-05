# Small program that runs the test cases

import std / [strutils, os, osproc, jsonutils, json, tables, sequtils, algorithm, strformat, unittest]
import basic/[sattypes, context, gitops, reporters, nimbleparser, pkgurls, compiledpatterns, versions]
import basic/deptypes
import dependencies
import testerutils

if not dirExists("tests/ws_testtraverse/buildGraph"):
  ensureGitHttpServer()

# proc createGraph*(s: PkgUrl): DepGraph =
#   result = DepGraph(nodes: @[], reqs: defaultReqs())
#   result.packageToDependency[s] = result.nodes.len
#   result.nodes.add Dependency(pkg: s, versions: @[], isRoot: true, isTopLevel: true, activeVersion: -1)

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

suite "test expand with git tags":
  setup:
    setAtlasVerbosity(Warning)

    # These will change if atlas-tests is regnerated!
    # To update run and use commits not adding a proj_x.nim file
    #    curl http://localhost:4242/buildGraph/ws_generated-logs.txt
    let projAtags = dedent"""
    fb3804df03c3c414d98d1f57deeb44c8a223ba44 1.1.0
    7ca5581cd5355f6b5461a23f9683f19378bd268a
    e479b438015e734bea67a9c63d783e78cab5746e 1.0.0
    """.parseTaggedVersions(false)

    let projBtags = dedent"""
    ee875baecee161ed053b87b583b2f08526838bd6 1.1.0
    cd3ad76043e5f983f704be6bf61e57d187fe070f
    af4275109d60caaeacf2912a37c2339aca40a922 1.0.0
    """.parseTaggedVersions(false)

    let projCtags = dedent"""
    9331e14f3fa20ed75b7d5c0ab93aa5fb0293192f 1.2.0
    c7540297c01dc57a98cb1fce7660ab6f2a0cee5f
    """.parseTaggedVersions(false)

    let projDtags = dedent"""
    dd98f775ae33d450dc7f936f850e247e820e31ad 2.0.0
    0dec9c9733129919972416f04e73b1fb2cbf3bd3 1.0.0
    """.parseTaggedVersions(false)

  test "ws_testtraverse collect nimbles":
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer
        discard context().overrides.addPattern("$+", "file://./buildGraph/$#")

        let dir = ospaths2.getCurrentDir()
        # writeFile("ws_testtraverse.nimble", "requires \"proj_a\"\n")

        let deps = setupGraph()
        var nc = NimbleContext()
        # var graph = DepGraph(nodes: @[], reqs: defaultReqs())
        let pkg = nc.createUrl(dir, projectName = "ws_testtraverse")

        var dep0 = Dependency(pkg: pkg, isRoot: true, isTopLevel: true)
        var dep1 = Dependency(pkg: nc.createUrl("file://./buildGraph/proj_a"), isRoot: true)
        var dep2 = Dependency(pkg: nc.createUrl("file://./buildGraph/proj_b"), isRoot: true)
        var dep3 = Dependency(pkg: nc.createUrl("file://./buildGraph/proj_c"), isRoot: true)
        var dep4 = Dependency(pkg: nc.createUrl("file://./buildGraph/proj_d"), isRoot: true)

        nc.loadDependency(dep0)
        nc.loadDependency(dep1)
        nc.loadDependency(dep2)
        nc.loadDependency(dep3)
        nc.loadDependency(dep4)

        check collectNimbleVersions(nc, dep0) == newSeq[VersionTag]()
        proc tolist(tags: seq[VersionTag]): seq[string] = tags.mapIt($VersionTag(v: Version"", c: it.c)).sorted()

        check collectNimbleVersions(nc, dep1).tolist() == projAtags.tolist()
        check collectNimbleVersions(nc, dep2).tolist() == projBtags.tolist()
        check collectNimbleVersions(nc, dep3).tolist() == projCtags.tolist()
        check collectNimbleVersions(nc, dep4).tolist() == projDtags.tolist()

  test "ws_testtraverse traverseDependency":
      # setAtlasVerbosity(Info)
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        context().workspace = paths.getCurrentDir()
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer

        var nc = NimbleContext()
        discard nc.overrides.addPattern("$+", "file://buildGraph/$#")

        let deps = setupGraph()
        let dir = paths.getCurrentDir().absolutePath

        let specs: DependencySpecs = expand(nc, AllReleases, dir)

        # echo "\tspec:\n", specs.toJson(ToJsonOptions(enumMode: joptEnumString))
        let sp = specs.depsToSpecs.pairs().toSeq()

        check $sp[0][0] == "file://$1" % [$dir]
        check $sp[1][0] == "file://buildGraph/proj_a"
        check $sp[2][0] == "file://buildGraph/proj_b"
        check $sp[3][0] == "file://buildGraph/proj_c"
        check $sp[4][0] == "file://buildGraph/proj_d"

        let vt = toVersionTag

        block:
          let sp = sp[0][1]
          check sp.versions.len() == 1
          check sp.versions[vt"#head@-"].status == Normal
          check sp.versions[vt"#head@-"].deps.len() == 1
          check $sp.versions[vt"#head@-"].deps[0][0] == "file://buildGraph/proj_a"
          check $sp.versions[vt"#head@-"].deps[0][1] == "#head"

        block:
          let sp = sp[1][1] # proj A
          let v1 = projAtags[0]
          let v2 = projAtags[1]
          let v3 = projAtags[2]
          check sp.versions.len() == 3
          check sp.versions[v1].status == Normal
          check sp.versions[v1].deps.len() == 1

          check sp.versions[v2].status == Normal
          check sp.versions[v2].deps.len() == 1

          check $sp.versions[v1].deps[0][0] == "file://buildGraph/proj_b"
          check $sp.versions[v1].deps[0][1] == ">= 1.1.0"

          check $sp.versions[v2].deps[0][0] == "file://buildGraph/proj_b"
          check $sp.versions[v2].deps[0][1] == ">= 1.0.0"

          check $sp.versions[v3].deps[0][0] == "file://buildGraph/proj_b"
          check $sp.versions[v3].deps[0][1] == ">= 1.0.0"

        block:
          let sp = sp[2][1] # proj B
          let v1 = projBtags[0]
          let v2 = projBtags[1]
          let v3 = projBtags[2]
          check sp.versions.len() == 3
          check sp.versions[v1].status == Normal
          check sp.versions[v1].deps.len() == 1

          check sp.versions[v2].status == Normal
          check sp.versions[v2].deps.len() == 1

          check $sp.versions[v1].deps[0][0] == "file://buildGraph/proj_c"
          check $sp.versions[v1].deps[0][1] == ">= 1.1.0"

          check $sp.versions[v2].deps[0][0] == "file://buildGraph/proj_c"
          check $sp.versions[v2].deps[0][1] == ">= 1.0.0"

          check $sp.versions[v3].deps[0][0] == "file://buildGraph/proj_c"
          check $sp.versions[v3].deps[0][1] == ">= 1.0.0"

        block:
          let sp = sp[3][1] # proj C
          let v1 = projCtags[0]
          let v2 = projCtags[1]
          check sp.versions.len() == 2
          check sp.versions[v1].status == Normal
          check sp.versions[v1].deps.len() == 1

          check sp.versions[v2].status == Normal
          check sp.versions[v2].deps.len() == 1

          check $sp.versions[v1].deps[0][0] == "file://buildGraph/proj_d"
          check $sp.versions[v1].deps[0][1] == ">= 1.0.0"

          check $sp.versions[v2].deps[0][0] == "file://buildGraph/proj_d"
          check $sp.versions[v2].deps[0][1] == ">= 1.2.0"

        block:
          let sp = sp[4][1] # proj D
          let v1 = projDtags[0]
          let v2 = projDtags[1]
          check sp.versions.len() == 2
          check sp.versions[v1].status == Normal
          check sp.versions[v1].deps.len() == 1

          check sp.versions[v2].status == Normal
          check sp.versions[v2].deps.len() == 0

          check $sp.versions[v1].deps[0][0] == "file://buildGraph/does_not_exist"
          check $sp.versions[v1].deps[0][1] == ">= 1.2.0"

  test "ws_testtraverse traverseDependency from http":
      # setAtlasVerbosity(Info)
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        context().workspace = paths.getCurrentDir()
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer

        var nc = NimbleContext()
        discard context().overrides.addPattern("$+", "http://localhost:4242/buildGrap/$#")

        let deps = setupGraph()
        let dir = paths.getCurrentDir().absolutePath

        let specs: DependencySpecs = expand(nc, AllReleases, dir)

        echo "\tspec:\n", specs.toJson(ToJsonOptions(enumMode: joptEnumString))
        let sp = specs.depsToSpecs.pairs().toSeq()

        check $sp[0][0] == "file://$1" % [$dir]
        check $sp[1][0] == "file://buildGraph/proj_a"
        check $sp[2][0] == "file://buildGraph/proj_b"
        check $sp[3][0] == "file://buildGraph/proj_c"
        check $sp[4][0] == "file://buildGraph/proj_d"

        let vt = toVersionTag

        block:
          let sp = sp[0][1]
          check sp.versions.len() == 1
          check sp.versions[vt"#head@-"].status == Normal
          check sp.versions[vt"#head@-"].deps.len() == 1
          check $sp.versions[vt"#head@-"].deps[0][0] == "file://buildGraph/proj_a"
          check $sp.versions[vt"#head@-"].deps[0][1] == "#head"

        block:
          let sp = sp[1][1] # proj A
          let v1 = projAtags[0]
          let v2 = projAtags[1]
          let v3 = projAtags[2]
          check sp.versions.len() == 3
          check sp.versions[v1].status == Normal
          check sp.versions[v1].deps.len() == 1

          check sp.versions[v2].status == Normal
          check sp.versions[v2].deps.len() == 1

          check $sp.versions[v1].deps[0][0] == "file://buildGraph/proj_b"
          check $sp.versions[v1].deps[0][1] == ">= 1.1.0"

          check $sp.versions[v2].deps[0][0] == "file://buildGraph/proj_b"
          check $sp.versions[v2].deps[0][1] == ">= 1.0.0"

          check $sp.versions[v3].deps[0][0] == "file://buildGraph/proj_b"
          check $sp.versions[v3].deps[0][1] == ">= 1.0.0"

        block:
          let sp = sp[2][1] # proj B
          let v1 = projBtags[0]
          let v2 = projBtags[1]
          let v3 = projBtags[2]
          check sp.versions.len() == 3
          check sp.versions[v1].status == Normal
          check sp.versions[v1].deps.len() == 1

          check sp.versions[v2].status == Normal
          check sp.versions[v2].deps.len() == 1

          check $sp.versions[v1].deps[0][0] == "file://buildGraph/proj_c"
          check $sp.versions[v1].deps[0][1] == ">= 1.1.0"

          check $sp.versions[v2].deps[0][0] == "file://buildGraph/proj_c"
          check $sp.versions[v2].deps[0][1] == ">= 1.0.0"

          check $sp.versions[v3].deps[0][0] == "file://buildGraph/proj_c"
          check $sp.versions[v3].deps[0][1] == ">= 1.0.0"

        block:
          let sp = sp[3][1] # proj C
          let v1 = projCtags[0]
          let v2 = projCtags[1]
          check sp.versions.len() == 2
          check sp.versions[v1].status == Normal
          check sp.versions[v1].deps.len() == 1

          check sp.versions[v2].status == Normal
          check sp.versions[v2].deps.len() == 1

          check $sp.versions[v1].deps[0][0] == "file://buildGraph/proj_d"
          check $sp.versions[v1].deps[0][1] == ">= 1.0.0"

          check $sp.versions[v2].deps[0][0] == "file://buildGraph/proj_d"
          check $sp.versions[v2].deps[0][1] == ">= 1.2.0"

        block:
          let sp = sp[4][1] # proj D
          let v1 = projDtags[0]
          let v2 = projDtags[1]
          check sp.versions.len() == 2
          check sp.versions[v1].status == Normal
          check sp.versions[v1].deps.len() == 1

          check sp.versions[v2].status == Normal
          check sp.versions[v2].deps.len() == 0

          check $sp.versions[v1].deps[0][0] == "file://buildGraph/does_not_exist"
          check $sp.versions[v1].deps[0][1] == ">= 1.2.0"

suite "test expand with no git tags":

  setup:
    setAtlasVerbosity(Warning)

    # These will change if atlas-tests is regnerated!
    # To update run and use commits not adding a proj_x.nim file
    #    curl http://localhost:4242/buildGraph/ws_generated-logs.txt
    let projAtags = dedent"""
    61eacba5453392d06ed0e839b52cf17462d94648 1.1.0
    6a1cc178670d372f21c21329d35579e96283eab0
    88d1801bff2e72cdaf2d29b438472336df6aa66d 1.0.0
    """.parseTaggedVersions(false)

    let projBtags = dedent"""
    c70824d8b9b669cc37104d35055fd8c11ecdd680 1.1.0
    bbb208a9cad0d58f85bd00339c85dfeb8a4f7ac0
    289ae9eea432cdab9d681ab69444ae9d439eb6ae 1.0.0
    """.parseTaggedVersions(false)

    let projCtags = dedent"""
    d6c04d67697df7807b8e2b6028d167b517d13440 1.2.0
    8756fa4575bf750d4472ac78ba91520f05a1de60
    """.parseTaggedVersions(false)

    let projDtags = dedent"""
    7ee36fecb09ef33024d3aa198ed87d18c28b3548 2.0.0
    0bd0e77a8cbcc312185c2a1334f7bf2eb7b1241f 1.0.0
    """.parseTaggedVersions(false)

  test "ws_testtraverse collect nimbles":
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer
        discard context().overrides.addPattern("$+", "file://./buildGraphNoGitTags/$#")

        let dir = ospaths2.getCurrentDir()
        # writeFile("ws_testtraverse.nimble", "requires \"proj_a\"\n")

        let deps = setupGraph()
        var nc = NimbleContext()
        # var graph = DepGraph(nodes: @[], reqs: defaultReqs())
        let pkg = nc.createUrl(dir, projectName = "ws_testtraverse")

        var dep0 = Dependency(pkg: pkg, isRoot: true, isTopLevel: true)
        var dep1 = Dependency(pkg: nc.createUrl("file://./buildGraphNoGitTags/proj_a"), isRoot: true)
        var dep2 = Dependency(pkg: nc.createUrl("file://./buildGraphNoGitTags/proj_b"), isRoot: true)
        var dep3 = Dependency(pkg: nc.createUrl("file://./buildGraphNoGitTags/proj_c"), isRoot: true)
        var dep4 = Dependency(pkg: nc.createUrl("file://./buildGraphNoGitTags/proj_d"), isRoot: true)

        nc.loadDependency(dep0)
        nc.loadDependency(dep1)
        nc.loadDependency(dep2)
        nc.loadDependency(dep3)
        nc.loadDependency(dep4)

        check collectNimbleVersions(nc, dep0) == newSeq[VersionTag]()
        proc tolist(tags: seq[VersionTag]): seq[string] = tags.mapIt($VersionTag(v: Version"", c: it.c)).sorted()

        check collectNimbleVersions(nc, dep1).tolist() == projAtags.tolist()
        check collectNimbleVersions(nc, dep2).tolist() == projBtags.tolist()
        check collectNimbleVersions(nc, dep3).tolist() == projCtags.tolist()
        check collectNimbleVersions(nc, dep4).tolist() == projDtags.tolist()


  test "ws_testtraverse traverseDependency no git tags":
      setAtlasVerbosity(Info)
      withDir "tests/ws_testtraverse":
        removeDir("deps")
        context().workspace = paths.getCurrentDir()
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer

        var nc = NimbleContext()
        discard nc.overrides.addPattern("$+", "file://buildGraphNoGitTags/$#")

        let deps = setupGraphNoGitTags()
        let dir = paths.getCurrentDir().absolutePath

        let specs: DependencySpecs = expand(nc, AllReleases, dir)

        # echo "\tspec:\n", specs.toJson(ToJsonOptions(enumMode: joptEnumString))
        let sp = specs.depsToSpecs.pairs().toSeq()

        check $sp[0][0] == "file://$1" % [$dir]
        check $sp[1][0] == "file://buildGraphNoGitTags/proj_a"
        check $sp[2][0] == "file://buildGraphNoGitTags/proj_b"
        check $sp[3][0] == "file://buildGraphNoGitTags/proj_c"
        check $sp[4][0] == "file://buildGraphNoGitTags/proj_d"

        let vt = toVersionTag

        block:
          let sp = sp[0][1]
          check sp.versions.len() == 1
          check sp.versions[vt"#head@-"].status == Normal
          check sp.versions[vt"#head@-"].deps.len() == 1
          check $sp.versions[vt"#head@-"].deps[0][0] == "file://buildGraphNoGitTags/proj_a"
          check $sp.versions[vt"#head@-"].deps[0][1] == "#head"

        proc stripcommits(tags: seq[VersionTag]): seq[VersionTag] = tags.mapIt(VersionTag(v: Version"", c: it.c))

        block:
          let sp = sp[1][1] # proj A
          let projAtags = projAtags.stripcommits()
          let v1 = projAtags[0]
          let v2 = projAtags[1]
          let v3 = projAtags[2]
          check sp.versions.len() == 3
          check sp.versions[v1].status == Normal
          check sp.versions[v1].deps.len() == 1

          check sp.versions[v2].status == Normal
          check sp.versions[v2].deps.len() == 1

          check $sp.versions[v1].deps[0][0] == "file://buildGraphNoGitTags/proj_b"
          check $sp.versions[v1].deps[0][1] == ">= 1.1.0"

          check $sp.versions[v2].deps[0][0] == "file://buildGraphNoGitTags/proj_b"
          check $sp.versions[v2].deps[0][1] == ">= 1.0.0"

          check $sp.versions[v3].deps[0][0] == "file://buildGraphNoGitTags/proj_b"
          check $sp.versions[v3].deps[0][1] == ">= 1.0.0"

        block:
          let sp = sp[2][1] # proj B
          let projBtags = projBtags.stripcommits()
          let v1 = projBtags[0]
          let v2 = projBtags[1]
          let v3 = projBtags[2]
          check sp.versions.len() == 3
          check sp.versions[v1].status == Normal
          check sp.versions[v1].deps.len() == 1

          check sp.versions[v2].status == Normal
          check sp.versions[v2].deps.len() == 1

          check $sp.versions[v1].deps[0][0] == "file://buildGraphNoGitTags/proj_c"
          check $sp.versions[v1].deps[0][1] == ">= 1.1.0"

          check $sp.versions[v2].deps[0][0] == "file://buildGraphNoGitTags/proj_c"
          check $sp.versions[v2].deps[0][1] == ">= 1.0.0"

          check $sp.versions[v3].deps[0][0] == "file://buildGraphNoGitTags/proj_c"
          check $sp.versions[v3].deps[0][1] == ">= 1.0.0"

        block:
          let sp = sp[3][1] # proj C
          let projCtags = projCtags.stripcommits()
          let v1 = projCtags[0]
          let v2 = projCtags[1]
          check sp.versions.len() == 2
          check sp.versions[v1].status == Normal
          check sp.versions[v1].deps.len() == 1

          check sp.versions[v2].status == Normal
          check sp.versions[v2].deps.len() == 1

          check $sp.versions[v1].deps[0][0] == "file://buildGraphNoGitTags/proj_d"
          check $sp.versions[v1].deps[0][1] == ">= 1.0.0"

          check $sp.versions[v2].deps[0][0] == "file://buildGraphNoGitTags/proj_d"
          check $sp.versions[v2].deps[0][1] == ">= 1.2.0"

        block:
          let sp = sp[4][1] # proj D
          let projDtags = projDtags.stripcommits()
          let v1 = projDtags[0]
          let v2 = projDtags[1]
          check sp.versions.len() == 2
          check sp.versions[v1].status == Normal
          check sp.versions[v1].deps.len() == 1

          check sp.versions[v2].status == Normal
          check sp.versions[v2].deps.len() == 0

          check $sp.versions[v1].deps[0][0] == "file://buildGraphNoGitTags/does_not_exist"
          check $sp.versions[v1].deps[0][1] == ">= 1.2.0"


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
