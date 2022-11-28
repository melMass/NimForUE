include ../unreal/prelude
import std/[times, strformat, tables, json, bitops, jsonUtils, strutils, options, sugar, algorithm, sequtils, hashes]
import fproperty
import models
include modelconstructor #For some odd reason (a cycle in the mod probably) if this is not included but imported the make* arent visible here?
export models
import emitter

const fnPrefixes = @["", "Receive", "K2_"]



func isTArray(prop: FPropertyPtr): bool = not castField[FArrayProperty](prop).isNil()
func isTMap(prop: FPropertyPtr): bool = not castField[FMapProperty](prop).isNil()
func isTSet(prop: FPropertyPtr): bool = not castField[FSetProperty](prop).isNil()
func isInterface(prop: FPropertyPtr): bool = not castField[FInterfaceProperty](prop).isNil()
func isTEnum(prop: FPropertyPtr): bool = "TEnumAsByte" in prop.getName()
func isTObjectPtr(prop: FPropertyPtr): bool = return false # "TObjectPtr" in prop.getCPPType()
func isDynDel(prop: FPropertyPtr): bool = not castField[FDelegateProperty](prop).isNil()
func isMulticastDel(prop: FPropertyPtr): bool = not castField[FMulticastDelegateProperty](prop).isNil()
#TODO Dels


func getNimTypeAsStr(prop: FPropertyPtr, outer: UObjectPtr): string = #The expected type is something that UEField can understand
  func cleanCppType(cppType: string): string =
    #Do multireplacehere
    let cppType =
      cppType.replace("<", "[")
              .replace(">", "]")
              .replace("*", "Ptr")
    if cppType == "float": return "float32"
    if cppType == "double": return "float64"
    return cppType
    

  if prop.isTArray():
    var innerType = castField[FArrayProperty](prop).getInnerProp().getCPPType()
    if prop.isTObjectPtr():
      innerType = innerType.getInnerCppGenericType()
    return fmt"TArray[{innerType.cleanCppType()}]"


  if prop.isTSet():
    var elementProp = castField[FSetProperty](prop).getElementProp().getCPPType()
    if prop.isTObjectPtr():
      elementProp = elementProp.getInnerCppGenericType()
    return fmt"TSet[{elementProp.cleanCppType()}]"

  if prop.isTMap(): #better pattern here, i.e. option chain
    let mapProp = castField[FMapProperty](prop)
    var keyType = mapProp.getKeyProp().getCPPType()
    var valueType = mapProp.getValueProp().getCPPType()

    if prop.isTObjectPtr():
      valueType = valueType.getInnerCppGenericType()

    return fmt"TMap[{keyType.cleanCppType()}, {valueType.cleanCppType()}]"

  try:
    # UE_Log &"Will get cpp type for prop {prop.getName()} NameCpp: {prop.getNameCPP()} and outer {outer.getName()}"

    let cppType = prop.getCPPType() #TODO review this. Hiphothesis it should not reach this point in the hotreload if the struct has the pointer to the prev ue type and therefore it shouldnt crash

    if cppType == "double": return "float64"
    if cppType == "float": return "float32"

    if prop.isTEnum(): #Not sure if it would be better to just support it on the macro
      return cppType.replace("TEnumAsByte<", "")
        .replace(">", "")
    if prop.isInterface():
      let class = castField[FInterfaceProperty](prop).getInterfaceClass()
      # UE_Warn &"Interface The cpp type is {cppType} and the inner class is {class}"
      return fmt"TScriptInterface[U{class.getName()}]"

    if prop.isTObjectPtr():
      UE_Log &"Will get cpp type for prop {prop.getName()} NameCpp: {prop.getNameCPP()}"
      return cppType.replace("TObjectPtr<", "")
        .replace(">", "") & "Ptr"

    let nimType = cppType.cleanCppType()

    # UE_Warn prop.getTypeName() #private?
    return nimType
  except:
    raise newException(Exception, fmt"Unsupported type {prop.getName()}")


