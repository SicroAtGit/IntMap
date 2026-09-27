
XIncludeFile "IntMap.pbi"

EnableExplicit

#BenchKeyCount = 1000000
#BenchSeed     = 20260703 ; fixed seed -> same shuffle order in every run

; Every measurement except Insert runs this many times inside one timed region
; and the total is divided afterwards. With a single pass the fastest figures
; land at 1 to 6 ms, where `ElapsedMilliseconds()` cannot resolve them well
; enough to carry a ratio.
#BenchRepeats = 10

#BenchKeyBase = $100000000

CompilerIf #PB_Compiler_Backend = #PB_Backend_C
  #BenchBackend$ = "C"
CompilerElse
  #BenchBackend$ = "ASM"
CompilerEndIf

CompilerIf #PB_Compiler_Optimizer
  #BenchOptimizer$ = "optimizer enabled"
CompilerElse
  #BenchOptimizer$ = "optimizer disabled"
CompilerEndIf

; `DisableDebugger` is no substitute: the manual states that it does not fully
; turn the debugger off and that performance checks must not rely on it.
CompilerIf #PB_Compiler_Debugger
  CompilerError "Disable debugger!"
CompilerEndIf

Procedure IntMapBytes(*intMap.IntMap::IntMapData)
  Protected bitsPerWord = SizeOf(Integer) * 8
  Protected liveWords = (*intMap\entriesCap + bitsPerWord - 1) / bitsPerWord
  
  ProcedureReturn *intMap\entriesCap * SizeOf(IntMap::IntMapEntry) +
                  *intMap\slotsSize * SizeOf(Long) +
                  liveWords * SizeOf(Integer)
EndProcedure

Procedure ReportTime(name$, milliseconds.q, repeats = 1)
  Protected.d perPass
  If repeats > 1
    perPass = milliseconds ; via `.d`, so the division cannot truncate
    perPass / repeats
    PrintN("    " + LSet(name$, 24) + StrD(perPass, 1) + " ms")
  Else
    PrintN("    " + LSet(name$, 24) + Str(milliseconds) + " ms")
  EndIf
EndProcedure

Procedure ReportMemory(name$, kiB)
  Protected.d mib = kiB
  mib / 1024
  PrintN("    " + LSet(name$, 24) + StrD(mib, 1) + " MiB")
EndProcedure

Procedure CheckSum(name$, got.q, want.q)
  If got = want
    PrintN("    " + LSet(name$, 24) + "checksum ok")
  Else
    PrintN("    " + LSet(name$, 24) + "CHECKSUM WRONG: got=" + Str(got) +
                                      " want=" + Str(want))
  EndIf
EndProcedure

OpenConsole()

Define i, j, repeats
Define.q time, elapsedTime, sum, expectedSum, expectedHalfSum
Define sink$

Define versionMajor = #PB_Compiler_Version / 100
Define versionMinor = #PB_Compiler_Version % 100

