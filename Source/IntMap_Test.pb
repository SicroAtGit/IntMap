
XIncludeFile "IntMap.pbi"

EnableExplicit

#TestKeyMax = 9223372036854775807
#TestKeyMin = -9223372036854775808

Global g_pass = 0
Global g_fail = 0

Procedure AssertEq(got.q, want.q, name$)
  If got = want
    g_pass + 1
    PrintN("[PASS] " + name$ + "  (=" + Str(got) + ")")
  Else
    g_fail + 1
    PrintN("[FAIL] " + name$ + "  got=" + Str(got) + "  want=" + Str(want))
  EndIf
EndProcedure

Procedure AssertStr(got$, want$, name$)
  If got$ = want$
    g_pass + 1
    PrintN("[PASS] " + name$ + "  (" + got$ + ")")
  Else
    g_fail + 1
    PrintN("[FAIL] " + name$ + "  got=[" + got$ + "]  want=[" + want$ + "]")
  EndIf
EndProcedure

; Returns the keys in iteration order as "key1,key2,key3"
Procedure$ IterKeys(*intMap.IntMap::IntMapData)
  Protected result$
  Protected index = IntMap::NextIndex(*intMap, 0)
  
  While index >= 0
    If result$ <> ""
      result$ + ","
    EndIf
    result$ + Str(IntMap::KeyAt(*intMap, index))
    index = IntMap::NextIndex(*intMap, index + 1)
  Wend
  
  ProcedureReturn result$
EndProcedure

CompilerIf #PB_Compiler_ExecutableFormat <> #PB_Compiler_Console
  CompilerError "Compile as console program!"
CompilerEndIf

CompilerIf #PB_Compiler_Debugger = #False
  CompilerError "Enable debugger!"
CompilerEndIf

OpenConsole()
PrintN("=== IntMap test suite ===")

Define *intMap.IntMap::IntMapData = IntMap::New()
If *intMap = 0
  PrintN("IntMap::New(): Error")
  Print("Press Enter to quit...")
  Input()
  CloseConsole()
  End
EndIf

Define i, n, ok, round, removed
Define startSlot, runLength, maxRun, index
Define.q hiKey

PrintN("--- 1) Basic operations ---")