func getUnrealTypeFromName[T](name: FString): Option[UObjectPtr] =
  #ScriptStruct, Classes
  result = tryUECast[UObject](getUTypeByName[T](name))
  # UE_Log &"Name: {name} result: {result}"

func tryGetUTypeByName[T](name: FString): Option[ptr T] =
  #ScriptStruct, Classes
  tryUECast[T](getUTypeByName[T](name))


func isBPExposed(ufun: UFunctionPtr): bool = FUNC_BlueprintCallable in ufun.functionFlags

func isBPExposed(str: UFieldPtr): bool = str.hasMetadata("BlueprintType")

func isBPExposed(str: UScriptStructPtr): bool = str.hasMetadata("BlueprintType")

func isBPExposed(cls: UClassPtr): bool =

  cls.hasMetadata("BlueprintType") or
  cls.hasMetadata("BlueprintSpawnableComponent") or
      (cast[uint32](CLASS_MinimalAPI) and cast[uint32](cls.classFlags)) != 0 or
      (cast[uint32](CLASS_Abstract) and cast[uint32](cls.classFlags)) != 0 or
      cls.getFuncsFromClass()
        .filter(isBPExposed)
        .any()


proc isBPExposed(prop: FPropertyPtr, outer: UObjectPtr): bool =
  var typeName = prop.getNimTypeAsStr(outer)
  if typeName.contains("TObjectPtr"):
    typeName = typeName.extractTypeFromGenericInNimFormat("TObjectPtr")
  typeName = typeName.removeFirstLetter()

  let isTypeExposed = tryGetUTypeByName[UClass](typeName).map(isBPExposed)
    .chainNone(()=>tryGetUTypeByName[UScriptStruct](typeName).map(isBPExposed))
    .chainNone(()=>tryGetUTypeByName[UFunction](prop.getNimTypeAsStr(outer)).map(isBPExposed))
    .get(true) #we assume it is by default

  let flags = prop.getPropertyFlags()
  (CPF_BlueprintVisible in flags or CPF_Parm in flags) and
  isTypeExposed

func isBPExposed(uenum: UEnumPtr): bool = true


func isNimTypeInAffectedTypes(nimType: string, affectedTypes: seq[string]): bool =
  let isAffected =
    affectedTypes
    .any(typ =>
        typ.removeLastLettersIfPtr() == nimType.removeLastLettersIfPtr() or
        typ == nimType.extractTypeFromGenericInNimFormat("TObjectPtr") or
        typ == nimType.extractTypeFromGenericInNimFormat("TArray")

      )

  # UE_Log &"Is affected {nimType} {isAffected}"
  isAffected


#Function that receives a FProperty and returns a Type as string
proc toUEField*(prop: FPropertyPtr, outer: UStructPtr, rules: seq[UEImportRule] = @[]): Option[UEField] = #The expected type is something that UEField can understand
  let name = prop.getName()

  var nimType = prop.getNimTypeAsStr(outer)
  if "TEnumAsByte" in nimType:
    nimType = nimType.extractTypeFromGenericInNimFormat("TEnumAsByte")
  if "TObjectPtr" in nimType:
    let objType = nimType.extractTypeFromGenericInNimFormat("TObjectPtr")
    nimType = nimType.replace(&"TObjectPtr[{objType}]", objType & "Ptr")

  for rule in rules:
    if rule.target == uerTField and rule.rule == uerIgnore and
        (name in rule.affectedTypes or isNimTypeInAffectedTypes(nimType, rule.affectedTypes)):
        return none(UEField)

  let importRule = rules.getRuleAffectingType(nimType, uerInnerClassDelegate)
  if importRule.isSome():
    # UE_Error &"Delegate {nimType} is affected by uerInnedClassDelegate"
    #the outer of this delegate should be the same outer as the property
    #notice these delegates are not ment to be used in your our type (the name wouldnt match, it can be fixed but doesnt make sense)
    let outerName = outer.getPrefixCpp() & outer.getName()
    let isEmpty = not importRule.get().onlyFor.any()
    if isEmpty or outerName in importRule.get().onlyFor:
      nimType = getFuncDelegateNimName(nimType, outerName)


  if (prop.isBpExposed(outer) or uerImportBlueprintOnly notin rules):
    some makeFieldAsUProp(name, nimType, prop.getPropertyFlags(), @[], prop.getSize(), prop.getOffset())
  else:
    none(UEField)


