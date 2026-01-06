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
  SharedOrderedTable*[K, V] = ref object
    lock: Lock
    data: OrderedTable[K, V]

proc initSharedOrderedTable*[K, V](): SharedOrderedTable[K, V] =
  new(result)
  initLock(result.lock)
  result.data = initOrderedTable[K, V]()

proc ensureInit[K, V](table: var SharedOrderedTable[K, V]) =
  if table.isNil:
    table = initSharedOrderedTable[K, V]()

proc initSharedOrderedTable*[K, V](table: var SharedOrderedTable[K, V]) =
  table = initSharedOrderedTable[K, V]()

proc deinitSharedOrderedTable*[K, V](table: SharedOrderedTable[K, V]) =
  if table.isNil:
    return
  deinitLock(table.lock)

proc len*[K, V](table: SharedOrderedTable[K, V]): int =
  if table.isNil:
    return 0
  withLock table.lock:
    result = table.data.len

proc hasKey*[K, V](table: SharedOrderedTable[K, V]; key: K): bool =
  if table.isNil:
    return false
  withLock table.lock:
    result = key in table.data

proc contains*[K, V](table: SharedOrderedTable[K, V]; key: K): bool =
  result = table.hasKey(key)

proc getOrDefault*[K, V](table: SharedOrderedTable[K, V]; key: K; default: V): V =
  if table.isNil:
    return default
  withLock table.lock:
    result = table.data.getOrDefault(key, default)

proc get*[K, V](table: SharedOrderedTable[K, V]; key: K; found: var bool): V =
  if table.isNil:
    found = false
    return
  withLock table.lock:
    if key in table.data:
      found = true
      result = table.data[key]
    else:
      found = false

proc `[]`*[K, V](table: SharedOrderedTable[K, V]; key: K): V =
  var found = false
  result = table.get(key, found)
  if not found:
    raise newException(KeyError, "key not found")

proc `[]=`*[K, V](table: var SharedOrderedTable[K, V]; key: K; value: V) =
  table.put(key, value)

proc put*[K, V](table: var SharedOrderedTable[K, V]; key: K; value: V) =
  table.ensureInit()
  withLock table.lock:
    table.data[key] = value

proc del*[K, V](table: var SharedOrderedTable[K, V]; key: K) =
  if table.isNil:
    return
  withLock table.lock:
    if key in table.data:
      table.data.del(key)

proc clear*[K, V](table: var SharedOrderedTable[K, V]) =
  if table.isNil:
    return
  withLock table.lock:
    table.data.clear()

proc keysSnapshot*[K, V](table: SharedOrderedTable[K, V]): seq[K] =
  if table.isNil:
    return @[]
  withLock table.lock:
    result = newSeqOfCap[K](table.data.len)
    for key in table.data.keys:
      result.add(key)

proc valuesSnapshot*[K, V](table: SharedOrderedTable[K, V]): seq[V] =
  if table.isNil:
    return @[]
  withLock table.lock:
    result = newSeqOfCap[V](table.data.len)
    for value in table.data.values:
      result.add(value)

proc pairsSnapshot*[K, V](table: SharedOrderedTable[K, V]): seq[(K, V)] =
  if table.isNil:
    return @[]
  withLock table.lock:
    result = newSeqOfCap[(K, V)](table.data.len)
    for key, value in table.data.pairs:
      result.add((key, value))

iterator keys*[K, V](table: SharedOrderedTable[K, V]): K =
  for key in table.keysSnapshot():
    yield key

iterator values*[K, V](table: SharedOrderedTable[K, V]): V =
  for value in table.valuesSnapshot():
    yield value

iterator mvalues*[K, V](table: SharedOrderedTable[K, V]): V =
  for value in table.valuesSnapshot():
    yield value

iterator pairs*[K, V](table: SharedOrderedTable[K, V]): (K, V) =
  for item in table.pairsSnapshot():
    yield item

iterator items*[K, V](table: SharedOrderedTable[K, V]): V =
  for value in table.valuesSnapshot():
    yield value

template withSharedTable*[K, V](table: SharedOrderedTable[K, V]; body: untyped) =
  if not table.isNil:
    withLock table.lock:
      body
