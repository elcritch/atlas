# Small program that runs the test cases

import std / [strutils, os, uri, jsonutils, json, tables, sequtils, strformat, unittest]
import basic/[sattypes, context, reporters, pkgurls, compiledpatterns, versions]
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

template testRequirements(sp: DependencySpec,
                          projTags: seq[VersionTag],
                          vers: openArray[(string, string)];
                          skipCount = false) =
  if not skipCount:
    check sp.releases.len() == vers.len()

  for idx, vt in projTags:
    # let vt = projTags[idx]
    echo "checking versiontag: " & $vt & " item: " & $vers[idx]
    let (url, ver) = vers[idx]
    check vt in sp.releases
    if vt in sp.releases:
      check sp.releases[vt].status == Normal
      if not skipCount:
        check sp.releases[vt].deps.len() == 1

      if url != "":
        check $sp.releases[vt].deps[0][0] == url
      if ver != "":
        check $sp.releases[vt].deps[0][1] == ver

suite "graph solve":
  setup:
    setAtlasVerbosity(Warning)
    context().overrides = Patterns()
    context().proxy = parseUri "http://localhost:4242"
    context().dumbProxy = true
    context().depsDir = Path "deps"

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

  test "ws_testtraverse traverseDependency":
      # setAtlasVerbosity(Info)
      withDir "tests/ws_semver_unit":
        removeDir("deps")
        context().workspace = paths.getCurrentDir()
        context().flags = {UsesOverrides, KeepWorkspace, ListVersions, FullClones}
        context().defaultAlgo = SemVer

        var nc = createNimbleContext()
        nc.nameToUrl["proj_a"] = toPkgUri(parseUri "https://example.com/buildGraph/proj_a")
        nc.nameToUrl["proj_b"] = toPkgUri(parseUri "https://example.com/buildGraph/proj_b")
        nc.nameToUrl["proj_c"] = toPkgUri(parseUri "https://example.com/buildGraph/proj_c")
        nc.nameToUrl["proj_d"] = toPkgUri(parseUri "https://example.com/buildGraph/proj_d")

        let deps = setupGraph()
        let dir = paths.getCurrentDir().absolutePath

        let specs: DependencySpecs = expand(nc, AllReleases, dir)

        echo "\tspec:\n", specs.toJson(ToJsonOptions(enumMode: joptEnumString))
        let sp = specs.depsToSpecs.pairs().toSeq()