func toUEField*(ufun: UFunctionPtr, rules: seq[UEImportRule] = @[]): Option[UEField] =

  let paramsMb = getFPropsFromUStruct(ufun).map(x=>toUEField(x, ufun, rules))
  let params = paramsMb.sequence()
  let allParamsExposedToBp = len(params) == len(paramsMb)
  let class = ueCast[UClass](ufun.getOuter())
  let className = class.getPrefixCpp() & class.getName()
  let actualName: string = uFun.getName()
  let fnNameNim = actualName.removePrefixes(fnPrefixes)

  for rule in rules:
    if actualName in rule.affectedTypes and rule.target == uerTField and rule.rule == uerIgnore: #TODO extract
      UE_Log &"Ignoring {actualName} because it is in the ignore list"
      return none(UEField)

  
  let funMetadata = ufun.getMetadataMap().ueMetaToNueMeta()
  var fnField = makeFieldAsUFun(fnNameNim, params, className, ufun.functionFlags, funMetadata)
  fnField.actualFunctionName = actualName
  let isStatic = (FUNC_Static in ufun.functionFlags) #Skips static functions for now so we can quickly iterate over compiling the engine types
  if ((ufun.isBpExposed()) or uerImportBlueprintOnly notin rules):
    some fnField
  else:
    none(UEField)

func tryParseJson[T](jsonStr: string): Option[T] =
  {.cast(noSideEffect).}:
    try:
      some parseJson(jsonStr).jsonTo(T)
    except:
      UE_Error &"Crashed parsing json for with json {jsonStr}"
      none[T]()

func getFirstBpExposedParent(parent: UClassPtr): UClassPtr =
  if parent.isBpExposed():
    UE_Log &"Parent {parent.getName()} is exposed"
    parent
  else:    
    UE_Log &"Parent {parent} is NOT exposed"

    getFirstBpExposedParent(parent.getSuperClass())

func toUEType*(cls: UClassPtr, rules: seq[UEImportRule] = @[]): Option[UEType] =
  
  let storedUEType = 
    cls.getMetadata(UETypeMetadataKey)
       .flatMap((x:FString)=>tryParseJson[UEType](x))

  if storedUEType.isSome(): return storedUEType

  let fields =  getFuncsFromClass(cls)
                  .map(fn=>toUEField(fn, rules)).sequence() &
                getFPropsFromUStruct(cls)
                  .map(prop=>toUEField(prop, cls, rules))
                  .sequence()


  let name = cls.getPrefixCpp() & cls.getName()
  let parent = someNil cls.getSuperClass()


  let parentName = parent
    .map(p => (if uerImportBlueprintOnly in rules: getFirstBpExposedParent(p) else: p))
    .map(p=>p.getPrefixCpp() & p.getName()).get("")

  let namePrefixed = cls.getPrefixCpp() & cls.getName()
  let shouldBeIgnored = (name: string, rule: UEImportRule) => name in rule.affectedTypes and rule.target == uertType and rule.rule == uerIgnore
  for rule in rules:
    if shouldBeIgnored(name, rule) or (parentName != "" and shouldBeIgnored(parentName, rule)):
      UE_Log &"Ignoring {name} because it is in the ignore list"
      return none(UEType)

  if cls.isBpExposed() or uerImportBlueprintOnly notin rules:
    some UEType(name: name, kind: uetClass, parent: parentName, fields: fields)
  else:
    # UE_Warn &"Class {name} is not exposed to BP"
    none(UEType)


