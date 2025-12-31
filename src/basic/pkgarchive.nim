#
#           Atlas Package Cloner
#        (c) Copyright 2024 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [httpclient, json, os, paths, strutils, uri, times]
import context, deptypes, versions, reporters, pkgurls, osutils
import libcurl

const
  DefaultPkgArchiveBaseUrl* = "http://localhost:6767"
  PackagesIndexFileName* = "packages.json"
  PackagesIndexXzFileName* = "packages.json.xz"
  PackageCacheFileName* = "package-cache.json"
  PackageDigestFileName* = "digest.json"

  PackageArchiveDir = Path"pkg_archive"

var
  pkgArchiveBaseUrlValue = parseUri(DefaultPkgArchiveBaseUrl)
  curlHandle: PCurl
  curlInitialized = false

proc ensureCurlHandle(): PCurl =
  if not curlInitialized:
    let status = global_init(GLOBAL_DEFAULT)
    if status != E_OK:
      warn "atlas:pkgarchive", "libcurl init failed:", $easy_strerror(status)
      return nil
    curlInitialized = true
  if curlHandle.isNil:
    curlHandle = easy_init()
    if curlHandle.isNil:
      warn "atlas:pkgarchive", "libcurl handle init failed"
  result = curlHandle

proc normalizeBaseUrl(url: string): string =
  result = url.strip()
  if result.len == 0:
    result = DefaultPkgArchiveBaseUrl
  elif "://" notin result:
    result = "http://" & result

proc pkgArchiveBaseUrl*(): Uri =
  pkgArchiveBaseUrlValue

proc setPkgArchiveBaseUrl*(url: Uri) =
  pkgArchiveBaseUrlValue = url

proc setPkgArchiveBaseUrl*(url: string) =
  pkgArchiveBaseUrlValue = parseUri(normalizeBaseUrl(url))


proc packageArchiveLocalDir*(pkg: PkgUrl; root: Path): Path =
  root / Path(pkg.shortName())

proc packageArchiveUrl*(pkg: PkgUrl; filename: string; baseUrl: Uri): Uri =
  baseUrl / pkg.shortName() / filename

proc packagesIndexUrl(baseUrl: Uri): Uri =
  baseUrl / PackagesIndexFileName

proc packagesIndexXzUrl(baseUrl: Uri): Uri =
  baseUrl / PackagesIndexXzFileName

proc archiveDirectory(): Path =
  project() / PackageArchiveDir

proc ensureArchiveDir(path: Path) =
  if path.string.len == 0:
    return
  if not dirExists(path.string):
    createDir(path.string)

proc downloadFileCurl(url: string; dest: Path; force: bool): bool =
  if not force and fileExists($dest):
    info "atlas:downloadFile", "downloaded already:", $dest, "url:", $url
    return true
  let curl = ensureCurlHandle()
  if curl.isNil:
    return false

  type CurlWriteData = ref object
    file: File

  proc onWrite(data: cstring, size: int, nitems: int, userData: pointer): int {.cdecl.} =
    let writeData = cast[CurlWriteData](userData)
    let len = size * nitems
    if len <= 0:
      return 0
    result = writeData.file.writeBuffer(cast[pointer](data), len)

  let writeData = CurlWriteData(file: open($dest, fmWrite))
  try:
    let parsedUrl = parseUri(url)
    discard curl.easy_setopt(OPT_URL, url)
    if parsedUrl.port.len > 0:
      try:
        info "atlas:downloadFile", "PORT:", parsedUrl.port
        discard curl.easy_setopt(OPT_PORT, parseInt(parsedUrl.port))
      except ValueError:
        discard
    discard curl.easy_setopt(OPT_FOLLOWLOCATION, 1)
    discard curl.easy_setopt(OPT_FAILONERROR, 1)
    discard curl.easy_setopt(OPT_HTTP_VERSION, libcurl.HTTP_VERSION(3))
    discard curl.easy_setopt(OPT_FRESH_CONNECT, 0)
    discard curl.easy_setopt(OPT_FORBID_REUSE, 0)
    discard curl.easy_setopt(OPT_WRITEFUNCTION, onWrite)
    discard curl.easy_setopt(OPT_WRITEDATA, writeData)

    info "atlas:downloadFile", "downloading:", $url, "to:", $dest
    let status = curl.easy_perform()
    if status == E_OK:
      result = true
    else:
      warn "atlas:pkgarchive", "libcurl download failed:", url, "error:",
        $easy_strerror(status)
  except CatchableError as err:
    warn "atlas:pkgarchive", "download failed:", url, "error:", err.msg
  finally:
    writeData.file.close()

