import std/[os, strutils, json, jsonutils, tables, sequtils, sets, paths, algorithm]
import context, deptypes, versions, nimblecontext, nimbleparser, reporters, pkgurls

proc isForkUrl*(nc: NimbleContext; url: PkgUrl): bool =
  let officialUrl = nc.lookup(url.shortName())
  let isGitUrl = url.url.scheme notin ["file", "link", "atlas"]
  result =
    isGitUrl and
    not officialUrl.isEmpty() and
    officialUrl.url.scheme notin ["file", "link", "atlas"] and
    officialUrl.url != url.url

proc isOfficialPackage*(nc: NimbleContext; url: PkgUrl): bool =
  if url.url.scheme in ["file", "link", "atlas"]:
    return false
  let shortName = url.shortName()
  if shortName.len == 0:
    return false
  let officialUrl = nc.lookup(shortName)
  result = not officialUrl.isEmpty()

const
  RepoCacheDirName* = Path".caches"
  RepoCacheFormatVersion* = 1

type
  RepoCacheCommit* = object
    hash*: string
    origin*: string
    isEmpty*: bool

  RepoCacheRequirement* = object
    name*: string
    shortName*: string
    url*: string
    version*: string

  RepoCacheNimbleFile* = object
    path*: string
    name*: string
    relative*: string

  RepoCacheRepoInfo* = object
    name*: string
    shortName*: string
    fullName*: string
    requiresName*: string
    url*: string
    scheme*: string
    state*: string
    isRoot*: bool
    isFork*: bool
    isOfficial*: bool
    isAtlasProject*: bool
    isLocalOnly*: bool
    isActive*: bool
    isFileProtocol*: bool
    module*: string
    activeVersion*: string
    ondisk*: string
    relativePath*: string
    primaryNimble*: string
    errors*: seq[string]

  RepoCacheGitInfo* = object
    mode*: string
    current*: RepoCacheCommit
    originHead*: RepoCacheCommit
    remote*: string
    isLocalOnly*: bool

  RepoCacheVersion* = object
    version*: string
    versionTag*: string
    isTip*: bool
    commit*: RepoCacheCommit
    status*: string
    hasInstallHooks*: bool
    releaseVersion*: string
    nimVersion*: string
    srcDir*: string
    error*: string
    requirements*: seq[RepoCacheRequirement]
    features*: Table[string, seq[RepoCacheRequirement]]
    featureFlags*: Table[string, seq[string]]

  RepoCacheFile* = object
    cacheVersion*: int
    repo*: RepoCacheRepoInfo
    nimbleFiles*: seq[RepoCacheNimbleFile]
    git*: RepoCacheGitInfo
    versions*: seq[RepoCacheVersion]
    packageErrors*: seq[string]

proc sanitizeCacheFileName(name: string): string =
  const InvalidChars = {'/', '\\', ':', '*', '?', '"', '<', '>', '|'}
  result = ""
  for ch in name:
    if ch in InvalidChars:
      result.add('_')
    else:
      result.add(ch)
  if result.len == 0:
    result = "package"

proc repoCacheDir*(): Path =
  let depsPath = depsDir()
  if depsPath.string.len == 0:
    warn "atlas:cache", "Skipping repo cache creation because deps dir is not configured"
    return Path""
  if not dirExists(depsPath.string):
    try:
      createDir(depsPath.string)
    except CatchableError as err:
      warn "atlas:cache", "Unable to create deps dir at:", $depsPath, "error:", err.msg
      return Path""
  let cacheDir = depsPath / RepoCacheDirName
  if not dirExists(cacheDir.string):
    try:
      createDir(cacheDir.string)
    except CatchableError as err:
      warn "atlas:cache", "Unable to create repo cache dir:", $cacheDir, "error:", err.msg
      return Path""
  result = cacheDir

proc repoCacheFile*(pkg: Package): Path =
  let cacheDir = repoCacheDir()
  if cacheDir.string.len == 0:
    return Path""
  var base = pkg.url.fullName()
  if base.len == 0:
    base = pkg.projectName
  if base.len == 0:
    base = pkg.url.shortName()
  base = sanitizeCacheFileName(base)
  result = cacheDir / Path(base & ".json")

