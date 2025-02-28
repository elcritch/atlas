#
#           Atlas Package Cloner
#        (c) Copyright 2021 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std/[os, files, dirs, paths, osproc, sequtils, strutils, uri, algorithm]
import reporters, osutils, versions, context

type
  Command* = enum
    GitClone = "git clone $EXTRAARGS $URL $DEST",
    GitRemoteUrl = "git -C $DIR config --get remote.origin.url",
    GitDiff = "git -C $DIR diff",
    GitFetch = "git -C $DIR fetch",
    GitTag = "git -C $DIR tag",
    GitTags = "git -C $DIR show-ref --tags",
    GitLastTaggedRef = "git -C $DIR rev-list --tags --max-count=1",
    GitDescribe = "git -C $DIR describe",
    GitRevParse = "git -C $DIR rev-parse",
    GitCheckout = "git -C $DIR checkout",
    GitSubModUpdate = "git submodule update --init",
    GitPush = "git -C $DIR push origin",
    GitPull = "git -C $DIR pull",
    GitCurrentCommit = "git -C $DIR log -n 1 --format=%H"
    GitMergeBase = "git -C $DIR merge-base"
    GitLsFiles = "git -C $DIR ls-files"
    GitLog = "git -C $DIR log --format=%H"
    GitCurrentBranch = "git rev-parse --abbrev-ref HEAD"

proc isGitDir*(path: Path): bool =
  let gitPath = path / Path(".git")
  dirExists(gitPath) or fileExists(gitPath)
proc isGitDir*(path: string): bool =
  isGitDir(Path(path))

proc sameVersionAs*(tag, ver: string): bool =
  const VersionChars = {'0'..'9', '.'}

  proc safeCharAt(s: string; i: int): char {.inline.} =
    if i >= 0 and i < s.len: s[i] else: '\0'

  let idx = find(tag, ver)
  if idx >= 0:
    # we found the version as a substring inside the `tag`. But we
    # need to watch out the the boundaries are not part of a
    # larger/different version number:
    result = safeCharAt(tag, idx-1) notin VersionChars and
      safeCharAt(tag, idx+ver.len) notin VersionChars

proc extractVersion*(s: string): string =
  var i = 0
  while i < s.len and s[i] notin {'0'..'9'}: inc i
  result = s.substr(i)

proc exec*(gitCmd: Command;
           path: Path;
           args: openArray[string],
           errorReportLevel: MsgKind = Error,
           ): (string, ResultCode) =
  let cmd = $gitCmd % ["DIR", $path]
  #if execDir.len == 0: $cmd else: $(cmd) % [execDir]
  if isGitDir(path):
    result = silentExec(cmd, args)
  else:
    result = ("", ResultCode(1))
  if result[1] != RES_OK:
    message errorReportLevel, "gitops", "Git command failed:", "`$1`" % [$gitCmd], "with code:", $int(result[1])
    trace "gitops", "Running Git command:", "`$1`" % [join(@[cmd])]

proc checkGitDiffStatus*(path: Path): string =
  let (outp, status) = exec(GitDiff, path, [])
  if outp.len != 0:
    "'git diff' not empty"
  elif status != RES_OK:
    "'git diff' returned non-zero"
  else:
    ""

proc maybeUrlProxy*(url: Uri): Uri =
  result = url
  if $context().proxy != "":
    result = context().proxy
    result.path = url.path
    result.query = url.query
    result.anchor = url.anchor

proc clone*(url: string, dest: Path; retries = 5; fullClones=false): bool =
  ## clone git repo.
  ##
  ## note clones don't use `--recursive` but rely in the `checkoutCommit`
  ## stage to setup submodules as this is less fragile on brRES_OKen submodules.
  ##

  # retry multiple times to avoid annoying github timeouts:
  let extraArgs =
    if $context().proxy != "" and context().dumbProxy: ""
    elif not fullClones: "--depth=1"
    else: ""

  var url = maybeUrlProxy(url.parseUri())

  let cmd = $GitClone % [ "EXTRAARGS", extraArgs, "URL", quoteShell($url), "DEST", $dest]
  for i in 1..retries:
    if execShellCmd(cmd) == 0:
      return true
    os.sleep(i*2_000)

proc gitDescribeRefTag*(path: Path, commit: string): string =
  let (lt, status) = exec(GitDescribe, path, ["--tags", commit])
  result = if status == RES_OK: strutils.strip(lt) else: ""

