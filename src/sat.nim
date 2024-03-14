## SAT solver
## (c) 2021 Andreas Rumpf
## Based on explanations and Haskell code from
## https://andrew.gibiansky.com/blog/verification/writing-a-sat-solver/

## Formulars as packed ASTs, no pointers no cry. Solves formulars with many
## thousands of variables in no time.

import satvars

const MaxDefaultIterations: int =
  when defined(debug): 1700 # lower than nim debug recursion limit
  else: 50_000 # total guesswork

type
  SatOverflowError* = object of CatchableError
  FormKind* = enum
    FalseForm, TrueForm, VarForm, NotForm, AndForm, OrForm, ExactlyOneOfForm, ZeroOrOneOfForm # 8 so the last 3 bits
  Atom = distinct BaseType
  Formular* = seq[Atom] # linear storage

const
  KindBits = 3
  KindMask = 0b111

template kind(a: Atom): FormKind = FormKind(BaseType(a) and KindMask)
template intVal(a: Atom): BaseType = BaseType(a) shr KindBits

proc newVar*(val: VarId): Atom {.inline.} =
  Atom((BaseType(val) shl KindBits) or BaseType(VarForm))

proc newOperation(k: FormKind; val: BaseType): Atom {.inline.} =
  Atom((val shl KindBits) or BaseType(k))

proc trueLit*(): Atom {.inline.} = Atom(TrueForm)
proc falseLit*(): Atom {.inline.} = Atom(FalseForm)

proc lit(k: FormKind): Atom {.inline.} = Atom(k)

when false:
  proc isTrueLit(a: Atom): bool {.inline.} = a.kind == TrueForm
  proc isFalseLit(a: Atom): bool {.inline.} = a.kind == FalseForm

proc varId(a: Atom): VarId =
  assert a.kind == VarForm
  result = VarId(BaseType(a) shr KindBits)

type
  PatchPos = distinct int
  FormPos = distinct int

template firstSon(n: FormPos): FormPos = FormPos(n.int+1)

proc prepare(dest: var Formular; source: Formular; sourcePos: FormPos): PatchPos =
  result = PatchPos dest.len
  dest.add source[sourcePos.int]

proc prepare(dest: var Formular; k: FormKind): PatchPos =
  result = PatchPos dest.len
  dest.add newOperation(k, 1)

proc patch(f: var Formular; pos: PatchPos) =
  let pos = pos.int
  let k = f[pos].kind
  assert k > VarForm
  let distance = int32(f.len - pos)
  f[pos] = newOperation(k, distance)

proc nextChild(f: Formular; pos: var int) {.inline.} =
  let x = f[int pos]
  pos += (if x.kind <= VarForm: 1 else: int(intVal(x)))

proc sons2(f: Formular; n: FormPos): (FormPos, FormPos) {.inline.} =
  var p = n.int + 1
  nextChild(f, p)
  result = (n.firstSon, FormPos(p))

iterator sonsReadonly(f: Formular; n: FormPos): FormPos =
  var pos = n.int
  assert f[pos].kind > VarForm
  let last = pos + f[pos].intVal
  inc pos
  while pos < last:
    yield FormPos pos
    nextChild f, pos

iterator sons(dest: var Formular; source: Formular; n: FormPos): FormPos =
  let patchPos = prepare(dest, source, n)
  for x in sonsReadonly(source, n): yield x
  patch dest, patchPos

proc copyTree(dest: var Formular; source: Formular; n: FormPos) =
  let x = source[int n]
  let len = (if x.kind <= VarForm: 1 else: int(intVal(x)))
  for i in 0..<len:
    dest.add source[i+n.int]

# String representation

proc toString(dest: var string; f: Formular; n: FormPos; varRepr: proc (dest: var string; i: int)) =
  assert n.int >= 0
  assert n.int < f.len
  case f[n.int].kind
  of FalseForm: dest.add 'F'
  of TrueForm: dest.add 'T'
  of VarForm:
    varRepr dest, varId(f[n.int]).int
  else:
    case f[n.int].kind
    of AndForm:
      dest.add "(&"
    of OrForm:
      dest.add "(|"
    of ExactlyOneOfForm:
      dest.add "(1=="
    of NotForm:
      dest.add "(~"
    of ZeroOrOneOfForm:
      dest.add "(1>="
    else: assert false, "cannot happen"
    var i = 0
    for child in sonsReadonly(f, n):
      if i > 0: dest.add ' '
      toString(dest, f, child, varRepr)
      inc i
    dest.add ')'