proc commitInfo(commit: CommitHash): RepoCacheCommit =
  RepoCacheCommit(
    hash: commit.h,
    #short: commit.short(),
    origin: $commit.orig,
    isEmpty: commit.isEmpty()
  )

proc encodeRequirement(url: PkgUrl; interval: VersionInterval): RepoCacheRequirement =
  RepoCacheRequirement(
    name: url.projectName(),
    shortName: url.shortName(),
    url: $url,
    version: $interval
  )

proc encodeRequirements(reqs: seq[(PkgUrl, VersionInterval)]): seq[RepoCacheRequirement] =
  for dep in reqs:
    let (depUrl, interval) = dep
    result.add encodeRequirement(depUrl, interval)

proc encodeFeatures(features: Table[string, seq[(PkgUrl, VersionInterval)]]): Table[string, seq[RepoCacheRequirement]] =
  for feature, reqs in features:
    result[feature] = encodeRequirements(reqs)

proc encodeFeatureFlags(reqs: Table[PkgUrl, HashSet[string]]): Table[string, seq[string]] =
  for depUrl, flags in reqs:
    var sortedFlags = flags.toSeq()
    sortedFlags.sort()
    result[$depUrl] = sortedFlags

proc nimbleFileEntries(nimbleFiles: seq[Path]; baseDir: Path): seq[RepoCacheNimbleFile] =
  for nimble in nimbleFiles:
    var entry = RepoCacheNimbleFile(
      path: $nimble,
      name: $nimble.splitPath().tail
    )
    if baseDir.string.len > 0:
      try:
        entry.relative = $nimble.relativePath(baseDir)
      except CatchableError:
        discard
    result.add entry

proc repoInfo(pkg: Package; nimbleFiles: seq[Path]): RepoCacheRepoInfo =
  result = RepoCacheRepoInfo(
    name: pkg.projectName,
    shortName: pkg.url.shortName(),
    fullName: pkg.url.fullName(),
    requiresName: pkg.url.requiresName(),
    url: $pkg.url,
    scheme: pkg.url.url.scheme,
    state: $pkg.state,
    isRoot: pkg.isRoot,
    isFork: pkg.isFork,
    isOfficial: pkg.isOfficial,
    isAtlasProject: pkg.isAtlasProject,
    isLocalOnly: pkg.isLocalOnly,
    isActive: pkg.active,
    isFileProtocol: pkg.url.isFileProtocol(),
    errors: pkg.errors
  )
  if pkg.module.len > 0:
    result.module = pkg.module
  if not pkg.activeVersion.isNil:
    result.activeVersion = repr(pkg.activeVersion.vtag)
  if pkg.ondisk.string.len > 0:
    result.ondisk = $pkg.ondisk
    result.relativePath = relativeToWorkspace(pkg.ondisk)
  if nimbleFiles.len > 0:
    result.primaryNimble = $nimbleFiles[0].splitPath().tail

proc buildVersionEntry(vtag: VersionTag; release: NimbleRelease): RepoCacheVersion =
  var entry = RepoCacheVersion(
    version: $vtag.v,
    versionTag: repr(vtag),
    isTip: vtag.isTip,
    commit: commitInfo(vtag.commit()),
    status: $release.status,
    hasInstallHooks: release.hasInstallHooks,
    requirements: encodeRequirements(release.requirements),
    features: encodeFeatures(release.features),
    featureFlags: encodeFeatureFlags(release.reqsByFeatures)
  )
  if release.version.string.len > 0:
    entry.releaseVersion = $release.version
  if release.nimVersion.string.len > 0:
    entry.nimVersion = $release.nimVersion
  if release.srcDir != Path"":
    entry.srcDir = $release.srcDir
  if release.err.len > 0:
    entry.error = release.err
  result = entry

proc versionEntries(pkg: Package): seq[RepoCacheVersion] =
  for pkgVer, release in pkg.versions:
    if pkgVer.isNil or release.isNil:
      continue
    result.add buildVersionEntry(pkgVer.vtag, release)

