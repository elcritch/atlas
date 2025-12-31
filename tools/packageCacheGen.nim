import std/[os, paths, tables, strutils]

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

const
  PackageArchivesDir = Path"pkg_archives"

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
  let pkgDirRel = outputRoot / Path(sanitizeName(pkg.url.fullName()))
  ensureDir(pkgDirRel)
  let pkgDir = pkgDirRel.absolutePath
  let baseName = sanitizeName(pkg.url.shortName() & "-" & versionSlug(pv.vtag))
  let xzPath = findExe("xz")
  let useXz = xzPath.len > 0
  let finalExt = if useXz: ".tar.xz" else: ".tar.gz"
  let finalPath = pkgDir / Path(baseName & finalExt)
  if fileExists($finalPath):
    trace pkg.url.projectName, "Archive already exists:", $finalPath
    return

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
  nc.traverseDependency(pkg, AllReleases, @[])
  let currentCommit = gitops.currentGitCommit(pkg.ondisk, Warning)
  if not currentCommit.isEmpty():
    writePackageCache(pkg, currentCommit, AllReleases)
  for ver, rel in pkg.versions:
    archiveRelease(pkg, ver, rel, outputRoot)

proc ensureWorkspaceDirs() =
  let depsPath = depsDir()
  if depsPath.string.len > 0:
    ensureDir(depsPath.absolutePath)
  let cachePath = cachesDirectory()
  if cachePath.string.len > 0:
    ensureDir(cachePath.absolutePath)

proc main() =
  ensureWorkspaceDirs()
  context().flags.incl IncludeTagsAndNimbleCommits
  context().flags.incl NimbleCommitsMax
  var nc = createNimbleContext()
  let pkgs = getPackageInfos()
  let archiveRoot = cachesDirectory() / PackageArchivesDir
  ensureDir(archiveRoot)
  for pkgInfo in pkgs:
    if pkgInfo.kind == pkPackage:
      processPackage(nc, pkgInfo, archiveRoot)

when isMainModule:
  main()
