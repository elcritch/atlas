#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, strutils, uri, tables, sequtils, sets, hashes, algorithm, paths, dirs, monotimes, times]
import basic/[context, deptypes, versions, osutils, nimbleparser, reporters, gitops, pkgurls, nimblecontext, deptypesjson, repocache]

export deptypes, versions, deptypesjson

proc collectNimbleVersions*(nc: NimbleContext; pkg: Package): seq[VersionTag] =
  let nimbleFiles = findNimbleFile(pkg)
  let dir = pkg.ondisk
  doAssert(pkg.ondisk.string != "", "Package ondisk must be set before collectNimbleVersions can be called! Package: " & $(pkg))
  result = @[]
  if nimbleFiles.len() == 1:
    result = collectFileCommits(dir, nimbleFiles[0], isLocalOnly = pkg.isLocalOnly)
    result.reverse()
    trace pkg, "collectNimbleVersions commits:", mapIt(result, it.c.short()).join(", "), "nimble:", $nimbleFiles[0]

type
  PackageAction* = enum
    DoNothing, DoClone

proc copyFromDisk*(pkg: Package, dest: Path): (CloneStatus, string) =
  let source = pkg.url.toOriginalPath()
  info pkg, "copyFromDisk cloning:", $dest, "from:", $source
  if dirExists(source) and not dirExists(dest):
    trace pkg, "copyFromDisk cloning:", $dest, "from:", $source
    copyDir(source.string, dest.string)
    result = (Ok, "")
  else:
    error pkg, "copyFromDisk not found:", $source
    result = (NotFound, $dest)


proc processNimbleRelease(
    nc: var NimbleContext;
    pkg: Package,
    release: VersionTag
): NimbleRelease =
  trace pkg.url.projectName, "Processing release:", $release

  var nimbleFiles: seq[Path]
  if release.version == Version"#head":
    trace pkg.url.projectName, "processRelease using current commit"
    nimbleFiles = findNimbleFile(pkg)
  elif release.commit.isEmpty():
    warn pkg.url.projectName, "processRelease missing commit ", $release, "at:", $pkg.ondisk
    result = NimbleRelease(status: HasBrokenRelease, err: "no commit")
    return
  else:
    nimbleFiles = cacheNimbleFilesFromGit(pkg, release.commit)

    # warn pkg.url.projectName, "processRelease unable to checkout commit ", $release, "at:", $pkg.ondisk
    # result = NimbleRelease(status: HasBrokenRelease, err: "error checking out release")

  if nimbleFiles.len() == 0:
    info "processRelease", "skipping release: missing nimble file:", $release
    result = NimbleRelease(status: HasUnknownNimbleFile, err: "missing nimble file")
  elif nimbleFiles.len() > 1:
    info "processRelease", "skipping release: ambiguous nimble file:", $release, "files:", $(nimbleFiles.mapIt(it.splitPath().tail).join(", "))
    result = NimbleRelease(status: HasUnknownNimbleFile, err: "ambiguous nimble file")
  else:
    let nimbleFile = nimbleFiles[0]
    result = nc.parseNimbleFile(nimbleFile)

    if result.status == Normal:
      registerReleaseDependencies(nc, pkg, result)

proc addFeatureDependencies(pkg: Package) =

  var featuresAdded = false
  warn pkg.url.projectName, "adding feature dependencies for root package; features:", $(context().features.toSeq().join(", ")), "versions:", $(pkg.versions.keys().toSeq().mapIt($it).join(", "))
  for flag in items(context().features):
    for ver, rel in pkg.versions:
      info pkg.url.projectName, "checking feature:", $flag, "in version:", $rel.version
      if flag in rel.features:
        let fdep = rel.features[flag]
        for pkgUrl, interval in items(fdep):
          info pkg.url.projectName, "adding feature reqsByFeatures:", $flag, "for:", $pkgUrl.url
          withValue(rel.reqsByFeatures, pkgUrl, reqsByFeatures):
            if flag notin reqsByFeatures[]:
              reqsByFeatures[].incl(flag)
              featuresAdded = true
          do:
            rel.reqsByFeatures[pkgUrl] = initHashSet[string]()
            rel.reqsByFeatures[pkgUrl].incl(flag)
      else:
        info pkg.url.projectName, "feature:", $flag, "not found for:", $rel.version
  
  if featuresAdded:
    warn pkg.url.projectName, "feature dependencies added"
    pkg.state = Found

