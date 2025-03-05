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

export depgraphtypes, deptypes, versions

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
  debug dir, "finding nimble file searching by name:", projectName, "found:", result.join(", ")

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
    trace dep.pkg.projectName, "collectNimbleVersions commits:", mapIt(result, it.c.short()).join(", "), "nimble:", $nimbleFiles[0]

proc processNimbleRelease(
    nc: var NimbleContext;
    dep: Dependency,
    release: VersionTag
): Requirements =
  info dep.pkg.projectName, "Processing release:", $release

  if release.version == Version"#head":
    trace dep.pkg.projectName, "processRelease using current commit"
  elif release.commit.isEmpty():
    error dep.pkg.projectName, "processRelease missing commit ", $release, "at:", $dep.ondisk
    result = Requirements(status: HasBrokenRelease, err: "no commit")
    return
  elif not checkoutGitCommit(dep.ondisk, release.commit, Error):
    warn dep.pkg.projectName, "processRelease unable to checkout commit ", $release, "at:", $dep.ondisk
    result = Requirements(status: HasBrokenRelease, err: "error checking out release")
    return

  let nimbleFiles = findNimbleFile(dep)
  var badNimbleFile = false
  if nimbleFiles.len() == 0:
    info "processRelease", "skipping release: missing nimble file:", $release
    result = Requirements(status: HasUnknownNimbleFile, err: "missing nimble file")
  elif nimbleFiles.len() > 1:
    info "processRelease", "skipping release: ambiguous nimble file:", $release, "files:", $(nimbleFiles.mapIt(it.splitPath().tail).join(", "))
    result = Requirements(status: HasUnknownNimbleFile, err: "ambiguous nimble file")
  else:
    let nimbleFile = nimbleFiles[0]
    result = nc.parseNimbleFile(nimbleFile, context().overrides)

    if result.status == Normal:
      for pkgUrl, interval in items(result.deps):
        # var pkgDep = specs.packageToDependency.getOrDefault(pkgUrl, nil)
        if pkgUrl notin nc.packageToDependency:
          info dep.pkg.projectName, "found new dep:", pkgUrl.projectName, "url:", pkgUrl.url()
          let pkgDep = Dependency(pkg: pkgUrl, state: NotInitialized)
          nc.packageToDependency[pkgUrl] = pkgDep
          # TODO: enrich versions with hashes when added
          # enrichVersionsViaExplicitHash graph[depIdx].versions, interval

proc addRelease(
    spec: var DependencySpec,
    nc: var NimbleContext;
    dep: Dependency,
    vtag: VersionTag
): VersionTag =
  var vtag = vtag
  info dep.pkg.projectName, "Adding Nimble version:", $vtag
  let release = nc.processNimbleRelease(dep, vtag)

  if vtag.v.string == "":
    vtag.v = release.version
    warn dep.pkg.projectName, "updating release tag information:", $vtag
  elif vtag.v != release.version:
    warn dep.pkg.projectName, "version mismatch between:", $vtag.v, "nimble version:", $release.version
  
  spec.versions[vtag] = release

