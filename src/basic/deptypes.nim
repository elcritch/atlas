import std/[unicode, paths, sha1, tables, json, jsonutils, hashes]
import sattypes, pkgurls, versions, context, compiledpatterns

export sha1, tables

type

  PackageState* = enum
    NotInitialized
    Found
    Processed
    Error

  ReleaseStatus* = enum
    Normal, HasBrokenRepo, HasBrokenNimbleFile, HasBrokenRelease, HasUnknownNimbleFile, HasBrokenDep

  Package* = ref object
    url*: PkgUrl
    state*: PackageState
    versions*: OrderedTable[PackageVersion, NimbleRelease]
    activeVersion*: PackageVersion
    module*: string
    ondisk*: Path
    nimbleFile*: Path
    active*: bool
    isLinkedProject*: bool
    isRoot*: bool
    errors*: seq[string]
    originHead*: CommitHash

  NimbleRelease* = ref object
    version*: Version
    nimVersion*: Version
    status*: ReleaseStatus
    requirements*: seq[(PkgUrl, VersionInterval)]
    hasInstallHooks*: bool
    srcDir*: Path
    err*: string
    rid*: VarId = NoVar

  PackageVersion* = ref object
    vtag*: VersionTag
    vid*: VarId = NoVar

  DepGraph* = object
    mode*: TraversalMode
    root*: Package
    pkgs*: OrderedTable[PkgUrl, Package]

  TraversalMode* = enum
    AllReleases,
    ExplicitVersions,
    CurrentCommit

const
  EmptyReqs* = 0
  UnknownReqs* = 1

  FileWorkspace* = "file://"

proc toPkgVer*(vtag: VersionTag): PackageVersion =
  result = PackageVersion(vtag: vtag)

proc version*(pv: PackageVersion): Version =
  pv.vtag.version
proc commit*(pv: PackageVersion): CommitHash =
  pv.vtag.commit

proc sortVersionsDesc*(a, b: (VersionTag, NimbleRelease)): int =
  sortVersionsDesc(a[0], b[0])

proc sortVersionsDesc*(a, b: (PackageVersion, NimbleRelease)): int =
  sortVersionsDesc(a[0].vtag, b[0].vtag)

proc sortVersionsAsc*(a, b: (VersionTag, NimbleRelease)): int =
  sortVersionsAsc(a[0], b[0])

proc sortVersionsAsc*(a, b: (PackageVersion, NimbleRelease)): int =
  sortVersionsAsc(a[0].vtag, b[0].vtag)

proc `$`*(d: Package): string =
  d.url.projectName()

proc projectName*(d: Package): string =
  d.url.projectName()

proc toJsonHook*(v: (PkgUrl, VersionInterval), opt: ToJsonOptions): JsonNode =
  result = newJObject()
  result["url"] = toJsonHook(v[0])
  result["version"] = toJsonHook(v[1])

proc fromJsonHook*(a: var (PkgUrl, VersionInterval); b: JsonNode; opt = Joptions()) =
  a[0].fromJson(b["url"])
  a[1].fromJson(b["version"])

proc toJsonHook*(r: NimbleRelease, opt: ToJsonOptions = ToJsonOptions()): JsonNode =
  if r == nil:
    return newJNull()
  result = newJObject()
  result["requirements"] = toJson(r.requirements, opt)
  if r.hasInstallHooks:
    result["hasInstallHooks"] = toJson(r.hasInstallHooks, opt)
  if r.srcDir != Path "":
    result["srcDir"] = toJson(r.srcDir, opt)
  result["version"] = toJson(r.version, opt)
  result["status"] = toJson(r.status, opt)
  if r.err != "":
    result["err"] = toJson(r.err, opt)

proc fromJsonHook*(r: var NimbleRelease; b: JsonNode; opt = Joptions()) =
  if r.isNil:
    r = new(NimbleRelease)
  r.version.fromJson(b["version"])
  r.requirements.fromJson(b["requirements"])
  r.status.fromJson(b["status"])
  if b.hasKey("hasInstallHooks"):
    r.hasInstallHooks = b["hasInstallHooks"].getBool()
  if b.hasKey("srcDir"):
    r.srcDir.fromJson(b["srcDir"])
  if b.hasKey("err"):
    r.err = b["err"].getStr()

proc hash*(r: Package): Hash =
  ## use pkg name and url for identification and lookups
  var h: Hash = 0
  h = h !& hash(r.url)
  result = !$h

proc hash*(r: NimbleRelease): Hash =
  var h: Hash = 0
  h = h !& hash(r.version)
  h = h !& hash(r.requirements)
  h = h !& hash(r.nimVersion)
  h = h !& hash(r.hasInstallHooks)
  h = h !& hash($r.srcDir)
  h = h !& hash($r.err)
  h = h !& hash($r.status)
  result = !$h

proc `==`*(a, b: NimbleRelease): bool =
  result = true
  result = result and a.version == b.version
  result = result and a.requirements == b.requirements
  result = result and a.nimVersion == b.nimVersion
  result = result and a.hasInstallHooks == b.hasInstallHooks
  result = result and a.srcDir == b.srcDir
  result = result and a.err == b.err
  result = result and a.status == b.status

proc `$`*(r: PackageVersion): string =
  result = $(r.vtag)

proc hash*(r: PackageVersion): Hash =
  result = hash(r.vtag)
proc `==`*(a, b: PackageVersion): bool =
  result = a.vtag == b.vtag

proc toJsonHook*(t: OrderedTable[PackageVersion, NimbleRelease], opt: ToJsonOptions): JsonNode =
  result = newJArray()
  for k, v in t:
    var tpl = newJArray()
    tpl.add toJson(k, opt)
    tpl.add toJson(v, opt)
    result.add tpl
    # result[repr(k.vtag)] = toJson(v, opt)

proc fromJsonHook*(t: var OrderedTable[PackageVersion, NimbleRelease]; b: JsonNode; opt = Joptions()) =
  for item in b:
    var pv: PackageVersion
    pv.fromJson(item[0])
    var release: NimbleRelease
    release.fromJson(item[1])
    t[pv] = release

proc toJsonHook*(t: OrderedTable[PkgUrl, Package], opt: ToJsonOptions): JsonNode =
  result = newJObject()
  for k, v in t:
    result[$(k)] = toJson(v, opt)

proc activeNimbleRelease*(pkg: Package): NimbleRelease =
  if pkg.activeVersion.isNil:
    result = nil
  else:
    let av = pkg.activeVersion
    result = pkg.versions[av]

proc toReporterName*(pkg: Package): string =
  if pkg.isNil: "nil"
  else: pkg.url.fullName()

proc findRelease*(pkg: Package, v: VersionInterval): NimbleRelease =
  for vtag, release in pkg.versions:
    if v.matches(vtag.vtag):
      return release
  result = nil

proc matches*(v: VersionInterval, pkgVer: PackageVersion): bool =
  v.matches(pkgVer.vtag)