proc addRelease(
    versions: var seq[(PackageVersion, NimbleRelease)],
    # pkg: var Package,
    nc: var NimbleContext;
    pkg: Package,
    vtag: VersionTag
): bool =
  var pkgver = vtag.toPkgVer()
  trace pkg.url.projectName, "Adding Nimble version:", $vtag
  try:
    let release = nc.processNimbleRelease(pkg, vtag)

    if vtag.v.string == "":
      pkgver.vtag.v = release.version
      trace pkg.url.projectName, "updating release tag information:", $pkgver.vtag
    elif release.version.string == "":
      warn pkg.url.projectName, "nimble file missing version information:", $pkgver.vtag
      release.version = vtag.version
    elif vtag.v != release.version and not pkg.isRoot:
      info pkg.url.projectName, "version mismatch between version tag:", $vtag.v, "and nimble version:", $release.version
    
    versions.add((pkgver, release))

    result = true
  except CatchableError as e:
    info pkg.url.projectName, "error processing nimble release:", $vtag, "error:", $e.msg
    return false

proc traverseDependency*(
    nc: var NimbleContext;
    pkg: var Package,
    mode: TraversalMode;
    explicitVersions: seq[VersionTag];
) =
  doAssert pkg.ondisk.dirExists() and pkg.state != NotInitialized, "Package should've been found or cloned at this point. Package: " & $pkg.url & " on disk: " & $pkg.ondisk

  var versions: seq[(PackageVersion, NimbleRelease)]

  let currentCommit = currentGitCommit(pkg.ondisk, Warning)
  if not pkg.isLocalOnly:
    discard gitops.ensureCanonicalOrigin(pkg.ondisk, pkg.url.toUri)
  pkg.originHead = gitops.findOriginTip(pkg.ondisk, errorReportLevel = Warning, isLocalOnly = pkg.isLocalOnly).commit()

  let usedCache = loadVersionsFromCache(nc, pkg, currentCommit, mode)
  let shouldWriteCache = mode == AllReleases and not usedCache

  if mode == CurrentCommit and currentCommit.isEmpty():
    # let vtag = VersionTag(v: Version"#head", c: initCommitHash("", FromHead))
    # versions.add((vtag, NimbleRelease(version: vtag.version, status: Normal)))
    # pkg.state = Processed
    # info pkg.url.projectName, "traversing dependency using current commit:", $vtag
    discard
  elif currentCommit.isEmpty():
    warn pkg.url.projectName, "traversing dependency unable to find git current version at ", $pkg.ondisk
    let vtag = VersionTag(v: Version"#head", c: initCommitHash("", FromHead))
    versions.add((vtag.toPkgVer, NimbleRelease(version: vtag.version, status: HasBrokenRepo)))
    pkg.state = Error
    return
  else:
    trace pkg.url.projectName, "traversing dependency current commit:", $currentCommit

  if not usedCache:
    case mode
    of CurrentCommit:
      trace pkg.url.projectName, "traversing dependency for only current commit"
      let vtag = VersionTag(v: Version"#head", c: initCommitHash(currentCommit, FromHead))
      discard versions.addRelease(nc, pkg, vtag)

    of ExplicitVersions:
      debug pkg.url.projectName, "traversing dependency found explicit versions:", $explicitVersions
      var uniqueCommits: HashSet[CommitHash]
      for ver in pkg.versions.keys():
        uniqueCommits.incl(ver.vtag.c)

      var explicitVersions = explicitVersions
      for version in mitems(explicitVersions):
        let vtag = gitops.expandSpecial(pkg.ondisk, vtag = version)
        version = vtag
        debug pkg.url.projectName, "explicit version:", $version, "vtag:", repr vtag

      for version in explicitVersions:
        debug pkg.url.projectName, "check explicit version:", repr version
        if version.commit.isEmpty():
          warn pkg.url.projectName, "explicit version has empty commit:", $version
        elif not uniqueCommits.containsOrIncl(version.commit):
          debug pkg.url.projectName, "add explicit version:", $version
          discard versions.addRelease(nc, pkg, version)

    of AllReleases:
      try:
        var uniqueCommits: HashSet[CommitHash]
        var nimbleVersions: HashSet[Version]
        var nimbleCommits = nc.collectNimbleVersions(pkg)

        debug pkg.url.projectName, "nimble explicit versions:", $explicitVersions
        for version in explicitVersions:
          if version.version == Version"" and
              not version.commit.isEmpty() and
              not uniqueCommits.containsOrIncl(version.commit):
              let vtag = VersionTag(v: Version"", c: version.commit)
              assert vtag.commit.orig == FromDep, "maybe this needs to be overriden like before: " & $vtag.commit.orig
              discard versions.addRelease(nc, pkg, vtag)

        let tags = collectTaggedVersions(pkg.ondisk, isLocalOnly = pkg.isLocalOnly)
        debug pkg.url.projectName, "nimble tags:", $tags
        for tag in tags:
          if not uniqueCommits.containsOrIncl(tag.c):
            discard versions.addRelease(nc, pkg, tag)
            assert tag.commit.orig == FromGitTag, "maybe this needs to be overriden like before: " & $tag.commit.orig

        if tags.len() == 0 or IncludeTagsAndNimbleCommits in context().flags:
          if NimbleCommitsMax in context().flags:
            nimbleCommits.reverse()

          debug pkg.url.projectName, "nimble commits:", $nimbleCommits
          for tag in nimbleCommits:
            if not uniqueCommits.containsOrIncl(tag.c):
              var vers: seq[(PackageVersion, NimbleRelease)]
              let added = vers.addRelease(nc, pkg, tag)
              if added and not nimbleVersions.containsOrIncl(vers[0][0].vtag.v):
                versions.add(vers)
            else:
              error pkg.url.projectName, "traverseDependency skipping nimble commit:", $tag, "uniqueCommits:", $(tag.c in uniqueCommits), "nimbleVersions:", $(tag.v in nimbleVersions)

        if versions.len() == 0:
          let vtag = VersionTag(v: Version"#head", c: initCommitHash(currentCommit, FromHead))
          debug pkg.url.projectName, "traverseDependency no versions found, using default #head", "at", $pkg.ondisk
          discard versions.addRelease(nc, pkg, vtag)

      finally:
        if not checkoutGitCommit(pkg.ondisk, currentCommit, Warning):
          info pkg.url.projectName, "traverseDependency error loading versions reverting to ", $currentCommit

    var uniqueReleases: Table[NimbleRelease, NimbleRelease]
    for (ver, rel) in versions:
      if rel notin uniqueReleases:
        uniqueReleases[rel] = rel
      else:
        trace pkg.url.projectName, "found duplicate release requirements at:", $ver.vtag

    info pkg.url.projectName, "unique versions found:", uniqueReleases.values().toSeq().mapIt($it.version).join(", ")
    for (ver, rel) in versions:
      if mode != ExplicitVersions and ver in pkg.versions:
        error pkg.url.projectName, "duplicate release found:", $ver.vtag, "new:", repr(rel)
        error pkg.url.projectName, "... existing: ", repr(pkg.versions[ver])
        error pkg.url.projectName, "duplicate release found:", $ver.vtag, "new:", repr(rel), " existing: ", repr(pkg.versions[ver])
        error pkg.url.projectName, "versions table:", $pkg.versions.keys().toSeq()
      pkg.versions[ver] = uniqueReleases[rel]
  else:
    info pkg.url.projectName, "Using cached version history"

  pkg.state = Processed

  if pkg.isRoot and context().features.len > 0:
    addFeatureDependencies(pkg)

  if shouldWriteCache:
    writePackageCache(nc, pkg, currentCommit, mode)