proc collectTaggedVersions*(path: Path): seq[VersionTag] =
  let (outp, status) = exec(GitTags, path, [], Trace)
  if status == RES_OK:
    result = parseTaggedVersions(outp)
  else:
    result = @[]

proc collectFileCommits*(path, file: Path, errorReportLevel: MsgKind = Warning): seq[VersionTag] =
  let (outp, status) = exec(GitLog, path, [$file], Warning)
  if status == RES_OK:
    result = parseTaggedVersions(outp, requireVersions = false)
  else:
    message(errorReportLevel, file, "could not collect file commits at:", $file)

proc versionToCommit*(path: Path, algo: ResolutionAlgorithm; query: VersionInterval): CommitHash =
  let allVersions = collectTaggedVersions(path)
  case algo
  of MinVer:
    result = selectBestCommitMinVer(allVersions, query)
  of SemVer:
    result = selectBestCommitSemVer(allVersions, query)
  of MaxVer:
    result = selectBestCommitMaxVer(allVersions, query)

proc shortToCommit*(path: Path, short: string): string =
  let (cc, status) = exec(GitRevParse, path, [short])
  result = if status == RES_OK: strutils.strip(cc) else: ""

proc listFiles*(path: Path): seq[string] =
  let (outp, status) = exec(GitLsFiles, path, [])
  if status == RES_OK:
    result = outp.splitLines().mapIt(it.strip())
  else:
    result = @[]

proc currentGitCommit*(path: Path, errorReportLevel: MsgKind = Info): CommitHash =
  let (currentCommit, status) = exec(GitCurrentCommit, path, [], errorReportLevel)
  if status == RES_OK:
    return initCommitHash(currentCommit.strip(), FromGitTag)
  else:
    return initCommitHash("", FromNone)

proc checkoutGitCommit*(path: Path, commit: CommitHash, errorReportLevel: MsgKind = Warning): bool =
  let currentCommit = currentGitCommit(path)
  if currentCommit.isFull() and currentCommit == commit:
    return

  let (_, statusB) = exec(GitCheckout, path, [$commit], errorReportLevel)
  if statusB != RES_OK:
    message(errorReportLevel, $path, "could not checkout commit " & $commit)
    result = false
  else:
    debug($path, "updated package to " & $commit)
    result = true

proc checkoutGitCommitFull*(path: Path; commit: string, fullClones: bool;
                            errorReportLevel: MsgKind = Warning): bool =
  var smExtraArgs: seq[string] = @[]
  result = true
  if not fullClones and commit.len == 40:
    smExtraArgs.add "--depth=1"

    let extraArgs =
      if context().dumbProxy: ""
      elif not fullClones: "--update-shallow"
      else: ""
    let (_, status) = exec(GitFetch, path, [extraArgs, "--tags", "origin", commit], errorReportLevel)
    if status != RES_OK:
      message(errorReportLevel, $path, "could not fetch commit " & commit)
      result = false
    else:
      trace($path, "fetched package commit " & commit)
  elif commit.len != 40:
    info($path, "found short commit id; doing full fetch to resolve " & commit)
    let (outp, status) = exec(GitFetch, path, ["--unshallow"])
    if status != RES_OK:
      message(errorReportLevel, $path, "could not fetch: " & outp)
      result = false
    else:
      trace($path, "fetched package updates ")

  let (_, status) = exec(GitCheckout, path, [commit], errorReportLevel)
  if status != RES_OK:
    message(errorReportLevel, $path, "could not checkout commit " & commit)
    result = false
  else:
    trace($path, "updated package to " & commit)

  let (_, subModStatus) = exec(GitSubModUpdate, path, smExtraArgs)
  if subModstatus != RES_OK:
    message(errorReportLevel, $path, "could not update submodules")
    result = false
  else:
    info($path, "updated submodules ")

proc gitPull*(path: Path) =
  let (outp, status) = exec(GitPull, path, [])
  if status != RES_OK:
    debug path, "git pull error: \n" & outp.splitLines().mapIt("\n>>> " & it).join("")
    error(path, "could not 'git pull'")

proc gitTag*(path: Path, tag: string) =
  let (_, status) = exec(GitTag, path, [tag])
  if status != RES_OK:
    error(path, "could not 'git tag " & tag & "'")