proc `$`*(f: Formular): string =
  assert f.len > 0
  toString(result, f, FormPos 0, proc (dest: var string; x: int) =
    dest.add 'v'
    dest.addInt x
  )

proc `$`*(f: Formular; varRepr: proc (dest: var string; i: int)): string =
  assert f.len > 0
  toString(result, f, FormPos 0, varRepr)

type
  Builder* = object
    f: Formular
    toPatch: seq[PatchPos]

proc isEmpty*(b: Builder): bool {.inline.} =
  b.f.len == 0 or b.f.len == 1 and b.f[0].kind in {NotForm, AndForm, OrForm, ExactlyOneOfForm, ZeroOrOneOfForm}

proc openOpr*(b: var Builder; k: FormKind) =
  b.toPatch.add PatchPos b.f.len
  b.f.add newOperation(k, 0)

proc closeOpr*(b: var Builder) =
  patch(b.f, b.toPatch.pop())

proc add*(b: var Builder; a: Atom) =
  b.f.add a

proc add*(b: var Builder; a: VarId) =
  b.f.add newVar(a)

proc addNegated*(b: var Builder; a: VarId) =
  b.openOpr NotForm
  b.f.add newVar(a)
  b.closeOpr

proc getPatchPos*(b: Builder): PatchPos =
  PatchPos b.f.len

proc resetToPatchPos*(b: var Builder; p: PatchPos) =
  b.f.setLen p.int

proc deleteLastNode*(b: var Builder) =
  b.f.setLen b.f.len - 1

type
  BuilderPos* = distinct int

proc rememberPos*(b: Builder): BuilderPos {.inline.} = BuilderPos b.f.len
proc rewind*(b: var Builder; pos: BuilderPos) {.inline.} = setLen b.f, int(pos)

proc toForm*(b: var Builder): Formular =
  assert b.toPatch.len == 0, "missing `closeOpr` calls"
  result = move b.f

proc isValid*(v: VarId): bool {.inline.} = v.int32 >= 0

proc freeVariable(f: Formular): VarId =
  ## returns NoVar if there is no free variable.
  for i in 0..<f.len:
    if f[i].kind == VarForm: return varId(f[i])
  return NoVar

proc maxVariable*(f: Formular): int =
  result = -1
  for i in 0..<f.len:
    if f[i].kind == VarForm: result = max(result, int varId(f[i]))
  inc result

proc createSolution*(f: Formular): Solution =
  satvars.createSolution(maxVariable f)

