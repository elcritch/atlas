import std/[paths, sha1, tables, json, jsonutils, hashes]
import sattypes, pkgurls, versions, context

export sha1

type

  DependencyState* = enum
    NotInitialized
    Found
    Processed
    Error

  DependencyInfo* = object
    isRoot*: bool
    isTopLevel*: bool
    ondisk*: Path
    errors*: seq[string]

  Dependency* = ref object
    pkg*: PkgUrl
    info*: DependencyInfo
    state*: DependencyState
    versions*: OrderedTable[VersionTag, Requirements]
  
  DepConstraint* = object
    pkg*: PkgUrl
    info*: DependencyInfo
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

  NimbleContext* = object
    hasPackageList*: bool
    nameToUrl*: Table[string, string]
    packageToDependency*: Table[PkgUrl, Dependency]

const
  EmptyReqs* = 0
  UnknownReqs* = 1

proc sortDepVersions*(a, b: DepVersion): int =
  (if a.vtag.v < b.vtag.v: 1
  elif a.vtag.v == b.vtag.v: 0
  else: -1)

proc initDepVersion*(version: Version, commit: CommitHash, req = EmptyReqs, vid = NoVar): DepVersion =
  result = DepVersion(vtag: VersionTag(c: commit, v: version), req: req, vid: vid)

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
