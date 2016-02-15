proc initRefNodeData(p: pointer): RefNodeData =
    result.p = p
    result.count = 1
    result.anchor = yAnchorNone

proc newConstructionContext(): ConstructionContext =
    new(result)
    result.refs = initTable[AnchorId, pointer]()

proc newSerializationContext(s: AnchorStyle): SerializationContext =
    new(result)
    result.refsList = newSeq[RefNodeData]()
    result.style = s

proc initSerializationTagLibrary(): TagLibrary {.raises: [].} =
    result = initTagLibrary()
    result.tags["!"] = yTagExclamationMark
    result.tags["?"] = yTagQuestionMark
    result.tags["tag:yaml.org,2002:str"]       = yTagString
    result.tags["tag:yaml.org,2002:null"]      = yTagNull
    result.tags["tag:yaml.org,2002:bool"]      = yTagBoolean
    result.tags["tag:yaml.org,2002:float"]     = yTagFloat
    result.tags["tag:yaml.org,2002:timestamp"] = yTagTimestamp
    result.tags["tag:yaml.org,2002:value"]     = yTagValue
    result.tags["tag:yaml.org,2002:binary"]    = yTagBinary

var
    serializationTagLibrary* = initSerializationTagLibrary() ## \
        ## contains all local tags that are used for type serialization. Does
        ## not contain any of the specific default tags for sequences or maps,
        ## as those are not suited for Nim's static type system.
        ##
        ## Should not be modified manually. Will be extended by
        ## `serializable <#serializable,stmt,stmt>`_.

static:
    iterator objectFields(n: NimNode): tuple[name: NimNode, t: NimNode]
            {.raises: [].} =
        assert n.kind in [nnkRecList, nnkTupleTy]
        for identDefs in n.children:
            let numFields = identDefs.len - 2
            for i in 0..numFields - 1:
                yield (name: identDefs[i], t: identDefs[^2])
    
    var existingTuples = newSeq[NimNode]()

template presentTag(t: typedesc, ts: TagStyle): TagId =
     if ts == tsNone: yTagQuestionMark else: yamlTag(t)

template setTagUriForType*(t: typedesc, uri: string): stmt =
    ## Associate the given uri with a certain type. This uri is used as YAML tag
    ## when loading and dumping values of this type.
    let id {.gensym.} = serializationTagLibrary.registerUri(uri)
    proc yamlTag*(T: typedesc[t]): TagId {.inline, raises: [].} = id

template setTagUriForType*(t: typedesc, uri: string, idName: expr): stmt =
    ## Like `setTagUriForType <#setTagUriForType,typedesc,string>`_, but lets
    ## you choose a symbol for the `TagId <#TagId>`_ of the uri. This is only
    ## necessary if you want to implement serialization / construction yourself.
    let idName* = serializationTagLibrary.registerUri(uri)
    proc yamlTag*(T: typedesc[t]): TagId {.inline, raises: [].} = idName

setTagUriForType(char, "!nim:system:char", yTagNimChar)
setTagUriForType(int8, "!nim:system:int8", yTagNimInt8)
setTagUriForType(int16, "!nim:system:int16", yTagNimInt16)
setTagUriForType(int32, "!nim:system:int32", yTagNimInt32)
setTagUriForType(int64, "!nim:system:int64", yTagNimInt64)
setTagUriForType(uint8, "!nim:system:uint8", yTagNimUInt8)
setTagUriForType(uint16, "!nim:system:uint16", yTagNimUInt16)
setTagUriForType(uint32, "!nim:system:uint32", yTagNimUInt32)
setTagUriForType(uint64, "!nim:system:uint64", yTagNimUInt64)
setTagUriForType(float32, "!nim:system:float32", yTagNimFloat32)
setTagUriForType(float64, "!nim:system:float64", yTagNimFloat64)

proc lazyLoadTag*(uri: string): TagId {.inline, raises: [].} =
    ## Internal function. Do not call explicitly.
    try:
        result = serializationTagLibrary.tags[uri]
    except KeyError:
        result = serializationTagLibrary.registerUri(uri)