proc hasHeadVersion(pkg: Package): bool =
  for pkgVer in pkg.versions.keys():
    if pkgVer.vtag.v.isHead:
      return true
  result = false

proc headRelease(nc: var NimbleContext; nimbleFiles: seq[Path]): NimbleRelease =
  if nimbleFiles.len == 1:
    try:
      result = nc.parseNimbleFile(nimbleFiles[0])
    except CatchableError as err:
      result = NimbleRelease(status: HasBrokenNimbleFile, err: err.msg)
  elif nimbleFiles.len == 0:
    result = NimbleRelease(status: HasUnknownNimbleFile, err: "missing nimble file")
  else:
    result = NimbleRelease(status: HasUnknownNimbleFile, err: "ambiguous nimble file")
  if result.version.string.len == 0:
    result.version = Version"#head"

proc gitInfo(pkg: Package; currentCommit: CommitHash; mode: TraversalMode): RepoCacheGitInfo =
  RepoCacheGitInfo(
    mode: $mode,
    current: commitInfo(currentCommit),
    originHead: commitInfo(pkg.originHead),
    remote: $pkg.url,
    isLocalOnly: pkg.isLocalOnly
  )

proc buildRepoCache(nc: var NimbleContext; pkg: Package; nimbleFiles: seq[Path];
                    currentCommit: CommitHash; mode: TraversalMode): RepoCacheFile =
  var versions = versionEntries(pkg)
  if not hasHeadVersion(pkg):
    let headTag = VersionTag(
      v: Version"#head",
      c: initCommitHash(currentCommit, FromHead),
      isTip: true
    )
    versions.add buildVersionEntry(headTag, headRelease(nc, nimbleFiles))
  var cache = RepoCacheFile(
    cacheVersion: RepoCacheFormatVersion,
    repo: repoInfo(pkg, nimbleFiles),
    nimbleFiles: nimbleFileEntries(nimbleFiles, pkg.ondisk),
    git: gitInfo(pkg, currentCommit, mode),
    versions: versions,
    packageErrors: pkg.errors
  )
  result = cache

proc loadRepoCache*(jsonNode: JsonNode): RepoCacheFile =
  result = jsonTo(jsonNode, RepoCacheFile,
    Joptions(allowExtraKeys: true, allowMissingKeys: true))

proc loadRepoCache*(filename: Path): RepoCacheFile =
  let jsonNode = parseFile($filename)
  result = loadRepoCache(jsonNode)

proc pruneRepoCacheJson(node: JsonNode) =
  ## Remove optional repo cache fields when they are empty to keep cache output compact.
  if node.isNil:
    return
  case node.kind
  of JObject:
    var keysToDelete: seq[string]
    for key, child in pairs(node):
      pruneRepoCacheJson(child)
      case key
      of "module", "activeVersion", "ondisk", "relativePath",
         "primaryNimble", "relative", "releaseVersion", "nimVersion",
         "srcDir", "error":
        if child.kind == JString and child.str.len == 0:
          keysToDelete.add key
      of "features", "featureFlags":
        if child.kind == JObject and child.len == 0:
          keysToDelete.add key
      of "hasInstallHooks", "isTip", "isEmpty":
        if child.kind == JBool and not child.bVal:
          keysToDelete.add key
      else:
        discard
    for key in keysToDelete:
      node.delete(key)
  of JArray:
    for child in items(node):
      pruneRepoCacheJson(child)
  else:
    discard

proc writePackageCache*(nc: var NimbleContext; pkg: Package;
                        currentCommit: CommitHash; mode: TraversalMode) =
  if pkg.isNil:
    return
  let cachePath = repoCacheFile(pkg)
  if cachePath.string.len == 0:
    return
  var nimbleFiles: seq[Path] = @[]
  try:
    nimbleFiles = findNimbleFile(pkg)
  except CatchableError as err:
    warn pkg.projectName, "Unable to locate nimble files for cache:", err.msg
  let cache = buildRepoCache(nc, pkg, nimbleFiles, currentCommit, mode)
  try:
    let jsonCache = toJson(cache, ToJsonOptions(enumMode: joptEnumString))
    pruneRepoCacheJson(jsonCache)
    writeFile($cachePath, pretty(jsonCache))
    trace pkg.projectName, "Wrote repo cache:", $cachePath
  except CatchableError as err:
    warn pkg.projectName, "Unable to write repo cache:", $cachePath, "error:", err.msg