proc loadDependency*(
    nc: NimbleContext,
    pkg: var Package,
    onClone: PackageAction = DoClone,
) = 
  if pkg.isRoot:
    pkg.ondisk = project()
    pkg.isAtlasProject = true
    pkg.isLocalOnly = true
    if pkg.state != Found:
      pkg.state = Found
    return

  doAssert pkg.ondisk.string == ""

  let officialUrl = nc.lookup(pkg.url.shortName())
  let isFork = pkg.isFork

  if isFork:
    let canonicalDir = officialUrl.toDirectoryPath()
    let forkDir = pkg.url.toDirectoryPath()
    if dirExists(forkDir) and not dirExists(canonicalDir) and
        forkDir.isRelativeTo(depsDir()) and canonicalDir.isRelativeTo(depsDir()):
      try:
        moveDir(forkDir.string, canonicalDir.string)
      except OSError:
        discard
    pkg.ondisk = canonicalDir
  else:
    pkg.ondisk = pkg.url.toDirectoryPath()

  pkg.isAtlasProject = pkg.url.isAtlasProject()
  var todo = if dirExists(pkg.ondisk): DoNothing else: DoClone

  if pkg.state == LazyDeferred:
    todo = DoNothing

  debug pkg.url.projectName, "loading dependency todo:", $todo, "ondisk:", $pkg.ondisk, "isLinked:", $pkg.url.isFileProtocol, "isLazyDeferred:", $(pkg.state == LazyDeferred)
  case todo
  of DoClone:
    if onClone == DoNothing:
      pkg.state = Error
      pkg.errors.add "Not found"
    else:
      let (status, msg) =
        if pkg.url.isFileProtocol:
          pkg.isLocalOnly = true
          copyFromDisk(pkg, pkg.ondisk)
        else:
          gitops.clone(pkg.url.toUri, pkg.ondisk)
      if status == Ok:
        if not pkg.isLocalOnly:
          discard gitops.ensureCanonicalOrigin(pkg.ondisk, pkg.url.toUri)
          discard gitops.resolveRemoteName(pkg.ondisk)
          if isFork:
            discard gitops.ensureRemoteForUrl(pkg.ondisk, officialUrl.toUri)
          discard gitops.fetchRemoteTags(pkg.ondisk)
        pkg.state = Found
      else:
        pkg.state = Error
        pkg.errors.add $status & ": " & msg
  of DoNothing:
    if pkg.ondisk.dirExists():
      pkg.state = Found
      if not pkg.isLocalOnly:
        discard gitops.ensureCanonicalOrigin(pkg.ondisk, pkg.url.toUri)
        discard gitops.resolveRemoteName(pkg.ondisk)
        if isFork:
          discard gitops.ensureRemoteForUrl(pkg.ondisk, officialUrl.toUri)
      if UpdateRepos in context().flags:
        gitops.updateRepo(pkg.ondisk)
        if not pkg.isLocalOnly:
          discard gitops.fetchRemoteTags(pkg.ondisk)
        
    else:
      pkg.state = Error
      pkg.errors.add "ondisk location missing"

