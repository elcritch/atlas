#
#           Atlas Package Cloner
#        (c) Copyright 2023 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Resolves package names and turn them to URLs.

import std / [os, paths, uri, strutils, osproc]
import basic/[context, gitops, reporters, pkgurls]

proc retryUrl(cmd: string,
              url: Uri;
              displayName: string;
              tryBeforeSleep = true): bool =
  ## Retries a url-based command `cmd` with an increasing delay.
  ## Performs an initial request when `tryBeforeSLeep` is `true`.
  const Pauses = [0, 1000, 2000, 3000, 4000, 6000]
  let firstPause = if tryBeforeSleep: 0 else: 1
  for i in firstPause..<Pauses.len:
    if i > firstPause: infoNow displayName, "Retrying remote URL: " & $url
    os.sleep(Pauses[i])
    if execCmdEx(cmd)[1] == QuitSuccess: return true
  return false

proc cloneUrl*(url: PkgUrl,
               dest: Path;
               cloneUsingHttps: bool): (CloneStatus, string) =
  ## Returns an error message on error or else "".
  assert not dest.string.contains("://")

  var modurl = url.toUri()
  if modurl.scheme == "git":
    if cloneusinghttps:
      modurl.scheme = "https"
    else:
      modurl.scheme = ""

  let isGitHub = modurl.hostname == "github.com"
  if isGitHub and modurl.path.endswith("/"):
    # github + https + trailing url slash causes a
    # checkout/ls-remote to fail with repository not found
    modurl.path = modurl.path.strip(leading=false, trailing=true, {'/'})
  infoNow url.projectName, "Cloning url: " & $modurl

  # Checking repo with git
  let gitCmdStr = "git ls-remote --quiet --tags " & $modurl
  var success = execCmdEx(gitCmdStr)[1] == QuitSuccess
  if not success and isGitHub:
    infoNow url.projectName, "Trying to clone url again: " & $modurl
    # retry multiple times to avoid annoying GitHub timeouts:
    success = retryUrl(gitCmdStr, modurl, url.projectName, false)

  if not success:
    if isGitHub:
      (NotFound, "Unable to identify url: " & $modurl)
    else:
      # Checking repo with Mercurial
      if retryUrl("hg identify " & $modurl, modurl, url.projectName, true):
        (NotFound, "Unable to identify url: " & $modurl)
      else:
        let hgCmdStr = "hg clone " & $modurl & " " & $dest
        if retryUrl(hgCmdStr, modurl, url.projectName, true):
          (Ok, "")
        else:
          (OtherError, "exernal program failed: " & hgCmdStr)
  else:
    if gitops.clone(url.url, dest, fullClones=true): # gitops.clone has buit-in retrying
      (Ok, "")
    else:
      (OtherError, "exernal program failed: " & $GitClone)
