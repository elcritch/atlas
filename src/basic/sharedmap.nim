#
#           Atlas Package Cloner
#        (c) Copyright 2025
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std/[tables]
import locks

type
  SharedOrderedTable*[K, V] = object
    lock: Lock
    data: OrderedTable[K, V]

proc initSharedOrderedTable*[K, V](table: var SharedOrderedTable[K, V]) =
  initLock(table.lock)
  table.data = initOrderedTable[K, V]()

proc deinitSharedOrderedTable*[K, V](table: var SharedOrderedTable[K, V]) =
  deinitLock(table.lock)

proc len*[K, V](table: var SharedOrderedTable[K, V]): int =
  withLock table.lock:
    result = table.data.len

proc hasKey*[K, V](table: var SharedOrderedTable[K, V]; key: K): bool =
  withLock table.lock:
    result = key in table.data

proc getOrDefault*[K, V](table: var SharedOrderedTable[K, V]; key: K; default: V): V =
  withLock table.lock:
    result = table.data.getOrDefault(key, default)

proc get*[K, V](table: var SharedOrderedTable[K, V]; key: K; found: var bool): V =
  withLock table.lock:
    if key in table.data:
      found = true
      result = table.data[key]
    else:
      found = false

proc put*[K, V](table: var SharedOrderedTable[K, V]; key: K; value: V) =
  withLock table.lock:
    table.data[key] = value

proc del*[K, V](table: var SharedOrderedTable[K, V]; key: K) =
  withLock table.lock:
    if key in table.data:
      table.data.del(key)

proc clear*[K, V](table: var SharedOrderedTable[K, V]) =
  withLock table.lock:
    table.data.clear()

proc keysSnapshot*[K, V](table: var SharedOrderedTable[K, V]): seq[K] =
  withLock table.lock:
    result = newSeqOfCap[K](table.data.len)
    for key in table.data.keys:
      result.add(key)

proc valuesSnapshot*[K, V](table: var SharedOrderedTable[K, V]): seq[V] =
  withLock table.lock:
    result = newSeqOfCap[V](table.data.len)
    for value in table.data.values:
      result.add(value)

proc pairsSnapshot*[K, V](table: var SharedOrderedTable[K, V]): seq[(K, V)] =
  withLock table.lock:
    result = newSeqOfCap[(K, V)](table.data.len)
    for key, value in table.data.pairs:
      result.add((key, value))

template withSharedTable*[K, V](table: var SharedOrderedTable[K, V]; body: untyped) =
  withLock table.lock:
    body