proc registerReleaseDependencies*(
    nc: var NimbleContext;
    pkg: Package;
    release: NimbleRelease
) =
  if release.isNil or release.status != Normal:
    return

  for req in release.requirements:
    let (reqUrl, reqInterval) = req
    if reqInterval.isSpecial:
      let commit = reqInterval.extractSpecificCommit()
      nc.explicitVersions.mgetOrPut(reqUrl, initHashSet[VersionTag]()).incl(
        VersionTag(v: Version($(reqInterval)), c: commit)
      )

    if reqUrl notin nc.packageToDependency:
      let pkgDep = Package(
        url: reqUrl,
        state: NotInitialized,
        isFork: isForkUrl(nc, reqUrl),
        isOfficial: isOfficialPackage(nc, reqUrl)
      )
      nc.packageToDependency[reqUrl] = pkgDep
    elif nc.packageToDependency[reqUrl].state == LazyDeferred:
      warn pkg.url.projectName, "Changing LazyDeferred pkg to DoLoad:", $reqUrl.url
      nc.packageToDependency[reqUrl].state = DoLoad

  for feature, rq in release.features:
    for dep in items(rq):
      let (featureUrl, featureInterval) = dep
      if featureInterval.isSpecial:
        let commit = featureInterval.extractSpecificCommit()
        nc.explicitVersions.mgetOrPut(featureUrl, initHashSet[VersionTag]()).incl(
          VersionTag(v: Version($(featureInterval)), c: commit)
        )
      if featureUrl notin nc.packageToDependency:
        let state = if feature notin context().features: LazyDeferred else: NotInitialized
        let pkgDep = Package(
          url: featureUrl,
          state: state,
          isFork: isForkUrl(nc, featureUrl),
          isOfficial: isOfficialPackage(nc, featureUrl)
        )
        nc.packageToDependency[featureUrl] = pkgDep
        debug pkg.url.projectName, "Found new feature pkg:", featureUrl.projectName,
          "url:", $featureUrl.url, "projectName:", $featureUrl.projectName, "state:", $state
      elif nc.packageToDependency[featureUrl].state == LazyDeferred and feature in context().features:
        warn pkg.url.projectName, "Changing LazyDeferred pkg to DoLoad:", $featureUrl.url
        nc.packageToDependency[featureUrl].state = DoLoad

proc parseCommitOrigin(origin: string): CommitOrigin =
  try:
    result = parseEnum[CommitOrigin](origin)
  except ValueError:
    result = FromNone

proc decodeCommit(info: RepoCacheCommit): CommitHash =
  if info.hash.len == 0 or info.isEmpty:
    result = initCommitHash("", parseCommitOrigin(info.origin))
  else:
    result = initCommitHash(info.hash, parseCommitOrigin(info.origin))

proc commitsMatch(expected, cached: CommitHash): bool =
  result = not expected.isEmpty() and not cached.isEmpty() and expected == cached

proc decodeCachedVersionTag(entry: RepoCacheVersion): VersionTag =
  var tagStr = entry.versionTag
  if tagStr.len == 0 and entry.version.len > 0 and entry.commit.hash.len > 0:
    tagStr = entry.version & "@" & entry.commit.hash
  var isTip = entry.isTip
  if tagStr.len > 0 and tagStr[^1] == '^':
    tagStr.setLen(tagStr.len - 1)
    isTip = true
  var tag: VersionTag
  if tagStr.len > 0:
    tag.fromJson(%tagStr)
  else:
    tag = VersionTag(v: Version"", c: initCommitHash("", FromNone))
  let commit = decodeCommit(entry.commit)
  if not commit.isEmpty():
    tag.c = commit
  tag.isTip = isTip
  result = tag