macro serializable*(types: stmt): stmt =
    ## Macro for customizing serialization of user-defined types.
    ## Currently does not provide more features than just using the standard
    ## serialization procs. This will change in the future.
    assert types.kind == nnkTypeSection
    result = newStmtList(types)
    for typedef in types.children:
        assert typedef.kind == nnkTypeDef
        let
            tName = $typedef[0].symbol
            tIdent = newIdentNode(tName)
        var
            tUri: NimNode
            recList: NimNode
        assert typedef[1].kind == nnkEmpty
        let objectTy = typedef[2]
        case objectTy.kind
        of nnkObjectTy:
            assert objectTy[0].kind == nnkEmpty
            assert objectTy[1].kind == nnkEmpty
            tUri = newStrLitNode("!nim:custom:" & tName)
            recList = objectTy[2]
        of nnkTupleTy:
            if objectTy in existingTuples:
                continue
            existingTuples.add(objectTy)
            
            recList = objectTy
            tUri = newStmtList()
            var
                first = true
                curStrLit = "!nim:tuple("
                curInfix = tUri
            for field in objectFields(recList):
                if first:
                    first = false
                else:
                    curStrLit &= ","
                curStrLit &= $field.name & "="
                var tmp = newNimNode(nnkInfix).add(newIdentNode("&"),
                        newStrLitNode(curStrLit))
                curInfix.add(tmp)
                curInfix = tmp
                tmp = newNimNode(nnkInfix).add(newIdentNode("&"),
                        newCall("safeTagUri", newCall("yamlTag",
                            newCall("type", field.t))))
                curInfix.add(tmp)
                curInfix = tmp
                curStrLit = ""
            curInfix.add(newStrLitNode(curStrLit & ")"))
            tUri = tUri[0]
        else:
            assert false
                
        # yamlTag()
        
        var yamlTagProc = newProc(newIdentNode("yamlTag"), [
                newIdentNode("TagId"),
                newIdentDefs(newIdentNode("T"), newNimNode(nnkBracketExpr).add(
                             newIdentNode("typedesc"), tIdent))])
        var impl = newStmtList(newCall("lazyLoadTag", tUri))
        yamlTagProc[6] = impl
        result.add(yamlTagProc)
        
        # constructObject()
        
        var constructProc = newProc(newIdentNode("constructObject"), [
                newEmptyNode(),
                newIdentDefs(newIdentNode("s"), newIdentNode("YamlStream")),
                newIdentDefs(newIdentNode("c"),
                newIdentNode("ConstructionContext")),
                newIdentDefs(newIdentNode("result"),
                             newNimNode(nnkVarTy).add(tIdent))])
        constructProc[4] = newNimNode(nnkPragma).add(
                newNimNode(nnkExprColonExpr).add(newIdentNode("raises"),
                newNimNode(nnkBracket).add(
                newIdentNode("YamlConstructionError"),
                newIdentNode("YamlStreamError"))))
        impl = quote do:
            var event = s()
            if finished(s) or event.kind != yamlStartMap:
                raise newException(YamlConstructionError, "Expected map start")
            if event.mapTag != yTagQuestionMark and
                    event.mapTag != yamlTag(type(`tIdent`)):
                raise newException(YamlConstructionError,
                                   "Wrong tag for " & `tName`)
            event = s()
            assert(not finished(s))
            while event.kind != yamlEndMap:
                assert event.kind == yamlScalar
                assert event.scalarTag in [yTagQuestionMark, yTagString]
                case event.scalarContent
                else:
                    raise newException(YamlConstructionError,
                            "Unknown key for " & `tName` & ": " &
                            event.scalarContent)
                event = s()
                assert(not finished(s))
        var keyCase = impl[5][1][2]
        assert keyCase.kind == nnkCaseStmt
        for field in objectFields(recList):
            keyCase.insert(1, newNimNode(nnkOfBranch).add(
                    newStrLitNode($field.name.ident)).add(newStmtList(
                        newCall("constructObject", [newIdentNode("s"),
                        newIdentNode("c"),
                        newDotExpr(newIdentNode("result"), field.name)])
                    ))
            )
            
        constructProc[6] = impl
        result.add(constructProc)
        
        # representObject()
        
        var representProc = newProc(newIdentNode("representObject"), [
                newIdentNode("RawYamlStream"),
                newIdentDefs(newIdentNode("value"), tIdent),
                newIdentDefs(newIdentNode("ts"),
                             newIdentNode("TagStyle")),
                newIdentDefs(newIdentNode("c"),
                             newIdentNode("SerializationContext"))])
        representProc[4] = newNimNode(nnkPragma).add(
                newNimNode(nnkExprColonExpr).add(newIdentNode("raises"),
                newNimNode(nnkBracket)))
        var iterBody = newStmtList(
            newLetStmt(newIdentNode("childTagStyle"), newNimNode(nnkIfExpr).add(
                newNimNode(nnkElifExpr).add(
                    newNimNode(nnkInfix).add(newIdentNode("=="),
                        newIdentNode("ts"), newIdentNode("tsRootOnly")),
                    newIdentNode("tsNone")
                ), newNimNode(nnkElseExpr).add(newIdentNode("ts")))),
            newNimNode(nnkYieldStmt).add(
                newNimNode(nnkObjConstr).add(newIdentNode("YamlStreamEvent"),
                    newNimNode(nnkExprColonExpr).add(newIdentNode("kind"),
                        newIdentNode("yamlStartMap")),
                    newNimNode(nnkExprColonExpr).add(newIdentNode("mapTag"),
                        newNimNode(nnkIfExpr).add(newNimNode(nnkElifExpr).add(
                            newNimNode(nnkInfix).add(newIdentNode("=="),
                                newIdentNode("ts"),
                                newIdentNode("tsNone")),
                            newIdentNode("yTagQuestionMark")
                        ), newNimNode(nnkElseExpr).add(
                            newCall("yamlTag", newCall("type", tIdent))
                        ))),
                    newNimNode(nnkExprColonExpr).add(newIdentNode("mapAnchor"),
                        newIdentNode("yAnchorNone"))    
                )
        ), newNimNode(nnkYieldStmt).add(newNimNode(nnkObjConstr).add(
            newIdentNode("YamlStreamEvent"), newNimNode(nnkExprColonExpr).add(
                newIdentNode("kind"), newIdentNode("yamlEndMap")
            )
        )))
        
        var i = 2
        for field in objectFields(recList):
            let
                fieldIterIdent = newIdentNode($field.name & "Events")
                fieldNameString = newStrLitNode($field.name)
            iterbody.insert(i, quote do:
                yield YamlStreamEvent(kind: yamlScalar,
                                      scalarTag: presentTag(string,
                                                            childTagStyle),
                                      scalarAnchor: yAnchorNone,
                                      scalarContent: `fieldNameString`)
            )
            iterbody.insert(i + 1, newVarStmt(fieldIterIdent,
                    newCall("representObject", newDotExpr(newIdentNode("value"),
                    field.name), newIdentNode("childTagStyle"),
                    newIdentNode("c"))))
            iterbody.insert(i + 2, quote do:
                for event in `fieldIterIdent`():
                    yield event
            )
            i += 3
        impl = newStmtList(newAssignment(newIdentNode("result"), newProc(
                newEmptyNode(), [newIdentNode("YamlStreamEvent")], iterBody,
                nnkIteratorDef)))
        representProc[6] = impl
        result.add(representProc)