proc simplify(dest: var Formular; source: Formular; n: FormPos; sol: Solution): FormKind =
  ## Returns either a Const constructor or a simplified expression;
  ## if the result is not a Const constructor, it guarantees that there
  ## are no Const constructors in the source tree further down.
  let s = source[n.int]
  result = s.kind
  case result
  of FalseForm, TrueForm:
    # nothing interesting to do:
    dest.add s
  of VarForm:
    let v = sol.getVar(varId(s))
    case v
    of SetToFalse:
      dest.add falseLit()
      result = FalseForm
    of SetToTrue:
      dest.add trueLit()
      result = TrueForm
    else:
      dest.add s
  of NotForm:
    let oldLen = dest.len
    var inner: FormKind
    for child in sons(dest, source, n):
      inner = simplify(dest, source, child, sol)
    if inner in {FalseForm, TrueForm}:
      setLen dest, oldLen
      result = (if inner == FalseForm: TrueForm else: FalseForm)
      dest.add lit(result)
  of AndForm, OrForm:
    let (tForm, fForm) = if result == AndForm: (TrueForm, FalseForm)
                         else:                 (FalseForm, TrueForm)

    let initialLen = dest.len
    var childCount = 0
    for child in sons(dest, source, n):
      let oldLen = dest.len

      let inner = simplify(dest, source, child, sol)
      # ignore 'and T' or 'or F' subexpressions:
      if inner == tForm:
        setLen dest, oldLen
      elif inner == fForm:
        # 'and F' is always false and 'or T' is always true:
        result = fForm
        break
      else:
        inc childCount

    if result == fForm:
      setLen dest, initialLen
      dest.add lit(result)
    elif childCount == 1:
      for i in initialLen..<dest.len-1:
        dest[i] = dest[i+1]
      setLen dest, dest.len-1
      result = dest[initialLen].kind
    elif childCount == 0:
      # that means all subexpressions where ignored:
      setLen dest, initialLen
      result = tForm
      dest.add lit(result)
  of ZeroOrOneOfForm:
    let initialLen = dest.len
    var childCount = 0
    var trueCount = 0
    for child in sons(dest, source, n):
      let oldLen = dest.len

      let inner = simplify(dest, source, child, sol)
      # ignore 'ZeroOrOneOf F' subexpressions:
      if inner == FalseForm:
        setLen dest, oldLen
      else:
        if inner == TrueForm:
          inc trueCount
        inc childCount

    if trueCount >= 2:
      setLen dest, initialLen
      dest.add lit FalseForm
      result = FalseForm
    elif trueCount == childCount:
      setLen dest, initialLen
      if trueCount <= 1:
        dest.add lit TrueForm
        result = TrueForm
      else:
        dest.add lit FalseForm
        result = FalseForm
    elif childCount == 1:
      setLen dest, initialLen
      dest.add lit TrueForm
      result = TrueForm

  of ExactlyOneOfForm:
    let initialLen = dest.len
    var childCount = 0
    var trueCount = 0
    for child in sons(dest, source, n):
      let oldLen = dest.len

      let inner = simplify(dest, source, child, sol)
      # ignore 'exactlyOneOf F' subexpressions:
      if inner == FalseForm:
        setLen dest, oldLen
      else:
        if inner == TrueForm:
          inc trueCount
        inc childCount

    if trueCount >= 2:
      setLen dest, initialLen
      dest.add lit FalseForm
      result = FalseForm
    elif trueCount == childCount:
      setLen dest, initialLen
      if trueCount != 1:
        dest.add lit FalseForm
        result = FalseForm
      else:
        dest.add lit TrueForm
        result = TrueForm
    elif childCount == 1:
      for i in initialLen..<dest.len-1:
        dest[i] = dest[i+1]
      setLen dest, dest.len-1
      result = dest[initialLen].kind

proc appender(dest: var string; x: int) =
  dest.add 'v'
  dest.addInt x

proc tos(f: Formular; n: FormPos): string =
  result = ""
  toString(result, f, n, appender)

proc eval(f: Formular; n: FormPos; s: Solution): bool =
  assert n.int >= 0
  assert n.int < f.len
  case f[n.int].kind
  of FalseForm: result = false
  of TrueForm: result = true
  of VarForm:
    let v = varId(f[n.int])
    result = s.isTrue(v)
  else:
    case f[n.int].kind
    of AndForm:
      for child in sonsReadonly(f, n):
        if not eval(f, child, s): return false
      return true
    of OrForm:
      for child in sonsReadonly(f, n):
        if eval(f, child, s): return true
      return false
    of ExactlyOneOfForm:
      var conds = 0
      for child in sonsReadonly(f, n):
        if eval(f, child, s): inc conds
      result = conds == 1
    of NotForm:
      for child in sonsReadonly(f, n):
        if not eval(f, child, s): return true
      return false
    of ZeroOrOneOfForm:
      var conds = 0
      for child in sonsReadonly(f, n):
        if eval(f, child, s): inc conds
      result = conds <= 1
    else: assert false, "cannot happen"

proc eval*(f: Formular; s: Solution): bool =
  eval(f, FormPos(0), s)