proc downloadFileHttp(url: string; dest: Path; force: bool): bool =
  if not force and fileExists($dest):
    info "atlas:downloadFile", "downloaded already:", $dest, "url:", $url
    return true
  var client = newHttpClient()
  try:
    info "atlas:downloadFile", "downloading:", $url, "to:", $dest
    client.downloadFile(url, $dest)
    result = true
  except CatchableError as err:
    warn "atlas:pkgarchive", "download failed:", url, "error:", err.msg
  finally:
    client.close()

proc downloadFile(url: string; dest: Path; force: bool): bool =
  if UseCurlDownloads in context().flags:
    return downloadFileCurl(url, dest, force)
  downloadFileHttp(url, dest, force)

proc downloadPackageFile*(pkg: PkgUrl; filename: string; baseUrl: Uri;
                          destRoot: Path; force = false): bool =
  let pkgDir = packageArchiveLocalDir(pkg, destRoot)
  ensureArchiveDir(pkgDir)
  let url = packageArchiveUrl(pkg, filename, baseUrl)
  let dest = pkgDir / Path(filename)
  result = downloadFile($url, dest, force)

proc downloadPackageFile*(pkg: PkgUrl; filename: string; force = false): bool =
  downloadPackageFile(pkg, filename, pkgArchiveBaseUrlValue, archiveDirectory(), force)

proc downloadPackagesIndex*(destDir: Path; baseUrl: Uri; force = false): bool =
  if destDir.string.len == 0:
    return false
  ensureArchiveDir(destDir)
  let dest = destDir / Path(PackagesIndexFileName)
  let url = packagesIndexUrl(baseUrl)
  info "atlas:downloadPackagesIndex", "downloading packages.json from:", $url
  result = downloadFile($url, dest, force)

proc downloadPackagesIndex*(destDir: Path; force = false): bool =
  downloadPackagesIndex(destDir, pkgArchiveBaseUrlValue, force)

proc downloadPackagesIndexXz*(destDir: Path; baseUrl: Uri; force = false): bool =
  if destDir.string.len == 0:
    return false
  ensureArchiveDir(destDir)
  let dest = destDir / Path(PackagesIndexXzFileName)
  let url = packagesIndexXzUrl(baseUrl)
  info "atlas:downloadPackagesIndex", "downloading packages.json.xz from:", $url
  result = downloadFile($url, dest, force)

proc downloadPackagesIndexXz*(destDir: Path; force = false): bool =
  downloadPackagesIndexXz(destDir, pkgArchiveBaseUrlValue, force)

proc downloadPackageRepoCache*(pkg: PkgUrl; baseUrl: Uri; destRoot: Path;
                               force = false): bool =
  downloadPackageFile(pkg, PackageCacheFileName, baseUrl, destRoot, force)

proc downloadPackageRepoCache*(pkg: PkgUrl; force = false): bool =
  downloadPackageFile(pkg, PackageCacheFileName, pkgArchiveBaseUrlValue,
                      archiveDirectory(), force)

proc downloadPackageDigest*(pkg: PkgUrl; baseUrl: Uri; destRoot: Path;
                            force = false): bool =
  downloadPackageFile(pkg, PackageDigestFileName, baseUrl, destRoot, force)

proc downloadPackageDigest*(pkg: PkgUrl; force = false): bool =
  downloadPackageFile(pkg, PackageDigestFileName, pkgArchiveBaseUrlValue,
                      archiveDirectory(), force)

proc readArchiveDigest*(path: Path): seq[string] =
  if not fileExists($path):
    return
  try:
    let root = parseFile($path)
    if root.kind != JObject or not root.hasKey("archives"):
      return
    for entry in root["archives"]:
      if entry.kind != JObject or not entry.hasKey("file"):
        continue
      let filename = entry["file"].getStr("")
      if filename.len > 0:
        result.add(filename)
  except CatchableError as err:
    warn "atlas:pkgarchive", "Unable to read digest:", $path, "error:", err.msg

proc selectArchiveForRelease(pkg: Package; archives: seq[string]): string

proc downloadPackageArchives*(pkg: Package; baseUrl: Uri; destRoot: Path;
                              force = false): bool =
  result = true
  let pkgDir = packageArchiveLocalDir(pkg.url, destRoot)
  ensureArchiveDir(pkgDir)
  let digestPath = pkgDir / Path PackageDigestFileName
  if force or not fileExists($digestPath):
    if not downloadPackageDigest(pkg.url, baseUrl, destRoot, force):
      return false
  let archives = readArchiveDigest(digestPath)
  if archives.len == 0:
    warn "atlas:pkgarchive", "No archives listed in digest:", $digestPath
    return false
  let archiveName = selectArchiveForRelease(pkg, archives)
  if archiveName.len == 0:
    warn "atlas:pkgarchive", "No archive found for package release"
    return false
  info "atlas:pkgarchive", "archive selected:", archiveName
  let url = packageArchiveUrl(pkg.url, archiveName, baseUrl)
  let dest = pkgDir / Path(archiveName)
  if not downloadFile($url, dest, force):
    result = false

