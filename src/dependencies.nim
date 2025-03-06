#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, strutils, uri, tables, unicode, sequtils, sets, json, hashes, algorithm, paths, files, dirs]
import basic/[context, deptypes, versions, osutils, nimbleparser, packageinfos, reporters, gitops, parse_requires, pkgurls, compiledpatterns]

export deptypes, versions

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

proc findNimbleFile*(info: Package): seq[Path] =
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
    let res = clone(parseUri "https://github.com/nim-lang/packages", pkgsDir)
    if res[0] != Ok:
      error DefaultPackagesSubDir, "cannot clone packages repo: " & res[1]

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
  result.overrides = context().overrides
  fillPackageLookupTable(result)

proc collectNimbleVersions*(nc: NimbleContext; dep: Package): seq[VersionTag] =
  let nimbleFiles = findNimbleFile(dep)
  let dir = dep.ondisk
  doAssert(dep.ondisk.string != "", "Package ondisk must be set before collectNimbleVersions can be called! Package: " & $(dep))
  result = @[]
  if nimbleFiles.len() == 1:
    result = collectFileCommits(dir, nimbleFiles[0])
    result.reverse()
    trace dep.pkg.projectName, "collectNimbleVersions commits:", mapIt(result, it.c.short()).join(", "), "nimble:", $nimbleFiles[0]

type
  PackageAction* = enum
    DoNothing, DoClone

proc pkgUrlToDirname*(dep: Package): (Path, PackageAction) =
  # XXX implement namespace support here
  # var dest = Path g.ondisk.getOrDefault(d.pkg.url)
  var dest = Path ""
  if dep.isTopLevel:
    trace dep.pkg.projectName, "pkgUrlToDirName topLevel= " & $dep.isTopLevel
    dest = context().workspace
  else:
    let depsDir = context().workspace / context().depsDir
    dest = depsDir / Path(dep.pkg.projectName)
    trace dep.pkg.projectName, "pkgUrlToDirName depsDir:", $depsDir, "projectName:", dep.pkg.projectName
  dest = dest.absolutePath
  result = (dest, if dirExists(dest): DoNothing else: DoClone)

proc copyFromDisk*(dep: Package; destDir: Path): (CloneStatus, string) =
  var dir = Path dep.pkg.url
  if dir.string.startsWith(FileWorkspace):
    dir = context().workspace / Path(dir.string.substr(FileWorkspace.len))
  #template selectDir(a, b: string): string =
  #  if dirExists(a): a else: b

  #let dir = selectDir(u & "@" & w.commit, u)
  if dep.isTopLevel:
    trace dir, "copyFromDisk isTopLevel", $dir
    result = (Ok, $dir)
  elif dirExists(dir):
    trace dir, "copyFromDisk cloning:", $dir
    copyDir($dir, $destDir)
    result = (Ok, "")
  else:
    warn dir, "copyFromDisk not found:", $dir
    result = (NotFound, $dir)
  #writeFile destDir / ThisVersion, w.commit
  #echo "WRITTEN ", destDir / ThisVersion

proc processNimbleRelease(
    nc: var NimbleContext;
    dep: Package,
    release: VersionTag
): NimbleRelease =
  info dep.pkg.projectName, "Processing release:", $release

  if release.version == Version"#head":
    trace dep.pkg.projectName, "processRelease using current commit"
  elif release.commit.isEmpty():
    error dep.pkg.projectName, "processRelease missing commit ", $release, "at:", $dep.ondisk
    result = NimbleRelease(status: HasBrokenRelease, err: "no commit")
    return
  elif not checkoutGitCommit(dep.ondisk, release.commit, Error):
    warn dep.pkg.projectName, "processRelease unable to checkout commit ", $release, "at:", $dep.ondisk
    result = NimbleRelease(status: HasBrokenRelease, err: "error checking out release")
    return

  let nimbleFiles = findNimbleFile(dep)
  var badNimbleFile = false
  if nimbleFiles.len() == 0:
    info "processRelease", "skipping release: missing nimble file:", $release
    result = NimbleRelease(status: HasUnknownNimbleFile, err: "missing nimble file")
  elif nimbleFiles.len() > 1:
    info "processRelease", "skipping release: ambiguous nimble file:", $release, "files:", $(nimbleFiles.mapIt(it.splitPath().tail).join(", "))
    result = NimbleRelease(status: HasUnknownNimbleFile, err: "ambiguous nimble file")
  else:
    let nimbleFile = nimbleFiles[0]
    result = nc.parseNimbleFile(nimbleFile, context().overrides)

    if result.status == Normal:
      for pkgUrl, interval in items(result.deps):
        # var pkgDep = specs.packageToDependency.getOrDefault(pkgUrl, nil)
        if pkgUrl notin nc.packageToDependency:
          debug dep.pkg.projectName, "Found new dep:", pkgUrl.projectName, "url:", pkgUrl.url()
          let pkgDep = Package(pkg: pkgUrl, state: NotInitialized)
          nc.packageToDependency[pkgUrl] = pkgDep
          # TODO: enrich versions with hashes when added
          # enrichVersionsViaExplicitHash graph[depIdx].versions, interval

