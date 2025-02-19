# Small program that runs the test cases

import std / [strutils, os, osproc, sequtils, strformat, unittest]
import basic/context
import testerutils

ensureGitHttpServer()

template removeDirs() =
  removeDir "does_not_exist"
  removeDir "semproject"
  removeDir "minproject"
  removeDir "source"
  removeDir "proj_a"
  removeDir "proj_b"
  removeDir "proj_c"
  removeDir "proj_d"

proc setupGraph* =
  createDir "buildGraph"
  withDir "buildGraph":

    exec "git clone http://localhost:4242/buildGraph/proj_a"
    exec "git clone http://localhost:4242/buildGraph/proj_b"
    exec "git clone http://localhost:4242/buildGraph/proj_c"
    exec "git clone http://localhost:4242/buildGraph/proj_d"

proc setupGraphNoGitTags* =
  createDir "buildGraphNoGitTags"
  withDir "buildGraphNoGitTags":

    exec "git clone http://localhost:4242/buildGraphNoGitTags/proj_a"
    exec "git clone http://localhost:4242/buildGraphNoGitTags/proj_b"
    exec "git clone http://localhost:4242/buildGraphNoGitTags/proj_c"
    exec "git clone http://localhost:4242/buildGraphNoGitTags/proj_d"

suite "basic repo tests":
  test "tests/ws_testtraverse":
      withDir "tests/ws_testtraverse":
        removeDirs()
        setupGraph()
        let semVerExpectedResult = dedent"""
        [Info] (../resolve) selected:
        [Info] (proj_a) [ ] (proj_a, 1.1.0)
        [Info] (proj_a) [x] (proj_a, 1.0.0)
        [Info] (proj_b) [ ] (proj_b, 1.1.0)
        [Info] (proj_b) [x] (proj_b, 1.0.0)
        [Info] (proj_c) [x] (proj_c, 1.2.0)
        [Info] (proj_d) [ ] (proj_d, 2.0.0)
        [Info] (proj_d) [x] (proj_d, 1.0.0)
        [Info] (../resolve) end of selection
        """

  test "tests/ws_testtraverse":
      withDir "tests/ws_testtraverse":
        removeDirs()
        setupGraphNoGitTags()
        let semVerExpectedResultNoGitTags = dedent"""
        [Info] (../resolve) selected:
        [Info] (proj_a) [ ] (proj_a, #head)
        [Info] (proj_a) [ ] (proj_a, 1.1.0)
        [Info] (proj_a) [x] (proj_a, 1.0.0)
        [Info] (proj_b) [ ] (proj_b, #head)
        [Info] (proj_b) [ ] (proj_b, 1.1.0)
        [Info] (proj_b) [x] (proj_b, 1.0.0)
        [Info] (proj_c) [ ] (proj_c, #head)
        [Info] (proj_c) [x] (proj_c, 1.2.0)
        [Info] (proj_c) [ ] (proj_c, 1.0.0)
        [Info] (proj_d) [ ] (proj_d, #head)
        [Info] (proj_d) [ ] (proj_d, 2.0.0)
        [Info] (proj_d) [x] (proj_d, 1.0.0)
        [Info] (../resolve) end of selection
        """

infoNow "tester", "All tests run successfully"

# if failures > 0: quit($failures & " failures occurred.")

# Normal: create or remotely cloning repos
# nim c -r   1.80s user 0.71s system 60% cpu 4.178 total
# shims/nim c -r   32.00s user 25.11s system 41% cpu 2:18.60 total
# nim c -r   30.83s user 24.67s system 40% cpu 2:17.17 total

# Local repos:
# nim c -r   1.59s user 0.60s system 88% cpu 2.472 total
# w/integration: nim c -r   23.86s user 18.01s system 71% cpu 58.225 total
# w/integration: nim c -r   32.00s user 25.11s system 41% cpu 1:22.80 total
