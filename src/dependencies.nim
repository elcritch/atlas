#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, strutils, tables, unicode, sequtils, sets, json, hashes, algorithm, paths, files, dirs]
import basic/[context, deptypes, versions, osutils, nimbleparser, packageinfos, reporters, gitops, parse_requires, pkgurls, compiledpatterns]

const
  DefaultPackagesSubDir* = Path "packages"

type
  TraversalMode* = enum
    AllReleases,
    CurrentCommit

when defined(nimAtlasBootstrap):
  import ../dist/sat/src/sat/satvars
else:
  import sat/satvars

proc findNimbleFile*(nimbleFile: Path): seq[Path] =
  if fileExists(nimbleFile):
    result.add nimbleFile

proc findNimbleFile*(dir: Path, projectName: string): seq[Path] =
  var nimbleFile = dir / Path(projectName & ".nimble")
  result = findNimbleFile(nimbleFile)
  if result.len() == 0:
    for file in walkFiles($dir / "*.nimble"):
      result.add Path(file)
  debug "findNimbleFile:search:", " name: " & projectName & " found: " & $result

proc findNimbleFile*(dep: DepConstraint | Dependency): seq[Path] =
  doAssert(dep.info.ondisk.string != "", "Package ondisk must be set before findNimbleFile can be called! Package: " & $(dep.pkg))
  result = findNimbleFile(dep.info.ondisk, dep.pkg.projectName & ".nimble")

proc getPackageInfos*(depsDir: Path): seq[PackageInfo] =
  result = @[]
  var uniqueNames = initHashSet[string]()
  var jsonFiles = 0
  for kind, path in walkDir($(depsDir / DefaultPackagesSubDir)):
    if kind == pcFile and path.endsWith(".json"):
      inc jsonFiles
      let packages = json.parseFile(path)
      for p in packages:
        let pkg = p.fromJson()
        if pkg != nil and not uniqueNames.containsOrIncl(pkg.name):
          result.add(pkg)

proc updatePackages*(depsDir: Path) =
  if dirExists($(depsDir / DefaultPackagesSubDir)):
    withDir($(depsDir / DefaultPackagesSubDir)):
      gitPull(depsDir / DefaultPackagesSubDir)
  else:
    withDir $depsDir:
      let success = clone("https://github.com/nim-lang/packages", DefaultPackagesSubDir)
      if not success:
        error DefaultPackagesSubDir, "cannot clone packages repo"

proc fillPackageLookupTable(c: var NimbleContext; depsdir: Path) =
  if not c.hasPackageList:
    c.hasPackageList = true
    if not fileExists($(depsDir / DefaultPackagesSubDir / Path "packages.json")):
      updatePackages(depsdir)
    let packages = getPackageInfos(depsDir)
    for entry in packages:
      c.nameToUrl[unicode.toLower entry.name] = entry.url

proc createNimbleContext*(depsdir: Path): NimbleContext =
  result = NimbleContext()
  fillPackageLookupTable(result, depsdir)

proc collectNimbleVersions*(nc: NimbleContext; dep: Dependency): seq[VersionTag] =
  let nimbleFiles = findNimbleFile(dep)
  let dir = dep.info.ondisk
  doAssert(dep.info.ondisk.string != "", "Package ondisk must be set before collectNimbleVersions can be called! Package: " & $(dep.pkg))
  result = @[]
  if nimbleFiles.len() == 1:
    result = collectFileCommits(dir, nimbleFiles[0], ignoreError = true)
    result.reverse()
    trace "collectNimbleVersions", "commits: " & $mapIt(result, it.c.short())

proc loadRelease(dep: var Dependency, nc: var NimbleContext; release: VersionTag) =
  debug "loadRelease", "name: " & dep.pkg.projectName & " release: " & $release

  if release.version == Version"#head":
    trace "loadRelease", "using current commit"
  elif release.commit.isEmpty():
    error "loadRelease", "missing commit " & $release & " at " & $dep.info.ondisk
    dep.versions[release] = Requirements(status: HasBrokenRelease, err: "no commit")
    return
  elif not checkoutGitCommit(dep.info.ondisk, release.commit):
    dep.versions[release] = Requirements(status: HasBrokenRelease, err: "error checking out release")
    return

  let nimbleFiles = findNimbleFile(dep)
  var badNimbleFile = false
  if nimbleFiles.len() == 0:
    info "loadRelease", "skipping release: missing nimble file" & $release
    dep.versions[release] = Requirements(status: HasUnknownNimbleFile, err: "missing nimble file")
  elif nimbleFiles.len() > 1:
    info "loadRelease", "skipping release: ambiguous nimble file" & $release & " files: " & $(nimbleFiles.mapIt(it.splitPath().tail).join(", "))
    dep.versions[release] = Requirements(status: HasUnknownNimbleFile, err: "ambiguous nimble file")
  
  let nimbleFile = nimbleFiles[0]
  let nimbleReqs = parseNimbleFile(nc, nimbleFile, context().overrides)
  if nimbleReqs.status == Normal:
    dep.versions[release] = nimbleReqs

    for pkgUrl, interval in items(nimbleReqs.deps):
      var pkgDep = nc.packageToDependency.getOrDefault(pkgUrl, nil)
      if pkgDep == nil:
        pkgDep = Dependency(pkg: pkgUrl, state: NotInitialized)
        nc.packageToDependency[pkgUrl] = pkgDep
        # TODO: enrich versions with hashes when added
        # enrichVersionsViaExplicitHash graph[depIdx].versions, interval