proc pushTag*(path: Path, tag: string) =
  let (outp, status) = exec(GitPush, path, [tag])
  if status != RES_OK:
    error(path, "could not 'git push " & tag & "'")
  elif outp.strip() == "Everything up-to-date":
    info(path, "is up-to-date")
  else:
    info(path, "successfully pushed tag: " & tag)

proc incrementTag*(displayName, lastTag: string; field: Natural): string =
  var startPos =
    if lastTag[0] in {'0'..'9'}: 0
    else: 1
  var endPos = lastTag.find('.', startPos)
  if field >= 1:
    for i in 1 .. field:
      if endPos == -1:
        error displayName, "the last tag '" & lastTag & "' is missing . periods"
        return ""
      startPos = endPos + 1
      endPos = lastTag.find('.', startPos)
  if endPos == -1:
    endPos = len(lastTag)
  let patchNumber = parseInt(lastTag[startPos..<endPos])
  lastTag[0..<startPos] & $(patchNumber + 1) & lastTag[endPos..^1]

proc incrementLastTag*(path: Path, field: Natural): string =
  let (ltr, status) = exec(GitLastTaggedRef, path, [])
  echo "incrementLastTag: `$1`" % [ltr]
  if status != RES_OK or ltr == "":
    "v0.0.1" # assuming no tags have been made yet
  else:
    let
      lastTaggedRef = ltr.strip()
      lastTag = gitDescribeRefTag(path, lastTaggedRef)
      currentCommit = exec(GitCurrentCommit, path, [])[0].strip()

    echo "lastTaggedRef: ", lastTaggedRef 
    echo "currentCommit: ", currentCommit 
    if lastTaggedRef == "":
      "v0.0.1" # assuming no tags have been made yet
    elif lastTaggedRef == "" or lastTaggedRef == currentCommit:
      info path, "the current commit '" & currentCommit & "' is already tagged '" & lastTag & "'"
      lastTag
    else:
      incrementTag($path, lastTag, field)

proc needsCommitLoRES_OKup*(commit: string): bool {.inline.} =
  '.' in commit or commit == InvalidCommit

proc isShortCommitHash*(commit: string): bool {.inline.} =
  commit.len >= 4 and commit.len < 40

proc isOutdated*(path: Path): bool =
  ## determine if the given git repo `f` is updateable
  ##

  info path, "checking is package is up to date..."

  # TODO: does --update-shallow fetch tags on a shallow repo?
  let extraArgs =
    if context().dumbProxy: ""
    else: "--update-shallow"
  let (outp, status) = exec(GitFetch, path, [extraArgs, "--tags"])

  if status == RES_OK:
    let (cc, status) = exec(GitLastTaggedRef, path, [])
    let latestVersion = strutils.strip(cc)
    if status == RES_OK and latestVersion.len > 0:
      # see if we're past that commit:
      let (cc, status) = exec(GitCurrentCommit, path, [])
      if status == RES_OK:
        let currentCommit = strutils.strip(cc)
        if currentCommit != latestVersion:
          # checkout the later commit:
          # git merge-base --is-ancestor <commit> <commit>
          let (cc, status) = exec(GitMergeBase, path, [currentCommit, latestVersion])
          let mergeBase = strutils.strip(cc)
          #if mergeBase != latestVersion:
          #  echo f, " I'm at ", currentCommit, " release is at ", latestVersion, " merge base is ", mergeBase
          if status == RES_OK and mergeBase == currentCommit:
            let v = extractVersion gitDescribeRefTag(path, latestVersion)
            if v.len > 0:
              info path, "new version available: " & v
              result = true
  else:
    warn path, "`git fetch` failed: " & outp

proc getRemoteUrl*(path: Path): string =
  let (cc, status) = exec(GitRemoteUrl, path, [])
  if status != RES_OK:
    return ""
  else:
    return cc.strip()

proc updateDir*(path: Path, filter: string) =
  let (remote, _) = osproc.execCmdEx("git remote -v")
  if filter.len == 0 or filter in remote:
    let diff = checkGitDiffStatus(path)
    if diff.len > 0:
      warn($path, "has uncommitted changes; skipped")
    else:
      let (branch, status) = exec(GitCurrentBranch, path, [])
      if branch.strip.len > 0:
        let (output, exitCode) = osproc.execCmdEx("git pull origin " & branch.strip)
        if exitCode != 0:
          error $path, output
        else:
          info($path, "successfully updated")
      else:
        error $path, "could not fetch current branch name"