func toUEType*(str: UScriptStructPtr, rules: seq[UEImportRule] = @[]): Option[UEType] =
  #same as above
  let storedUEType = 
    str.getMetadata(UETypeMetadataKey)
       .flatMap((x:FString)=>tryParseJson[UEType](x))
  
  if storedUEType.isSome(): return storedUEType

  let name = str.getPrefixCpp() & str.getName()

  let fields = getFPropsFromUStruct(str)
    .map(x=>toUEField(x, str, rules))
    .sequence()

  let metadata = str.getMetaDataMap()
    .toTable()
    .pairs
    .toSeq()
    .mapIt(makeUEMetadata($it[0], it[1]))

  for rule in rules:
    if name in rule.affectedTypes and rule.rule == uerIgnore:
      return none(UEType)

  # let parent = str.getSuperClass()
  # let parentName = parent.getPrefixCpp() & parent.getName()
  if str.isBpExposed() or uerImportBlueprintOnly notin rules:
    var size, alignment: int32
    if str.hasStructOps():
      size = str.getSize()
      alignment = str.getAlignment()
    else:
      UE_Warn &"The struct {str} does not have StructOps therefore we cant calculate the size and alignment"

    some UEType(name: name, kind: uetStruct, fields: fields, metadata: metadata, size: size, alignment: alignment)
  else:
    # UE_Warn &"Struct {name} is not exposed to BP"
    none(UEType)


func toUEType*(del: UDelegateFunctionPtr, rules: seq[UEImportRule] = @[]): Option[UEType] =
  let storedUEType = 
    del.getMetadata(UETypeMetadataKey)
       .flatMap((x:FString)=>tryParseJson[UEType](x))

  if storedUEType.isSome(): return storedUEType

  var name = del.getPrefixCpp() & del.getName()

  let fields = getFPropsFromUStruct(del)
    .map(x=>toUEField(x, del, rules))
    .sequence()

  let nameWithoutSuffix = name.replace(DelegateFuncSuffix, "")
  for rule in rules:
    if nameWithoutSuffix in rule.affectedTypes and rule.rule == uerIgnore:
      UE_Warn &"Ignoring {name} because it is in the ignore list"
      return none(UEType)

  #TODO is defaulting to MulticastDelegate this may be wrong when trying to autogen the types
  #Maybe I can just cast it?
  # none(UEType)
  let kind = if FUNC_MulticastDelegate in del.functionFlags: uedelMulticastDynScriptDelegate else: uedelDynScriptDelegate
    #Handle class inner delegates:
  let outer = tryUECast[UClass](del.getOuter())
  let outerName = outer.map(cls => $(cls.getPrefixCpp() & cls.getName())).get("")
  let importRule = rules.getRuleAffectingType(nameWithoutSuffix, uerInnerClassDelegate)
  if importRule.isSome():
    let isEmpty = not importRule.get().onlyFor.any()
    if isEmpty or outerName in importRule.get().onlyFor:
      name = getFuncDelegateNimName(name, outerName)

  some UEType(name: name, kind: uetDelegate, delKind: kind, fields: fields.reversed(), outerClassName: outerName)
  # else:
  #     UE_Log &"Delegate {name} is not exposed to BP"
  #     none(UEType)

func toUEType*(uenum: UEnumPtr, rules: seq[UEImportRule] = @[]): Option[UEType] = #notice we have to specify the type because we use specific functions here. All types are Nim base types
    # let fields = getFPropsFromUStruct(enum).map(toUEField)
  let storedUEType = 
    uenum.getMetadata(UETypeMetadataKey)
       .flatMap((x:FString)=>tryParseJson[UEType](x))

  if storedUEType.isSome(): return storedUEType

  let name = uenum.getName()
  var fields = newSeq[UEField]()
  for fieldName in uenum.getEnums():
    if fieldName.toLowerAscii() in fields.mapIt(it.name.toLowerAscii()):
      # UE_Warn &"Skipping enum value {fieldName} in {name} because it collides with another field."
      continue

    fields.add(makeFieldASUEnum(fieldName.removePref("_")))


  if uenum.isBpExposed():
    some UEType(name: name, kind: uetEnum, fields: fields)
  else:
    UE_Warn &"Enum {name} is not exposed to BP"
    none(UEType)

