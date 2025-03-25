#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, strutils, uri, tables, sequtils, sets, hashes, algorithm, paths, dirs]
import basic/[context, deptypes, versions, osutils, nimbleparser, reporters, gitops, pkgurls, nimblecontext, deptypesjson]

export deptypes, versions, deptypesjson

proc collectNimbleVersions*(nc: NimbleContext; pkg: Package): seq[VersionTag] =
  let nimbleFiles = findNimbleFile(pkg)
  let dir = pkg.ondisk
  doAssert(pkg.ondisk.string != "", "Package ondisk must be set before collectNimbleVersions can be called! Package: " & $(pkg))
  result = @[]
  if nimbleFiles.len() == 1:
    result = collectFileCommits(dir, nimbleFiles[0])
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
      for pkgUrl, interval in items(result.requirements):
        # debug pkg.url.projectName, "INTERVAL: ", $interval, "isSpecial:", $interval.isSpecial, "explicit:", $interval.extractSpecificCommit()
        if interval.isSpecial:
          let commit = interval.extractSpecificCommit()
          nc.explicitVersions.mgetOrPut(pkgUrl).incl(VersionTag(v: Version($(interval)), c: commit))

        if pkgUrl notin nc.packageToDependency:
          debug pkg.url.projectName, "Found new pkg:", pkgUrl.projectName, "url:", $pkgUrl.url, "projectName:", $pkgUrl.projectName
          # debug pkg.url.projectName, "Found new pkg:", pkgUrl.projectName, "repr:", $pkgUrl.repr
          let pkgDep = Package(url: pkgUrl, state: NotInitialized)
          nc.packageToDependency[pkgUrl] = pkgDep

proc addRelease(
    versions: var seq[(PackageVersion, NimbleRelease)],
    # pkg: var Package,
    nc: var NimbleContext;
    pkg: Package,
    vtag: VersionTag
): PackageVersion =
  var pkgver = vtag.toPkgVer()
  trace pkg.url.projectName, "Adding Nimble version:", $vtag
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
  result = pkgver

proc traverseDependency*(
    nc: var NimbleContext;
    pkg: var Package,
    mode: TraversalMode;
    explicitVersions: seq[VersionTag];
) =
  doAssert pkg.ondisk.dirExists() and pkg.state != NotInitialized, "Package should've been found or cloned at this point. Package: " & $pkg.url & " on disk: " & $pkg.ondisk

  var versions: seq[(PackageVersion, NimbleRelease)]

  let currentCommit = currentGitCommit(pkg.ondisk, Warning)
  pkg.originHead = gitops.gitFindOriginTip(pkg.ondisk, Warning).commit()

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

  case mode
  of CurrentCommit:
    trace pkg.url.projectName, "traversing dependency for only current commit"
    let vtag = VersionTag(v: Version"#head", c: initCommitHash(currentCommit, FromHead))
    discard versions.addRelease(nc, pkg, vtag)

  of ExplicitVersions:
    debug pkg.url.projectName, "traversing dependency found explicit versions:", $explicitVersions
    # for ver, rel in pkg.versions:
    #   versions.add((ver, rel))

    var uniqueCommits: HashSet[CommitHash]
    for ver in pkg.versions.keys():
      uniqueCommits.incl(ver.vtag.c)

    # get full hash from short hashes
    # TODO: handle shallow clones here?
    var explicitVersions = explicitVersions
    for version in mitems(explicitVersions):
      let vtag = gitops.expandSpecial(pkg.ondisk, version)
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

      ## Note: always prefer tagged versions
      let tags = collectTaggedVersions(pkg.ondisk)
      debug pkg.url.projectName, "nimble tags:", $tags
      for tag in tags:
        if not uniqueCommits.containsOrIncl(tag.c):
          discard versions.addRelease(nc, pkg, tag)
          assert tag.commit.orig == FromGitTag, "maybe this needs to be overriden like before: " & $tag.commit.orig

      if tags.len() == 0 or IncludeTagsAndNimbleCommits in context().flags:
        ## Note: skip nimble commit versions unless explicitly enabled
        ## package maintainers may delete a tag to skip a versions, which we'd override here
        if NimbleCommitsMax in context().flags:
          # reverse the order so the newest commit is preferred for new versions
          nimbleCommits.reverse()

        debug pkg.url.projectName, "nimble commits:", $nimbleCommits
        for tag in nimbleCommits:
          if not uniqueCommits.containsOrIncl(tag.c):
            # trace pkg.url.projectName, "traverseDependency adding nimble commit:", $tag
            var vers: seq[(PackageVersion, NimbleRelease)]
            let pver = vers.addRelease(nc, pkg, tag)
            if not nimbleVersions.containsOrIncl(pver.vtag.v):
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

  # make sure identicle NimbleReleases refer to the same ref
  var uniqueReleases: Table[NimbleRelease, NimbleRelease]
  for (ver, rel) in versions:
    if rel notin uniqueReleases:
      # trace pkg.url.projectName, "found unique release requirements at:", $ver.vtag
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
  
  # TODO: filter by unique versions first?
  pkg.state = Processed