proc safeTagUri*(id: TagId): string {.raises: [].} =
    ## Internal function. Do not call explicitly.
    try:
        let uri = serializationTagLibrary.uri(id)
        if uri.len > 0 and uri[0] == '!':
            return uri[1..uri.len - 1]
        else:
            return uri
    except KeyError:
        # cannot happen (theoretically, you known)
        assert(false)

template constructScalarItem(bs: var YamlStream, item: YamlStreamEvent,
                             name: string, t: TagId, content: stmt) =
    item = bs.next()
    if item.kind != yamlScalar:
        raise newException(YamlConstructionError, "Expected scalar")
    if item.scalarTag notin [yTagQuestionMark, yTagExclamationMark, t]:
        raise newException(YamlConstructionError, "Wrong tag for " & name)
    try:
        content
    except YamlConstructionError:
        raise
    except Exception:
        var e = newException(YamlConstructionError,
                "Cannot construct to " & name & ": " & item.scalarContent)
        e.parent = getCurrentException()
        raise e

proc yamlTag*(T: typedesc[string]): TagId {.inline, noSideEffect, raises: [].} =
    yTagString

proc constructObject*(s: var YamlStream, c: ConstructionContext,
                      result: var string)
        {.raises: [YamlConstructionError, YamlStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(s, item, "string", yTagString):
        result = item.scalarContent

proc representObject*(value: string, ts: TagStyle = tsNone,
        c: SerializationContext): RawYamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield scalarEvent(value, presentTag(string, ts), yAnchorNone)

proc constructObject*[T: int8|int16|int32|int64](
        s: var YamlStream, c: ConstructionContext, result: var T)
        {.raises: [YamlConstructionError, YamlStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(s, item, name(T), yamlTag(T)):
        result = T(parseBiggestInt(item.scalarContent))

template constructObject*(s: var YamlStream, c: ConstructionContext,
                          result: var int) =
    {.fatal: "The length of `int` is platform dependent. Use int[8|16|32|64].".}
    discard

proc representObject*[T: int8|int16|int32|int64](
        value: T, ts: TagStyle = tsNone, c: SerializationContext):
        RawYamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield scalarEvent($value, presentTag(T, ts), yAnchorNone)

template representObject*(value: int, tagStyle: TagStyle,
                          c: SerializationContext): RawYamlStream =
    {.fatal: "The length of `int` is platform dependent. Use int[8|16|32|64].".}
    discard

{.push overflowChecks: on.}
proc parseBiggestUInt(s: string): uint64 =
    result = 0
    for c in s:
        if c in {'0'..'9'}:
            result *= 10.uint64 + (uint64(c) - uint64('0'))
        elif c == '_':
            discard
        else:
            raise newException(ValueError, "Invalid char in uint: " & c)
{.pop.}

proc constructObject*[T: uint8|uint16|uint32|uint64](
        s: var YamlStream, c: ConstructionContext, result: var T)
        {.raises: [YamlConstructionError, YamlStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(s, item, name[T], yamlTag(T)):
        result = T(parseBiggestUInt(item.scalarContent))

template constructObject*(s: var YamlStream, c: ConstructionContext,
                          result: var uint) =
    {.fatal:
        "The length of `uint` is platform dependent. Use uint[8|16|32|64].".}
    discard

proc representObject*[T: uint8|uint16|uint32|uint64](
        value: T, ts: TagStyle, c: SerializationContext):
        RawYamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield scalarEvent($value, presentTag(T, ts), yAnchorNone)

template representObject*(value: uint, ts: TagStyle, c: SerializationContext):
         RawYamlStream =
    {.fatal:
        "The length of `uint` is platform dependent. Use uint[8|16|32|64].".}
    discard

proc constructObject*[T: float32|float64](
        s: var YamlStream, c: ConstructionContext, result: var T)
         {.raises: [YamlConstructionError, YamlStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(s, item, name(T), yamlTag(T)):
        let hint = guessType(item.scalarContent)
        case hint
        of yTypeFloat:
            result = T(parseBiggestFloat(item.scalarContent))
        of yTypeFloatInf:
            if item.scalarContent[0] == '-':
                result = NegInf
            else:
                result = Inf
        of yTypeFloatNaN:
            result = NaN
        else:
            raise newException(YamlConstructionError,
                    "Cannot construct to float: " & item.scalarContent)

template constructObject*(s: var YamlStream, c: ConstructionContext,
                          result: var float) =
    {.fatal: "The length of `float` is platform dependent. Use float[32|64].".}

proc representObject*[T: float32|float64](value: T, ts: TagStyle,
                                          c: SerializationContext):
        RawYamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        var
            asString: string
        case value
        of Inf:
            asString = ".inf"
        of NegInf:
            asString = "-.inf"
        of NaN:
            asString = ".nan"
        else:
            asString = $value
        yield scalarEvent(asString, presentTag(T, ts), yAnchorNone)

template representObject*(value: float, tagStyle: TagStyle,
                          c: SerializationContext): RawYamlStream =
    {.fatal: "The length of `float` is platform dependent. Use float[32|64].".}

proc yamlTag*(T: typedesc[bool]): TagId {.inline, raises: [].} = yTagBoolean

proc constructObject*(s: var YamlStream, c: ConstructionContext,
                      result: var bool)
         {.raises: [YamlConstructionError, YamlStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(s, item, "bool", yTagBoolean):
        case guessType(item.scalarContent)
        of yTypeBoolTrue:
            result = true
        of yTypeBoolFalse:
            result = false
        else:
            raise newException(YamlConstructionError,
                    "Cannot construct to bool: " & item.scalarContent)
        
proc representObject*(value: bool, ts: TagStyle,
                      c: SerializationContext): RawYamlStream  {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield scalarEvent(if value: "y" else: "n", presentTag(bool, ts),
                          yAnchorNone)

proc constructObject*(s: var YamlStream, c: ConstructionContext,
                      result: var char)
        {.raises: [YamlConstructionError, YamlStreamError].} =
    var item: YamlStreamEvent
    constructScalarItem(s, item, "char", yTagNimChar):
        if item.scalarContent.len != 1:
            raise newException(YamlConstructionError,
                    "Cannot construct to char (length != 1): " &
                    item.scalarContent)
        else:
            result = item.scalarContent[0]

proc representObject*(value: char, ts: TagStyle,
                      c: SerializationContext): RawYamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield scalarEvent("" & value, presentTag(char, ts), yAnchorNone)

proc yamlTag*[I](T: typedesc[seq[I]]): TagId {.inline, raises: [].} =
    let uri = "!nim:system:seq(" & safeTagUri(yamlTag(I)) & ")"
    result = lazyLoadTag(uri)

proc constructObject*[T](s: var YamlStream, c: ConstructionContext,
                         result: var seq[T])
        {.raises: [YamlConstructionError, YamlStreamError].} =
    let event = s.next()
    if event.kind != yamlStartSequence:
        raise newException(YamlConstructionError, "Expected sequence start")
    if event.seqTag notin [yTagQuestionMark, yamlTag(seq[T])]:
        raise newException(YamlConstructionError, "Wrong tag for seq[T]")
    result = newSeq[T]()
    while s.peek().kind != yamlEndSequence:
        var item: T
        try: constructObject(s, c, item)
        except AssertionError, YamlConstructionError,
               YamlStreamError: raise
        except:
            # compiler bug: https://github.com/nim-lang/Nim/issues/3772
            assert(false)
        result.add(item)
    discard s.next()

proc representObject*[T](value: seq[T], ts: TagStyle,
        c: SerializationContext): RawYamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        let childTagStyle = if ts == tsRootOnly: tsNone else: ts
        yield YamlStreamEvent(kind: yamlStartSequence,
                              seqTag: presentTag(seq[T], ts),
                              seqAnchor: yAnchorNone)
        for item in value:
            var events = representObject(item, childTagStyle, c)
            while true:
                let event = events()
                if finished(events): break
                yield event
        yield YamlStreamEvent(kind: yamlEndSequence)

proc yamlTag*[K, V](T: typedesc[Table[K, V]]): TagId {.inline, raises: [].} =
    try:
        let
            keyUri     = serializationTagLibrary.uri(yamlTag(K))
            valueUri   = serializationTagLibrary.uri(yamlTag(V))
            keyIdent   = if keyUri[0] == '!': keyUri[1..keyUri.len - 1] else:
                         keyUri
            valueIdent = if valueUri[0] == '!':
                    valueUri[1..valueUri.len - 1] else: valueUri
            uri = "!nim:tables:Table(" & keyUri & "," & valueUri & ")"
        result = lazyLoadTag(uri)
    except KeyError:
        # cannot happen (theoretically, you known)
        assert(false)

proc constructObject*[K, V](s: var YamlStream, c: ConstructionContext,
                            result: var Table[K, V])
        {.raises: [YamlConstructionError, YamlStreamError].} =
    let event = s.next()
    if event.kind != yamlStartMap:
        raise newException(YamlConstructionError, "Expected map start, got " &
                           $event.kind)
    if event.mapTag notin [yTagQuestionMark, yamlTag(Table[K, V])]:
        raise newException(YamlConstructionError, "Wrong tag for Table[K, V]")
    result = initTable[K, V]()
    while s.peek.kind != yamlEndMap:
        var
            key: K
            value: V
        try:
            constructObject(s, c, key)
            constructObject(s, c, value)
        except AssertionError: raise
        except Exception:
            # compiler bug: https://github.com/nim-lang/Nim/issues/3772
            assert(false)
        result[key] = value
    discard s.next()

proc representObject*[K, V](value: Table[K, V], ts: TagStyle,
        c: SerializationContext): RawYamlStream {.raises:[].} =
    result = iterator(): YamlStreamEvent =
        let childTagStyle = if ts == tsRootOnly: tsNone else: ts
        yield YamlStreamEvent(kind: yamlStartMap,
                              mapTag: presentTag(Table[K, V], ts),
                              mapAnchor: yAnchorNone)
        for key, value in value.pairs:
            var events = representObject(key, childTagStyle, c)
            while true:
                let event = events()
                if finished(events): break
                yield event
            events = representObject(value, childTagStyle, c)
            while true:
                let event = events()
                if finished(events): break
                yield event
        yield YamlStreamEvent(kind: yamlEndMap)

template yamlTag*(T: typedesc[object|enum]): expr =
    var uri = when compiles(yamlTagId(T)): yamlTagId(T) else:
            "!nim:custom:" & (typetraits.name(type(T)))
    try:
        serializationTagLibrary.tags[uri]
    except KeyError:
        serializationTagLibrary.registerUri(uri)

template yamlTag*(T: typedesc[tuple]): expr =
    var
        i: T
        uri = "!nim:tuple("
        first = true
    for name, value in fieldPairs(i):
        if first: first = false
        else: uri.add(",")
        uri.add(safeTagUri(yamlTag(type(value))))
    uri.add(")")
    try: serializationTagLibrary.tags[uri]
    except KeyError: serializationTagLibrary.registerUri(uri)

proc constructObject*[O](s: var YamlStream, c: ConstructionContext,
                         result: var ref O)
        {.raises: [YamlConstructionError, YamlStreamError].}

proc constructObject*[O: object|tuple](s: var YamlStream,
                                       c: ConstructionContext,
                                       result: var O)
        {.raises: [YamlConstructionError, YamlStreamError].} =
    let e = s.next()
    if e.kind != yamlStartMap:
        raise newException(YamlConstructionError, "Expected map start, got " &
                           $e.kind)
    if e.mapAnchor != yAnchorNone:
        raise newException(YamlConstructionError, "Anchor on a non-ref type")
    while s.peek.kind != yamlEndMap:
        let e = s.next()
        if e.kind != yamlScalar:
            raise newException(YamlConstructionError,
                    "Expected field name, got " & $e.kind)
        let name = e.scalarContent
        for fname, value in fieldPairs(result):
            if fname == name:
                constructObject(s, c, value)
                break
    discard s.next()

proc representObject*[O: object|tuple](value: O, ts: TagStyle,
        c: SerializationContext): RawYamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        let childTagStyle = if ts == tsRootOnly: tsNone else: ts
        yield startMapEvent(presentTag(O, ts), yAnchorNone)
        for name, value in fieldPairs(value):
            yield scalarEvent(name, presentTag(string, childTagStyle),
                              yAnchorNone)
            var events = representObject(value, childTagStyle, c)
            while true:
                let event = events()
                if finished(events): break
                yield event
        yield endMapEvent()

proc constructObject*[O: enum](s: var YamlStream, c: ConstructionContext,
                               result: var O)
        {.raises: [YamlConstructionError, YamlStreamError].} =
    let e = s.next()
    if e.kind != yamlScalar:
        raise newException(YamlConstructionError, "Expected scalar, got " &
                           $e.kind)
    if e.scalarAnchor != yAnchorNone:
        raise newException(YamlConstructionError, "Anchor on a non-ref type")
    if e.scalarTag notin [yTagQuestionMark, yamlTag(O)]:
        raise newException(YamlConstructionError,
                           "Wrong tag for " & type(O).name)
    try: result = parseEnum[O](e.scalarContent)
    except ValueError:
        var ex = newException(YamlConstructionError, "Cannot parse '" &
                e.scalarContent & "' as " & type(O).name)
        ex.parent = getCurrentException()
        raise ex

proc representObject*[O: enum](value: O, ts: TagStyle,
        c: SerializationContext): RawYamlStream {.raises: [].} =
    result = iterator(): YamlStreamEvent =
        yield scalarEvent($value, presentTag(O, ts), yAnchorNone)

proc yamlTag*[O](T: typedesc[ref O]): TagId {.inline, raises: [].} = yamlTag(O)

proc constructObject*[O](s: var YamlStream, c: ConstructionContext,
                         result: var ref O) =
    var e = s.peek()
    if e.kind == yamlScalar:
        if e.scalarTag == yTagNull or (
                e.scalarTag in [yTagQuestionMark, yTagExclamationMark] and
                guessType(e.scalarContent) == yTypeNull):
            result = nil
            discard s.next()
            return
    elif e.kind == yamlAlias:
        try:
            result = cast[ref O](c.refs[e.aliasTarget])
            discard s.next()
            return
        except KeyError:
            assert(false)
    new(result)
    template removeAnchor(anchor: var AnchorId) {.dirty.} =
        if anchor != yAnchorNone:
            assert(not c.refs.hasKey(anchor))
            c.refs[anchor] = cast[pointer](result)
            anchor = yAnchorNone
    
    case e.kind
    of yamlScalar: removeAnchor(e.scalarAnchor)
    of yamlStartMap: removeAnchor(e.mapAnchor)
    of yamlStartSequence: removeAnchor(e.seqAnchor)
    else: assert(false)
    s.peek = e
    try:
        constructObject(s, c, result[])
    except YamlConstructionError, YamlStreamError, AssertionError:
        raise
    except Exception:
        var e = newException(YamlStreamError,
                             getCurrentExceptionMsg())
        e.parent = getCurrentException()
        raise e

proc representObject*[O](value: ref O, ts: TagStyle, c: SerializationContext):
        RawYamlStream {.raises: [].} =
    if value == nil:
        result = iterator(): YamlStreamEvent =
            yield scalarEvent("~", yTagNull)
    elif c.style == asNone:
        result = representObject(value[], ts, c)
    else:
        let
            p = cast[pointer](value)
        for i in countup(0, c.refsList.high):
            if p == c.refsList[i].p:
                c.refsList[i].count.inc()
                result = iterator(): YamlStreamEvent =
                    yield aliasEvent(if c.style == asAlways: AnchorId(i) else:
                                     cast[AnchorId](p))
                return
        c.refsList.add(initRefNodeData(p))
        let
            a = if c.style == asAlways: AnchorId(c.refsList.high) else:
                cast[AnchorId](p)
            childTagStyle = if ts == tsAll: tsAll else: tsRootOnly
        result = iterator(): YamlStreamEvent =
            var child = representObject(value[], childTagStyle, c)
            var first = child()
            assert(not finished(child))
            case first.kind 
            of yamlStartMap:
                first.mapAnchor = a
                if ts == tsNone: first.mapTag = yTagQuestionMark
            of yamlStartSequence:
                first.seqAnchor = a
                if ts == tsNone: first.seqTag = yTagQuestionMark
            of yamlScalar:
                first.scalarAnchor = a
                if ts == tsNone and guessType(first.scalarContent) != yTypeNull:
                    first.scalarTag = yTagQuestionMark
            else: discard
            yield first
            while true:
                let event = child()
                if finished(child): break
                yield event

proc construct*[T](s: var YamlStream, target: var T)
        {.raises: [YamlConstructionError, YamlStreamError].} =
    ## Construct a Nim value from a YAML stream.
    var
        context = newConstructionContext()
    try:
        var e = s.next()
        assert(e.kind == yamlStartDocument)
        
        constructObject(s, context, target)
        e = s.next()
        assert(e.kind == yamlEndDocument)
    except YamlConstructionError, YamlStreamError, AssertionError:
        raise
    except Exception:
        # may occur while calling s()
        var ex = newException(YamlStreamError, "")
        ex.parent = getCurrentException()
        raise ex

proc load*[K](input: Stream, target: var K)
        {.raises: [YamlConstructionError, IOError, YamlParserError].} =
    ## Load a Nim value from a YAML character stream.
    var
        parser = newYamlParser(serializationTagLibrary)
        events = parser.parse(input)
    try:
        construct(events, target)
    except YamlConstructionError, AssertionError:
        raise
    except YamlStreamError:
        let e = (ref YamlStreamError)(getCurrentException())
        if e.parent of IOError:
            raise (ref IOError)(e.parent)
        elif e.parent of YamlParserError:
            raise (ref YamlParserError)(e.parent)
        else:
            assert(false)
    except Exception:
        # compiler bug: https://github.com/nim-lang/Nim/issues/3772
        assert(false)

proc setAnchor(a: var AnchorId, q: var seq[RefNodeData], n: var AnchorId)
        {.inline.} =
    if a != yAnchorNone:
        let p = cast[pointer](a)
        for i in countup(0, q.len - 1):
            if p == q[i].p:
                if q[i].count > 1:
                    assert(q[i].anchor == yAnchorNone)
                    q[i].anchor = n
                    a = n
                    n = AnchorId(int(n) + 1)
                else:
                    a = yAnchorNone
                break

proc setAliasAnchor(a: var AnchorId, q: var seq[RefNodeData]) {.inline.} =
    let p = cast[pointer](a)
    for i in countup(0, q.len - 1):
        if p == q[i].p:
            assert q[i].count > 1
            assert q[i].anchor != yAnchorNone
            a = q[i].anchor
            return
    assert(false)
    
proc represent*[T](value: T, ts: TagStyle = tsRootOnly,
                   a: AnchorStyle = asTidy): YamlStream {.raises: [].} =
    ## Represent a Nim value as ``YamlStream``.
    var
        context = newSerializationContext(a)
        objStream = iterator(): YamlStreamEvent =
            yield YamlStreamEvent(kind: yamlStartDocument)
            var events = representObject(value, ts, context)
            while true:
                let e = events()
                if finished(events): break
                yield e
            yield YamlStreamEvent(kind: yamlEndDocument)
    if a == asTidy:
        var objQueue = newSeq[YamlStreamEvent]()
        try:
            for event in objStream():
                objQueue.add(event)
        except Exception:
            assert(false)
        var next = 0.AnchorId
        var backend = iterator(): YamlStreamEvent =
            for i in countup(0, objQueue.len - 1):
                var event = objQueue[i]
                case event.kind
                of yamlStartMap:
                    event.mapAnchor.setAnchor(context.refsList, next)
                of yamlStartSequence:
                    event.seqAnchor.setAnchor(context.refsList, next)
                of yamlScalar:
                    event.scalarAnchor.setAnchor(context.refsList, next)
                of yamlAlias:
                    event.aliasTarget.setAliasAnchor(context.refsList)
                else:
                    discard
                yield event
        result = initYamlStream(backend)
    else:
        result = initYamlStream(objStream)

proc dump*[K](value: K, target: Stream, style: PresentationStyle = psDefault,
              tagStyle: TagStyle = tsRootOnly,
              anchorStyle: AnchorStyle = asTidy, indentationStep: int = 2)
            {.raises: [YamlPresenterJsonError, YamlPresenterOutputError].} =
    ## Dump a Nim value as YAML character stream.
    var events = represent(value, if style == psCanonical: tsAll else: tagStyle,
                           if style == psJson: asNone else: anchorStyle)
    try:
        present(events, target, serializationTagLibrary, style, indentationStep)
    except YamlStreamError:
        # serializing object does not raise any errors, so we can ignore this
        var e = getCurrentException()
        assert(false)
    except YamlPresenterJsonError, YamlPresenterOutputError, AssertionError, FieldError:
        raise
    except Exception:
        # cannot occur as represent() doesn't raise any errors
        assert(false)