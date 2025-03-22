import std/[unittest, os, algorithm, dirs, files, strutils, importutils, terminal, json, jsonutils]
import basic/[context, pkgurls, deptypes, nimblecontext, compiledpatterns, osutils, versions, depgraphtypes]
import basic/[sattypes, versions]

when false:
  from nameresolver import resolvePackage

suite "json serde":

  test "json serde version interval":

    proc p(s: string): VersionInterval =
      var err = false
      result = parseVersionInterval(s, 0, err)
      # assert not err

    let interval = p"1.0.0"
    let jn = toJson(interval)
    var interval2 = VersionInterval()
    interval2.fromJson(jn)
    check interval == interval2

    let query = p">= 1.2 & < 1.4"
    let jn2 = toJson(query)
    var query2 = VersionInterval()
    query2.fromJson(jn2)
    check query == query2

  test "var ids":
    let var1 = VarId(1)
    let jn = toJson(var1)
    var var2 = VarId(0)
    var2.fromJson(jn)
    check var1 == var2

  test "path":
    let path1 = Path("test.nim")
    let jn = toJson(path1)
    var path2: Path
    path2.fromJson(jn)
    check path1 == path2

  test "test version tag and commit hash str":
    let c1 = initCommitHash("24870f48c40da2146ce12ff1e675e6e7b9748355", FromNone)
    let v1 = VersionTag(v: Version"#head", c: c1)

    check $c1 == "24870f48c40da2146ce12ff1e675e6e7b9748355"
    check $v1 == "#head@24870f48"

    let v2 = toVersionTag("#head@24870f48c40da2146ce12ff1e675e6e7b9748355")
    check $v2 == "#head@24870f48"
    check repr(v2) == "#head@24870f48c40da2146ce12ff1e675e6e7b9748355"

    let v3 = toVersionTag("#head@-")
    check v3.v.string == "#head"
    check v3.c.h == ""
    check $v3 == "#head@-"

    let v4 = VersionTag(v: Version"#head", c: initCommitHash("", FromGitTag))
    check v4 == v3

    let jn = toJson(v1)
    var v5 = VersionTag()
    v5.fromJson(jn)
    check v5 == v1
    echo "v5: ", repr(v5)

    let jn2 = toJson(c1)
    var c2 = CommitHash()
    c2.fromJson(jn2)
    check c2 == c1
    echo "c2: ", repr(c2)

    let jn3 = toJson(v3)
    var v6 = VersionTag()
    v6.fromJson(jn3)
    check v6 == v3
    echo "v6: ", repr(v6)

    let jn4 = toJson(v4)
    var v7 = VersionTag()
    v7.fromJson(jn4)
    check v7 == v4
    echo "v7: ", repr(v7)

  test "test empty version tag":
    let v8 = VersionTag()
    echo "v8: ", repr(v8)
    let jn = toJson(v8)

    var v9 = VersionTag()
    v9.fromJson(jn)
    check v9 == v8
    echo "v9: ", repr(v9)
    
  