proc downloadPackageArchives*(pkg: Package; force = false): bool =
  downloadPackageArchives(pkg, pkgArchiveBaseUrlValue, archiveDirectory(), force)

proc stripArchiveSuffix(filename: string): string =
  const suffixes = [".tar.gz", ".tgz", ".tar.bz2", ".tar.xz", ".tar"]
  for suffix in suffixes:
    if filename.endsWith(suffix):
      return filename[0 ..< filename.len - suffix.len]
  result = filename

proc selectArchiveForRelease(pkg: Package; archives: seq[string]): string =
  if archives.len == 0:
    return ""
  if archives.len == 1:
    return archives[0]
  var version = ""
  let release = pkg.activeNimbleRelease()
  if not release.isNil and release.version.string.len > 0 and not release.version.isHead:
    version = release.version.string
  if version.len == 0 and not pkg.activeVersion.isNil:
    let vtag = pkg.activeVersion.vtag.v
    if not vtag.isHead:
      version = vtag.string
  if version.len > 0:
    for name in archives:
      if version in name:
        return name
  result = ""

proc extractArchive(archivePath, destDir: Path): bool =
  let depsPath = depsDir()
  if depsPath.string.len == 0:
    return false
  let tempDir = depsPath / Path(".atlas_extract_" & $getCurrentProcessId() & "_" & $getTime().toUnix())
  try:
    createDir(tempDir.string)
    let status = execProcessStream("tar", @["-xf", $archivePath, "-C", $tempDir])
    if status != RES_OK:
      warn "atlas:pkgarchive", "unable to extract archive:", $archivePath
      return false
    var entries: seq[(PathComponent, Path)] = @[]
    for kind, path in walkDir(tempDir.string):
      if kind in {pcDir, pcFile, pcLinkToDir, pcLinkToFile}:
        entries.add((kind, Path(path)))
    if entries.len == 1 and entries[0][0] == pcDir:
      moveDir(entries[0][1].string, destDir.string)
    else:
      if not dirExists(destDir.string):
        createDir(destDir.string)
      for (kind, path) in entries:
        let target = destDir / path.splitPath().tail
        case kind
        of pcDir:
          moveDir(path.string, target.string)
        of pcFile, pcLinkToDir, pcLinkToFile:
          moveFile(path.string, target.string)
        else:
          discard
    result = true
  finally:
    if dirExists(tempDir.string):
      try:
        removeDir(tempDir.string)
      except CatchableError:
        discard

proc loadArchiveRelease*(pkg: Package): bool =
  if UseBinaryPkgs notin context().flags:
    return false
  if not pkg.isOfficial or pkg.isFork or pkg.url.isFileProtocol():
    return false

  let release = pkg.activeNimbleRelease()
  doAssert not pkg.activeVersion.isNil and not release.isNil

  if pkg.ondisk.string.len > 0 and dirExists(pkg.ondisk.string):
    return false

  let cacheRoot = cachesDirectory()
  if cacheRoot.string.len == 0:
    warn pkg, "missing caches directory, cannot download archives"
    return false

  if not downloadPackageArchives(pkg, pkgArchiveBaseUrl(), cacheRoot):
    warn pkg, "unable to download package archives"
    return false

  let pkgDir = packageArchiveLocalDir(pkg.url, cacheRoot)
  let digestPath = pkgDir / Path PackageDigestFileName
  let archives = readArchiveDigest(digestPath)
  if archives.len == 0:
    warn pkg, "no archives listed in digest:", $digestPath
    return false
  let archiveName = selectArchiveForRelease(pkg, archives)
  if archiveName.len == 0:
    warn pkg, "no archive found for release:", $release.version
    return false
  let archivePath = pkgDir / Path(archiveName)
  if not fileExists(archivePath.string):
    warn pkg, "missing archive file:", $archivePath
    return false
  let destDir = depsDir() / Path(stripArchiveSuffix(archiveName))
  if dirExists(destDir.string):
    pkg.ondisk = destDir
    return true
  if not extractArchive(archivePath, destDir):
    warn pkg, "unable to extract archive:", $archivePath
    return false
  notice pkg, "using package archive:", $archivePath, "at:", $destDir
  pkg.ondisk = destDir
  result = true