proc addRelease(
    releases: var seq[(VersionTag, NimbleRelease)],
    # spec: var PackageSpec,
    nc: var NimbleContext;
    dep: Package,
    vtag: VersionTag
): VersionTag =
  result = vtag
  warn dep.pkg.projectName, "Adding Nimble version:", $vtag
  let release = nc.processNimbleRelease(dep, vtag)

  if vtag.v.string == "":
    result.v = release.version
    debug dep.pkg.projectName, "updating release tag information:", $result
  elif release.version.string == "":
    warn dep.pkg.projectName, "nimble file missing version information:", $result
    release.version = vtag.version
  elif vtag.v != release.version:
    warn dep.pkg.projectName, "version mismatch between:", $vtag.v, "nimble version:", $release.version
  
  releases.add((result, release,))

proc traverseDependency*(
    nc: var NimbleContext;
    dep: var Package,
    mode: TraversalMode;
    versions: seq[VersionTag];
): PackageSpec =
  doAssert dep.ondisk.dirExists() and dep.state != NotInitialized, "PackageSpec should've been found or cloned at this point"

  result = PackageSpec()
  var releases: seq[(VersionTag, NimbleRelease)]

  let currentCommit = currentGitCommit(dep.ondisk, Warning)
  if mode == CurrentCommit and currentCommit.isEmpty():
    # let vtag = VersionTag(v: Version"#head", c: initCommitHash("", FromHead))
    # releases.add((vtag, NimbleRelease(version: vtag.version, status: Normal)))
    # dep.state = Processed
    # info dep.pkg.projectName, "traversing dependency using current commit:", $vtag
    discard
  elif currentCommit.isEmpty():
    warn dep.pkg.projectName, "traversing dependency unable to find git current version at ", $dep.ondisk
    let vtag = VersionTag(v: Version"#head", c: initCommitHash("", FromHead))
    releases.add((vtag, NimbleRelease(version: vtag.version, status: HasBrokenRepo)))
    dep.state = Error
    return
  else:
    trace dep.pkg.projectName, "traversing dependency current commit:", $currentCommit

  case mode
  of CurrentCommit:
    trace dep.pkg.projectName, "traversing dependency for only current commit"
    let vtag = VersionTag(v: Version"#head", c: initCommitHash(currentCommit, FromHead))
    discard releases.addRelease(nc, dep, vtag)

  of AllReleases:
    try:
      var uniqueCommits: HashSet[CommitHash]
      let nimbleCommits = nc.collectNimbleVersions(dep)

      info dep.pkg.projectName, "traverseDependency nimble explicit versions:", $versions
      for version in versions:
        if version.version == Version"" and
            not version.commit.isEmpty() and
            not uniqueCommits.containsOrIncl(version.commit):
            let vtag = VersionTag(v: Version"", c: version.commit)
            assert vtag.commit.orig == FromDep, "maybe this needs to be overriden like before: " & $vtag.commit.orig
            discard releases.addRelease(nc, dep, vtag)

      ## Note: always prefer tagged versions
      let tags = collectTaggedVersions(dep.ondisk)
      info dep.pkg.projectName, "traverseDependency nimble tags:", $tags
      for tag in tags:
        if not uniqueCommits.containsOrIncl(tag.c):
          let tag = releases.addRelease(nc, dep, tag)
          assert tag.commit.orig == FromGitTag, "maybe this needs to be overriden like before: " & $tag.commit.orig

      if tags.len() == 0 or context().includeTagsAndNimbleCommits:
        ## Note: skip nimble commit versions unless explicitly enabled
        ## package maintainers may delete a tag to skip a versions, which we'd override here
        info dep.pkg.projectName, "traverseDependency nimble commits:", $nimbleCommits
        for tag in nimbleCommits:
          if not uniqueCommits.containsOrIncl(tag.c):
            discard releases.addRelease(nc, dep, tag)

      if releases.len() == 0:
        let vtag = VersionTag(v: Version"#head", c: initCommitHash(currentCommit, FromHead))
        info dep.pkg.projectName, "traverseDependency no versions found, using default #head", "at", $dep.ondisk
        discard releases.addRelease(nc, dep, vtag)

    finally:
      if not checkoutGitCommit(dep.ondisk, currentCommit, Warning):
        info dep.pkg.projectName, "traverseDependency error loading releases reverting to ", $currentCommit

  dep.state = Processed

  var uniqueReleases: Table[NimbleRelease, NimbleRelease]
  for (vtag, rel) in releases:
    if rel notin uniqueReleases:
      trace dep.pkg.projectName, "found unique release requirements at:", $vtag
      uniqueReleases[rel] = rel
    else:
      trace dep.pkg.projectName, "found duplicate release requirements at:", $vtag

  info dep.pkg.projectName, "unique releases found:", uniqueReleases.values().toSeq().mapIt($it.version).join(", ")
  for (vtag, rel) in releases:
    if vtag in result.releases:
      error dep.pkg.projectName, "duplicate release found:", $vtag, "new:", repr(rel)
      error dep.pkg.projectName, "... existing: ", repr(result.releases[vtag])
      error dep.pkg.projectName, "duplicate release found:", $vtag, "new:", repr(rel), " existing: ", repr(result.releases[vtag])
      error dep.pkg.projectName, "releases table:", $result.releases.keys().toSeq()
    result.releases[vtag] = uniqueReleases[rel]
  
  # TODO: filter by unique versions first?
  result.releases.sort(sortVersions)

