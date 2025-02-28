#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, sha1, paths, strutils, tables, unicode, hashes, json, jsonutils]
import sattypes, deptypes, versions, context, reporters, gitops, parse_requires, pkgurls, compiledpatterns

proc addError*(err: var string; nimbleFile: string; msg: string) =
  if err.len > 0: err.add "\n"
  else: err.add "in file: " & nimbleFile & "\n"
  err.add msg

proc isUrl(s: string): bool {.inline.} = s.len > 5 and s.contains "://"

proc parseNimbleFile*(nc: NimbleContext; nimbleFile: Path; p: Patterns): Requirements =
  let nimbleInfo = extractRequiresInfo(nimbleFile)
  let nimbleHash = secureHashFile($nimbleFile)

  result = Requirements(
    hasInstallHooks: nimbleInfo.hasInstallHooks,
    srcDir: nimbleInfo.srcDir,
    status: if nimbleInfo.hasErrors: HasBrokenNimbleFile else: Normal,
    vid: NoVar,
    nimbleHash: nimbleHash,
    version: parseExplicitVersion(nimbleInfo.version)
  )

  for r in nimbleInfo.requires:
    var i = 0
    while i < r.len and r[i] notin {'#', '<', '=', '>'} + Whitespace: inc i
    let name = r.substr(0, i-1)

    try:
      let url = nc.createUrl(name)

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
          result.deps.add (url, query)
    except ValueError, IOError, OSError:
      result.status = HasBrokenDep
      warn nimbleFile, "cannot resolve dependency package name: " & name
      result.err.addError $nimbleFile, "cannot resolve package name: " & name

proc genRequiresLine(u: string): string = "requires \"$1\"\n" % u.escape("", "")

proc patchNimbleFile*(nc: var NimbleContext;
                      p: Patterns; nimbleFile: Path, name: string) =
  var didReplace = false
  var u = substitute(p, name, didReplace)
  if not didReplace:
    let ln = unicode.toLower(name) 
    if name.isUrl:
      u = name
    elif ln in nc.nameToUrl:
      u = $(nc.nameToUrl[ln])
    else:
      u = ""

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
