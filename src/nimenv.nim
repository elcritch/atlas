#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Implementation of the "Nim virtual environment" (`atlas env`) feature.

import std / [os, strscans, strutils]
import basic/[gitops, context, versions, osutils]

when defined(windows):
  const
    BatchFile = """
@echo off
set PATH="$1";%PATH%
"""
else:
  const
    ShellFile = "export PATH=$1:$$PATH\n"

const
  ActivationFile = when defined(windows): Path "activate.bat" else: Path "activate.sh"

proc infoAboutActivation(nimDest: Path, nimVersion: string) =
  when defined(windows):
    info nimDest, "RUN\nnim-" & nimVersion & "\\activate.bat"
  else:
    info nimDest, "RUN\nsource nim-" & nimVersion & "/activate.sh"

proc setupNimEnv*(workspace: Path, nimVersion: string; keepCsources: bool) =
  when false:
    template isDevel(nimVersion: string): bool = nimVersion == "devel"

    template exec(command: string) =
      let cmd = command # eval once
      if os.execShellCmd(cmd) != 0:
        error ("nim-" & nimVersion), "failed: " & cmd
        return

    let nimDest = Path("nim-" & nimVersion)
    if dirExists($(workspace / nimDest)):
      if not fileExists($(workspace / nimDest / ActivationFile)):
        info nimDest, "already exists; remove or rename and try again"
      else:
        infoAboutActivation nimDest, nimVersion
      return

    var major, minor, patch: int
    if nimVersion != "devel":
      if not scanf(nimVersion, "$i.$i.$i", major, minor, patch):
        error "nim", "cannot parse version requirement"
        return
    let csourcesVersion =
      if nimVersion.isDevel or (major == 1 and minor >= 9) or major >= 2:
        # already uses csources_v2
        "csources_v2"
      elif major == 0:
        "csources" # has some chance of working
      else:
        "csources_v1"
    withDir $workspace:
      if not dirExists(csourcesVersion):
        exec "git clone https://github.com/nim-lang/" & csourcesVersion
      exec "git clone https://github.com/nim-lang/nim " & $nimDest
    withDir $workspace / csourcesVersion:
      when defined(windows):
        exec "build.bat"
      else:
        let makeExe = findExe("make")
        if makeExe.len == 0:
          exec "sh build.sh"
        else:
          exec "make"
    let nimExe0 = ".." / csourcesVersion / "bin" / "nim".addFileExt(ExeExt)
    let dir = Path(workspace / nimDest)
    withDir $(workspace / nimDest):
      let nimExe = "bin" / "nim".addFileExt(ExeExt)
      copyFileWithPermissions nimExe0, nimExe
      let query = createQueryEq(if nimVersion.isDevel: Version"#head" else: Version(nimVersion))
      if not nimVersion.isDevel:
        let commit = versionToCommit(dir, SemVer, query)
        if commit.len == 0:
          error nimDest, "cannot resolve version to a commit"
          return
        discard checkoutGitCommit(dir, commit)
      exec nimExe & " c --noNimblePath --skipUserCfg --skipParentCfg --hints:off koch"
      let kochExe = when defined(windows): "koch.exe" else: "./koch"
      exec kochExe & " boot -d:release --skipUserCfg --skipParentCfg --hints:off"
      exec kochExe & " tools --skipUserCfg --skipParentCfg --hints:off"
      # remove any old atlas binary that we now would end up using:
      if cmpPaths(getAppDir(), $(workspace / nimDest / "bin".Path)) != 0:
        removeFile "bin" / "atlas".addFileExt(ExeExt)
      # unless --keep is used delete the csources because it takes up about 2GB and
      # is not necessary afterwards:
      if not keepCsources:
        removeDir $workspace / csourcesVersion / "c_code"
      let pathEntry = workspace / nimDest / "bin".Path
      when defined(windows):
        writeFile "activate.bat", BatchFile % $pathEntry.replace('/', '\\')
      else:
        writeFile "activate.sh", ShellFile % $pathEntry
      infoAboutActivation nimDest, nimVersion