func convertToUEType[T](obj: UObjectPtr, rules: seq[UEImportRule] = @[]): Option[UEType] =
  tryUECast[T](obj).flatMap((val: ptr T)=>toUEType(val, rules))

proc getUETypeFrom(obj: UObjectPtr, rules: seq[UEImportRule] = @[]): Option[UEType] =
  if obj.getFlags() & RF_ClassDefaultObject == RF_ClassDefaultObject:
    return none[UEType]()

  convertToUEType[UClass](obj, rules)
    .chainNone(()=>convertToUEType[UScriptStruct](obj, rules))
    .chainNone(()=>convertToUEType[UEnum](obj, rules))
    .chainNone(()=>convertToUEType[UDelegateFunction](obj, rules))

func getFPropertiesFrom*(ueType: UEType): seq[FPropertyPtr] =
  case ueType.kind:
  of uetClass:
    let outer = getUTypeByName[UClass](ueType.name.removeFirstLetter())
    if outer.isNil(): return @[] #Deprecated classes are the only thing that can return nil.

    let props = outer.getFPropsFromUStruct() &
                outer.getFuncsParamsFromClass()
    # for p in props:
    #     UE_Log p.getCppType()
    props

  of uetStruct, uetDelegate:
    tryGetUTypeByName[UStruct](ueType.name.removeFirstLetter())
      .map((str: UStructPtr)=>str.getFPropsFromUStruct())
      .get(@[])

  of uetEnum: @[]


#returns all modules neccesary to reference the UEType
func getModuleNames*(ueType: UEType, excludeMods:seq[string]= @[]): seq[string] =
  #only uStructs based for now
  let typesToSkip = @["uint8", "uint16", "uint32", "uint64",
                      "int", "int8", "int16", "int32", "int64",
                      "float", "float32", "double",
                      "bool", "FString", "TArray"
    ]
  func filterType(typeName: string): bool = typeName notin typesToSkip
  proc typeToModule(propType: string): Option[string] =
    getUnrealTypeFromName[UStruct](propType.removeFirstLetter().removeLastLettersIfPtr())
      .chainNone(()=>getUnrealTypeFromName[UEnum](propType.extractTypeFromGenericInNimFormat("TEnumAsByte")))
      .chainNone(()=>getUnrealTypeFromName[UStruct](propType))
      .map((obj: UObjectPtr) => $obj.getModuleName())

  let depsFromProps =
    ueType
      .getFPropertiesFrom()
      .mapIt(getNimTypeAsStr(it, nil))

  let otherDeps =
    case ueType.kind:
    of uetClass: ueType.parent
    else: ueType.name
  let fieldsMissedProps =
    ueType
      .fields
      .filterIt(it.kind == uefProp and it.uePropType notin depsFromProps)
      .mapIt(it.uePropType)
  (depsFromProps & otherDeps & fieldsMissedProps)
    # .mapIt(getInnerCppGenericType($it.getCppType()))
    .filter(filterType)
    .map(getNameOfUENamespacedEnum)
    .map(typeToModule)
    .sequence()
    .deduplicate()
    .filterIt(it notin excludeMods)

func getModuleHeader*(module: UEModule): seq[string] =
  module.types
    .filterIt(it.kind == uetStruct)
    .mapIt(it.metadata["ModuleRelativePath"])
    .sequence()
    .mapIt(&"""#include "{it}" """)