proc loadDependency*(
    nc: NimbleContext,
    pkg: var Package,
    onClone: PackageAction = DoClone,
) = 
  doAssert pkg.ondisk.string == ""
  pkg.ondisk = pkg.url.toDirectoryPath()
  pkg.isAtlasProject = pkg.url.isAtlasProject()
  let todo = if dirExists(pkg.ondisk): DoNothing else: DoClone

  debug pkg.url.projectName, "loading dependency isLinked:", $pkg.isAtlasProject
  debug pkg.url.projectName, "loading dependency todo:", $todo, "ondisk:", $pkg.ondisk
  case todo
  of DoClone:
    if onClone == DoNothing:
      pkg.state = Error
      pkg.errors.add "Not found"
    else:
      let (status, msg) =
        if pkg.url.isFileProtocol:
          copyFromDisk(pkg, pkg.ondisk)
        else:
          gitops.clone(pkg.url.toUri, pkg.ondisk)
      if status == Ok:
        pkg.state = Found
      else:
        pkg.state = Error
        pkg.errors.add $status & ": " & msg
  of DoNothing:
    if pkg.ondisk.dirExists():
      pkg.state = Found
      if UpdateRepos in context().flags:
        gitops.updateRepo(pkg.ondisk)
        
    else:
      pkg.state = Error
      pkg.errors.add "ondisk location missing"

proc expandGraph*(path: Path, nc: var NimbleContext; mode: TraversalMode, onClone: PackageAction, isLinkPath = false): DepGraph =
  ## Expand the graph by adding all dependencies.
  
  doAssert path.string != "."
  let url = nc.createUrlFromPath(path, isLinkPath)
  notice url.projectName, "expanding root package at:", $path, "url:", $url
  var root = Package(url: url, isRoot: true)
  # nc.loadDependency(pkg)

  result = DepGraph(root: root, mode: mode)
  nc.packageToDependency[root.url] = root

  notice "atlas:expand", "Expanding packages for:", $root.projectName

  var processing = true
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
    for pkgUrl in pkgUrls:
      var pkg = nc.packageToDependency[pkgUrl]
      case pkg.state:
      of NotInitialized:
        info pkg.projectName, "Initializing package:", $pkg.url
        nc.loadDependency(pkg, onClone)
        trace pkg.projectName, "expanded pkg:", pkg.repr
        processing = true
      of Found:
        info pkg.projectName, "Processing package at:", pkg.ondisk.relativeToWorkspace()
        # processing = true
        let mode = if pkg.isRoot or pkg.isAtlasProject: CurrentCommit else: mode
        nc.traverseDependency(pkg, mode, @[])
        trace pkg.projectName, "processed pkg:", $pkg
        processing = true
        result.pkgs[pkgUrl] = pkg
      else:
        discard

  for pkgUrl, versions in nc.explicitVersions:
    info pkgUrl.projectName, "explicit versions: ", versions.toSeq().mapIt($it).join(", ")
    var pkg = nc.packageToDependency[pkgUrl]
    if pkg.state == Processed:
      nc.traverseDependency(pkg, ExplicitVersions, versions.toSeq())

  info "atlas:expand", "Finished expanding packages for:", $root.projectName

proc findProjects*(path: Path): seq[Path] =
  result = @[]
  for k, f in walkDir(path):
    if k == pcDir and dirExists(f / Path".git"):
      result.add(f)