proc trivialVars(f: Formular; n: FormPos; val: uint64; sol: var Solution) =
  case f[n.int].kind
  of FalseForm, TrueForm: discard
  of VarForm:
    let v = varId(f[n.int])
    sol.setVar(v, val or sol.getVar(v))
  of NotForm:
    let newVal = if val == SetToFalse: SetToTrue else: SetToFalse
    trivialVars(f, n.firstSon, newVal, sol)
  of OrForm:
    if val == SetToTrue:
      # XXX We assume here that it's an implication. We should test that instead:
      let (a, b) = sons2(f, n)
      if eval(f, a.firstSon, sol):
        trivialVars(f, b, SetToTrue, sol)
  of AndForm:
    if val == SetToTrue:
      for child in sonsReadonly(f, n):
        trivialVars(f, child, val, sol)
  of ExactlyOneOfForm, ZeroOrOneOfForm:
    if val == SetToTrue:
      var trueAt = -1
      for ch in sonsReadonly(f, n):
        if f[ch.int].kind == VarForm:
          let v = varId(f[ch.int])
          if sol.getVar(v) == SetToTrue:
            trueAt = ch.int
      if trueAt >= 0:
        # All others must be false:
        for ch in sonsReadonly(f, n):
          if f[ch.int].kind == VarForm:
            let v = varId(f[ch.int])
            if ch.int != trueAt:
              sol.setVar(v, SetToFalse or sol.getVar(v))

proc satisfiableIter(f: Formular; sout: var Solution; iters: var int): bool =
  if iters == 0:
    return false
  dec iters

  let v = freeVariable(f)
  if v == NoVar:
    result = f[0].kind == TrueForm
  else:
    var s = sout
    trivialVars(f, FormPos(0), SetToTrue, s)
    if containsInvalid(s):
      sout = s
      return false

    result = false
    # We have a variable to guess.
    # Construct the two guesses.
    # Return whether either one of them works.
    let prevValue = s.getVar(v)
    s.setVar(v, SetToFalse)

    var falseGuess: Formular
    let res = simplify(falseGuess, f, FormPos 0, s)

    if res == TrueForm:
      result = true
    else:
      result = satisfiableIter(falseGuess, s, iters)
      if iters == 0:
        return false

      if not result:
        s.setVar(v, SetToTrue)

        var trueGuess: Formular
        let res = simplify(trueGuess, f, FormPos 0, s)

        if res == TrueForm:
          result = true
        else:
          result = satisfiableIter(trueGuess, s, iters)
          if iters == 0:
            return
          #if not result:
          # Revert the assignment after trying the second option
          #  s.setVar(v, prevValue)
    if result:
      sout = s

proc satisfiable*(f: Formular; sout: var Solution;
                  maxIters: int = MaxDefaultIterations): bool {.raises: [SatOverflowError].} =
  ## Determines if the SAT problem given in the given Formular `f` is satisfiable.
  var iters = maxIters
  result = satisfiableIter(f, sout, iters)
  if iters == 0:
    raise newException(SatOverflowError, "SAT iteration limit exceeded")

type
  Space = seq[Solution]

proc mul(a, b: Space): Space =
  result = @[]
  for i in 0..<a.len:
    if not a[i].invalid:
      for j in 0..<b.len:
        if not b[j].invalid:
          result.add a[i]
          combine result[^1], b[j]

