#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, strutils, tables, unicode, sets, json, hashes, algorithm]
import basic/[context, depgraphtypes, versions, osutils, nimbleparser, packageinfos, reporters, gitops, parserequires, pkgurls, compiledpatterns]

const
  DefaultPackagesSubDir* = "packages"

when defined(nimAtlasBootstrap):
  import ../dist/sat/src/sat/satvars
else:
  import sat/satvars

proc getPackageInfos*(depsDir: string): seq[PackageInfo] =
  result = @[]
  var uniqueNames = initHashSet[string]()
  var jsonFiles = 0
  for kind, path in walkDir(depsDir / DefaultPackagesSubDir):
    if kind == pcFile and path.endsWith(".json"):
      inc jsonFiles
      let packages = json.parseFile(path)
      for p in packages:
        let pkg = p.fromJson()
        if pkg != nil and not uniqueNames.containsOrIncl(pkg.name):
          result.add(pkg)

proc updatePackages*(c: var AtlasContext; depsDir: string) =
  if dirExists(depsDir / DefaultPackagesSubDir):
    withDir(c, depsDir / DefaultPackagesSubDir):
      gitPull(c, DefaultPackagesSubDir)
  else:
    withDir c, depsDir:
      let success = clone(c, "https://github.com/nim-lang/packages", DefaultPackagesSubDir)
      if not success:
        error c, DefaultPackagesSubDir, "cannot clone packages repo"

proc fillPackageLookupTable(r: var AtlasContext; c: var NimbleContext; depsdir: string) =
  if not c.hasPackageList:
    c.hasPackageList = true
    if not fileExists(depsDir / DefaultPackagesSubDir / "packages.json"):
      updatePackages(r, depsdir)
    let packages = getPackageInfos(depsDir)
    for entry in packages:
      c.nameToUrl[unicode.toLower entry.name] = entry.url

proc createNimbleContext*(r: var AtlasContext; depsdir: string): NimbleContext =
  result = NimbleContext()
  fillPackageLookupTable(r, result, depsdir)

proc collectNimbleVersions*(c: var AtlasContext; nc: NimbleContext; g: var DepGraph; idx: int): seq[string] =
  let (outerNimbleFile, found) = findNimbleFile(g, idx)
  result = @[]
  if found == 1:
    let (outp, status) = exec(c, GitLog, [outerNimbleFile])
    if status == 0:
      for line in splitLines(outp):
        if line.len > 0 and not line.endsWith("^{}"):
          result.add line
    result.reverse()
