import std/[unicode, paths, sha1, tables, json, jsonutils, hashes]
import sattypes, pkgurls, versions, context, compiledpatterns

export sha1

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
    dep*: Dependency
    versions*: OrderedTable[VersionTag, Requirements]
  
  DepConstraint* = object
    dep*: Dependency
    activeVersion*: int
    active*: bool
    versions*: seq[DepVersion]

  DepVersion* = object  # Represents a specific version of a project.
    vtag*: VersionTag
    req*: int # index into graph.reqs so that it can be shared between versions
    vid*: VarId

  Requirements* = object
    version*: Version
    status*: RequirementStatus
    deps*: seq[(PkgUrl, VersionInterval)]
    nimbleHash*: SecureHash
    hasInstallHooks*: bool
    srcDir*: Path
    nimVersion*: Version
    err*: string
    vid*: VarId

  RequirementStatus* = enum
    Normal, HasBrokenRepo, HasBrokenNimbleFile, HasBrokenRelease, HasUnknownNimbleFile, HasBrokenDep

  CommitOrigin = enum
    FromHead, FromGitTag, FromDep, FromNimbleFile

  DependencySpecs* = ref object
    packageToDependency*: Table[PkgUrl, Dependency]
    depsToSpecs*: Table[Dependency, DependencySpec]
    nimbleCtx*: NimbleContext

  NimbleContext* = object
    patterns*: Patterns
    hasPackageList*: bool
    nameToUrl*: Table[string, PkgUrl]

const
  EmptyReqs* = 0
  UnknownReqs* = 1

proc createUrl*(nc: NimbleContext, name: string; projectName: string = ""): PkgUrl =
  ## primary point to createUrl's from a name or argument
  ## TODO: add unit tests!
  var didReplace = false
  var name = substitute(nc.patterns, name, didReplace)
  if name.isUrl():
    result = createUrlSkipPatterns(name)
  else:
    let lname = unicode.toLower(name)
    if lname in nc.nameToUrl:
      result = nc.nameToUrl[lname]
    else:
      result = createUrlSkipPatterns(name)
  if projectName != "":
    result.projectName = projectName

proc sortDepVersions*(a, b: DepVersion): int =
  (if a.vtag.v < b.vtag.v: 1
  elif a.vtag.v == b.vtag.v: 0
  else: -1)

proc initDepVersion*(version: Version, commit: CommitHash, req = EmptyReqs, vid = NoVar): DepVersion =
  result = DepVersion(vtag: VersionTag(c: commit, v: version), req: req, vid: vid)

proc `$`*(d: Dependency): string =
  d.pkg.projectName

proc projectName*(d: Dependency): string =
  d.pkg.projectName
proc projectName*(s: DependencySpec): string =
  s.dep.pkg.projectName

proc commit*(d: DepConstraint): CommitHash =
  result =
    if d.activeVersion >= 0 and d.activeVersion < d.versions.len: d.versions[d.activeVersion].vtag.commit()
    else: CommitHash(h: "")

proc enrichVersionsViaExplicitHash*(versions: var seq[DepVersion]; x: VersionInterval) =
  let commit = extractSpecificCommit(x)
  if not commit.isEmpty():
    for ver in versions:
      if ver.vtag.commit() == commit:
        return
    versions.add initDepVersion(Version"", commit) 

proc toJsonHook*(v: (PkgUrl, VersionInterval), opt: ToJsonOptions): JsonNode =
  result = newJObject()
  result["url"] = toJsonHook(v[0])
  result["version"] = toJsonHook(v[1])

proc toJsonHook*(r: Requirements, opt: ToJsonOptions): JsonNode =
  result = newJObject()
  result["deps"] = toJson(r.deps, opt)
  if r.hasInstallHooks:
    result["deps"] = toJson(r.hasInstallHooks, opt)
  if r.srcDir != Path "":
    result["srcDir"] = toJson(r.srcDir, opt)
  if r.version != Version"":
    result["version"] = toJson(r.version, opt)
  if r.vid != NoVar:
    result["varId"] = toJson(r.vid, opt)
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

proc hash*(r: Requirements): Hash =
  var h: Hash = 0
  h = h !& hash(r.deps)
  h = h !& hash(r.hasInstallHooks)
  h = h !& hash($r.srcDir)
  #h = h !& hash(r.version)
  h = h !& hash(r.nimVersion)
  result = !$h

proc `==`*(a, b: Requirements): bool =
  result = a.deps == b.deps and a.hasInstallHooks == b.hasInstallHooks and
      a.srcDir == b.srcDir and a.nimVersion == b.nimVersion
  #and a.version == b.version