proc loadDependency*(
    nc: var NimbleContext;
    pkgUrl: PkgUrl,
    path: Path,
    mode: TraversalMode;
    versions: seq[VersionTag];
): Dependency =
  result = Dependency(info: DependencyInfo(ondisk: path))

  let currentCommit = currentGitCommit(path, Error)
  trace "depgraphs:releases", "currentCommit: " & $currentCommit
  if currentCommit.isEmpty():
    warn "loadDependency", "unable to find git current version at " & $path
    let vtag = VersionTag(v: Version"#head", c: initCommitHash("", FromHead))
    result.versions[vtag] = Requirements(status: HasBrokenRepo)
    return

  case mode
  of CurrentCommit:
    trace "loadDependency", "only loading current commit"
    let vtag = VersionTag(v: Version"#head", c: initCommitHash(currentCommit, FromHead))
    result.loadRelease(nc, vtag)

  of AllReleases:
    try:
      var uniqueCommits: HashSet[CommitHash]
      let nimbleCommits = collectNimbleVersions(nc, result)
      debug "loadDependency", "nimble versions: " & $nimbleCommits

      for version in versions:
        if version.version == Version"" and
            not version.commit.isEmpty() and
            not uniqueCommits.containsOrIncl(version.commit):
            let vtag = VersionTag(v: Version"", c: version.commit)
            assert vtag.commit.orig == FromDep, "maybe this needs to be overriden like before"
            result.loadRelease(nc, vtag)

      let tags = collectTaggedVersions(path)
      for tag in tags:
        if not uniqueCommits.containsOrIncl(tag.c):
          result.loadRelease(nc, tag)
          assert tag.commit.orig == FromGitTag, "maybe this needs to be overriden like before"

      for tag in nimbleCommits:
        if not uniqueCommits.containsOrIncl(tag.c):
          result.loadRelease(nc, tag)

      if result.versions.len() == 0:
        let vtag = VersionTag(v: Version"#head", c: initCommitHash(currentCommit, FromHead))
        info "loadDependency", "no versions found, using default #head" & " at " & $path
        result.loadRelease(nc, vtag)

    finally:
      if not checkoutGitCommit(path, currentCommit, Warning):
        info "loadDependency", "error loading releases reverting to " & $ currentCommit


proc traverseDependency*(nc: NimbleContext;
                         mode: TraversalMode) =

  # let versions = dep.versions

  let mode = if dep.isRoot: CurrentCommit else: mode

  loadDependency(nc)
  # for (origin, release) in releases(dep.ondisk, mode, versions, nimbleVersions):
  #   traverseRelease(nimbleCtx, graph, idx, origin, release, prevNimbleContents)
  dep.state = Processed

proc expand*(nc: NimbleContext; mode: TraversalMode, ) =
  ## Expand the graph by adding all dependencies.
  
  var processed = initHashSet[PkgUrl]()

  while i < graph.nodes.len:
    if not processed.containsOrIncl(graph[i].pkg):
      let (dest, todo) = pkgUrlToDirname(graph, graph[i])

      debug "expand", "todo: " & $todo & " pkg: " & graph[i].pkg.projectName & " dest: " & $dest
      # important: the ondisk path set here!
      graph[i].ondisk = dest

      case todo
      of DoClone:
        let (status, msg) =
          if graph[i].pkg.isFileProtocol:
            copyFromDisk(graph[i], dest)
          else:
            cloneUrl(graph[i].pkg, dest, false)
        if status == Ok:
          graph[i].state = Found
        else:
          graph[i].state = Error
          graph[i].errors.add $status & ":" & msg
      of DoNothing:
        if graph[i].ondisk.dirExists():
          graph[i].state = Found
        else:
          graph[i].state = Error
          graph[i].errors.add "ondisk location missing"

      if graph[i].state == Found:
        traverseDependency(nimbleCtx, graph, i, mode)
    inc i

  # if context().dumpGraphs:
  #   dumpJson(graph, "graph-expanded.json")
