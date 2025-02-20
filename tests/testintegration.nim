# Small program that runs the test cases

import std / [strutils, os, osproc, sequtils, strformat, unittest]
import basic/context
import testerutils

proc integrationTest() =
  # Test installation of some "important_packages" which we are sure
  # won't disappear in the near or far future. Turns out `nitter` has
  # quite some dependencies so it suffices:

  exec atlasExe & " --proxy=http://localhost:4242/ --dumbproxy --full --verbosity:trace --keepWorkspace use https://github.com/zedeus/nitter"
  # exec atlasExe & " --verbosity:trace --keepWorkspace use https://github.com/zedeus/nitter"

  sameDirContents("expected", ".")

proc cleanupIntegrationTest() =
  var dirs: seq[string] = @[]
  for k, f in walkDir("."):
    if k == pcDir and dirExists(f / ".git"):
      dirs.add f
  for d in dirs: removeDir d
  removeFile "nim.cfg"
  removeFile "ws_integration.nimble"

withDir "tests/ws_integration":
  try:
    integrationTest()
  finally:
    when not defined(keepTestDirs):
      cleanupIntegrationTest()

# if failures > 0: quit($failures & " failures occurred.")

# Normal: create or remotely cloning repos
# nim c -r   1.80s user 0.71s system 60% cpu 4.178 total
# shims/nim c -r   32.00s user 25.11s system 41% cpu 2:18.60 total
# nim c -r   30.83s user 24.67s system 40% cpu 2:17.17 total

# Local repos:
# nim c -r   1.59s user 0.60s system 88% cpu 2.472 total
# w/integration: nim c -r   23.86s user 18.01s system 71% cpu 58.225 total
# w/integration: nim c -r   32.00s user 25.11s system 41% cpu 1:22.80 total
