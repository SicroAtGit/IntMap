# IntMap

https://github.com/SicroAtGit/IntMap

## About

`IntMap` is a hash map with integer keys that additionally preserves the insertion order. When iterating, the entries come back in exactly the order in which they were inserted — unlike a classic hash map (unordered) or a tree (sorted by key).

The module is built on two cooperating arrays: a dense array holding the actual key/value pairs in insertion order, and a sparse index array that only maps a key's hash to a position in the dense array. Iteration walks the dense array directly, which keeps the memory access sequential and cache-friendly; lookups only probe the index. This is the "compact dictionary" architecture (see [Design and Acknowledgments](#design-and-acknowledgments)).

## Requirements

Developed and tested with PureBasic 6.41 on Linux x64, with both the ASM and the C backend, and with the 32-bit compiler via Wine, where the test suite passes as well and behaves identically. Only core PureBasic features are used, so other platforms should work, but they have not been tested.

## Performance

Measured with `IntMap_Benchmark.pb`: 1,000,000 keys, PureBasic 6.41, Linux x64 on an AMD Ryzen 9 5900X with DDR4-3200, optimizer enabled, debugger disabled, compiled as a console program. The keys are 16-byte aligned, which is the unfavourable case a naive hash would stumble over (see [Hashing](#hashing)) and the shape real memory addresses have.

| Operation | ASM backend | C backend |
| --------- | ----------- | --------- |
| Insert | 43 ms | 16 ms |
| Lookup, insertion order | 17.1 ms | 3.0 ms |
| Lookup, random order | 25.6 ms | 7.7 ms |
| Iteration | 4.5 ms | 0.6 ms |
| Delete half (500k keys) | 9.4 ms | 3.5 ms |

The C backend is worth between roughly three and eight times the speed here, so the column that matters is the one for the backend you actually compile with. Every figure except Insert is averaged over ten passes, which is why they carry a decimal.

For comparison, the same workload with PureBasic's built-in `Map`, pre-sized with `NewMap m.i(1000000)`. Integer keys have to become strings there, and the benchmark runs both `Hex()` and `Str()` keys, so that the faster of the two is a measured result and not a claim. That way the `Map` is compared in its faster form, and whatever gap remains belongs to the map rather than to the key conversion. ASM backend:

| Operation | IntMap | PB `Map`, `Hex()` keys | PB `Map`, `Str()` keys |
| --------- | ------ | ---------------------- | ---------------------- |
| Insert | 43 ms | 108 ms | 112 ms |
| Lookup, random order | 25.6 ms | 243.9 ms | 313.8 ms |
| Iteration | 4.5 ms | 13.1 ms | 17.1 ms |
| Delete half (500k keys) | 9.4 ms | 41.5 ms | 71.5 ms |
| Key conversion alone | — | 18.1 ms | 19.9 ms |

The last row is why both key forms are listed: `Str()` costs only 1.8 ms more to convert than `Hex()`, yet its random lookup is 70 ms slower and even iteration, which converts nothing, is 4 ms slower. The difference is the extra character that is hashed, compared and stored with every element, not the conversion.

The table uses the ASM backend because that is the narrower margin. The `Map` lives in PureBasic's precompiled runtime library and barely changes with the backend (under 4 %), while `IntMap` is recompiled, so on the C backend the factor for random lookups grows from about 9.5 to about 31.7.

These factors depend on the hardware. A single thread on the 5900X uses one half of its L3 cache, 32 MiB, which holds the 24.1 MiB map but not the `Map`'s million separately allocated nodes, whose lookups therefore wait on main memory. With less cache per core, `IntMap` reaches main memory too: the order of the results holds, but the factor shrinks.

`IntMap_Benchmark.pb` reproduces every figure in both tables; compile it once with each backend. Its comments explain the repetitions and why Insert is measured only once.

The memory figure is computed from the map structure rather than measured, so it is exact: 24.1 MiB for 1,000,000 entries (16 MiB dense array, 8 MiB index, 0.12 MiB live bitmap), independent of backend and integer width. There is no counterpart for the `Map`, whose separately allocated nodes could only be estimated.

## Examples

### Basic Usage

```purebasic
*intMap.IntMap::IntMapData = IntMap::New()
If *intMap
  IntMap::Put(*intMap, 1000, 42)
  IntMap::Put(*intMap, 2000, 84)

  If IntMap::Has(*intMap, 1000)
    Debug "Value: " + Str(IntMap::Get(*intMap, 1000))
  EndIf

  Debug "Count: " + Str(IntMap::Count(*intMap))
  IntMap::Free(*intMap)
Else
  Debug "Error!"
EndIf
```

### Iteration in Insertion Order

```purebasic
*intMap.IntMap::IntMapData = IntMap::New()
If *intMap
  IntMap::Put(*intMap, 30, 3)
  IntMap::Put(*intMap, 10, 1)
  IntMap::Put(*intMap, 20, 2)
  IntMap::Remove(*intMap, 10)

  index = IntMap::NextIndex(*intMap, 0)
  While index >= 0
    Debug Str(IntMap::KeyAt(*intMap, index)) + " = " + Str(IntMap::ValueAt(*intMap, index))
    index = IntMap::NextIndex(*intMap, index + 1)
  Wend
  ; Output: 30 = 3, then 20 = 2 (the deleted entry is skipped)

  IntMap::Free(*intMap)
Else
  Debug "Error!"
EndIf
```

If you iterate frequently, call `Compact()` once and then loop directly over `0` to `Count() - 1` without any check — after compacting there are no holes left.

### Using the Map as a Set

`PutNew()` inserts only if the key is absent and reports whether the key was new, which answers "have I seen this before?" in a single probe instead of a `Has()` plus `Put()` pair:

```purebasic
*seen.IntMap::IntMapData = IntMap::New()
If *seen
  If IntMap::PutNew(*seen, 1000, 0)
    Debug "New number"
  Else
    Debug "Already known"
  EndIf
  IntMap::Free(*seen)
Else
  Debug "Error!"
EndIf
```

### Strings and Structures as Values

```purebasic
Structure ItemStruc
  text$
EndStructure

*intMap.IntMap::IntMapData = IntMap::New()
If *intMap
  *item.ItemStruc = AllocateStructure(ItemStruc)
  If *item
    *item\text$ = "Hello"
    IntMap::Put(*intMap, 1000, *item)
  EndIf

  *item = IntMap::Get(*intMap, 1000)
  If *item
    Debug *item\text$
  EndIf

  ; The map owns its three arrays, never what a value points at. Release the
  ; items before the map itself, while the addresses are still reachable.
  index = IntMap::NextIndex(*intMap, 0)
  While index >= 0
    FreeStructure(IntMap::ValueAt(*intMap, index))
    index = IntMap::NextIndex(*intMap, index + 1)
  Wend
  IntMap::Free(*intMap)
Else
  Debug "Error!"
EndIf
```

The same pattern covers any structure, which is how a map of objects is built. PureBasic's own `Map` can declare the value type directly (`NewMap items.ItemStruc()`) because the compiler generates a map per type; a module cannot do that, so the address takes its place.

### Embedding the Structure

Instead of `New()` and `Free()`, an `IntMapData` structure can be embedded in your own structure, initialized with `Init()` and released with `ClearStructure()`:

```purebasic
Structure MyDataStruc
  someField.i
  someIntMap.IntMap::IntMapData
EndStructure

Define myData.MyDataStruc
IntMap::Init(@myData\someIntMap, 1024)
IntMap::Put(@myData\someIntMap, 1000, 42)

ClearStructure(@myData\someIntMap, IntMap::IntMapData)
```

## Public Constants

```purebasic
#ModuleVersion$ ; SemVer 2.0 specification
```

## Public Structures

```purebasic
Structure IntMapEntry
  key.q   ; The key (every integer value is allowed, including 0)
  value.q ; The associated value
EndStructure
```

```purebasic
Structure IntMapData
  Array slots.l(0)             ; Hash index (`.l` = 32 bits saves memory):
                               ;   0 = empty, -1 = tombstone,
                               ;   else denseIndex + 1
  Array entries.IntMapEntry(0) ; Dense array; insertion order
  Array liveBits.i(0)          ; One bit per dense slot: 1 = live, 0 = hole
  mask.i                       ; `slotsSize` - 1 (power-of-two mask)
  shift.i                      ; 64 - log2(`slotsSize`)
  slotsSize.i                  ; Size of the index array (power of two)
  entriesCap.i                 ; Capacity of the dense array (power of two)
  used.i                       ; Next free dense slot (live entries + holes)
  count.i                      ; Number of live entries
  indexTombstones.i            ; Number of tombstones in the index
EndStructure
```

`IntMapData` is public so that a map can be embedded in your own structure, but its fields are not meant to be read directly: use the `KeyAt()` and `ValueAt()` macros below instead of reaching into `entries`, and `Count()` and `NextIndex()` instead of the bookkeeping fields.

## Public Macros

- **`KeyAt(_map_, _index_)`**<br><br>
Returns the key stored at a dense index, as returned by `NextIndex()`.

- **`ValueAt(_map_, _index_)`**<br><br>
Returns the value stored at a dense index. Being a macro, it can also be assigned to, which is how a value is updated in place during iteration: `IntMap::ValueAt(*intMap, index) = newValue`.

Both are macros rather than functions on purpose: they are plain text substitution and therefore cost nothing in the iteration loop, which is the module's fastest path. Neither performs any check: the index must come from `NextIndex()`, or from the range `0` to `Count() - 1` after a `Compact()`.

## Public Functions

- **`New(initialCapacity = 16)`**<br><br>
Allocates a new map on the heap, initializes it and returns the pointer to the `IntMapData` structure. If an error occurred null is returned. If the final number of entries is known in advance, passing it as `initialCapacity` avoids repeated growth steps and the transient memory peak of the last doubling. The counterpart is `Free()`.

- **`Init(*intMap.IntMapData, initialCapacity = 16)`**<br><br>
Initializes an already existing `IntMapData` structure, for maps embedded in your own structures rather than allocated with `New()`. `initialCapacity` is rounded up to the next power of two. Structures initialized this way must not be released with `Free()`. Calling it on a map that is already in use resets it, which is also the only way to shrink the reserved capacity again - `Clear()` deliberately keeps it. Note that `Put()` initializing a zeroed structure by itself is a safety net for a forgotten call, not a replacement: it only recognizes an all-zero structure, and it never triggers for `Get()`, `Has()` or `Remove()`.

- **`Free(*intMap.IntMapData)`**<br><br>
Frees a map created with `New()`, including its internal arrays. NOT for structures initialized with `Init()`.

- **`Clear(*intMap.IntMapData)`**<br><br>
Empties the map. The already reserved memory is kept, which makes this cheap when the map is refilled immediately afterwards.

- **`Put(*intMap.IntMapData, key.q, value.q)`**<br><br>
Inserts the key/value pair, or updates the value if the key already exists. Every integer is allowed as a key, including `0` and negative values. On success `#True` is returned; `#False` only if the capacity limit has been reached. The return value may be ignored.

- **`PutNew(*intMap.IntMapData, key.q, value.q)`**<br><br>
Inserts the key/value pair ONLY if the key does not exist yet; an existing entry is left untouched. Returns `#True` if the entry was newly inserted, `#False` if the key already existed or the capacity limit has been reached. This saves the otherwise necessary `Has()` plus `Put()` pair, because a single probe answers both questions. Useful for sets, where "was not in there yet" is the payload information.

- **`Get(*intMap.IntMapData, key.q)`**<br><br>
Returns the value stored under the key, or `0` if the key does not exist. Since `0` is also a legitimate value, use `Has()` when the difference matters.

- **`Has(*intMap.IntMapData, key.q)`**<br><br>
Returns `#True` if the key exists, otherwise `#False`.

- **`Remove(*intMap.IntMapData, key.q)`**<br><br>
Removes the key. Deletion is lazy: nothing is moved, so all remaining entries keep their positions and therefore the insertion order. The freed slot is reclaimed later, in bulk (see [Deletion Behaviour](#deletion-behaviour)).

- **`Count(*intMap.IntMapData)`**<br><br>
Returns the number of live entries, not counting holes left by `Remove()`.

- **`Compact(*intMap.IntMapData)`**<br><br>
Removes the holes from the dense array while preserving the insertion order, and rebuilds the index. After this call the dense indices `0` to `Count() - 1` are all live, which allows iterating without any liveness check.

- **`NextIndex(*intMap.IntMapData, fromIndex)`**<br><br>
Returns the next live dense index greater than or equal to `fromIndex`, or `-1` at the end. Holes left by `Remove()` are skipped; `fromIndex` must not be negative.

## Deletion Behaviour

`Remove()` marks the dense slot as a hole and the index slot as a tombstone, and does not decrease `used`. Cleanup happens automatically at the next growth step, and the map cannot bloat in the process: the dense array is only doubled while more than half of the slots are live, otherwise it is compacted in place without allocating new memory. Consequently `entriesCap < 4 * count` holds at every growth step, so the overhead is bounded.

The one case that needs attention is a mass deletion with no subsequent inserts: the holes then stay until something triggers cleanup, which lengthens the probe chains and makes iteration skip over holes. Calling `Compact()` once resolves it.

Like most hash maps, it does not shrink its reserved capacity on its own: `Init()` resets it, and the memory is returned by `Free()`, or by `ClearStructure()` for an embedded map.

## Hashing

The module uses Fibonacci hashing: the key is multiplied by 2<sup>64</sup> divided by the golden ratio, and the upper bits of the product are taken as the starting slot. The multiplication moves the well-mixed information into the high bits; masking the low bits of the key directly would cluster badly for aligned memory addresses, whose low bits are always zero. Aligned pointers are therefore a natural key type rather than a problem case: the index is drawn from the bits that vary. Collisions are resolved by linear probing, and the index load is kept below 75 % so that an empty slot always exists and every probe loop terminates.

## Notes and Limitations

- **Keys:** every integer is valid, including `0` and negative values. Liveness is tracked in a separate bitmap rather than by a reserved key value. Keys and values are `.q`, so the range is the full 64 bits on either build.
- **Capacity:** the index slots are 32-bit and store `denseIndex + 1`, which limits a map to `$7FFFFFFF` entries. `Put()` and `PutNew()` refuse beyond that instead of overflowing silently. The limit cannot be reached on a 32-bit build; on a 64-bit build it takes at least 48 GiB of memory, 32 GiB for the dense array and 16 GiB for the index.
- **Initialization:** the correct way is `New()` or `Init()`. As a safety net, `Put()` initializes a zeroed structure on the first insert (for example after a `Define` with a forgotten `Init()`), and `Get()`, `Has()` and `Remove()` on a zeroed structure are harmless. The safety net only recognizes an `IntMapData` structure that is entirely zero, not one whose memory still holds old data.
- **Thread safety:** none built in. Several threads may use `IntMap`, each with its own map or taking turns on a shared one, but never two threads on the same map at the same time; guard a shared map with a mutex.
- **Not cryptographic:** the hash is not hardened against deliberately constructed collisions, so it is not suitable for attacker-controlled keys.

## Tests

`IntMap_Test.pb` contains a self-checking test suite with 131 assertions across sixteen groups, covering the basic operations, key `0`, `PutNew()`, the `KeyAt()`/`ValueAt()` macros, insertion order across deletion and compaction, calls that should do nothing at all, negative and very large keys, a 200,000-key stress test, the spread of those keys over the index and of keys that differ only in their upper 32 bits, tombstone handling, insert/delete churn, the lazy-init safety net, automatic compaction, and re-initialization of a map already in use.

Compile it as a console program with the debugger enabled; the file refuses to build otherwise. Each assertion reports `[PASS]` or `[FAIL]` with the expected and actual value, and the run ends with a summary. The module switches the debugger off for its own code, because it would slow the map down considerably; what it checks are the suite's own accesses, including the direct index reads of the distribution groups and every `KeyAt()`/`ValueAt()` expansion. The suite measures nothing, so the instrumentation cannot falsify a result.

Nothing in the module depends on the PureBasic version, but the two files are worth running after a compiler update or on a platform that has not been tested yet.

## Design and Acknowledgments

The following credits the ideas the implementation rests on. This is courtesy, not a licensing obligation — the module is an independent implementation and not a translation or port of foreign code.

- **Compact/ordered dictionary design** (dense array plus index table): Raymond Hettinger, ["More compact dictionaries with faster iteration"][Hettinger], python-dev, 2012-12-10; implemented in CPython (since 3.6) and PyPy. Note that the post targets memory savings and faster iteration — insertion order is not its goal and is not mentioned there. For holes left by deletion it sketches a swap, which this module deliberately avoids because it would destroy the ordering; it compacts order-preservingly instead. CPython also marks holes through the entry itself, which is unproblematic there because its keys are object pointers and `NULL` is never a valid key; this module stores raw integers, so it uses a separate live bitmap to keep every key value valid.
- **Multiplicative / Fibonacci hashing:** the method goes back to D. E. Knuth, *The Art of Computer Programming*, Vol. 3; the implementation here follows Malte Skarupke, ["Fibonacci Hashing: The Optimization that the World Forgot"][Skarupke] (2018).

## License

The project is licensed under the [MIT license].

<!--------------------------------------------------------------------------->

[Hettinger]: https://mail.python.org/pipermail/python-dev/2012-December/123028.html "python-dev: More compact dictionaries with faster iteration"
[Skarupke]: https://probablydance.com/2018/06/16/fibonacci-hashing-the-optimization-that-the-world-forgot-or-a-better-alternative-to-integer-modulo/ "Fibonacci Hashing: The Optimization that the World Forgot"

[MIT license]: ./LICENSE
