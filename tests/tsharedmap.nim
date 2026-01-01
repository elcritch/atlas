import std/unittest

import basic/sharedmap

suite "SharedOrderedTable":
  test "basic operations and snapshots":
    var table: SharedOrderedTable[string, int]
    initSharedOrderedTable(table)
    defer:
      deinitSharedOrderedTable(table)

    table.put("alpha", 1)
    table.put("beta", 2)

    check table.len == 2
    check table.hasKey("alpha")

    var found = false
    let value = table.get("alpha", found)
    check found
    check value == 1

    check table.getOrDefault("missing", -1) == -1

    let keys = table.keysSnapshot()
    let values = table.valuesSnapshot()
    let pairs = table.pairsSnapshot()

    check keys == @["alpha", "beta"]
    check values == @[1, 2]
    check pairs == @[("alpha", 1), ("beta", 2)]

    table.del("alpha")
    check table.len == 1
    check not table.hasKey("alpha")