PrintN("=== IntMap benchmark ===")
PrintN("PureBasic " + Str(versionMajor) + "." + RSet(Str(versionMinor), 2, "0") +
       "  |  " + #BenchBackend$ + " backend" +
       "  |  " + Str(SizeOf(Integer) * 8) + "-bit" +
       "  |  " + #BenchOptimizer$)
PrintN(Str(#BenchKeyCount) + " keys, 16-byte aligned")
PrintN("")

expectedSum = #BenchKeyCount
expectedSum * (#BenchKeyCount + 1)
expectedSum / 2

; Sum of the odd `i` only (the half that survives the deletion below):
; 1+3+5+... = (n/2)^2 for an even n.
expectedHalfSum = #BenchKeyCount / 2
expectedHalfSum * expectedHalfSum

; The shuffled lookup order is built up front, so shuffling is never part of a
; measurement.
Dim order.q(#BenchKeyCount - 1)
For i = 1 To #BenchKeyCount
  order(i - 1) = #BenchKeyBase + i * 16
Next
RandomSeed(#BenchSeed)
For i = #BenchKeyCount - 1 To 1 Step -1
  j = Random(i)
  Swap order(i), order(j)
Next

PrintN("--- IntMap ---")

Define.IntMap::IntMapData *intMap = IntMap::New(1024)
If *intMap = 0
  PrintN("ABORT: New() returned 0 (allocation failure)")
  Print("Press Enter to quit...") : Input() : CloseConsole() : End
EndIf

; Insert is the one measurement that is not repeated. It is the only operation
; whose first run has to obtain its memory from the operating system; every
; later round would get the just-released blocks handed back and measure a warm
; allocator instead. That hits a map of a million separate nodes far harder than
; one of two large arrays, so repeating it would flatter one candidate over the
; other.
time = ElapsedMilliseconds()
For i = 1 To #BenchKeyCount
  IntMap::Put(*intMap, #BenchKeyBase + i * 16, i)
Next
ReportTime("Insert", ElapsedMilliseconds() - time)

; Read with the map full, before any deletion.
ReportMemory("Memory", IntMapBytes(*intMap) / 1024)

; (a) Lookup in insertion order: the cache-friendly best case
sum = 0
time = ElapsedMilliseconds()
For repeats = 1 To #BenchRepeats
  For i = 1 To #BenchKeyCount
    sum + IntMap::Get(*intMap, #BenchKeyBase + i * 16)
  Next
Next
ReportTime("Lookup (insertion)", ElapsedMilliseconds() - time, #BenchRepeats)
CheckSum("Lookup (insertion)", sum, expectedSum * #BenchRepeats)

; (b) Lookup in random order: the unfavourable case (more cache misses)
sum = 0
time = ElapsedMilliseconds()
For repeats = 1 To #BenchRepeats
  For i = 0 To #BenchKeyCount - 1
    sum + IntMap::Get(*intMap, order(i))
  Next
Next
ReportTime("Lookup (random)", ElapsedMilliseconds() - time, #BenchRepeats)
CheckSum("Lookup (random)", sum, expectedSum * #BenchRepeats)

; Iteration: a sequential scan of the dense array, no hashing involved
sum = 0
time = ElapsedMilliseconds()
For repeats = 1 To #BenchRepeats
  i = IntMap::NextIndex(*intMap, 0)
  While i >= 0
    sum + IntMap::ValueAt(*intMap, i)
    i = IntMap::NextIndex(*intMap, i + 1)
  Wend
Next
ReportTime("Iteration", ElapsedMilliseconds() - time, #BenchRepeats)
CheckSum("Iteration", sum, expectedSum * #BenchRepeats)

; Delete half: the even keys, which leaves holes and tombstones behind. Between
; rounds the map is restored with `Clear()` plus a full refill, outside the
; timed region: `Clear()` keeps entriesCap and slotsSize, and re-inserting in
; the same order rebuilds the identical layout, so every round starts from the
; same state. Re-adding only the deleted keys would not work here - `Put()`
; appends at `used`, which `Remove()` leaves untouched, so the map would grow
; instead of filling its holes.
elapsedTime = 0
For repeats = 1 To #BenchRepeats
  If repeats > 1
    IntMap::Clear(*intMap)
    For i = 1 To #BenchKeyCount
      IntMap::Put(*intMap, #BenchKeyBase + i * 16, i)
    Next
  EndIf
  time = ElapsedMilliseconds()
  For i = 2 To #BenchKeyCount Step 2
    IntMap::Remove(*intMap, #BenchKeyBase + i * 16)
  Next
  elapsedTime + (ElapsedMilliseconds() - time)
Next
ReportTime("Delete half", elapsedTime, #BenchRepeats)

sum = 0
i = IntMap::NextIndex(*intMap, 0)
While i >= 0
  sum + IntMap::ValueAt(*intMap, i)
  i = IntMap::NextIndex(*intMap, i + 1)
Wend
CheckSum("Delete half", sum, expectedHalfSum)

IntMap::Free(*intMap)
PrintN("")

PrintN("--- PureBasic Map (Hex() keys, pre-sized) ---")

; The same workload with the built-in Map. Integer keys have to become strings
; there, so the conversion is part of every figure; the last line of each block
; measures it alone, to be subtracted. `FindMapElement()` is used for the
; lookups because map(key$) would create a missing element instead of reporting
; the miss.
;
; `Hex()` runs first on purpose. The `Str()` block below inherits an allocator
; that already holds the million element nodes this block released, which can
; only make the second block look better. `Hex()` therefore runs under the
; handicap: if it still wins, the win is real and its size is an upper bound
; rather than a flattering one.

NewMap hexMap(#BenchKeyCount)

; Single-pass, for the reason given at the IntMap Insert above.
time = ElapsedMilliseconds()
For i = 1 To #BenchKeyCount
  hexMap(Hex(#BenchKeyBase + i * 16)) = i
Next
ReportTime("Insert", ElapsedMilliseconds() - time)

sum = 0
time = ElapsedMilliseconds()
For repeats = 1 To #BenchRepeats
  For i = 0 To #BenchKeyCount - 1
    If FindMapElement(hexMap(), Hex(order(i)))
      sum + hexMap()
    EndIf
  Next
Next
ReportTime("Lookup (random)", ElapsedMilliseconds() - time, #BenchRepeats)
CheckSum("Lookup (random)", sum, expectedSum * #BenchRepeats)

sum = 0
time = ElapsedMilliseconds()
For repeats = 1 To #BenchRepeats
  ForEach hexMap()
    sum + hexMap()
  Next
Next
ReportTime("Iteration", ElapsedMilliseconds() - time, #BenchRepeats)
CheckSum("Iteration", sum, expectedSum * #BenchRepeats)

; Restored between rounds with `ClearMap()` plus a full refill, outside the
; timed region - the same treatment IntMap gets above. The slot count is fixed
; at `NewMap()` and survives clearing, so every round deletes from a map built
; exactly the way the first one was. Re-adding only the deleted keys would leave
; the odd elements in place and allocate new ones for the even half, which is a
; different structure from round two onwards.
elapsedTime = 0
For repeats = 1 To #BenchRepeats
  If repeats > 1
    ClearMap(hexMap())
    For i = 1 To #BenchKeyCount
      hexMap(Hex(#BenchKeyBase + i * 16)) = i
    Next
  EndIf
  time = ElapsedMilliseconds()
  For i = 2 To #BenchKeyCount Step 2
    DeleteMapElement(hexMap(), Hex(#BenchKeyBase + i * 16))
  Next
  elapsedTime + (ElapsedMilliseconds() - time)
Next
ReportTime("Delete half", elapsedTime, #BenchRepeats)

sum = 0
ForEach hexMap()
  sum + hexMap()
Next
CheckSum("Delete half", sum, expectedHalfSum)

time = ElapsedMilliseconds()
For repeats = 1 To #BenchRepeats
  For i = 1 To #BenchKeyCount
    sink$ = Hex(#BenchKeyBase + i * 16)
  Next
Next
ReportTime("Hex() alone", ElapsedMilliseconds() - time, #BenchRepeats)

ClearMap(hexMap())
PrintN("")

PrintN("--- PureBasic Map (Str() keys, pre-sized) ---")

; The obvious way to turn an integer into a map key, measured so that the choice
; of `Hex()` above is a result rather than an assertion. Two things differ:
; `Str()` divides where `Hex()` shifts and masks, and over this key range it
; produces one character more to hash and to store. The gap between the two
; "alone" lines separates those effects - what the conversion costs, and what
; the extra character costs.

NewMap strMap(#BenchKeyCount)

; Single-pass, for the reason given at the IntMap Insert above.
time = ElapsedMilliseconds()
For i = 1 To #BenchKeyCount
  strMap(Str(#BenchKeyBase + i * 16)) = i
Next
ReportTime("Insert", ElapsedMilliseconds() - time)

sum = 0
time = ElapsedMilliseconds()
For repeats = 1 To #BenchRepeats
  For i = 0 To #BenchKeyCount - 1
    If FindMapElement(strMap(), Str(order(i)))
      sum + strMap()
    EndIf
  Next
Next
ReportTime("Lookup (random)", ElapsedMilliseconds() - time, #BenchRepeats)
CheckSum("Lookup (random)", sum, expectedSum * #BenchRepeats)

sum = 0
time = ElapsedMilliseconds()
For repeats = 1 To #BenchRepeats
  ForEach strMap()
    sum + strMap()
  Next
Next
ReportTime("Iteration", ElapsedMilliseconds() - time, #BenchRepeats)
CheckSum("Iteration", sum, expectedSum * #BenchRepeats)

; Restored between rounds with `ClearMap()` plus a full refill, outside the
; timed region - the same treatment IntMap gets above. The slot count is fixed
; at `NewMap()` and survives clearing, so every round deletes from a map built
; exactly the way the first one was. Re-adding only the deleted keys would leave
; the odd elements in place and allocate new ones for the even half, which is a
; different structure from round two onwards.
elapsedTime = 0
For repeats = 1 To #BenchRepeats
  If repeats > 1
    ClearMap(strMap())
    For i = 1 To #BenchKeyCount
      strMap(Str(#BenchKeyBase + i * 16)) = i
    Next
  EndIf
  time = ElapsedMilliseconds()
  For i = 2 To #BenchKeyCount Step 2
    DeleteMapElement(strMap(), Str(#BenchKeyBase + i * 16))
  Next
  elapsedTime + (ElapsedMilliseconds() - time)
Next
ReportTime("Delete half", elapsedTime, #BenchRepeats)

sum = 0
ForEach strMap()
  sum + strMap()
Next
CheckSum("Delete half", sum, expectedHalfSum)

time = ElapsedMilliseconds()
For repeats = 1 To #BenchRepeats
  For i = 1 To #BenchKeyCount
    sink$ = Str(#BenchKeyBase + i * 16)
  Next
Next
ReportTime("Str() alone", ElapsedMilliseconds() - time, #BenchRepeats)

ClearMap(strMap())

PrintN("================================")
PrintN("Done. Run this again with the other backend for the full picture.")
PrintN("")
Print("Press Enter to quit...")
Input()
CloseConsole()
