
DeclareModule IntMap
  
  EnableExplicit
  
  #ModuleVersion$ = "1.0.0-beta.1" ; SemVer 2.0 specification
  
  Structure IntMapEntry
    key.q   ; The key (every integer value is allowed, including 0)
    value.q ; The associated value
  EndStructure
  
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
  
  ; Returns the key stored at a dense index, as returned by `NextIndex()`.
  Macro KeyAt(_map_, _index_)
    _map_\entries(_index_)\key
  EndMacro
  
  ; Returns the value stored at a dense index. Being a macro, it can also be
  ; assigned to, which is how a value is updated in place during iteration:
  ; `IntMap::ValueAt(*intMap, index) = newValue`.
  Macro ValueAt(_map_, _index_)
    _map_\entries(_index_)\value
  EndMacro
  
  ; Both are macros rather than functions on purpose: they are plain text
  ; substitution and therefore cost nothing in the iteration loop, which is the
  ; module's fastest path. Neither performs any check: the index must come from
  ; `NextIndex()`, or from the range `0` to `Count() - 1` after a `Compact()`.
  
  ; Initializes an already existing `IntMapData` structure, for maps embedded in
  ; your own structures rather than allocated with `New()`. `initialCapacity` is
  ; rounded up to the next power of two. Structures initialized this way must
  ; not be released with `Free()`. Calling it on a map that is already in use
  ; resets it, which is also the only way to shrink the reserved capacity again
  ; - `Clear()` deliberately keeps it. Note that `Put()` initializing a zeroed
  ; structure by itself is a safety net for a forgotten call, not a replacement:
  ; it only recognizes an all-zero structure, and it never triggers for `Get()`,
  ; `Has()` or `Remove()`.
  Declare Init(*intMap.IntMapData, initialCapacity = 16)
  
  ; Allocates a new map on the heap, initializes it and returns the pointer to
  ; the `IntMapData` structure. If an error occurred null is returned. If the
  ; final number of entries is known in advance, passing it as `initialCapacity`
  ; avoids repeated growth steps and the transient memory peak of the last
  ; doubling. The counterpart is `Free()`.
  Declare New(initialCapacity = 16)
  
  ; Frees a map created with `New()`, including its internal arrays. NOT for
  ; structures initialized with `Init()`.
  Declare Free(*intMap.IntMapData)
  
  ; Empties the map. The already reserved memory is kept, which makes this cheap
  ; when the map is refilled immediately afterwards.
  Declare Clear(*intMap.IntMapData)
  
  ; Inserts the key/value pair, or updates the value if the key already exists.
  ; Every integer is allowed as a key, including `0` and negative values. On
  ; success `#True` is returned; `#False` only if the capacity limit has been
  ; reached. The return value may be ignored.
  Declare Put(*intMap.IntMapData, key.q, value.q)
  
  ; Inserts the key/value pair ONLY if the key does not exist yet; an existing
  ; entry is left untouched. Returns `#True` if the entry was newly inserted,
  ; `#False` if the key already existed or the capacity limit has been reached.
  ; This saves the otherwise necessary `Has()` plus `Put()` pair, because a
  ; single probe answers both questions. Useful for sets, where "was not in
  ; there yet" is the payload information.
  Declare PutNew(*intMap.IntMapData, key.q, value.q)
  
  ; Returns the value stored under the key, or `0` if the key does not exist.
  ; Since `0` is also a legitimate value, use `Has()` when the difference
  ; matters.
  Declare.q Get(*intMap.IntMapData, key.q)
  
  ; Returns `#True` if the key exists, otherwise `#False`.
  Declare Has(*intMap.IntMapData, key.q)
  
  ; Removes the key. Deletion is lazy: nothing is moved, so all remaining
  ; entries keep their positions and therefore the insertion order. The freed
  ; slot is reclaimed later, in bulk (see [Deletion
  ; Behaviour](#deletion-behaviour)).
  Declare Remove(*intMap.IntMapData, key.q)
  
  ; Returns the number of live entries, not counting holes left by `Remove()`.
  Declare Count(*intMap.IntMapData)
  
  ; Removes the holes from the dense array while preserving the insertion order,
  ; and rebuilds the index. After this call the dense indices `0` to
  ; `Count() - 1` are all live, which allows iterating without any liveness
  ; check.
  Declare Compact(*intMap.IntMapData)
  
  ; Returns the next live dense index greater than or equal to `fromIndex`, or
  ; `-1` at the end. Holes left by `Remove()` are skipped; `fromIndex` must not
  ; be negative.
  Declare NextIndex(*intMap.IntMapData, fromIndex)
  
EndDeclareModule

Module IntMap
  
  ; Invariants (always hold):
  ;   - `slotsSize` and `entriesCap` are always powers of two.
  ;   - `mask` = `slotsSize` - 1           (fast "modulo `slotsSize`")
  ;   - `shift` = 64 - log2(`slotsSize`)   (to take the upper hash bits)
  ;   - `liveBits` bit of `d` = 1 means: dense slot `d` is live; 0 = hole.
  ;   - No index slot ever points at a hole: `Remove()` turns that slot into
  ;     a tombstone in the same step. That is why `Get()`, `Has()` and the
  ;     probe loops need no liveness check.
  ;   - `used` = next free dense position = live entries + holes.
  ;   - `count` = number of live entries (holes excluded).
  ;   - The index load (`count` + tombstones) is always kept below 75%, so an
  ;     empty slot always exists and every probe loop terminates.
  
  ; In debug mode the IntMap quickly becomes very slow.
  DisableDebugger
  
  ; Maximum number of dense slots: the index slots are `.l` (32-bit signed) and
  ; store denseIndex + 1; the largest representable value is $7FFFFFFF. `Put()`
  ; refuses beyond that (see below).
  #IntMap_MaxEntries = $7FFFFFFF
  
  ; Fibonacci hash constant: 2^64 / golden ratio (odd -> the multiplication is a
  ; bijection mod 2^64).
  #IntMap_HashMul = $9E3779B97F4A7C15
  
  ; Live bitmap: one bit per dense slot (1 = live, 0 = hole). A bit instead of a
  ; reserved key value is what makes every key valid. Word width follows
  ; `SizeOf(Integer)` so the shifts stay native.
  CompilerIf #PB_Compiler_32Bit
    #IntMap_WordShift = 5 ; 32 bits per `.i` word
    #IntMap_WordMask  = 31
  CompilerElse
    #IntMap_WordShift = 6 ; 64 bits per `.i` word
    #IntMap_WordMask  = 63
  CompilerEndIf
  
  Macro IntMap_WordsFor(cap)
    (((cap) + #IntMap_WordMask) >> #IntMap_WordShift)
  EndMacro
  
  Macro IntMap_SetLive(mp, d)
    mp\liveBits((d) >> #IntMap_WordShift) | (1 << ((d) & #IntMap_WordMask))
  EndMacro
  
  Macro IntMap_ClearLive(mp, d)
    mp\liveBits((d) >> #IntMap_WordShift) & ~(1 << ((d) & #IntMap_WordMask))
  EndMacro
  
  Macro IntMap_IsLive(mp, d)
    (mp\liveBits((d) >> #IntMap_WordShift) >> ((d) & #IntMap_WordMask)) & 1
  EndMacro
  
  ; Starting slot of the probe chain. `hVar` is a `.q` scratch variable of the
  ; caller - `shift` reaches up to 63, so the product must stay 64 bits wide
  ; even on a 32-bit build. `shiftV`/`maskV` are local copies of `*intMap\shift`
  ; and `*intMap\mask`. A macro, not a procedure: the ASM backend does not inline,
  ; and this is the hottest path.
  Macro IntMap_StartSlot(iVar, hVar, keyExpr, shiftV, maskV)
    hVar = (keyExpr) * #IntMap_HashMul
    iVar = (hVar >> (shiftV)) & (maskV)
  EndMacro
  
  ; Smallest power of two >= `n` (minimum 8).
  Procedure NextPow2(n)
    Protected p = 8
    
    While p < n
      p = p << 1
    Wend
    
    ProcedureReturn p
  EndProcedure
  
  ; Integer base-2 logarithm; for a power of two this is the number of index
  ; bits. Deliberately integer, not a floating-point log: a rounded 3.9999 -> 3
  ; would destroy the `shift`.
  Procedure Log2Pow2(p)
    Protected b = 0
    
    While (1 << b) < p
      b = b + 1
    Wend
    
    ProcedureReturn b
  EndProcedure
  
  ; Finds the key via the index; returns its dense index, or `-1`. Linear
  ; probing: an empty slot ends the search, a tombstone is skipped, and a
  ; positive slot still needs the key comparison because different keys can
  ; share a slot.
  Procedure Lookup(*intMap.IntMapData, key.q)
    Protected mask  = *intMap\mask
    Protected shift = *intMap\shift
    Protected.q h
    Protected i, d, s
    
    IntMap_StartSlot(i, h, key, shift, mask)
    Repeat
      s = *intMap\slots(i)
      If s = 0
        ProcedureReturn -1
      ElseIf s > 0
        d = s - 1
        If *intMap\entries(d)\key = key
          ProcedureReturn d
        EndIf
      EndIf
      i = (i + 1) & mask ; linear probing (`& mask` = wraparound)
    ForEver
  EndProcedure
  
  ; Walks the probe chain once and returns both the dense index (or -1) and, in
  ; `*slotOut`, the matching index slot - on a hit the slot holding the key, on
  ; a miss the slot to insert into (first tombstone of the chain, else the empty
  ; end slot). `Put()` and `Remove()` need both, so this saves them a second
  ; pass. `Get()`/`Has()` keep using the leaner `Lookup()`.
  Procedure FindSlot(*intMap.IntMapData, key.q, *slotOut.Integer)
    Protected mask  = *intMap\mask
    Protected shift = *intMap\shift
    Protected firstDeleted = -1
    Protected i, d, s
    Protected.q h
    
    IntMap_StartSlot(i, h, key, shift, mask)
    
    Repeat
      s = *intMap\slots(i)
      If s = 0
        If firstDeleted >= 0
          *slotOut\i = firstDeleted
        Else
          *slotOut\i = i
        EndIf
        ProcedureReturn -1
      ElseIf s = -1
        If firstDeleted = -1
          firstDeleted = i
        EndIf
      Else
        d = s - 1
        If *intMap\entries(d)\key = key
          *slotOut\i = i
          ProcedureReturn d
        EndIf
      EndIf
      i = (i + 1) & mask
    ForEver
  EndProcedure
  
  ; Rebuilds the index from the live dense entries. Called when the index gets
  ; too full (tombstones count towards that) or after `Compact()`, when
  ; positions have moved. All tombstones disappear.
  ;
  ; The headroom loop guarantees the load is below the 75% trigger on return.
  ; Without it that would only be almost true: `NextPow2()` can round down to
  ; the size that was already there (in practice at `count` = 5), and the
  ; rebuild would run without effect. It changes nothing from `count` = 6 on.
  Procedure RebuildIndex(*intMap.IntMapData)
    Protected r, j
    Protected.q k, h
    
    ; target load roughly ~66%
    Protected size = NextPow2((*intMap\count * 3 / 2) + 1)
    
    If size < 8 : size = 8 : EndIf
    
    ; secure headroom below the 75% rule
    While ((*intMap\count + 1) * 4) >= (size * 3)
      size = size << 1
    Wend
    
    *intMap\slotsSize = size
    *intMap\mask      = size - 1
    *intMap\shift     = 64 - Log2Pow2(size)
    ReDim *intMap\slots(size - 1)
    Protected i.i
    For i = 0 To size - 1
      *intMap\slots(i) = 0
    Next
    *intMap\indexTombstones = 0
    
    Protected mask  = *intMap\mask
    Protected shift = *intMap\shift
    
    For r = 0 To *intMap\used - 1
      If IntMap_IsLive(*intMap, r)
        k = *intMap\entries(r)\key
        IntMap_StartSlot(j, h, k, shift, mask)
        ; Keys are unique, so no comparison is needed here - just walk on to the
        ; next free slot.
        While *intMap\slots(j) <> 0
          j = (j + 1) & mask
        Wend
        ; The slot points at dense index r
        *intMap\slots(j) = r + 1
      EndIf
    Next
  EndProcedure
  
  ; Public Function. Description in the module declaration block. Two-pointer
  ; compaction: write pointer `w`, read pointer `r`. Afterwards `used` equals
  ; `count`, so iteration needs no liveness check.
  Procedure Compact(*intMap.IntMapData)
    ; w is the write pointer (next free position at the front), r the read
    ; pointer that walks everything
    Protected w, r, i
    
    For r = 0 To *intMap\used - 1
      If IntMap_IsLive(*intMap, r)
        If w <> r
          *intMap\entries(w)\key   = *intMap\entries(r)\key
          *intMap\entries(w)\value = *intMap\entries(r)\value
        EndIf
        w = w + 1
      EndIf
    Next
    *intMap\used = w
    
    ; Reset the bitmap accordingly: 0..w-1 are live, the rest is free.
    Protected words = IntMap_WordsFor(*intMap\entriesCap)
    For i = 0 To words - 1
      *intMap\liveBits(i) = 0
    Next
    For i = 0 To w - 1
      IntMap_SetLive(*intMap, i)
    Next
    RebuildIndex(*intMap) ; positions have moved
  EndProcedure
  
  ; Makes sure there is room before every NEW entry. Returns `#True` if the
  ; index was rebuilt - then remembered slot positions are invalid and the
  ; caller must probe again. Plain dense growth does not touch the index and
  ; returns `#False`.
  ;
  ; The `entriesCap` = 0 guard catches a never-initialized structure: without
  ; it, growing would compute 0 << 1 = 0 and trigger `ReDim(-1)`, which corrupts
  ; memory silently without the debugger.
  ;
  ; When the dense array is full it compacts instead of doubling if at most half
  ; the slots are live, so heavy deleting costs no new memory. Tombstones count
  ; towards the 75% index load, so delete- heavy usage triggers a rebuild that
  ; clears them.
  Procedure EnsureForInsert(*intMap.IntMapData)
    Protected indexChanged
    
    ; (0) never initialized? -> do it now (lazy init)
    If *intMap\entriesCap = 0
      Init(*intMap, 16)
      ProcedureReturn #True
    EndIf
    
    ; dense array full? -> compact (many holes) or enlarge
    If *intMap\used >= *intMap\entriesCap
      If *intMap\count <= (*intMap\entriesCap >> 1)
        Compact(*intMap)
        indexChanged = #True
      Else
        Protected oldWords = IntMap_WordsFor(*intMap\entriesCap)
        *intMap\entriesCap = *intMap\entriesCap << 1
        ReDim *intMap\entries(*intMap\entriesCap - 1)
        ; Let the live bitmap grow along. ReDim preserves the old content, but
        ; the NEW words must be zeroed (otherwise random slots would count as
        ; occupied).
        Protected newWords = IntMap_WordsFor(*intMap\entriesCap)
        ReDim *intMap\liveBits(newWords - 1)
        Protected w
        For w = oldWords To newWords - 1
          *intMap\liveBits(w) = 0
        Next
        ; only dense grew: `slots()` untouched -> positions stay valid
      EndIf
    EndIf
    
    ; index load > 75% ? -> rebuild (clears tombstones, grows if needed)
    If ((*intMap\count + *intMap\indexTombstones + 1) * 4) >= (*intMap\slotsSize * 3)
      RebuildIndex(*intMap)
      indexChanged = #True
    EndIf
    
    ProcedureReturn indexChanged
  EndProcedure
  
  ; Public Function. Description in the module declaration block.
  Procedure Init(*intMap.IntMapData, initialCapacity = 16)
    Protected cap = NextPow2(initialCapacity)
    Protected w, i
    
    *intMap\count           = 0
    *intMap\used            = 0
    *intMap\indexTombstones = 0
    *intMap\entriesCap      = cap
    ReDim *intMap\entries(cap - 1)
    Protected words = IntMap_WordsFor(cap)
    ReDim *intMap\liveBits(words - 1)
    
    For w = 0 To words - 1
      *intMap\liveBits(w) = 0
    Next
    ; index ~1.5x dense (load headroom)
    Protected size = NextPow2((cap * 3 / 2) + 1)
    *intMap\slotsSize = size
    *intMap\mask      = size - 1
    *intMap\shift     = 64 - Log2Pow2(size)
    ReDim *intMap\slots(size - 1)
    For i = 0 To size - 1
      *intMap\slots(i) = 0
    Next
  EndProcedure
  
  ; Public Function. Description in the module declaration block.
  Procedure New(initialCapacity = 16)
    Protected *intMap.IntMapData = AllocateStructure(IntMapData)
    If *intMap
      Init(*intMap, initialCapacity)
    EndIf
    ProcedureReturn *intMap
  EndProcedure
  
  ; Public Function. Description in the module declaration block.
  Procedure Free(*intMap.IntMapData)
    If *intMap
      FreeStructure(*intMap)
    EndIf
  EndProcedure
  
  ; Public Function. Description in the module declaration block.
  Procedure Clear(*intMap.IntMapData)
    Protected i
    
    *intMap\count           = 0
    *intMap\used            = 0
    *intMap\indexTombstones = 0
    
    For i = 0 To *intMap\slotsSize - 1
      *intMap\slots(i) = 0
    Next
    
    Protected words = IntMap_WordsFor(*intMap\entriesCap)
    For i = 0 To words - 1
      *intMap\liveBits(i) = 0
    Next
  EndProcedure
  
  ; Public Function. Description in the module declaration block. The remembered
  ; slot from `FindSlot()` survives plain dense growth and only has to be
  ; re-probed when the index itself was rebuilt.
  Procedure Put(*intMap.IntMapData, key.q, value.q)
    Protected slot
    
    Protected d = FindSlot(*intMap, key, @slot)
    If d >= 0
      *intMap\entries(d)\value = value
      ProcedureReturn #True
    EndIf
    
    ; If the index was rebuilt, the remembered slot is stale and the key is
    ; definitely absent - so just re-fetch the slot.
    If EnsureForInsert(*intMap)
      FindSlot(*intMap, key, @slot)
    EndIf
    
    ; Slot encoding (`.l`) exhausted -> do not overflow
    If *intMap\used >= #IntMap_MaxEntries
      ProcedureReturn #False
    EndIf
    
    d = *intMap\used
    *intMap\entries(d)\key   = key
    *intMap\entries(d)\value = value
    IntMap_SetLive(*intMap, d)
    *intMap\used  = *intMap\used  + 1
    *intMap\count = *intMap\count + 1
    If *intMap\slots(slot) = -1
      *intMap\indexTombstones = *intMap\indexTombstones - 1
    EndIf
    *intMap\slots(slot) = d + 1
    
    ProcedureReturn #True
  EndProcedure
  
  ; Public Function. Description in the module declaration block. Same insertion
  ; path as `Put()`; only the hit case differs, where the existing entry is left
  ; untouched instead of being updated.
  Procedure PutNew(*intMap.IntMapData, key.q, value.q)
    Protected slot
    
    Protected d = FindSlot(*intMap, key, @slot)
    If d >= 0
      ProcedureReturn #False
    EndIf
    
    ; If the index was rebuilt, the remembered slot is stale and the key is
    ; definitely absent - so just re-fetch the slot.
    If EnsureForInsert(*intMap)
      FindSlot(*intMap, key, @slot)
    EndIf
    
    ; Slot encoding (`.l`) exhausted -> do not overflow
    If *intMap\used >= #IntMap_MaxEntries
      ProcedureReturn #False
    EndIf
    
    d = *intMap\used
    *intMap\entries(d)\key   = key
    *intMap\entries(d)\value = value
    IntMap_SetLive(*intMap, d)
    *intMap\used  = *intMap\used  + 1
    *intMap\count = *intMap\count + 1
    If *intMap\slots(slot) = -1
      *intMap\indexTombstones = *intMap\indexTombstones - 1
    EndIf
    *intMap\slots(slot) = d + 1
    
    ProcedureReturn #True
  EndProcedure
  
  ; Public Function. Description in the module declaration block.
  Procedure.q Get(*intMap.IntMapData, key.q)
    Protected d = Lookup(*intMap, key)
    
    If d >= 0
      ProcedureReturn *intMap\entries(d)\value
    EndIf
    ProcedureReturn 0
  EndProcedure
  
  ; Public Function. Description in the module declaration block.
  Procedure Has(*intMap.IntMapData, key.q)
    If Lookup(*intMap, key) >= 0
      ProcedureReturn #True
    EndIf
    ProcedureReturn #False
  EndProcedure
  
  ; Public Function. Description in the module declaration block. The dense
  ; entry becomes a hole and the index slot a tombstone. `used` stays unchanged,
  ; so later entries keep their position and therefore the order. Cleanup
  ; happens in bulk later, in `Compact()` or `RebuildIndex()`.
  Procedure Remove(*intMap.IntMapData, key.q)
    Protected slot
    Protected d = FindSlot(*intMap, key, @slot)
    If d >= 0
      ; Dense hole - the key stays in place, it is never read again
      IntMap_ClearLive(*intMap, d)
      *intMap\slots(slot)     = -1 ; index tombstone
      *intMap\count           = *intMap\count - 1
      *intMap\indexTombstones = *intMap\indexTombstones + 1
    EndIf
  EndProcedure
  
  ; Public Function. Description in the module declaration block.
  Procedure Count(*intMap.IntMapData)
    ProcedureReturn *intMap\count
  EndProcedure
  
  ; Public Function. Description in the module declaration block.
  Procedure NextIndex(*intMap.IntMapData, fromIndex)
    Protected i = fromIndex
    Protected u = *intMap\used
    
    While i < u
      If IntMap_IsLive(*intMap, i)
        ProcedureReturn i
      EndIf
      i = i + 1
    Wend
    
    ProcedureReturn -1
  EndProcedure
  
EndModule

CompilerIf #PB_Compiler_IsMainFile
  
  Define.IntMap::IntMapData *m = IntMap::New()
  
  ; Correctness with real memory addresses
  Define *a = AllocateMemory(64)
  Define *b = AllocateMemory(128)
  Define *c = AllocateMemory(256)
  
  IntMap::Put(*m, *a, 64)
  IntMap::Put(*m, *b, 128)
  IntMap::Put(*m, *c, 256)
  
  Debug "Get(*b) = " + Str(IntMap::Get(*m, *b)) ; 128
  Debug "Has(*c) = " + Str(IntMap::Has(*m, *c)) ; 1
  Debug "Has(0)  = " + Str(IntMap::Has(*m, 0))  ; 0
  
  IntMap::Remove(*m, *b)
  Debug "Count   = " + Str(IntMap::Count(*m)) ; 2
  
  ; Iteration in insertion order (deleted entries are skipped)
  Define index = IntMap::NextIndex(*m, 0)
  While index >= 0
    Debug "  [" + Str(index) + "] key=" + Str(IntMap::KeyAt(*m, index)) + " value=" + Str(IntMap::ValueAt(*m, index))
    index = IntMap::NextIndex(*m, index + 1)
  Wend
  
  FreeMemory(*a) : FreeMemory(*b) : FreeMemory(*c)
  IntMap::Free(*m)
  
CompilerEndIf
