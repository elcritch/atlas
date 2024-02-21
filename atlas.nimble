# Package
version = "0.8.0"
author = "Araq"
description = "Atlas is a simple package cloner tool. It manages an isolated workspace."
license = "MIT"
srcDir = "src"
skipDirs = @["doc"]
bin = @["atlas"]
installFiles  = @["build.nims"]

# Dependencies
requires "nim >= 2.0.0"

include "build.nims"