proc toUEModule*(pkg: UPackagePtr, rules: seq[UEImportRule], excludeDeps: seq[string], includeDeps: seq[string]): seq[UEModule] =
  let allObjs = pkg.getAllObjectsFromPackage[:UObject]()
  let name = pkg.getShortName()
  var types = allObjs.toSeq()
    .map((obj: UObjectPtr) => getUETypeFrom(obj, rules))
    .sequence()

  let excludeFromModuleNames = @["CoreUObject", name]
  let deps = (types
    .mapIt(it.getModuleNames(excludeFromModuleNames))
    .foldl(a & b, newSeq[string]()) & includeDeps)
    .deduplicate()
    .filterIt(it != name and it notin excludeDeps)

  #TODO Per module add them to a virtual module
  let excludedTypes = types.filterIt(it.getModuleNames(excludeFromModuleNames).any(modName => modName in excludeDeps))
  for t in excludedTypes:
    UE_Warn &"Module: + {name} Excluding {t.name} from {name} because it depends on {t.getModuleNames(excludeFromModuleNames)}"

  types = types.filterIt(it notin excludedTypes)
  #Virtual modules
  var virtModules = newSeq[UEModule]()
  for r in rules:
    if r.rule == uerVirtualModule:
      let r = r
      let (virtualModuleTypes, types) = types.partition((x: UEType) => x.name in r.affectedTypes)
      virtModules.add UEModule(name: r.moduleName, types: virtualModuleTypes, isVirtual: true, dependencies: deps & name)

  UE_Log &"Module: + {name} Types: {types.mapIt(it.name)} Excluded types: {excludedTypes.mapIt(it.name)}"
  UE_Warn &"Module: + {name} excluded deps: {excludeDeps}"

  # UE_Log &"Deps for {name}: {deps}"
  var module = makeUEModule(name, types, rules, deps)
  module.hash = $hash($module.toJson())
  module & virtModules


proc emitFProperty*(propField: UEField, outer: UStructPtr): FPropertyPtr =
  assert propField.kind == uefProp

  let prop: FPropertyPtr = newFProperty(makeFieldVariant outer, propField)
  prop.setPropertyFlags(propField.propFlags or prop.getPropertyFlags())
  for metadata in propField.metadata:
    prop.setMetadata(metadata.name, $metadata.value)
  outer.addCppProperty(prop)
  prop


#this functions should only being use when trying to resolve
#the nim name in unreal on the emit, when the actual name is not set already.
#it is also taking into consideration when converting from ue to nim via UClass->UEType
func findFunctionByNameWithPrefixes*(cls: UClassPtr, name: string): Option[UFunctionPtr] =
  for prefix in fnPrefixes:
    let fnName = prefix & name
    # assert not cls.isNil()
    if cls.isNil():
      return none[UFunctionPtr]()
    let fun = cls.findFunctionByName(makeFName(fnName))
    if not fun.isNil():
      return some fun

  none[UFunctionPtr]()

#note at some point class can be resolved from the UEField?
proc emitUFunction*(fnField: UEField, cls: UClassPtr, fnImpl: Option[UFunctionNativeSignature]): UFunctionPtr =
  let superCls = someNil(cls.getSuperClass())
  let superFn = superCls.flatmap((scls: UClassPtr)=>scls.findFunctionByNameWithPrefixes(fnField.name))

  #if we are overriden a function we use the name with the prefix
  #notice this only works with BlueprintEvent so check that too.
  let fnName = superFn.map(fn=>fn.getName().makeFName()).get(fnField.name.makeFName())


  const objFlags = RF_Public | RF_Transient | RF_MarkAsRootSet | RF_MarkAsNative
  var fn = newUObject[UNimFunction](cls, fnName, objFlags)
  fn.functionFlags = EFunctionFlags(fnField.fnFlags)

  if superFn.isSome():
    let sFn = superFn.get()
    fn.functionFlags = (fn.functionFlags | (sFn.functionFlags & (FUNC_FuncInherit | FUNC_Public | FUNC_Protected | FUNC_Private | FUNC_BlueprintPure | FUNC_HasOutParms)))

    copyMetadata(sFn, fn)
    fn.setMetadata("ToolTip", fn.getMetadata("ToolTip").get()&" vNim")
    setSuperStruct(fn, sFn)


  fn.Next = cls.Children
  cls.Children = fn

  for field in fnField.signature.reversed():
    let fprop = field.emitFProperty(fn)
  
  UE_Log &"FNName: {fn.getName()} Metadata {fnField.metadata}"

  if superFn.isNone():
    for metadata in fnField.metadata:
      fn.setMetadata(metadata.name, $metadata.value)

  cls.addFunctionToFunctionMap(fn, fnName)
  if fnImpl.isSome(): #blueprint implementable events doesnt have a function implementation
    fn.setNativeFunc(makeFNativeFuncPtr(fnImpl.get()))
  fn.staticLink(true)
  fn.sourceHash = $hash(fnField.sourceHash)
  # fn.parmsSize = uprops.foldl(a + b.getSize(), 0) doesnt seem this is necessary
  fn


