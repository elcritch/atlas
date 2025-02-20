import std/[strformat, strutils]

task build, "Build local atlas":
  exec "nim c -d:debug -o:./atlas src/atlas.nim"

task unitTests, "Runs unit tests":
  exec "nim c -d:debug -r tests/unittests.nim"

task tester, "Runs integration tests":
  exec "nim c -d:debug -r tests/tester.nim"

task buildRelease, "Build release":
  exec "nimble install -y sat"
  when defined(macosx):
    let x86Args = "\"-target x86_64-apple-macos11 -arch x86_64 -DARCH=x86_64\""
    exec "nim c -d:release --passC:" & x86args & " --passL:" & x86args & " -o:./atlas_x86_64 src/atlas.nim"
    let armArgs = "\"-target arm64-apple-macos11 -arch arm64 -DARCH=arm64\""
    exec "nim c -d:release --passC:" & armArgs & " --passL:" & armArgs & " -o:./atlas_arm64 src/atlas.nim"
    exec "lipo -create -output atlas atlas_x86_64 atlas_arm64"
    rmFile("atlas_x86_64")
    rmFile("atlas_arm64")
  else:
    let os = getEnv("OS")
    let arch = getEnv("ARCH")
    if os != "" and arch != "":
      if os == "windows":
        exec "nim c -d:release -d:mingw -o:./atlas src/atlas.nim"
      else:
        exec "nim c -d:release --cpu:" & arch & " --os:" & os & " -o:./atlas src/atlas.nim"
    else:
      exec "nim c -d:release -o:./atlas src/atlas.nim"

task testReposSetup, "Setup atlas-tests from a cached zip":
  let version = "0.1.3"
  let repo = "https://github.com/nim-lang/atlas-tests/"
  let file = "atlas-tests.zip"
  let url = fmt"{repo}/releases/download/v{version}/{file}"
  if not dirExists("atlas-tests"):
    echo "Downloading Test Repos zip"
    exec(fmt"curl -L -o {file} {url}")
    echo "Unzipping Test Repos"
    exec(fmt"unzip -o {file}")
  else:
    let actualver =
      if fileExists("atlas-tests/atlas_tests.nimble"):
        readFile("atlas-tests/atlas_tests.nimble").split("=")[^1].replace("\"","").strip()
      else:
        "0.0.0"
    echo "Atlas Tests: got version: ", actualver , " expected: ", version
    if version notin actualver:
      echo fmt"Atlas Tests Outdated; Updating..."
      echo "Downloading Test Repos zip"
      exec(fmt"curl -L -o {file} {url}")
      echo "Deleting Atlas Test Repos"
      exec(fmt"mv atlas-tests atlas-tests-old-{actualver}")
      echo "Unzipping Test Repos"
      exec(fmt"unzip -o {file}")

task runGitHttpServer, "Run test http server":
  testReposSetupTask()
  exec "nim c -r tests/githttpserver.nim atlas-tests/ws_integration atlas-tests/ws_generated"

task test, "Runs all tests":
  testReposSetupTask() # download atlas-tests
  unitTestsTask() # tester runs both
  testerTask()

--path:"$nim"

--path:"../sat/src/"
