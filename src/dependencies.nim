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
  DefaultPackagesSubDir* = Path"packages"

type
  TraversalMode* = enum
    AllReleases,
    CurrentCommit

when defined(nimAtlasBootstrap):
  import ../dist/sat/src/sat/satvars
else:
  import sat/satvars

proc packagesDirectory*(): Path =
  context().depsDir / DefaultPackagesSubDir

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

proc findNimbleFile*(info: Dependency): seq[Path] =
  doAssert(info.ondisk.string != "", "Package ondisk must be set before findNimbleFile can be called! Package: " & $(info))
  result = findNimbleFile(info.ondisk, info.projectName() & ".nimble")

proc getPackageInfos*(pkgsDir = packagesDirectory()): seq[PackageInfo] =
  result = @[]
  var uniqueNames = initHashSet[string]()
  var jsonFiles = 0
  for kind, path in walkDir(pkgsDir):
    if kind == pcFile and path.string.endsWith(".json"):
      inc jsonFiles
      let packages = json.parseFile($path)
      for p in packages:
        let pkg = p.fromJson()
        if pkg != nil and not uniqueNames.containsOrIncl(pkg.name):
          result.add(pkg)

proc updatePackages*(pkgsDir = packagesDirectory()) =
  let pkgsDir = context().depsDir / DefaultPackagesSubDir
  if dirExists(pkgsDir):
    gitPull(pkgsDir)
  else:
    if not clone("https://github.com/nim-lang/packages", pkgsDir):
      error DefaultPackagesSubDir, "cannot clone packages repo"

proc fillPackageLookupTable(c: var NimbleContext) =
  let pkgsDir = packagesDirectory()
  if not c.hasPackageList:
    c.hasPackageList = true
    if not fileExists(pkgsDir / Path"packages.json"):
      updatePackages(pkgsDir)
    let packages = getPackageInfos(pkgsDir)
    for entry in packages:
      c.nameToUrl[unicode.toLower entry.name] = entry.url

proc createNimbleContext*(): NimbleContext =
  result = NimbleContext()
  fillPackageLookupTable(result)

proc collectNimbleVersions*(nc: NimbleContext; info: Dependency): seq[VersionTag] =
  let nimbleFiles = findNimbleFile(info)
  let dir = info.ondisk
  doAssert(info.ondisk.string != "", "Package ondisk must be set before collectNimbleVersions can be called! Package: " & $(info))
  result = @[]
  if nimbleFiles.len() == 1:
    result = collectFileCommits(dir, nimbleFiles[0], ignoreError = true)
    result.reverse()
    trace "collectNimbleVersions", "commits: " & $mapIt(result, it.c.short())

proc loadRelease(dep: Dependency, specs: DependencySpecs; release: VersionTag): DependencieSpec =
  debug "loadRelease", "name: " & dep.projectName() & " release: " & $release

  if release.version == Version"#head":
    trace "loadRelease", "using current commit"
  elif release.commit.isEmpty():
    error "loadRelease", "missing commit " & $release & " at " & $dep.info.ondisk
    result.versions[release] = Requirements(status: HasBrokenRelease, err: "no commit")
    return
  elif not checkoutGitCommit(dep.info.ondisk, release.commit):
    dep.versions[release] = Requirements(status: HasBrokenRelease, err: "error checking out release")
    return

  let nimbleFiles = findNimbleFile(dep.info)
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
        pkgDep = DependencySpec(info: Dependency(pkg: pkgUrl), state: NotInitialized)
        nc.packageToDependency[pkgUrl] = pkgDep
        # TODO: enrich versions with hashes when added
        # enrichVersionsViaExplicitHash graph[depIdx].versions, interval


proc traverseDependency*(
    dep: var DependencySpec,
    deps: Dependencies;
    mode: TraversalMode;
    versions: seq[VersionTag];
): DependencySpec =
  doAssert dep.info.ondisk.fileExists() and dep.state != NotInitialized, "DependencySpec should've been found or cloned at this point"

  result = DependencySpec(info: Dependency(ondisk: path))

  let currentCommit = currentGitCommit(path, Error)
  trace "depgraphs:releases", "currentCommit: " & $currentCommit
  if currentCommit.isEmpty():
    warn "traverseDependency", "unable to find git current version at " & $path
    let vtag = VersionTag(v: Version"#head", c: initCommitHash("", FromHead))
    result.versions[vtag] = Requirements(status: HasBrokenRepo)
    result.state = Error
    return

  case mode
  of CurrentCommit:
    trace "traverseDependency", "only loading current commit"
    let vtag = VersionTag(v: Version"#head", c: initCommitHash(currentCommit, FromHead))
    result.loadRelease(nc, vtag)

  of AllReleases:
    try:
      var uniqueCommits: HashSet[CommitHash]
      let nimbleCommits = collectNimbleVersions(nc, result)
      debug "traverseDependency", "nimble versions: " & $nimbleCommits

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
        info "traverseDependency", "no versions found, using default #head" & " at " & $path
        result.loadRelease(nc, vtag)

    finally:
      if not checkoutGitCommit(path, currentCommit, Warning):
        info "traverseDependency", "error loading releases reverting to " & $ currentCommit

  result.state = Processed

proc loadDependency*(
    info: var Dependency,
    path: Path
) = 
  case todo
  of DoClone:
    let (status, msg) =
      if graph[i].pkg.isFileProtocol:
        copyFromDisk(graph[i], dest)
      else:
        cloneUrl(graph[i].pkg, dest, false)
    if status == Ok:
      dep.state = Found
    else:
      dep.state = Error
      dep.errors.add $status & ":" & msg
  of DoNothing:
    if dep.ondisk.dirExists():
      dep.state = Found
    else:
      dep.state = Error
      dep.errors.add "ondisk location missing"


proc expand*(nc: NimbleContext; mode: TraversalMode, root: Package) =
  ## Expand the graph by adding all dependencies.
  
  var processed = initHashSet[PkgUrl]()

  for pkg, dep in nc.packageToDependency.mpairs():
    if dep.state == NotInitialized:
      let (dest, todo) = pkgUrlToDirname(graph, dep)

      debug "expand", "todo: " & $todo & " pkg: " & graph[i].pkg.projectName & " dest: " & $dest
      # important: the ondisk path set here!
      graph[i].ondisk = dest

    inc i

  # if context().dumpGraphs:
  #   dumpJson(graph, "graph-expanded.json")