proc loadDependency*(
    nc: NimbleContext,
    dep: var Package,
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
        gitops.clone(dep.pkg.toUri, dest)
    if status == Ok:
      dep.state = Found
    else:
      dep.state = Error
      dep.errors.add $status & ": " & msg
  of DoNothing:
    if dep.ondisk.dirExists():
      dep.state = Found
    else:
      dep.state = Error
      dep.errors.add "ondisk location missing"

proc expand*(nc: var NimbleContext; mode: TraversalMode, path: Path): PackageSpecs =
  ## Expand the graph by adding all dependencies.
  
  let pkg = nc.createUrl(path)
  warn pkg.projectName, "expanding root package at:", $pkg
  var dep = Package(pkg: pkg, isRoot: true, isTopLevel: true)
  # nc.loadDependency(dep)

  var processed = initHashSet[PkgUrl]()
  var specs = PackageSpecs()
  nc.packageToDependency[dep.pkg] = dep

  var processing = true
  while processing:
    processing = false
    let pkgs = nc.packageToDependency.keys().toSeq()
    info "Expand", "Expanding packages for:", $pkg.projectName
    for pkg in pkgs:
      template dep(): var Package = nc.packageToDependency[pkg]
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
        for vtag, reqs in spec.releases:
          debug pkg.projectName, "spec version:", $vtag, "reqs:", $(toJsonHook(reqs))
        specs.pkgsToSpecs[pkg] = spec
        processing = true
      else:
        discard

  for pkg, spec in specs.pkgsToSpecs:
    info pkg.projectName, "Processed:", $pkg.url()
    for vtag, reqs in spec.releases:
      info pkg.projectName, "spec version:", $vtag, "reqs:", reqs.deps.mapIt($(it[0].projectName) & " " & $(it[1])).join(", "), "status:", $reqs.status

  result = specs

  # if context().dumpGraphs:
  #   dumpJson(graph, "graph-expanded.json")
