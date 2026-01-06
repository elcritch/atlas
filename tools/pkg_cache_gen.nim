import std/[algorithm, os, paths, tables, strutils, json, osproc, threadpool]

import basic/context
import basic/packageinfos
import basic/nimblecontext
import basic/pkgurls
import basic/reporters
import basic/versions
import basic/gitops
import basic/osutils
import basic/repocache
import dependencies

const ArchiveExcludeDirs = [
  ".git",
  ".github",
  ".gitlab",
  ".circleci",
  ".vscode",
  ".idea",
  ".hg",
  ".svn",
  ".bzr",
  ".darcs"
]

proc sanitizeName(s: string): string =
  const Allowed = Digits + Letters + {'-', '_', '.'}
  for ch in s:
    if ch in Allowed:
      result.add(ch)
    else:
      result.add('_')
  if result.len == 0:
    result = "pkg"

proc versionSlug(tag: VersionTag): string =
  var parts: seq[string]
  var versionPart = tag.v.string
  if versionPart.len > 0 and versionPart != "~":
    if versionPart.startsWith("#"):
      versionPart = versionPart[1..^1]
    parts.add(versionPart)
  var commitPart = tag.c.short()
  if commitPart == "-" or commitPart.len == 0:
    commitPart = tag.c.h
  if commitPart.len > 0:
    parts.add(commitPart)
  if parts.len == 0:
    parts.add("unknown")
  result = sanitizeName(parts.join("-"))

proc ensureDir(path: Path) =
  if path.string.len > 0 and not dirExists(path.string):
    createDir(path.string)

proc sha256File(path: Path): string =
  if not fileExists($path):
    return ""
  let sha256sum = findExe("sha256sum")
  doAssert sha256sum.len() > 0
  let (output, code) = execProcessCapture(sha256sum, @[$path], {poUsePath, poEvalCommand})
  if code.int != 0:
    warn "packageCacheGen", "Unable to hash archive:", $path, "error:", output.strip()
    return ""
  let digest = output.splitWhitespace()
  if digest.len == 0:
    warn "packageCacheGen", "Unable to parse sha256 output for:", $path
    return ""
  result = digest[0]

proc collectArchiveDigests(pkgDir: Path): seq[(string, string)] =
  info "packageCacheGen", "collecting archive digests:", $pkgDir
  if not dirExists(pkgDir.string):
    return
  for kind, path in walkDir(pkgDir.string):
    if kind != pcFile:
      continue
    let pathObj = Path(path)
    let filename = $pathObj.splitPath().tail
    if not (filename.endsWith(".tar.gz") or filename.endsWith(".tar.xz")):
      continue
    let digest = sha256File(pathObj)
    if digest.len == 0:
      warn "packageCacheGen", "Skipping digest for unreadable archive:", $pathObj
      continue
    result.add((filename, digest))
  result.sort(proc(a, b: (string, string)): int = cmpIgnoreCase(a[0], b[0]))

proc loadRepoCacheCopy(nc: var NimbleContext; pkg: Package): JsonNode =
  if pkg.isNil:
    return newJNull()
  let cachePath = repoCacheFile(pkg)
  if cachePath.string.len == 0:
    return newJNull()
  let currentCommit = currentGitCommit(pkg.ondisk, Warning)
  writePackageCache(nc, pkg, currentCommit, AllReleases)
  if not fileExists($cachePath):
    warn pkg.url.projectName, "Repo cache file missing:", $cachePath
    return newJNull()
  try:
    result = parseFile($cachePath)
  except CatchableError as err:
    warn pkg.url.projectName, "Unable to read repo cache:", $cachePath, "error:", err.msg
    result = newJNull()

proc writePackageDigest(pkg: Package; outputRoot: Path) =
  info pkg, "writing package diget"
  let pkgDirRel = outputRoot / Path pkg.url.shortName()
  ensureDir(pkgDirRel)
  let pkgDir = pkgDirRel.absolutePath
  let archives = collectArchiveDigests(pkgDir)
  var digestJson = newJObject()
  var archiveEntries = newJArray()
  for (filename, hash) in archives:
    var entry = newJObject()
    entry["file"] = %filename
    entry["sha256"] = %hash
    archiveEntries.add(entry)
  digestJson["archives"] = archiveEntries
  let digestPath = pkgDir / Path"digest.json"
  try:
    writeFile($digestPath, pretty(digestJson))
    info pkg.url.projectName, "Wrote digest:", $digestPath
  except CatchableError as err:
    warn pkg.url.projectName, "Unable to write digest:", $digestPath, "error:", err.msg

proc writePackageCacheCopy(nc: var NimbleContext; pkg: Package; outputRoot: Path) =
  info pkg, "writing repo cache copy"
  let pkgDirRel = outputRoot / Path pkg.url.shortName()
  ensureDir(pkgDirRel)
  let pkgDir = pkgDirRel.absolutePath
  let repoCache = loadRepoCacheCopy(nc, pkg)
  if repoCache.kind == JNull:
    warn pkg.url.projectName, "Repo cache copy is empty"
  let cachePath = pkgDir / Path"package-cache.json"
  try:
    writeFile($cachePath, pretty(repoCache))
    info pkg.url.projectName, "Wrote package cache copy:", $cachePath
  except CatchableError as err:
    warn pkg.url.projectName, "Unable to write package cache copy:", $cachePath, "error:", err.msg

