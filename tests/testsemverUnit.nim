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
#   result.nodes.add Package(pkg: s, versions: @[], isRoot: true, isTopLevel: true, activeVersion: -1)

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

template testRequirements(sp: PackageSpec,
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

  test "ws_semver_unit traverseDependency":
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

        let dir = paths.getCurrentDir().absolutePath

        let specs: PackageSpecs = expand(nc, AllReleases, dir)

        echo "\tspec:\n", specs.toJson(ToJsonOptions(enumMode: joptEnumString))
        let sp = specs.pkgsToSpecs.pairs().toSeq()

