#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Configuration handling.

import std / [strutils, os, streams, json, tables, jsonutils, uri, sequtils]
import basic/[versions, context, reporters, compiledpatterns, parse_requires, deptypes]

proc readPluginsDir(dir: Path) =
  for k, f in walkDir($(project() / dir)):
    if k == pcFile and f.endsWith(".nims"):
      extractPluginInfo f, context().plugins

type
  JsonConfig = object
    deps: string
    nameOverrides: Table[string, string]
    urlOverrides: Table[string, string]
    pkgOverrides: Table[string, string]
    plugins: string
    resolver: string
    graph: JsonNode

proc writeDefaultConfigFile*() =
  let config = JsonConfig(
    deps: $depsDir(relative=true),
    nameOverrides: initTable[string, string](),
    urlOverrides: initTable[string, string](),
    pkgOverrides: initTable[string, string](),
    resolver: $SemVer,
    graph: newJNull()
  )
  let configFile = getWorkspaceConfig()
  writeFile($configFile, pretty %*config)

proc readConfig*() =
  let configFile = getWorkspaceConfig()
  var f = newFileStream($configFile, fmRead)
  if f == nil:
    warn "atlas:config", "could not read project config:", $configFile
    return

  let j = parseJson(f, $configFile)
  try:
    let m = j.jsonTo(JsonConfig, Joptions(allowExtraKeys: true, allowMissingKeys: true))
    if m.deps.len > 0:
      context().depsDir = m.deps.Path
    
    # Handle package name overrides
    for key, val in m.nameOverrides:
      let err = context().nameOverrides.addPattern(key, val)
      if err.len > 0:
        error configFile, "invalid name override pattern: " & err

    # Handle URL overrides  
    for key, val in m.urlOverrides:
      let err = context().urlOverrides.addPattern(key, val)
      if err.len > 0:
        error configFile, "invalid URL override pattern: " & err

    # Handle package overrides
    for key, val in m.pkgOverrides:
      context().pkgOverrides[key] = parseUri(val)
    if m.resolver.len > 0:
      try:
        context().defaultAlgo = parseEnum[ResolutionAlgorithm](m.resolver)
      except ValueError:
        warn configFile, "ignored unknown resolver: " & m.resolver
    if m.plugins.len > 0:
      context().pluginsFile = m.plugins.Path
      readPluginsDir(m.plugins.Path)
  finally:
    close f

proc writeConfig*(graph: DepGraph) =
  # TODO: serialize graph in a smarter way

  let config = JsonConfig(
    deps: $depsDir(relative=true),
    nameOverrides: context().nameOverrides.toTable(),
    urlOverrides: context().urlOverrides.toTable(),
    pkgOverrides: context().pkgOverrides.pairs().toSeq().mapIt((it[0], $it[1])).toTable(),
    plugins: $context().pluginsFile,
    resolver: $context().defaultAlgo,
    graph: newJNull(),
  )
  let configFile = getWorkspaceConfig()
  writeFile($configFile, pretty %*config)