proc resolvePackageUrl(nc: var NimbleContext; pkgInfo: PackageInfo): PkgUrl =
  let lookup = nc.lookup(pkgInfo.name)
  if not lookup.isEmpty():
    return lookup
  try:
    result = createUrlSkipPatterns(pkgInfo.url, skipDirTest = true)
  except CatchableError as err:
    error "packageCacheGen", "Unable to resolve package URL for:", pkgInfo.name, "error:", err.msg
    result = PkgUrl()

proc archiveExcludePathspecs(): seq[string] =
  for dir in ArchiveExcludeDirs:
    result.add(":(exclude)" & dir)

proc archiveRelease(pkg: Package; pv: PackageVersion; rel: NimbleRelease; outputRoot: Path) =
  if rel.isNil or rel.status != Normal:
    return
  let pkgDirRel = outputRoot / Path pkg.url.shortName()
  ensureDir(pkgDirRel)

  let
    pkgDir = pkgDirRel.absolutePath
    baseName = sanitizeName(pkg.url.shortName() & "-" & versionSlug(pv.vtag))
    xzPath = findExe("xz")
    tarPath = pkgDir / Path(baseName & ".tar.xz")

  if fileExists($tarPath):
    info pkg.url.projectName, "Archive already exists:", $tarPath
    return

  let
    treeSpec = gitops.buildArchiveTreeSpec(pv.vtag.commit, $rel.srcDir)
    pathspecArgs = @[treeSpec, "--", "."] & archiveExcludePathspecs()
    gitPath = findExe("git")
    gitCmd = quoteShellCommand(@[gitPath, "-C", $pkg.ondisk, "archive", "--format=tar"] & pathspecArgs)
    compressCmd = gitCmd & " | " & quoteShell(xzPath) & " -T0 -z -c > " & quoteShell($tarPath)

  doAssert gitPath.len > 0
  if execShellCmd(compressCmd) != 0:
    warn pkg.url.projectName, "Failed to create archive with xz pipe:", $tarPath
    discard tryRemoveFile($tarPath)
  else:
    info pkg.url.projectName, "Created archive:", $tarPath

proc processPackage(nc: var NimbleContext; pkgInfo: PackageInfo; outputRoot: Path) =
  let pkgUrl = resolvePackageUrl(nc, pkgInfo)
  if pkgUrl.isEmpty():
    warn "packageCacheGen", "Skipping package with unresolved URL:", pkgInfo.name
    return
  let wasCloned = block:
    let isFork = isForkUrl(nc, pkgUrl)
    if isFork:
      let officialUrl = nc.lookup(pkgUrl.shortName())
      let canonicalDir =
        if officialUrl.isEmpty(): pkgUrl.toDirectoryPath()
        else: officialUrl.toDirectoryPath()
      let forkDir = pkgUrl.toDirectoryPath()
      isGitDir(canonicalDir) or isGitDir(forkDir)
    else:
      isGitDir(pkgUrl.toDirectoryPath())
  var pkg = Package(
    url: pkgUrl,
    state: NotInitialized,
    isFork: isForkUrl(nc, pkgUrl),
    isOfficial: isOfficialPackage(nc, pkgUrl)
  )
  pkg.errors = @[]
  pkg.versions = initOrderedTable[PackageVersion, NimbleRelease]()
  nc.packageToDependency[pkgUrl] = pkg
  nc.loadDependency(pkg)
  if pkg.state != Found:
    warn pkg.url.projectName, "Unable to load package:", pkg.errors.join("; ")
    return
  if not pkg.isLocalOnly and isGitDir(pkg.ondisk) and not wasCloned:
    gitops.gitPull(pkg.ondisk)
  nc.traverseDependency(pkg, AllReleases, @[])
  for ver, rel in pkg.versions:
    archiveRelease(pkg, ver, rel, outputRoot)
  writePackageDigest(pkg, outputRoot)
  writePackageCacheCopy(nc, pkg, outputRoot)

var
  nc = createNimbleContext()
  pkgs = getPackageInfos()

proc processPackageTask(pkgInfo: PackageInfo; outputRoot: Path) {.thread.} =
  {.gcsafe.}:
    processPackage(nc, pkgInfo, outputRoot)

proc ensureWorkspaceDirs() =
  let depsPath = depsDir()
  if depsPath.string.len > 0:
    ensureDir(depsPath.absolutePath)
  let cachePath = cachesDirectory()
  if cachePath.string.len > 0:
    ensureDir(cachePath.absolutePath)

proc copyPackagesJson(outputRoot: Path) =
  let source = packagesDirectory() / Path"packages.json"
  if not fileExists($source):
    warn "packageCacheGen", "packages.json not found at:", $source
    return
  let dest = outputRoot / Path"packages.json"
  try:
    copyFile($source, $dest)
    info "packageCacheGen", "Copied packages.json to:", $dest
  except CatchableError as err:
    warn "packageCacheGen", "Unable to copy packages.json:", err.msg

proc main() =
  putEnv("GIT_TERMINAL_PROMPT", "0")
  setAtlasVerbosity(Debug)
  ensureWorkspaceDirs()
  context().flags.incl IncludeTagsAndNimbleCommits
  context().flags.incl NimbleCommitsMax
  pkgs.sort(proc(a, b: PackageInfo): int = cmpIgnoreCase(a.name, b.name))
  let archiveRoot = packageArchiveDirectory()
  ensureDir(archiveRoot)
  copyPackagesJson(archiveRoot)
  #setMaxPoolSize(4)
  for pkgInfo in pkgs:
    if pkgInfo.kind == pkPackage:
      spawnX processPackageTask(pkgInfo, archiveRoot)
  sync()

when isMainModule:
  main()
