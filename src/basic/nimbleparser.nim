#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, paths, strutils, tables, unicode, hashes, json, jsonutils]
import sattypes, versions, context, reporters, gitops, parse_requires, pkgurls, compiledpatterns

type

  NimbleContext* = object
    hasPackageList*: bool
    nameToUrl*: Table[string, string]

# proc toJsonHook*(ss: seq[(PkgUrl, VersionInterval)]): JsonNode =
#   result = newJArray()
#   for v in ss:
#     result.add(% {"url": % v[0], "version": % v[1]} )

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

proc addError*(err: var string; nimbleFile: string; msg: string) =
  if err.len > 0: err.add "\n"
  else: err.add "in file: " & nimbleFile & "\n"
  err.add msg

proc isUrl(s: string): bool {.inline.} = s.len > 5 and s.contains "://"

proc parseNimbleFile*(nc: NimbleContext; nimbleFile: Path; p: Patterns): Requirements =
  let nimbleInfo = extractRequiresInfo(nimbleFile)

  result = Requirements(
    hasInstallHooks: nimbleInfo.hasInstallHooks,
    srcDir: nimbleInfo.srcDir,
    status: if nimbleInfo.hasErrors: HasBrokenNimbleFile else: Normal,
    vid: NoVar,
    version: parseExplicitVersion(nimbleInfo.version)
  )
  for r in nimbleInfo.requires:
    var i = 0
    while i < r.len and r[i] notin {'#', '<', '=', '>'} + Whitespace: inc i
    let name = r.substr(0, i-1)

    var didReplace = false
    var u = substitute(p, name, didReplace)
    if not didReplace:
      u = (if name.isUrl: name else: nc.nameToUrl.getOrDefault(unicode.toLower name, ""))

    if u.len == 0:
      result.status = HasBrokenDep
      result.err.addError $nimbleFile, "cannot resolve package name: " & name
    else:
      var err = false
      let query = parseVersionInterval(r, i, err) # update err

      if err:
        if result.status != HasBrokenDep:
          result.status = HasBrokenNimbleFile
          result.err.addError $nimbleFile, "invalid 'requires' syntax in nimble file: " & r
      else:
        if cmpIgnoreCase(name, "nim") == 0:
          let v = extractGeQuery(query)
          if v != Version"":
            result.nimVersion = v
        else:
          result.deps.add (createUrlSkipPatterns(u), query)

proc genRequiresLine(u: string): string = "requires \"$1\"\n" % u.escape("", "")

proc patchNimbleFile*(nc: var NimbleContext;
                      p: Patterns; nimbleFile: Path, name: string) =
  var didReplace = false
  var u = substitute(p, name, didReplace)
  if not didReplace:
    u = (if name.isUrl: name else: nc.nameToUrl.getOrDefault(unicode.toLower name, ""))

  if u.len == 0:
    error name, "cannot resolve package name: " & name
    return

  echo "NIMBLEFILE: ", $nimbleFile
  echo "NIMBLEFILE: ", $nimbleFile.absolutePath
  let req = parseNimbleFile(nc, nimbleFile, p)
  # see if we have this requirement already listed. If so, do nothing:
  for d in req.deps:
    if d[0].url == u:
      info(nimbleFile, "up to date")
      return

  let line = genRequiresLine(if didReplace: name else: u)
  var f = open($nimbleFile, fmAppend)
  try:
    f.writeLine line
  finally:
    f.close()
  info(nimbleFile, "updated")
