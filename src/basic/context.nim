#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [os, uri, paths]
import versions, parse_requires, compiledpatterns, reporters

export reporters

const
  UnitTests* = defined(atlasUnitTests)
  TestsDir* = "atlas/tests"

const
  AtlasWorkspace* = Path "atlas.workspace"

type
  CfgPath* = distinct string # put into a config `--path:"../x"`

  SemVerField* = enum
    major, minor, patch

  CloneStatus* = enum
    Ok, NotFound, OtherError

  Flag* = enum
    KeepCommits
    CfgHere
    UsesOverrides
    Keep
    KeepWorkspace
    ShowGraph
    AutoEnv
    NoExec
    ListVersions
    GlobalWorkspace
    FullClones
    IgnoreUrls

  AtlasContext* = object
    workspace*: Path = Path"."
    depsDir*: Path = Path"deps"
    flags*: set[Flag]
    #urlMapping*: Table[string, Package] # name -> url mapping
    dumpGraphs*: bool = true # TODO: debugging, plumb cli option later
    dumpFormular*: bool = true # TODO: debugging, plumb cli option later
    overrides*: Patterns
    defaultAlgo*: ResolutionAlgorithm
    plugins*: PluginInfo
    overridesFile*: Path
    pluginsFile*: Path
    proxy*: Uri
    dumbProxy*: bool = false
    forceGitToHttps*: bool = false
    includeTagsAndNimbleCommits*: bool = false

var atlasContext = AtlasContext()

proc setContext*(ctx: AtlasContext) =
  atlasContext = ctx
proc context*(): var AtlasContext =
  atlasContext

proc `==`*(a, b: CfgPath): bool {.borrow.}

proc displayName(c: AtlasContext; p: string): string =
  if p == c.workspace.string:
    p.absolutePath
  elif $c.depsDir != "" and p.isRelativeTo($c.depsDir):
    p.relativePath($c.depsDir)
  elif p.isRelativeTo($c.workspace):
    p.relativePath($c.workspace)
  else:
    p