proc traverseDependency*(
    nc: var NimbleContext;
    dep: var Dependency,
    mode: TraversalMode;
    versions: seq[VersionTag];
): DependencySpec =
  doAssert dep.ondisk.dirExists() and dep.state != NotInitialized, "DependencySpec should've been found or cloned at this point"

  result = DependencySpec()

  let currentCommit = currentGitCommit(dep.ondisk, Warning)
  if mode == CurrentCommit and currentCommit.isEmpty():
    let vtag = VersionTag(v: Version"#head", c: initCommitHash("", FromHead))
    result.versions[vtag] = Requirements(status: Normal)
    dep.state = Processed
    info dep.pkg.projectName, "traversing dependency using current commit:", $vtag
  elif currentCommit.isEmpty():
    warn dep.pkg.projectName, "traversing dependency unable to find git current version at ", $dep.ondisk
    let vtag = VersionTag(v: Version"#head", c: initCommitHash("", FromHead))
    result.versions[vtag] = Requirements(status: HasBrokenRepo)
    dep.state = Error
    return
  else:
    trace dep.pkg.projectName, "traversing dependency current commit:", $currentCommit

  case mode
  of CurrentCommit:
    trace dep.pkg.projectName, "traverseDependency only loading current commit"
    let vtag = VersionTag(v: Version"#head", c: initCommitHash(currentCommit, FromHead))
    discard result.addRelease(nc, dep, vtag)

  of AllReleases:
    try:
      var uniqueCommits: HashSet[CommitHash]
      let nimbleCommits = nc.collectNimbleVersions(dep)
      debug dep.pkg.projectName, "traverseDependency nimble versions:", $nimbleCommits

      for version in versions:
        if version.version == Version"" and
            not version.commit.isEmpty() and
            not uniqueCommits.containsOrIncl(version.commit):
            let vtag = VersionTag(v: Version"", c: version.commit)
            assert vtag.commit.orig == FromDep, "maybe this needs to be overriden like before"
            discard result.addRelease(nc, dep, vtag)

      let tags = collectTaggedVersions(dep.ondisk)
      for tag in tags:
        if not uniqueCommits.containsOrIncl(tag.c):
          let tag = result.addRelease(nc, dep, tag)
          assert tag.commit.orig == FromGitTag, "maybe this needs to be overriden like before"

      for tag in nimbleCommits:
        if not uniqueCommits.containsOrIncl(tag.c):
          discard result.addRelease(nc, dep, tag)

      if result.versions.len() == 0:
        let vtag = VersionTag(v: Version"#head", c: initCommitHash(currentCommit, FromHead))
        info dep.pkg.projectName, "traverseDependency no versions found, using default #head", "at", $dep.ondisk
        discard result.addRelease(nc, dep, vtag)

    finally:
      if not checkoutGitCommit(dep.ondisk, currentCommit, Warning):
        info dep.pkg.projectName, "traverseDependency error loading releases reverting to ", $currentCommit

  dep.state = Processed
  result.versions.sort(sortVersions)

proc loadDependency*(
    nc: NimbleContext,
    dep: var Dependency,
) = 
  let (dest, todo) = pkgUrlToDirname(dep)
  dep.ondisk = dest

  debug dep.pkg.projectName, "loading dependency todo:", $todo, "dest:", $dest
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

proc expand*(nc: var NimbleContext; mode: TraversalMode, path: Path): DependencySpecs =
  ## Expand the graph by adding all dependencies.
  
  let pkg = nc.createUrl(path)
  warn pkg.projectName, "expanding root package at:", $pkg
  var dep = Dependency(pkg: pkg, isRoot: true, isTopLevel: true)
  # nc.loadDependency(dep)

  var processed = initHashSet[PkgUrl]()
  var specs = DependencySpecs()
  nc.packageToDependency[dep.pkg] = dep

  var processing = true
  while processing:
    processing = false
    let pkgs = nc.packageToDependency.keys().toSeq()
    info "Expand", "Expanding packages for:", $pkg.projectName
    for pkg in pkgs:
      template dep(): var Dependency = nc.packageToDependency[pkg]
      case dep.state:
      of NotInitialized:
        info pkg.projectName, "Initializing at:", $dep
        nc.loadDependency(dep)
        debug pkg.projectName, "expanded dep:", dep.repr
        processing = true
      of Found:
        info pkg.projectName, "Processing at:", $dep.ondisk
        # processing = true
        let mode = if dep.isRoot: CurrentCommit else: mode
        let spec = nc.traverseDependency(dep, mode, @[])
        # debug pkg.projectName, "processed spec:", $spec
        for vtag, reqs in spec.versions:
          debug pkg.projectName, "spec version:", $vtag, "reqs:", $(toJsonHook(reqs))
        specs.depsToSpecs[pkg] = spec
        processing = true
      else:
        discard

  for pkg, spec in specs.depsToSpecs:
    warn pkg.projectName, "Processed:", $pkg.url()
    for vtag, reqs in spec.versions:
      info pkg.projectName, "spec version:", $vtag, "reqs:", reqs.deps.mapIt($(it[0].projectName) & " " & $(it[1])).join(", "), "status:", $reqs.status

  result = specs

  # if context().dumpGraphs:
  #   dumpJson(graph, "graph-expanded.json")
