import std/[unicode, paths, sha1, tables, json, jsonutils, hashes]
import sattypes, pkgurls, versions, context, compiledpatterns

export sha1, tables

type

  DependencyState* = enum
    NotInitialized
    Found
    Processed
    Error

  Dependency* = object
    pkg*: PkgUrl
    state*: DependencyState
    isRoot*: bool
    isTopLevel*: bool
    ondisk*: Path
    errors*: seq[string]

  DependencySpec* = object
    releases*: OrderedTable[VersionTag, NimbleRelease]
  
  NimbleRelease* = ref object
    version*: Version
    nimVersion*: Version
    status*: RequirementStatus
    deps*: seq[(PkgUrl, VersionInterval)]
    nimbleHash*: SecureHash
    hasInstallHooks*: bool
    srcDir*: Path
    err*: string

  RequirementStatus* = enum
    Normal, HasBrokenRepo, HasBrokenNimbleFile, HasBrokenRelease, HasUnknownNimbleFile, HasBrokenDep

  CommitOrigin = enum
    FromHead, FromGitTag, FromDep, FromNimbleFile

  DependencySpecs* = ref object
    depsToSpecs*: OrderedTable[PkgUrl, DependencySpec]

  NimbleContext* = object
    packageToDependency*: Table[PkgUrl, Dependency]
    overrides*: Patterns
    hasPackageList*: bool
    nameToUrl*: Table[string, PkgUrl]

const
  EmptyReqs* = 0
  UnknownReqs* = 1

  FileWorkspace* = "file://"

proc createUrl*(nc: NimbleContext, orig: Path): PkgUrl =
  var didReplace = false
  result = createUrlSkipPatterns($orig)

proc createUrl*(nc: NimbleContext, nameOrig: string; projectName: string = ""): PkgUrl =
  ## primary point to createUrl's from a name or argument
  ## TODO: add unit tests!
  var didReplace = false
  var name = substitute(nc.overrides, nameOrig, didReplace)
  debug "createUrl", "name:", name, "orig:", nameOrig, "patterns:", $nc.overrides
  if name.isUrl():
    result = createUrlSkipPatterns(name)
  else:
    let lname = unicode.toLower(name)
    if lname in nc.nameToUrl:
      result = nc.nameToUrl[lname]
    else:
      raise newException(ValueError, "project name not found in packages database")
  if projectName != "":
    result.projectName = projectName

proc sortVersions*(a, b: (VersionTag, NimbleRelease)): int =
  (if a[0].v < b[0].v: 1
  elif a[0].v == b[0].v: 0
  else: -1)

proc `$`*(d: Dependency): string =
  d.pkg.projectName

proc projectName*(d: Dependency): string =
  d.pkg.projectName

proc toJsonHook*(v: (PkgUrl, VersionInterval), opt: ToJsonOptions): JsonNode =
  result = newJObject()
  result["url"] = toJsonHook(v[0])
  result["version"] = toJsonHook(v[1])

proc toJsonHook*(r: NimbleRelease, opt: ToJsonOptions = ToJsonOptions()): JsonNode =
  result = newJObject()
  result["deps"] = toJson(r.deps, opt)
  if r.hasInstallHooks:
    result["deps"] = toJson(r.hasInstallHooks, opt)
  if r.srcDir != Path "":
    result["srcDir"] = toJson(r.srcDir, opt)
  if r.version != Version"":
    result["version"] = toJson(r.version, opt)
  # if r.vid != NoVar:
  #   result["varId"] = toJson(r.vid, opt)
  result["status"] = toJson(r.status, opt)

proc hash*(r: Dependency): Hash =
  ## use pkg name and url for identification and lookups
  var h: Hash = 0
  h = h !& hash(r.pkg)
  result = !$h
  # pkg*: PkgUrl
  # state*: DependencyState
  # isRoot*: bool
  # isTopLevel*: bool
  # ondisk*: Path
  # errors*: seq[string]

proc hash*(r: NimbleRelease): Hash =
  var h: Hash = 0
  h = h !& hash(r.deps)
  h = h !& hash(r.hasInstallHooks)
  h = h !& hash($r.srcDir)
  #h = h !& hash(r.version)
  h = h !& hash(r.nimVersion)
  result = !$h

proc `==`*(a, b: NimbleRelease): bool =
  result = a.deps == b.deps and a.hasInstallHooks == b.hasInstallHooks and
      a.srcDir == b.srcDir and a.nimVersion == b.nimVersion
  #and a.version == b.version

proc toJsonHook*(t: Table[VersionTag, NimbleRelease], opt: ToJsonOptions): JsonNode =
  result = newJObject()
  for k, v in t:
    result[repr(k)] = toJson(v, opt)

proc toJsonHook*(t: OrderedTable[VersionTag, NimbleRelease], opt: ToJsonOptions): JsonNode =
  result = newJObject()
  for k, v in t:
    result[repr(k)] = toJson(v, opt)

proc toJsonHook*(t: OrderedTable[PkgUrl, DependencySpec], opt: ToJsonOptions): JsonNode =
  result = newJObject()
  for k, v in t:
    result[$(k)] = toJson(v, opt)