proc decodeRequirement(nc: NimbleContext; req: RepoCacheRequirement): (PkgUrl, VersionInterval) =
  var pkgUrl: PkgUrl
  pkgUrl.fromJson(%req.url)
  pkgUrl = nc.normalizePkgUrl(pkgUrl)
  var interval: VersionInterval
  interval.fromJson(%req.version)
  result = (pkgUrl, interval)

proc decodeRequirements(nc: NimbleContext; reqs: seq[RepoCacheRequirement]): seq[(PkgUrl, VersionInterval)] =
  for req in reqs:
    result.add decodeRequirement(nc, req)

proc decodeFeatures(nc: NimbleContext; reqs: Table[string, seq[RepoCacheRequirement]]): Table[string, seq[(PkgUrl, VersionInterval)]] =
  for feature, deps in reqs:
    result[feature] = decodeRequirements(nc, deps)

proc decodeFeatureFlags(nc: NimbleContext; flags: Table[string, seq[string]]): Table[PkgUrl, HashSet[string]] =
  for depUrl, featureList in flags:
    var pkgUrl: PkgUrl
    pkgUrl.fromJson(%depUrl)
    pkgUrl = nc.normalizePkgUrl(pkgUrl)
    var featureSet = initHashSet[string]()
    for flag in featureList:
      featureSet.incl(flag)
    result[pkgUrl] = featureSet

proc decodeRelease(nc: NimbleContext; entry: RepoCacheVersion): NimbleRelease =
  new(result)
  result.requirements = decodeRequirements(nc, entry.requirements)
  result.features = decodeFeatures(nc, entry.features)
  result.reqsByFeatures = decodeFeatureFlags(nc, entry.featureFlags)
  result.hasInstallHooks = entry.hasInstallHooks
  if entry.status.len > 0:
    result.status.fromJson(%entry.status)
  else:
    result.status = Normal
  if entry.releaseVersion.len > 0:
    result.version.fromJson(%entry.releaseVersion)
  elif entry.version.len > 0:
    result.version.fromJson(%entry.version)
  if entry.nimVersion.len > 0:
    result.nimVersion.fromJson(%entry.nimVersion)
  if entry.srcDir.len > 0:
    result.srcDir.fromJson(%entry.srcDir)
  if entry.error.len > 0:
    result.err = entry.error

proc loadVersionsFromCache*(
    nc: var NimbleContext;
    pkg: var Package;
    currentCommit: CommitHash;
    mode: TraversalMode
): bool =
  if mode != AllReleases:
    return false
  let cachePath = repoCacheFile(pkg)
  if cachePath.string.len == 0 or not fileExists($cachePath):
    return false
  var cache: RepoCacheFile
  try:
    cache = loadRepoCache(cachePath)
  except CatchableError as err:
    warn pkg.url.projectName, "Unable to load repo cache:", $cachePath, "error:", err.msg
    return false
  if cache.git.mode != $mode:
    trace pkg.url.projectName, "Repo cache mode mismatch:", cache.git.mode, "!=", $mode
    return false
  let cachedOrigin = decodeCommit(cache.git.originHead)
  let cachedCurrent = decodeCommit(cache.git.current)
  if not commitsMatch(pkg.originHead, cachedOrigin):
    trace pkg.url.projectName, "Repo cache origin mismatch for:", $pkg.url
    return false
  if not commitsMatch(currentCommit, cachedCurrent):
    trace pkg.url.projectName, "Repo cache current commit mismatch for:", $pkg.url
    return false
  pkg.versions.clear()
  for entry in cache.versions:
    let pkgVer = decodeCachedVersionTag(entry).toPkgVer()
    let release = decodeRelease(nc, entry)
    pkg.versions[pkgVer] = release
    registerReleaseDependencies(nc, pkg, release)
  if pkg.versions.len == 0:
    warn pkg.url.projectName, "Repo cache is missing version history for:", $pkg.url
    return false
  if cache.packageErrors.len > 0:
    pkg.errors = cache.packageErrors
  info pkg.url.projectName, "Loaded", $pkg.versions.len, "releases from cache"
  result = true