proc expandGraph*(path: Path, nc: var NimbleContext; mode: TraversalMode, onClone: PackageAction, isLinkPath = false): DepGraph =
  ## Expand the graph by adding all dependencies.
  
  doAssert path.string != "."
  let expandStart = getMonoTime()
  let url = nc.createUrlFromPath(path, isLinkPath)
  notice url.projectName, "expanding root package at:", $path, "url:", $url
  var root = Package(
    url: url,
    isRoot: true,
    isFork: isForkUrl(nc, url),
    isOfficial: isOfficialPackage(nc, url)
  )
  # nc.loadDependency(pkg)

  result = DepGraph(root: root, mode: mode)
  initSharedOrderedTable(result.pkgs)
  nc.packageToDependency[root.url] = root

  notice "atlas:expand", "Expanding packages for:", $root.projectName

  var processing = true
  var processedExplicit: Table[PkgUrl, int]
  while processing:
    processing = false
    let pkgUrls = nc.packageToDependency.keys().toSeq()

    # just for more concise logging
    var initializingPkgs: seq[string]
    var processingPkgs: seq[string]
    for pkgUrl in pkgUrls:
      var pkg = nc.packageToDependency[pkgUrl]
      case pkg.state:
      of NotInitialized:
        initializingPkgs.add pkg.projectName
      of Found:
        processingPkgs.add pkg.projectName
      else:
        discard
    if initializingPkgs.len() > 0:
      notice root.projectName, "Initializing packages:", initializingPkgs.join(", ")
    if processingPkgs.len() > 0:
      notice root.projectName, "Processing packages:", processingPkgs.join(", ")

    # process packages
    debug "atlas:expandGraph", "Processing package count: ", $pkgUrls.len()
    for pkgUrl in pkgUrls:
      var pkg = nc.packageToDependency[pkgUrl]
      case pkg.state:
      of NotInitialized, DoLoad:
        info pkg.projectName, "Initializing package:", $pkg.url
        nc.loadDependency(pkg, onClone)
        trace pkg.projectName, "expanded pkg:", pkg.repr
        processing = true
      of LazyDeferred:
        if pkgUrl notin result.pkgs:
          result.pkgs[pkgUrl] = pkg
          pkg.versions[VersionTag(v: Version"*", c: initCommitHash("#head", FromHead)).toPkgVer] = NimbleRelease(version: Version"#head", status: Normal)
          result.pkgs[pkgUrl] = pkg
          info pkg.projectName, "Adding lazy deferred package to pkgs list:", $pkg.url
        else:
          trace pkg.projectName, "Skipping lazy deferred package:", $pkg.url
        pkg.state = LazyDeferred
      of Found:
        info pkg.projectName, "Processing package at:", pkg.ondisk.relativeToWorkspace()
        # processing = true
        let mode = if pkg.isRoot or pkg.isAtlasProject: CurrentCommit else: mode
        nc.traverseDependency(pkg, mode, @[])
        trace pkg.projectName, "processed pkg:", $pkg
        processing = true
        if pkgUrl notin result.pkgs:
          result.pkgs[pkgUrl] = pkg
      of Processed:
        discard
      else:
        discard
        info pkg.projectName, "Skipping package:", $pkg.url, "state:", $pkg.state

    debug "atlas:expandGraph", "Processing explicit versions count: ", $nc.explicitVersions.len()
    for pkgUrl in nc.explicitVersions.keys().toSeq():
      let versions = nc.explicitVersions[pkgUrl]
      info pkgUrl.projectName, "explicit versions: ", versions.toSeq().mapIt($it).join(", ")
      var pkg = nc.packageToDependency[pkgUrl]
      if pkg.state == Processed:
        let prevCount = processedExplicit.getOrDefault(pkgUrl, 0)
        if versions.len > prevCount:
          nc.traverseDependency(pkg, ExplicitVersions, versions.toSeq())
          processedExplicit[pkgUrl] = versions.len
          processing = true

  info "atlas:expand", "Finished expanding packages for:", $root.projectName
  let expandElapsed = getMonoTime() - expandStart
  notice "atlas:expand", "expandGraph took:", $expandElapsed

proc findProjects*(path: Path): seq[Path] =
  result = @[]
  for k, f in walkDir(path):
    if k == pcDir and dirExists(f / Path".git"):
      result.add(f)
