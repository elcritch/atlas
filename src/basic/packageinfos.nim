#
#           Atlas Package Cloner
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [httpclient, json, os, sets, strutils, paths, dirs, uri]
import context, reporters, gitops, pkgurls, pkgarchive, osutils

const
  UnitTests = defined(atlasUnitTests)
  PackageArchiveDir = Path"pkg_archive"
  PackagesIndexUrl = "https://raw.githubusercontent.com/nim-lang/packages/refs/heads/master/packages.json"

when UnitTests:
  proc findAtlasDir*(): string =
    result = currentSourcePath().absolutePath
    while not result.endsWith("atlas"):
      result = result.parentDir
      assert result != "", "atlas dir not found!"

type
  PackageKind* = enum
    pkPackage,
    pkAlias

  PackageInfo* = ref object
    name*: string
    case kind*: PackageKind
    of pkAlias:
      alias*: string
    of pkPackage:
      # Required fields in a PackageInfo.
      url*: string # Download location.
      license*: string
      downloadMethod*: string
      description*: string
      tags*: seq[string] # \
      # From here on, optional fields set to the empty string if not available.
      version*: string
      dvcsTag*: string
      web*: string # Info url for humans.

proc optionalField(obj: JsonNode, name: string, default = ""): string =
  if hasKey(obj, name) and obj[name].kind == JString:
    result = obj[name].str
  else:
    result = default

template requiredField(obj: JsonNode, name: string): string =
  block:
    let result = optionalField(obj, name, "")
    if result.len == 0:
      return nil
    result

proc fromJson*(obj: JsonNode): PackageInfo =
  if "alias" in obj:
    result = PackageInfo(kind: pkAlias)
    result.name = obj.requiredField("name")
    result.alias = obj.requiredField("alias")
  else:
    result = PackageInfo(kind: pkPackage)
    result.name = obj.requiredField("name")
    result.version = obj.optionalField("version")
    result.url = obj.requiredField("url")
    result.downloadMethod = obj.requiredField("method")
    result.dvcsTag = obj.optionalField("dvcs-tag")
    result.license = obj.optionalField("license")
    result.tags = @[]
    for t in obj["tags"]: result.tags.add(t.str)
    result.description = obj.requiredField("description")
    result.web = obj.optionalField("web")

proc `$`*(pkg: PackageInfo): string =
  result = pkg.name & ":\n"
  result &= "  url:         " & pkg.url & " (" & pkg.downloadMethod & ")\n"
  result &= "  tags:        " & pkg.tags.join(", ") & "\n"
  result &= "  description: " & pkg.description & "\n"
  result &= "  license:     " & pkg.license & "\n"
  if pkg.web.len > 0:
    result &= "  website:     " & pkg.web & "\n"

proc toTags*(j: JsonNode): seq[string] =
  result = @[]
  if j.kind == JArray:
    for elem in items j:
      result.add elem.getStr("")

proc packageArchiveDirectory*(): Path =
  project() / PackageArchiveDir

proc logPackageVersionsAndArchive(pkgs: seq[PackageInfo]) =
  var versions: seq[string]
  for pkg in pkgs:
    if pkg.kind == pkPackage and pkg.version.len > 0:
      versions.add(pkg.name & ":" & pkg.version)
  if versions.len > 0:
    info "atlas:packageinfos", "versions:", versions.join(", ")
  else:
    info "atlas:packageinfos", "versions: <none>"
  info "atlas:packageinfos", "archive path:", $packageArchiveDirectory()

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
  logPackageVersionsAndArchive(result)

proc downloadPackagesIndexFromUrl(pkgsDir: Path): bool =
  if pkgsDir.string.len == 0:
    return false
  if not dirExists(pkgsDir):
    createDir(pkgsDir.string)
  let dest = pkgsDir / Path"packages.json"
  var client = newHttpClient()
  try:
    info "atlas:packageinfos", "downloading packages.json from:", PackagesIndexUrl
    client.downloadFile(PackagesIndexUrl, $dest)
    result = true
  except CatchableError as err:
    warn "atlas:packageinfos", "unable to download packages.json:", err.msg
  finally:
    client.close()

proc unpackPackagesIndexXz(pkgsDir: Path): bool =
  let xzPath = findExe("xz")
  if xzPath.len == 0:
    warn "atlas:packageinfos", "xz not found; unable to extract packages.json"
    return false
  let src = pkgsDir / Path"packages.json.xz"
  if not fileExists(src.string):
    warn "atlas:packageinfos", "packages.json.xz missing:", $src
    return false
  let dest = pkgsDir / Path"packages.json"
  let (output, status) = execProcessCapture(xzPath, @["-d", "-c", $src])
  if status != RES_OK:
    warn "atlas:packageinfos", "unable to extract packages.json.xz"
    return false
  try:
    writeFile($dest, output)
    result = true
  except CatchableError as err:
    warn "atlas:packageinfos", "unable to write packages.json:", err.msg

proc updatePackages*(pkgsDir = packagesDirectory()) =
  let pkgsDir = depsDir() / DefaultPackagesSubDir
  if UseBinaryPkgs in context().flags:
    let archiveUrl = pkgArchiveBaseUrl()
    let archiveLabel = ($archiveUrl).toLowerAscii()
    let isAtlasArchive = "atlas-packages" in archiveLabel
    if isAtlasArchive and downloadPackagesIndexXz(pkgsDir):
      if unpackPackagesIndexXz(pkgsDir):
        info "atlas:packageinfos", "downloaded packages.json.xz to:", $pkgsDir
        return
    warn "atlas:packageinfos", "unable to download packages.json.xz, falling back to git clone"
  else:
    if downloadPackagesIndexFromUrl(pkgsDir):
      info "atlas:packageinfos", "downloaded packages.json to:", $pkgsDir
      return
    else:
      warn "atlas:packageinfos", "unable to download packages.json, falling back to git clone"

  if dirExists(pkgsDir):
    if isGitDir(pkgsDir.string):
      gitPull(pkgsDir)
    else:
      warn "atlas:packageinfos", "packages directory exists but is not a git repo:", $pkgsDir
  else:
    let pkgsUrl = parseUri "https://github.com/nim-lang/packages"
    let res = clone(pkgsUrl, pkgsDir)
    if res[0] != Ok:
      error DefaultPackagesSubDir, "cannot clone packages repo: " & res[1]
