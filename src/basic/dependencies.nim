import std/[paths, sha1, tables]
import sattypes, pkgurls, versions

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

  BaseDependency* = object of RootObj
    pkg*: PkgUrl
    info*: DependencyInfo

  Dependency* = object of BaseDependency
    state*: DependencyState
    versions*: OrderedTable[VersionTag, Requirements]
  
  DepConstraint* = object of BaseDependency
    activeVersion*: int
    active*: bool
    versions*: seq[DepVersion]

  DepVersion* = object  # Represents a specific version of a project.
    vtag*: VersionTag
    req*: int # index into graph.reqs so that it can be shared between versions
    vid*: VarId

  Requirements* = object of RootObj
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
    Normal, HasBrokenNimbleFile, HasUnknownNimbleFile, HasBrokenDep

  CommitOrigin = enum
    FromHead, FromGitTag, FromDep, FromNimbleFile

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
