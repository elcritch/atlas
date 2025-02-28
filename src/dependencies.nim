#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, strutils, tables, unicode, sequtils, sets, json, hashes, algorithm, paths, files, dirs]
import basic/[context, deptypes, depgraphtypes, versions, osutils, nimbleparser, packageinfos, reporters, gitops, parse_requires, pkgurls, compiledpatterns]
import cloner

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
  debug "findNimbleFile:search", "name:", projectName, "found:", $result

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
      c.nameToUrl[unicode.toLower(entry.name)] = createUrlSkipPatterns(entry.url, skipDirTest=true)

proc createNimbleContext*(): NimbleContext =
  result = NimbleContext()
  fillPackageLookupTable(result)

proc collectNimbleVersions*(nc: NimbleContext; dep: Dependency): seq[VersionTag] =
  let nimbleFiles = findNimbleFile(dep)
  let dir = dep.ondisk
  doAssert(dep.ondisk.string != "", "Package ondisk must be set before collectNimbleVersions can be called! Package: " & $(dep))
  result = @[]
  if nimbleFiles.len() == 1:
    result = collectFileCommits(dir, nimbleFiles[0])
    result.reverse()
    trace "collectNimbleVersions", "commits:", mapIt(result, it.c.short()).join(", ")

proc processRelease(specs: DependencySpecs; dep: Dependency, release: VersionTag): Requirements =
  debug "processRelease", "name: " & dep.projectName() & " release: " & $release

  if release.version == Version"#head":
    trace "processRelease", "using current commit"
  elif release.commit.isEmpty():
    error "processRelease", "missing commit " & $release & " at " & $dep.ondisk
    result = Requirements(status: HasBrokenRelease, err: "no commit")
    return
  elif not checkoutGitCommit(dep.ondisk, release.commit):
    result = Requirements(status: HasBrokenRelease, err: "error checking out release")
    return

  let nimbleFiles = findNimbleFile(dep)
  var badNimbleFile = false
  if nimbleFiles.len() == 0:
    info "processRelease", "skipping release: missing nimble file" & $release
    result = Requirements(status: HasUnknownNimbleFile, err: "missing nimble file")
  elif nimbleFiles.len() > 1:
    info "processRelease", "skipping release: ambiguous nimble file" & $release & " files: " & $(nimbleFiles.mapIt(it.splitPath().tail).join(", "))
    result = Requirements(status: HasUnknownNimbleFile, err: "ambiguous nimble file")
  else:
    let nimbleFile = nimbleFiles[0]
    result = parseNimbleFile(specs.nimbleCtx, nimbleFile, context().overrides)

    if result.status == Normal:
      for pkgUrl, interval in items(result.deps):
        # var pkgDep = specs.packageToDependency.getOrDefault(pkgUrl, nil)
        if pkgUrl notin specs.packageToDependency:
          let pkgDep = Dependency(pkg: pkgUrl, state: NotInitialized)
          specs.packageToDependency[pkgUrl] = pkgDep
          # TODO: enrich versions with hashes when added
          # enrichVersionsViaExplicitHash graph[depIdx].versions, interval

proc traverseDependency*(
    specs: DependencySpecs;
    dep: Dependency,
    mode: TraversalMode;
    versions: seq[VersionTag];
): DependencySpec =
  doAssert dep.ondisk.fileExists() and dep.state != NotInitialized, "DependencySpec should've been found or cloned at this point"

  result = DependencySpec(dep: dep)

  let currentCommit = currentGitCommit(dep.ondisk, Error)
  trace "depgraphs:releases", "currentCommit: " & $currentCommit
  if currentCommit.isEmpty():
    warn "traverseDependency", "unable to find git current version at " & $dep.ondisk
    let vtag = VersionTag(v: Version"#head", c: initCommitHash("", FromHead))
    result.versions[vtag] = Requirements(status: HasBrokenRepo)
    result.dep.state = Error
    return

  case mode
  of CurrentCommit:
    trace "traverseDependency", "only loading current commit"
    let vtag = VersionTag(v: Version"#head", c: initCommitHash(currentCommit, FromHead))
    result.versions[vtag] = specs.processRelease(result.dep, vtag)

  of AllReleases:
    try:
      var uniqueCommits: HashSet[CommitHash]
      let nimbleCommits = specs.nimbleCtx.collectNimbleVersions(dep)
      debug "traverseDependency", "nimble versions: " & $nimbleCommits

      for version in versions:
        if version.version == Version"" and
            not version.commit.isEmpty() and
            not uniqueCommits.containsOrIncl(version.commit):
            let vtag = VersionTag(v: Version"", c: version.commit)
            assert vtag.commit.orig == FromDep, "maybe this needs to be overriden like before"
            result.versions[vtag] = specs.processRelease(result.dep, vtag)

      let tags = collectTaggedVersions(dep.ondisk)
      for tag in tags:
        if not uniqueCommits.containsOrIncl(tag.c):
          result.versions[tag] = specs.processRelease(result.dep, tag)
          assert tag.commit.orig == FromGitTag, "maybe this needs to be overriden like before"

      for tag in nimbleCommits:
        if not uniqueCommits.containsOrIncl(tag.c):
          result.versions[tag] = specs.processRelease(result.dep, tag)

      if result.versions.len() == 0:
        let vtag = VersionTag(v: Version"#head", c: initCommitHash(currentCommit, FromHead))
        info "traverseDependency", "no versions found, using default #head", "at", $dep.ondisk
        result.versions[vtag] = specs.processRelease(result.dep, vtag)

    finally:
      if not checkoutGitCommit(dep.ondisk, currentCommit, Warning):
        info "traverseDependency", "error loading releases reverting to " & $ currentCommit

  result.dep.state = Processed

proc loadDependency*(
    nc: NimbleContext,
    dep: var Dependency,
) = 
  let (dest, todo) = pkgUrlToDirname(dep)
  dep.ondisk = dest

  debug "dependencies:loadDependency", "todo:", $todo, "dest:", $dest
  case todo
  of DoClone:
    let (status, msg) =
      if dep.pkg.isFileProtocol:
        copyFromDisk(dep, dest)
      else:
        cloneUrl(dep.pkg, dest, false)
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

      # debug "expand", "todo: " & $todo & " pkg: " & graph[i].pkg.projectName & " dest: " & $dest
      # # important: the ondisk path set here!
      # graph[i].ondisk = dest

proc expand*(nc: NimbleContext; mode: TraversalMode, pkg: PkgUrl): DependencySpecs =
  ## Expand the graph by adding all dependencies.
  
  info "expand", "pkg=", $pkg
  var dep = Dependency(pkg: pkg, isRoot: true, isTopLevel: true)
  var processed = initHashSet[PkgUrl]()
  var specs = DependencySpecs()

  for pkg, dep in specs.packageToDependency.mpairs():
    if dep.state == NotInitialized:
      nc.loadDependency(dep)


  # if context().dumpGraphs:
  #   dumpJson(graph, "graph-expanded.json")