proc isNotNil[T](x: ptr T): bool = not x.isNil()
proc isNimClassBase(cls: UClassPtr): bool = cls.isNimClass()

#This always be appened at the default constructor at the beggining
proc callSuperConstructor*(initializer: var FObjectInitializer) {.cdecl.} =
  let obj = initializer.getObj()
  let cls = obj.getClass()
  let cppCls = cls.getFirstCppClass()
  cppCls.classConstructor(initializer)
#This needs to be appended after the default constructor so comps can be init
proc postConstructor*(initializer: var FObjectInitializer) {.cdecl.} =
  let obj = initializer.getObj()
  let actor = tryUECast[AActor](obj)
  if actor.isSome():
    if actor.get().rootComponent.isnil():
        actor.get().rootComponent = initializer.createDefaultSubobject[:USceneComponent](n"DefaultSceneRoot")
  
proc defaultConstructor*(initializer: var FObjectInitializer) {.cdecl.} =
  callSuperConstructor(initializer)
  postConstructor(initializer)


proc setGIsUCCMakeStandaloneHeaderGenerator*(value: bool) {.importcpp: "(GIsUCCMakeStandaloneHeaderGenerator =#)".}

proc emitUClass*(ueType: UEType, package: UPackagePtr, fnTable: seq[FnEmitter], clsConstructor: Option[CtorInfo]): UFieldPtr =
  const objClsFlags = (RF_Public | RF_Transient | RF_Transactional | RF_WasLoaded | RF_MarkAsNative)

  let
    newCls = newUObject[UClass](package, makeFName(ueType.name.removeFirstLetter()), cast[EObjectFlags](objClsFlags))
    parentCls = someNil(getClassByName(ueType.parent.removeFirstLetter()))

  let parent = parentCls
    .getOrRaise(fmt "Parent class {ueType.parent} not found for {ueType.name}")

  assetCreated(newCls)

  newCls.propertyLink = parent.propertyLink
  newCls.classWithin = parent.classWithin
  newCls.classConfigName = parent.classConfigName

  newCls.setSuperStruct(parent)

  # use explicit casting between uint32 and enum to avoid range checking bug https://github.com/nim-lang/Nim/issues/20024
  newCls.classFlags = cast[EClassFlags](ueType.clsFlags.uint32 and parent.classFlags.uint32)
  newCls.classCastFlags = parent.classCastFlags

  copyMetadata(parent, newCls)
  # newCls.setMetadata("IsBlueprintBase", "true") #todo move to ueType. BlueprintType should be producing this
  # newCls.setMetadata("BlueprintType", "true") #todo move to ueType
  newCls.markAsNimClass()
  for metadata in ueType.metadata:
    newCls.setMetadata(metadata.name, $metadata.value)

  for field in ueType.fields:
    case field.kind:
    of uefProp: discard field.emitFProperty(newCls)
    of uefFunction:
      # UE_Log fmt"Emitting function {field.name} in class {newCls.getName()}" #notice each module emits its own functions  
      discard emitUFunction(field, newCls, getNativeFuncImplPtrFromUEField(getGlobalEmitter(), field))
    else:
      UE_Error("Unsupported field kind: " & $field.kind)
    #should gather the functions here?

  newCls.staticLink(true)
 
  setGIsUCCMakeStandaloneHeaderGenerator(true)
  newCls.bindType()
  setGIsUCCMakeStandaloneHeaderGenerator(false)
  newCls.assembleReferenceTokenStream()

  newCls.setClassConstructor(clsConstructor.map(ctor=>ctor.fn).get(defaultConstructor))
  clsConstructor.run(proc (cons: CtorInfo) =
    newCls.setMetadata(ClassConstructorMetadataKey, cons.hash)
  )

  newCls.setMetadata(UETypeMetadataKey, $ueType.toJson())


  discard newCls.getDefaultObject() #forces the creation of the cdo. the LC reinstancer needs it created before the object gets nulled out
    # broadcastAsset(newCls) Dont think this is needed since the notification will be done in the boundary of the plugin
  newCls