AssertEq(IntMap::Count(*intMap), 0, "New map is empty")
AssertEq(IntMap::Has(*intMap, 12345), #False, "Has() on an empty map")
AssertEq(IntMap::Get(*intMap, 12345), 0, "Get() on an empty map = 0")
AssertEq(IntMap::Put(*intMap, 100, 1), #True, "Put(100) new -> #True")
AssertEq(IntMap::Put(*intMap, 200, 2), #True, "Put(200) new -> #True")
AssertEq(IntMap::Put(*intMap, 300, 3), #True, "Put(300) new -> #True")
AssertEq(IntMap::Count(*intMap), 3, "Count after 3 puts")
AssertEq(IntMap::Get(*intMap, 100), 1, "Get(100)")
AssertEq(IntMap::Get(*intMap, 200), 2, "Get(200)")
AssertEq(IntMap::Get(*intMap, 300), 3, "Get(300)")
AssertEq(IntMap::Has(*intMap, 200), #True, "Has(200) present")
AssertEq(IntMap::Has(*intMap, 999), #False, "Has(999) absent")
AssertEq(IntMap::Put(*intMap, 200, 222), #True, "Put(200) update -> #True")
AssertEq(IntMap::Get(*intMap, 200), 222, "Get(200) after update")
AssertEq(IntMap::Count(*intMap), 3, "Count unchanged after update")

PrintN("--- 2) Key 0 is a fully valid key ---")

AssertEq(IntMap::Has(*intMap, 0), #False, "Has(0) before inserting = #False")
AssertEq(IntMap::Put(*intMap, 0, 555), #True, "Put(key=0) -> #True")
AssertEq(IntMap::Count(*intMap), 4, "Count after Put(0)")
AssertEq(IntMap::Has(*intMap, 0), #True, "Has(0) = #True")
AssertEq(IntMap::Get(*intMap, 0), 555, "Get(0) = 555")
AssertEq(IntMap::Put(*intMap, 0, 666), #True, "Put(0) update -> #True")
AssertEq(IntMap::Get(*intMap, 0), 666, "Get(0) after update")
AssertEq(IntMap::Count(*intMap), 4, "Count unchanged after updating key 0")
IntMap::Remove(*intMap, 0)
AssertEq(IntMap::Has(*intMap, 0), #False, "Has(0) after Remove = #False")
AssertEq(IntMap::Count(*intMap), 3, "Count after Remove(0)")
AssertEq(IntMap::Get(*intMap, 300), 3, "Neighbour intact after Remove(0)")

; Key 0 with value 0
IntMap::Clear(*intMap)
IntMap::Put(*intMap, 0, 0)
AssertEq(IntMap::Has(*intMap, 0), #True, "Has(0) with key=0 and value=0")
AssertEq(IntMap::Count(*intMap), 1, "Count with key=0 and value=0")

; Key 0 within the order and across Compact
IntMap::Clear(*intMap)
IntMap::Put(*intMap, 10, 1)
IntMap::Put(*intMap,  0, 2) ; Key 0 in the middle of the order
IntMap::Put(*intMap, 20, 3)
AssertStr(IterKeys(*intMap), "10,0,20", "Key 0 at its insertion position")
IntMap::Remove(*intMap, 10)
AssertStr(IterKeys(*intMap), "0,20", "Key 0 survives removal of its neighbour")
IntMap::Compact(*intMap)
AssertStr(IterKeys(*intMap), "0,20", "Key 0 survives Compact")
AssertEq(IntMap::Get(*intMap, 0), 2, "Get(0) after Compact")
AssertEq(IntMap::Count(*intMap), 2, "Count after Compact with key 0")

; Negative keys alongside 0
IntMap::Clear(*intMap)
IntMap::Put(*intMap,  0, 10)
IntMap::Put(*intMap, -1, 20)
AssertEq(IntMap::Get(*intMap,  0), 10, "Get(0) alongside -1")
AssertEq(IntMap::Get(*intMap, -1), 20, "Get(-1) alongside 0")

; Key 0 survives repeated growth (the live bitmap must grow along)
IntMap::Clear(*intMap)
For i = 0 To 999
  IntMap::Put(*intMap, i, i + 1) ; Keys 0..999
Next
AssertEq(IntMap::Count(*intMap), 1000, "Count with keys 0..999")
AssertEq(IntMap::Get(*intMap, 0), 1, "Get(0) after repeated growth")
AssertEq(IntMap::Get(*intMap, 999), 1000, "Get(999) after growth")

PrintN("--- 2b) PutNew: Insert only if the key is absent ---")

IntMap::Clear(*intMap)
AssertEq(IntMap::PutNew(*intMap, 5, 50), #True, "PutNew(5) new -> #True")
AssertEq(IntMap::Get(*intMap, 5), 50, "Get(5) after PutNew")
AssertEq(IntMap::PutNew(*intMap, 5, 999), #False, "PutNew(5) again -> #False")
AssertEq(IntMap::Get(*intMap, 5), 50, "Value stays unchanged")
AssertEq(IntMap::Count(*intMap), 1, "Count after duplicate PutNew")

; Key 0 via PutNew as well
AssertEq(IntMap::PutNew(*intMap, 0, 7), #True, "PutNew(key=0) -> #True")
AssertEq(IntMap::Get(*intMap, 0), 7, "Get(0) after PutNew")
AssertEq(IntMap::PutNew(*intMap, 0, 8), #False, "PutNew(0) again -> #False")
AssertEq(IntMap::Get(*intMap, 0), 7, "Value of key 0 stays unchanged")
AssertEq(IntMap::Count(*intMap), 2, "Count with key 0 via PutNew")

; PutNew after Remove -> counts as new again, order at the end
IntMap::Remove(*intMap, 5)
AssertEq(IntMap::PutNew(*intMap, 5, 51), #True, "PutNew(5) after Remove -> #True")
AssertStr(IterKeys(*intMap), "0,5", "Order after PutNew re-insert")

; PutNew across growth
IntMap::Clear(*intMap)
For i = 0 To 999
  IntMap::PutNew(*intMap, i, i + 1)
Next
AssertEq(IntMap::Count(*intMap), 1000, "PutNew: Count after 1000 new keys")
AssertEq(IntMap::PutNew(*intMap, 500, 0), #False, "PutNew: Existing key rejected")
AssertEq(IntMap::Get(*intMap, 500), 501, "PutNew: Value unchanged after rejection")

PrintN("--- 2c) Macros KeyAt / ValueAt ---")

IntMap::Clear(*intMap)
IntMap::Put(*intMap, 111, 11)
IntMap::Put(*intMap,   0, 22) ; Key 0 reachable via the macros too
IntMap::Put(*intMap, 333, 33)
IntMap::Remove(*intMap, 111) ; Hole at the front -> dense index 0 must be skipped
index = IntMap::NextIndex(*intMap, 0)
AssertEq(index, 1, "NextIndex skips the hole")
AssertEq(IntMap::KeyAt(*intMap, index), 0, "KeyAt returns key 0")
AssertEq(IntMap::ValueAt(*intMap, index), 22, "ValueAt returns 22")
index = IntMap::NextIndex(*intMap, index + 1)
AssertEq(IntMap::KeyAt(*intMap, index), 333, "KeyAt at the second entry")
AssertEq(IntMap::ValueAt(*intMap, index), 33, "ValueAt at the second entry")

; After Compact, 0..`Count()`-1 is contiguously valid
IntMap::Compact(*intMap)
AssertEq(IntMap::KeyAt(*intMap, 0), 0, "KeyAt(0) after Compact")
AssertEq(IntMap::ValueAt(*intMap, 0), 22, "ValueAt(0) after Compact")
AssertEq(IntMap::KeyAt(*intMap, 1), 333, "KeyAt(1) after Compact")
AssertEq(IntMap::ValueAt(*intMap, 1), 33, "ValueAt(1) after Compact")

; One past the last entry: iteration must end, not run off the array
AssertEq(IntMap::NextIndex(*intMap, IntMap::Count(*intMap)), -1, "NextIndex past the last entry = -1")

PrintN("--- 3) Insertion order ---")

IntMap::Clear(*intMap)
IntMap::Put(*intMap, 10, 0)
IntMap::Put(*intMap, 20, 0)
IntMap::Put(*intMap, 30, 0)
IntMap::Put(*intMap, 40, 0)
AssertStr(IterKeys(*intMap), "10,20,30,40", "Order after inserting")

IntMap::Remove(*intMap, 20)
AssertEq(IntMap::Count(*intMap), 3, "Count after Remove(20)")
AssertEq(IntMap::Has(*intMap, 20), #False, "20 is gone")
AssertStr(IterKeys(*intMap), "10,30,40", "Order after Remove(20) (hole skipped)")

; Removing a key that is not there must change nothing. Two different paths: 20
; leaves a tombstone the probe has to walk past, 999 was never inserted at all
; and its chain ends on an empty slot right away.
IntMap::Remove(*intMap, 20)
IntMap::Remove(*intMap, 999)
AssertEq(IntMap::Count(*intMap), 3, "Count unchanged after removing an absent key")
AssertStr(IterKeys(*intMap), "10,30,40", "Order unchanged after removing an absent key")

IntMap::Compact(*intMap)
AssertStr(IterKeys(*intMap), "10,30,40", "Order after Compact")
AssertEq(IntMap::Count(*intMap), 3, "Count after Compact")

; Compacting again, this time with no holes left at all -> must be a no-op
IntMap::Compact(*intMap)
AssertStr(IterKeys(*intMap), "10,30,40", "Compact without holes changes nothing")
AssertEq(IntMap::Count(*intMap), 3, "Count after Compact without holes")

; Re-insert at the end (new order)
IntMap::Put(*intMap, 50, 5)
AssertEq(IntMap::Get(*intMap, 50), 5, "Get(50) after re-insert")
AssertStr(IterKeys(*intMap), "10,30,40,50", "Order after re-insert")

PrintN("--- 4) value=0 vs. Has() (ambiguity of Get) ---")

IntMap::Clear(*intMap)
IntMap::Put(*intMap, 777, 0)
AssertEq(IntMap::Get(*intMap, 777), 0, "Get(777) = 0 (a real value)")
AssertEq(IntMap::Has(*intMap, 777), #True, "Has(777) despite value=0")
AssertEq(IntMap::Has(*intMap, 888), #False, "Has(888) absent (Get would also be 0)")

PrintN("--- 5) Negative and very large keys ---")

IntMap::Clear(*intMap)
; Keys are `.q`, so the range is the same on every build and the extreme
; values below are reachable on a 32-bit one too.
IntMap::Put(*intMap, -1, 111)
IntMap::Put(*intMap, -1000000, 222)
IntMap::Put(*intMap, #TestKeyMax, 333)
IntMap::Put(*intMap, #TestKeyMin, 444)
AssertEq(IntMap::Get(*intMap, -1), 111, "Get(-1)")
AssertEq(IntMap::Get(*intMap, -1000000), 222, "Get(-1000000)")
AssertEq(IntMap::Get(*intMap, #TestKeyMax), 333, "Get(largest positive key)")
AssertEq(IntMap::Get(*intMap, #TestKeyMin), 444, "Get(smallest negative key)")
AssertEq(IntMap::Count(*intMap), 4, "Count for negative/large keys")

PrintN("--- 6) Stress: Many aligned keys (exercises hashing + resize) ---")

IntMap::Clear(*intMap)
n = 200000
For i = 1 To n
  IntMap::Put(*intMap, i * 16, i) ; Lower 4 bits = 0
Next
AssertEq(IntMap::Count(*intMap), n, "Count after " + Str(n) + " inserts")

ok = #True
For i = 1 To n
  If IntMap::Get(*intMap, i * 16) <> i
    ok = #False
    Break
  EndIf
Next
AssertEq(ok, #True, "All " + Str(n) + " keys retrievable correctly")
AssertEq(IntMap::Has(*intMap, 7), #False, "Has(7) absent")
AssertEq(IntMap::Has(*intMap, (n + 1) * 16), #False, "Has(n+1) absent")

PrintN("--- 6b) Index distribution (probe runs) ---")

; The 200000 aligned keys from group 6 are still in the map and nothing has been
; removed yet, so every non-zero slot holds a live entry and no tombstone can
; lengthen a run. A working hash spreads the keys over the index; a hash that
; always returned the same slot would still be correct, but would pile every key
; into one run and turn each lookup into a linear scan. The correctness checks
; above cannot see that difference - this one can.
startSlot = 0
While startSlot < *intMap\slotsSize
  If *intMap\slots(startSlot) = 0
    Break ; Start on a free slot, so no run is split
  EndIf
  startSlot + 1
Wend
AssertEq(Bool(startSlot < *intMap\slotsSize), #True, "Index has free slots")

maxRun = 0
runLength = 0
For i = 0 To *intMap\slotsSize - 1
  If *intMap\slots((startSlot + i) & *intMap\mask)
    runLength + 1
    If runLength > maxRun
      maxRun = runLength
    EndIf
  Else
    runLength = 0
  EndIf
Next
AssertEq(Bool(maxRun < 256), #True, "Longest probe run below 256 (was " + Str(maxRun) + ")")

PrintN("--- 6c) Index distribution for keys that differ only in the upper 32 bits ---")

; Keys `i << 32` have all-zero lower halves, so they only spread over the index
; if the hash takes all 64 bits into account. A hash that used the lower 32 bits
; alone would send every key to the same start slot. 2000 keys keep that failure
; fast enough to be reported instead of hanging the run. The key is built in the
; `.q` variable `hiKey`: shifting the `.i` counter itself would overflow on a
; 32-bit build and test something else.
Define.IntMap::IntMapData *hi = IntMap::New()
For i = 1 To 2000
  hiKey = i
  hiKey = hiKey << 32
  IntMap::Put(*hi, hiKey, i)
Next
AssertEq(IntMap::Count(*hi), 2000, "Count after 2000 high keys")

ok = #True
For i = 1 To 2000
  hiKey = i
  hiKey = hiKey << 32
  If IntMap::Get(*hi, hiKey) <> i : ok = #False : Break : EndIf
Next
AssertEq(ok, #True, "All 2000 high keys retrievable")

startSlot = 0
While startSlot < *hi\slotsSize
  If *hi\slots(startSlot) = 0
    Break ; Start on a free slot, so no run is split
  EndIf
  startSlot + 1
Wend
AssertEq(Bool(startSlot < *hi\slotsSize), #True, "Index has free slots (high keys)")

maxRun = 0
runLength = 0
For i = 0 To *hi\slotsSize - 1
  If *hi\slots((startSlot + i) & *hi\mask)
    runLength + 1
    If runLength > maxRun
      maxRun = runLength
    EndIf
  Else
    runLength = 0
  EndIf
Next
AssertEq(Bool(maxRun < 256), #True, "Longest probe run below 256 for high keys (was " + Str(maxRun) + ")")
IntMap::Free(*hi)

PrintN("--- 7) Remove half (tombstones) + Compact ---")

removed = 0
For i = 1 To n
  If (i & 1) = 0 ; Remove the even ones
    IntMap::Remove(*intMap, i * 16)
    removed + 1
  EndIf
Next
AssertEq(IntMap::Count(*intMap), n - removed, "Count after removing half")

ok = #True
For i = 1 To n
  If (i & 1) = 1
    ; Odd: Present
    If IntMap::Get(*intMap, i * 16) <> i
      ok = #False
      Break
    EndIf
  Else
    ; Even: Gone
    If IntMap::Has(*intMap, i * 16)
      ok = #False
      Break
    EndIf
  EndIf
Next
AssertEq(ok, #True, "Odd present, even removed")

IntMap::Compact(*intMap)
AssertEq(IntMap::Count(*intMap), n - removed, "Count after Compact (stress test)")
ok = #True
For i = 1 To n
  If (i & 1) = 1
    If IntMap::Get(*intMap, i * 16) <> i : ok = #False : Break : EndIf
  EndIf
Next
AssertEq(ok, #True, "After Compact: Odd still correct")

PrintN("--- 8) Churn: Alternating insert/delete/update ---")

IntMap::Clear(*intMap)
For i = 0 To 999
  IntMap::Put(*intMap, 1000 + i, i) ; Keys 1000..1999
Next
For round = 1 To 50
  For i = 0 To 499
    IntMap::Remove(*intMap, 1000 + i) ; Take out the first 500 keys
  Next
  For i = 0 To 499
    IntMap::Put(*intMap, 1000 + i, i + round) ; and back in, the value changes.
  Next
Next
AssertEq(IntMap::Count(*intMap), 1000, "Count after churn")
ok = #True
For i = 0 To 499
  If IntMap::Get(*intMap, 1000 + i) <> i + 50 : ok = #False : Break : EndIf
Next
For i = 500 To 999 ; Never touched, so the value is still `i`
  If IntMap::Get(*intMap, 1000 + i) <> i : ok = #False : Break : EndIf
Next
AssertEq(ok, #True, "Churn: All values correct")

PrintN("--- 9) Clear + refill ---")

IntMap::Clear(*intMap)
AssertEq(IntMap::Count(*intMap), 0, "Count after Clear")
AssertEq(IntMap::Has(*intMap, 1000), #False, "Old keys gone after Clear")
IntMap::Put(*intMap, 42, 4242)
AssertEq(IntMap::Get(*intMap, 42), 4242, "Put/Get after Clear")
AssertEq(IntMap::Count(*intMap), 1, "Count after refill")

IntMap::Free(*intMap)

PrintN("--- 9b) Robustness: Zeroed structure without Init()/New() ---")

; Deliberate misuse: Define creates a zeroed structure and `Init()` is
; "forgotten". Expectation: Get/Has harmless, `Put()` initializes lazily; growth
; beyond the initial capacity also works. (Without the lazy-init guard in the
; module this block would corrupt memory when run without the debugger.)
Define.IntMap::IntMapData raw
AssertEq(IntMap::Get(@raw, 5), 0, "Get on a zeroed structure = 0")
AssertEq(IntMap::Has(@raw, 5), #False, "Has on a zeroed structure = #False")
AssertEq(IntMap::Put(@raw, 5, 50), #True, "Put on a zeroed structure (lazy init) -> #True")
For i = 1 To 40 ; Grows beyond the initial capacity of 16
  IntMap::Put(@raw, 100 + i, i)
Next
AssertEq(IntMap::Count(@raw), 41, "Count after lazy init + growth")
AssertEq(IntMap::Get(@raw, 5), 50, "Get(5) after lazy init")
AssertEq(IntMap::Get(@raw, 140), 40, "Get(140) after growth")

PrintN("--- 9c) Automatic compaction instead of doubling ---")

; Covers the branch in `EnsureForInsert()` that compacts instead of doubling
; when there are many holes (`count <= entriesCap/2`). A fresh map with a small
; capacity so the path is definitely hit. Important: the insertion order must
; survive the auto-compact too.
Define.IntMap::IntMapData *ac = IntMap::New(16)
For i = 1 To 16
  IntMap::Put(*ac, i, i) ; Dense array exactly full (used = cap = 16)
Next
For i = 1 To 12
  IntMap::Remove(*ac, i) ; 12 holes, only 13..16 stay live
Next
AssertEq(IntMap::Count(*ac), 4, "Before auto-compact: 4 live entries")
IntMap::Put(*ac, 17, 17) ; Triggers the auto-compact (instead of doubling)
AssertEq(IntMap::Count(*ac), 5, "After auto-compact: Count correct")
AssertEq(IntMap::Get(*ac, 13), 13, "After auto-compact: Get(13)")
AssertEq(IntMap::Get(*ac, 16), 16, "After auto-compact: Get(16)")
AssertEq(IntMap::Get(*ac, 17), 17, "After auto-compact: New key present")
AssertEq(IntMap::Has(*ac, 1), #False, "After auto-compact: Deleted key gone")
AssertStr(IterKeys(*ac), "13,14,15,16,17", "Order survives auto-compact")
IntMap::Free(*ac)

PrintN("--- 9d) Init() on an already used structure ---")

; `Init()` is not only for fresh structures: it also resets a map that is
; already in use. It is the only way to shrink the reserved capacity again -
; `Clear()` deliberately keeps it, and the lazy-init safety net in `Put()` never
; triggers on an initialized structure.
Define.IntMap::IntMapData ri
IntMap::Init(@ri, 16)
For i = 1 To 5000
  IntMap::Put(@ri, i, i)
Next
IntMap::Remove(@ri, 1) ; Leave a hole behind as well
AssertEq(IntMap::Count(@ri), 4999, "Before re-init: 4999 live entries")
AssertEq(Bool(ri\entriesCap >= 5000), #True, "Before re-init: Capacity has grown")

; (a) Re-init with a SMALLER capacity -> the arrays shrink
IntMap::Init(@ri, 16)
AssertEq(IntMap::Count(@ri), 0, "Re-init (shrink): Count reset")
AssertEq(ri\used, 0, "Re-init (shrink): Used reset")
AssertEq(ri\entriesCap, 16, "Re-init (shrink): Capacity back to 16")
AssertEq(IntMap::Has(@ri, 100), #False, "Re-init (shrink): Old keys gone")
AssertEq(IntMap::NextIndex(@ri, 0), -1, "Re-init (shrink): Iteration empty")
IntMap::Put(@ri, 7, 77)
AssertEq(IntMap::Get(@ri, 7), 77, "Re-init (shrink): Usable again")
AssertStr(IterKeys(@ri), "7", "Re-init (shrink): Order starts fresh")

; (b) Re-init with a LARGER capacity -> pre-sizing for a known count
IntMap::Init(@ri, 2048)
AssertEq(ri\entriesCap, 2048, "Re-init (grow): Capacity pre-sized")
AssertEq(IntMap::Count(@ri), 0, "Re-init (grow): Count reset")
AssertEq(IntMap::Has(@ri, 7), #False, "Re-init (grow): Previous key gone")
For i = 1 To 2000
  IntMap::Put(@ri, i * 3, i)
Next
AssertEq(IntMap::Count(@ri), 2000, "Re-init (grow): Refilled")
AssertEq(ri\entriesCap, 2048, "Re-init (grow): No growth step needed")
AssertEq(IntMap::Get(@ri, 3000), 1000, "Re-init (grow): Value correct")

PrintN("================================")
PrintN("RESULT: " + Str(g_pass) + " PASS, " + Str(g_fail) + " FAIL")
If g_fail = 0
  PrintN("ALL TESTS PASSED.")
Else
  PrintN("There were FAILURES -> see the [FAIL] lines above.")
EndIf

PrintN("")
Print("Press Enter to quit...")
Input()
CloseConsole()