proc solutionSpace(f: Formular; n: FormPos; maxVar: int; wanted: uint64): Space =
  assert n.int >= 0
  assert n.int < f.len
  result = @[]
  case f[n.int].kind
  of FalseForm:
    # We want `true` but got `false`:
    if wanted == SetToTrue:
      result.add createSolution(maxVar)
      result[0].invalid = true
  of TrueForm:
    # We want `false` but got `true`:
    if wanted == SetToFalse:
      result.add createSolution(maxVar)
      result[0].invalid = true
  of VarForm:
    if wanted == DontCare: return result
    result.add createSolution(maxVar)
    let v = varId(f[n.int])
    result[0].setVar(v, wanted)

  of AndForm:
    case wanted
    of SetToFalse:
      assert false, "not yet implemented: ~(& ...)"
    of SetToTrue:
      result.add createSolution(maxVar)
      for child in sonsReadonly(f, n):
        let inner = solutionSpace(f, child, maxVar, SetToTrue)
        result = mul(result, inner)
    else:
      discard "well we don't care about the value for the AND expression"

  of OrForm:
    case wanted
    of SetToFalse:
      # ~(A | B) == ~A & ~B
      # all children must be false:
      result.add createSolution(maxVar)
      for child in sonsReadonly(f, n):
        let inner = solutionSpace(f, child, maxVar, SetToFalse)
        result = mul(result, inner)
    of SetToTrue:
      # any of the children need to be true:
      for child in sonsReadonly(f, n):
        let inner = solutionSpace(f, child, maxVar, SetToTrue)
        for a in inner: result.add a
    else:
      discard "well we don't care about the value for the OR expression"

  of ExactlyOneOfForm:
    if wanted == DontCare: return
    assert wanted == SetToTrue
    var children: seq[FormPos] = @[]
    for child in sonsReadonly(f, n): children.add child
    for i in 0..<children.len:
      # child[i] must be true all others must be false:
      result.add createSolution(maxVar)

      for child in sonsReadonly(f, n):
        # child[i] must be true all others must be false:
        let k = if child.int == children[i].int: SetToTrue else: SetToFalse
        let inner = solutionSpace(f, child, maxVar, k)
        for a in inner:
          combine(result[result.len-1], a)

  of ZeroOrOneOfForm:
    if wanted == DontCare: return
    assert wanted == SetToTrue
    # all children must be false:
    result.add createSolution(maxVar)
    for child in sonsReadonly(f, n):
      let inner = solutionSpace(f, child, maxVar, SetToFalse)
      result = mul(result, inner)

    # or exactly one must be true:
    var children: seq[FormPos] = @[]
    for child in sonsReadonly(f, n): children.add child
    for i in 0..<children.len:
      # child[i] must be true all others must be false:
      result.add createSolution(maxVar)

      for child in sonsReadonly(f, n):
        # child[i] must be true all others must be false:
        let k = if child.int == children[i].int: SetToTrue else: SetToFalse
        let inner = solutionSpace(f, child, maxVar, k)
        for a in inner:
          combine(result[result.len-1], a)

  of NotForm:
    case wanted
    of SetToFalse:
      for child in sonsReadonly(f, n):
        return solutionSpace(f, child, maxVar, SetToTrue)
    of SetToTrue:
      for child in sonsReadonly(f, n):
        return solutionSpace(f, child, maxVar, SetToFalse)
    else:
      discard "well we don't care about the value for the NOT expression"
  else: assert false, "not implemented"

proc satisfiableSlow*(f: Formular; s: var Solution): bool =
  let space = solutionSpace(f, FormPos(0), maxVariable(f), SetToTrue)
  for candidate in space:
    if not candidate.invalid:
      s = candidate
      return true
  return false

import std / [strutils, parseutils]

proc parseFormular*(s: string; i: int; b: var Builder): int

proc parseOpr(s: string; i: int; b: var Builder; kind: FormKind; opr: string): int =
  result = i
  if not continuesWith(s, opr, result):
    quit "expected: " & opr
  inc result, opr.len
  b.openOpr kind
  while result < s.len and s[result] != ')':
    result = parseFormular(s, result, b)
  b.closeOpr
  if result < s.len and s[result] == ')':
    inc result
  else:
    quit "exptected: )"

proc parseFormular(s: string; i: int; b: var Builder): int =
  result = i
  while result < s.len and s[result] in Whitespace: inc result
  if s[result] == 'v':
    var number = 0
    inc result
    let span = parseInt(s, number, result)
    if span == 0: quit "invalid variable name"
    inc result, span
    b.add VarId(number)
  elif s[result] == 'T':
    b.add trueLit()
    inc result
  elif s[result] == 'F':
    b.add falseLit()
    inc result
  elif s[result] == '(':
    inc result
    case s[result]
    of '~':
      inc result
      b.openOpr NotForm
      result = parseFormular(s, result, b)
      b.closeOpr
      if s[result] == ')': inc result
      else: quit ") expected"
    of '|':
      result = parseOpr(s, result, b, OrForm, "|")
    of '&':
      result = parseOpr(s, result, b, AndForm, "&")
    of '1':
      if continuesWith(s, "1==", result):
        result = parseOpr(s, result, b, ExactlyOneOfForm, "1==")
      else:
        result = parseOpr(s, result, b, ZeroOrOneOfForm, "1>=")
    else:
      quit "unknown operator: " & s[result]
  else:
    quit "( expected, but got: " & s[result]