proc emitUStruct*[T](ueType: UEType, package: UPackagePtr): UFieldPtr =
  const objClsFlags = (RF_Public | RF_Transient | RF_MarkAsNative)
  let scriptStruct = newUObject[UNimScriptStruct](package, makeFName(ueType.name.removeFirstLetter()), objClsFlags)

  # scriptStruct.setMetadata("BlueprintType", "true") #todo move to ueType
  for metadata in ueType.metadata:
    scriptStruct.setMetadata(metadata.name, $metadata.value)

  scriptStruct.assetCreated()

  for field in ueType.fields:
    discard field.emitFProperty(scriptStruct)

  setCppStructOpFor[T](scriptStruct, nil)
  scriptStruct.bindType()
  scriptStruct.staticLink(true)
  scriptStruct.setMetadata(UETypeMetadataKey, $ueType.toJson())
  scriptStruct

proc emitUStruct*[T](ueType: UEType, package: string): UFieldPtr =
  let package = getPackageByName(package)
  if package.isnil():
    raise newException(Exception, "Package not found!")
  emitUStruct[T](ueType, package)

proc emitUEnum*(enumType: UEType, package: UPackagePtr): UFieldPtr =
  let name = enumType.name.makeFName()
  const objFlags = RF_Public | RF_Transient | RF_MarkAsNative
  let uenum = newUObject[UNimEnum](package, name, objFlags)
  for metadata in enumType.metadata:
    uenum.setMetadata(metadata.name, $metadata.value)
  let enumFields = makeTArray[TPair[FName, int64]]()
  for field in enumType.fields.pairs:
    let fieldName = field.val.name.makeFName()
    enumFields.add(makeTPair(fieldName, field.key.int64))
    # uenum.setMetadata("DisplayName", "Whatever"&field.val.name)) TODO the display name seems to be stored into a metadata prop that isnt the one we usually use
  discard uenum.setEnums(enumFields)
  uenum.setMetadata(UETypeMetadataKey, $enumType.toJson())

  uenum

proc emitUDelegate*(delType: UEType, package: UPackagePtr): UFieldPtr =
  let fnName = (delType.name.removeFirstLetter() & DelegateFuncSuffix).makeFName()
  const objFlags = RF_Public | RF_Transient | RF_MarkAsNative
  var fn = newUObject[UDelegateFunction](package, fnName, objFlags)
  fn.functionFlags = FUNC_MulticastDelegate or FUNC_Delegate
  for field in delType.fields.reversed():
    let fprop = field.emitFProperty(fn)
    # UE_Warn "Has Return " & $ (CPF_ReturnParm in fprop.getPropertyFlags())

  fn.staticLink(true)
  fn.setMetadata(UETypeMetadataKey, $delType.toJson())
  fn

proc createUFunctionInClass*(cls: UClassPtr, fnField: UEField, fnImpl: UFunctionNativeSignature): UFunctionPtr {.deprecated: "use emitUFunction instead".} =
  fnField.emitUFunction(cls, some fnImpl)



