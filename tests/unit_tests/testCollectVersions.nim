
import std/unittest
import std/strutils
import std/os
import std/tempfiles
import std/options

import ../setups

import depgraphs

suite "test pkgurls":

  test "basic url":
    withTempTestDir "basic_url":
      buildGraph()

