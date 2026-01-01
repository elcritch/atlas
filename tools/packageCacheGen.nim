import std/[algorithm, os, paths, tables, strutils, json, osproc]

import basic/context
import basic/packageinfos
import basic/nimblecontext
import basic/pkgurls
import basic/reporters
import basic/versions
import basic/gitops
import basic/osutils
import dependencies
import basic/repocache

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
  let sha256sumPath = findExe("sha256sum")
  let shasumPath = if sha256sumPath.len == 0: findExe("shasum") else: ""
  if sha256sumPath.len == 0 and shasumPath.len == 0:
    warn "packageCacheGen", "Unable to hash archive: no sha256sum or shasum in PATH:", $path
    return ""
  let cmd =
    if sha256sumPath.len > 0:
      quoteShell(sha256sumPath) & " " & quoteShell($path)
    else:
      quoteShell(shasumPath) & " -a 256 " & quoteShell($path)
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    warn "packageCacheGen", "Unable to hash archive:", $path, "error:", output.strip()
    return ""
  let digest = output.splitWhitespace()
  if digest.len == 0:
    warn "packageCacheGen", "Unable to parse sha256 output for:", $path
    return ""
  result = digest[0]

proc collectArchiveDigests(pkgDir: Path): seq[(string, string)] =
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

proc writePackageDigest(nc: var NimbleContext; pkg: Package; outputRoot: Path) =
  let pkgDirRel = outputRoot / Path pkg.url.shortName()
  ensureDir(pkgDirRel)
  let pkgDir = pkgDirRel.absolutePath
  let archives = collectArchiveDigests(pkgDir)
  let repoCache = loadRepoCacheCopy(nc, pkg)
  var digestJson = newJObject()
  var archiveEntries = newJArray()
  for (filename, hash) in archives:
    var entry = newJObject()
    entry["file"] = %filename
    entry["sha256"] = %hash
    archiveEntries.add(entry)
  digestJson["archives"] = archiveEntries
  digestJson["repoCache"] = repoCache
  let digestPath = pkgDir / Path"digest.json"
  try:
    writeFile($digestPath, pretty(digestJson))
    info pkg.url.projectName, "Wrote digest:", $digestPath
  except CatchableError as err:
    warn pkg.url.projectName, "Unable to write digest:", $digestPath, "error:", err.msg

proc resolvePackageUrl(nc: var NimbleContext; pkgInfo: PackageInfo): PkgUrl =
  let lookup = nc.lookup(pkgInfo.name)
  if not lookup.isEmpty():
    return lookup
  try:
    result = createUrlSkipPatterns(pkgInfo.url, skipDirTest = true)
  except CatchableError as err:
    error "packageCacheGen", "Unable to resolve package URL for:", pkgInfo.name, "error:", err.msg
    result = PkgUrl()

proc archiveRelease(pkg: Package; pv: PackageVersion; rel: NimbleRelease; outputRoot: Path) =
  if rel.isNil or rel.status != Normal:
    return
  let commit = pv.vtag.commit
  if commit.isEmpty():
    warn pkg.url.projectName, "Skipping release without commit:", repr(pv.vtag)
    return
  let pkgDirRel = outputRoot / Path pkg.url.shortName()
  ensureDir(pkgDirRel)
  let pkgDir = pkgDirRel.absolutePath
  let baseName = sanitizeName(pkg.url.shortName() & "-" & versionSlug(pv.vtag))
  let xzPath = findExe("xz")
  let useXz = xzPath.len > 0
  let tarXzPath = pkgDir / Path(baseName & ".tar.xz")
  let tarGzPath = pkgDir / Path(baseName & ".tar.gz")
  let existingPath =
    if fileExists($tarXzPath): $tarXzPath
    elif fileExists($tarGzPath): $tarGzPath
    else: ""
  if existingPath.len > 0:
    trace pkg.url.projectName, "Archive already exists:", existingPath
    return
  let finalPath = if useXz: tarXzPath else: tarGzPath

  let tempTar = pkgDir / Path(baseName & ".tar")
  var args: seq[string]
  let treeSpec = gitops.buildArchiveTreeSpec(commit, $rel.srcDir)
  if useXz:
    args = @["--format=tar", "--output=" & $tempTar, treeSpec]
  else:
    args = @["--format=tar.gz", "--output=" & $finalPath, treeSpec]

  let (_, status) = gitops.exec(GitArchive, pkg.ondisk, args, Warning)
  if status != RES_OK:
    warn pkg.url.projectName, "Failed to create archive:", $finalPath
    if useXz and fileExists($tempTar):
      discard tryRemoveFile($tempTar)
    return

  if useXz:
    let compressCmd = quoteShell(xzPath) & " -T0 -z -f " & quoteShell($tempTar)
    let res = execShellCmd(compressCmd)
    if res != 0:
      warn pkg.url.projectName, "Failed to compress archive with xz:", $tempTar
      if fileExists($tempTar & ".xz"):
        discard tryRemoveFile($tempTar & ".xz")
      return
    let compressed = $tempTar & ".xz"
    moveFile(compressed, $finalPath)
  info pkg.url.projectName, "Created archive:", $finalPath

proc processPackage(nc: var NimbleContext; pkgInfo: PackageInfo; outputRoot: Path) =
  let pkgUrl = resolvePackageUrl(nc, pkgInfo)
  if pkgUrl.isEmpty():
    warn "packageCacheGen", "Skipping package with unresolved URL:", pkgInfo.name
    return
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
  if not pkg.isLocalOnly and isGitDir(pkg.ondisk):
    gitops.gitPull(pkg.ondisk)
  nc.traverseDependency(pkg, AllReleases, @[])
  for ver, rel in pkg.versions:
    archiveRelease(pkg, ver, rel, outputRoot)
  writePackageDigest(nc, pkg, outputRoot)

proc ensureWorkspaceDirs() =
  let depsPath = depsDir()
  if depsPath.string.len > 0:
    ensureDir(depsPath.absolutePath)
  let cachePath = cachesDirectory()
  if cachePath.string.len > 0:
    ensureDir(cachePath.absolutePath)

proc main() =
  putEnv("GIT_TERMINAL_PROMPT", "0")
  setAtlasVerbosity(Info)
  ensureWorkspaceDirs()
  context().flags.incl IncludeTagsAndNimbleCommits
  context().flags.incl NimbleCommitsMax
  var nc = createNimbleContext()
  var pkgs = getPackageInfos()
  pkgs.sort(proc(a, b: PackageInfo): int = cmpIgnoreCase(a.name, b.name))
  let archiveRoot = packageArchiveDirectory()
  ensureDir(archiveRoot)
  for pkgInfo in pkgs:
    if pkgInfo.kind == pkPackage:
      processPackage(nc, pkgInfo, archiveRoot)

when isMainModule:
  main()
