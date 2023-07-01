include ../unreal/prelude
import ../unreal/editor/editor

import ../../buildscripts/[nimforueconfig]
import ../unreal/core/containers/containers

import std/[os, times, asyncdispatch, json, jsonutils, tables, hashes]
import std/[strutils, options, tables, sequtils, strformat, strutils, sugar]

import compiler / [ast, nimeval, vmdef, vm, llstream, types, lineinfos]
import compiler/options as copt
import ../vm/[uecall, runtimefield, vmconversion]
import ../codegen/[uemeta, projectinstrospect]
import ../utils/utils

const engineTypesModule = NimModules.filterIt(it.name == "enginetypes").head.get
const vmBindingsDir = PluginDir / "src" / "nimforue" / "unreal" / "bindings" / "vm"

static:
  genVMModuleFiles(vmBindingsDir, NimModules) 

type   
  VMQuit* = object of CatchableError
    info*: TLineInfo

proc getArg(a: VmArgs, i: int): TFullReg =
  result = a.slots[i+a.rb+1]

template measureTime*(name: static string, body: untyped) =
  let starts = times.now()
  body
  let ends = (times.now() - starts)
  let msg = name & " took " & $ends & "  seconds"
  UE_Log msg
 

proc onInterpreterError(config: ConfigRef, info: TLineInfo, msg: string, severity : Severity)  {.gcsafe.}  = 
  if severity == Severity.Error and config.error_counter >= config.error_max:
    var fileName: string
    for k, v in config.m.filenameToIndexTbl.pairs:
      if v == info.fileIndex:
        fileName = k
    UE_Error "Script Error: $1:$2:$3 $4." % [fileName, $info.line, $(info.col + 1), msg]
    raise (ref VMQuit)(info: info, msg: msg)


proc uCallInteropHostImpl(a:VmArgs) =  
  safe:
    let node : PNode = a.getArg(0).node
    let ueCall = fromVm(UECall, node)
    let result = ueCall.uCall()
    # UE_Warn &"uCallInterop result: {result}"    
    setResult(a, toVm(result))        


type 
  SomeObject* = object
    a : int 
  SomeObjectPtr* = ptr SomeObject

var someObject = SomeObject(a:10)
proc implementBaseFunctions(interpreter:Interpreter) = 
  #TODO review this. Maybe even something like nimscripter can help
   #This function can be implemented with uebind directly 
  interpreter.implementRoutine("NimForUE", "exposed", "log", proc (a: VmArgs) =
      let msg = a.getString(0)
      UE_Log msg
      discard
    )


  interpreter.implementRoutine("NimForUE", "exposed", "uCallInterop", uCallInteropHostImpl)

  #This function can be implemented with uebind directly 
  interpreter.implementRoutine("NimForUE", "exposed", "getClassByNameInterop", proc (a: VmArgs) =
      let className = a.getString(0)
      let cls = getClassByName(className)
      let classAddr = cast[int](cls)
      setResult(a, classAddr)
      discard
    )

  interpreter.implementRoutine("NimForUE", "exposed", "newUObjectInterop", proc (a: VmArgs) =
      #It needs cls and owner which can be nil
      let owner = cast[UObjectPtr](getInt(a, 0))
      let cls = cast[UClassPtr](getInt(a, 1))

      let obj = newObjectFromClass(owner, cls, ENone)
      obj.setFlags(RF_MarkAsRootSet)
      let objAddr = cast[int](obj)
      setResult(a, objAddr)
      discard
    )
    
  interpreter.implementRoutine("NimForUE", "exposed", "getSomeObjectPtr", proc (a: VmArgs) =
    let objAddr = cast[int](someObject.addr)      
    #  let node = newIntNode()
    setResult(a, objAddr)     
  )
  
  interpreter.implementRoutine("NimForUE", "corevm", "castIntToPtr", proc (a: VmArgs) =    
    setResult(a, getInt(a, 0))     
  )
  interpreter.implementRoutine("NimForUE", "exposed", "deref", proc (a: VmArgs) =    
    let address = getInt(a, 0)
    let valueAddr = cast[ptr int](address)
    if valueAddr.isNotNil:
      setResult(a, valueAddr[])     
    else:
      UE_Error &"deref: address is nil"
      setResult(a, 0)
  )

  #This function can be implemented with uebind directly 
  interpreter.implementRoutine("NimForUE", "exposed", "getName", proc(a: VmArgs) =
      let actor = cast[UObjectPtr](getInt(a, 0))
      if actor.isNil():
        setResult(a, "nil")
      else:
        setResult(a, actor.getName())
      # setResult(a, $actor.getName())
    )





func getVMImplFuncName*(info : UEBorrowInfo): string = (info.fnName & "VmImpl")

# var borrowedFns = newSeq[UFunctionNativeSignature]()
type BorrowKey = distinct string
proc hash(key: BorrowKey): Hash {.borrow.}
proc `==`(a, b: BorrowKey): bool {.borrow.}
proc `$`(key: BorrowKey): string {.borrow.}
var borrowTable = initTable[BorrowKey, UEBorrowInfo]() 
func getBorrowKey*(fn: UFunctionPtr): BorrowKey =  BorrowKey($(fn.getOuter().getName() & fn.getName())) #ClassNoPrefix_FuncName
func getBorrowKey*(borrow: UEBorrowInfo): BorrowKey = BorrowKey(borrow.className & borrow.fnName.capitalizeAscii()) #Note this is not reliable as it doesnt account for prefixes. It's only used for the vmconstructor
#[
  [] Functions are being replaced, we need to store them with a table. 
]#


var interpreter : Interpreter #needs to be global so it can be accesed from cdecl
var isInterpreterInit: bool

proc getValueFromPropInFn[T](context: UObjectPtr, stack: var FFrame) : T = 
  #does the same thing as StepCompiledIn but you dont need to know the type of the Fproperty upfront (which we dont)

  var paramValue {.inject.} : T #Define the param
  var paramAddr = cast[pointer](paramValue.addr) #Cast the Param with   
  if not stack.code.isNil():
      stack.step(context, paramAddr)
  else:
      var prop = cast[FPropertyPtr](stack.propertyChainForCompiledIn)
      stack.propertyChainForCompiledIn = stack.propertyChainForCompiledIn.next
      stepExplicitProperty(stack, paramAddr, prop)
  paramValue





proc borrowImpl(context: UObjectPtr; stack: var FFrame; returnResult: pointer) : void {.cdecl.} =
    stack.increaseStack()
    let fn = stack.node
    let borrowKey = fn.getBorrowKey()
    let borrowInfo = borrowTable[borrowKey]
    let vmFn = interpreter.selectRoutine(borrowInfo.getVMImplFuncName)
    if vmFn.isNil():
      UE_Error &"script does not export a proc of the name: {borrowInfo.fnName}"
      UE_Log &"All exported funcs: {borrowTable}"
      return
    #TODO pass params as json to vm call (from stack but review how it's done in uebind)
    try:
      
      var argsAsRtField = RuntimeField(kind:Struct)
      let propParams = fn.getFPropsFromUStruct().filterIt(it != fn.getReturnProperty())  
    #   for prop in propParams:
    #     let propName = prop.getName().firstToLow()
    #     let nimTypeStr = getNimTypeAsStr(prop, context).toJson()

    #     if prop.isInt() or prop.isObjectBased(): #ints a pointers 
    #       args.add(propName, getValueFromPropInFn[int](context, stack).toRuntimeField())
    #     if prop.isFloat():
    #       args.add(propName, getValueFromPropInFn[float](context, stack).toRuntimeField())
        
    #     if prop.isStruct():
    #       let structProp = castField[FStructProperty](prop)
    #       let scriptStruct = structProp.getScriptStruct()
    #       let structProps = scriptStruct.getFPropsFromUStruct() #Lets just do this here before making it recursive
    #       if structProps.any():                     
    #         let structValPtr = getValueFromPropInFn[pointer](context, stack) #TODO stepIn should be enough
    #         args.add(structProp.getName(), getProp(structProp, stack.mostRecentPropertyAddress))# getValueFromPropMemoryBlock(structProp, cast[ByteAddress](stack.mostRecentPropertyAddress))
    #       else:
    #          UE_Warn &" {scriptStruct.getName()} struct `{propName}` prop doesnt have any props"    


      for prop in propParams:
        discard getValueFromPropInFn[pointer](context, stack) #step in (review)
        let argName = prop.getName().firstToLow()
        let rtArg = getProp(prop, stack.mostRecentPropertyAddress)
        argsAsRtField.add(argName, rtArg)


        #ahora solo hay un entero
      let ueCallNode = makeUECall(makeUEFunc(borrowInfo.fnName, borrowInfo.className), context, argsAsRtField).toVm()
      let res = interpreter.callRoutine(vmFn, [ueCallNode])

      let returnProp = fn.getReturnProperty()
      if fn.doesReturn():
        let returnRuntimeField = fromVm(RuntimeField, res)
        returnRuntimeField.setProp(returnProp, returnResult)
    except:
      UE_Error &"error calling {borrowInfo.fnName} in script"
      UE_Error getCurrentExceptionMsg()
      UE_Error getStackTrace()
    #TODO return value


proc implementNativeFunc(borrowInfo: UEBorrowInfo) = 
  safe: 
    #Extract func here
    #At this point it will be the last added or not because it can be updated
    #But let's assume it's the case (we could use a stack or just store the last one separatedly)
    let cls = getClassByName(borrowInfo.className)
    if cls.isNil():
      UE_Error &"could not find class {borrowInfo.className}"

      return

    let ueBorrowUFunc = cls.findFunctionByNameWithPrefixes(borrowInfo.fnName.capitalizeAscii())
    if ueBorrowUFunc.isNone(): 
        UE_Error &"could not find function { borrowInfo.fnName} in class {borrowInfo.className}"
        return
    
    let borrowKey = ueBorrowUFunc.get.getBorrowKey()
    borrowTable.addOrUpdate(borrowKey, borrowInfo)
    UE_Log &"Borrow is Setup!Borrowing {borrowInfo.fnName} from {borrowInfo.className}"
    #notice we could store the prev version to restore it later on 
    ueBorrowUFunc.get.setNativeFunc((cast[FNativeFuncPtr](borrowImpl)))

proc setupBorrow(interpreter:Interpreter) = 
  interpreter.implementRoutine("NimForUE", "exposed", "setupBorrowInterop", proc(a: VmArgs) =
    safe:
      var borrowInfo = a.getString(0).parseJson().jsonTo(UEBorrowInfo)              
      implementNativeFunc(borrowInfo)
      if borrowInfo.isVmDefaultConstructor(): #we need to call the constructor right away
        let vmFn = interpreter.selectRoutine(borrowInfo.getVMImplFuncName)
        if vmFn.isNil():
          UE_Error &"script does not export a proc of the name: {borrowInfo.fnName}"
          UE_Log &"All exported funcs: {borrowTable}"
          return
        let cdo = getClassByName(borrowInfo.className).getDefaultObject()
        var args = RuntimeField(kind:Struct)
        args.add("self", cdo.toRuntimeField())
        let ueCallNode = makeUECall(makeUEFunc(borrowInfo.fnName, borrowInfo.className), cdo, args).toVm()
        let res = interpreter.callRoutine(vmFn, [ueCallNode])      
  )


var userSearchPaths : seq[string] = @[]
proc initInterpreterImpl(searchPaths:seq[string], script: string = "script.nim") : Interpreter = 
  let std = findNimStdLibCompileTime()
  interpreter = createInterpreter(script, @[
    std,
    std / "pure",
    std / "pure" / "collections",
    std / "core", 
    PluginDir / "src" / "nimforue",
    PluginDir/"src"/"nimforue"/"utils",
    PluginDir/"src"/"nimforue"/"unreal"/"bindings"/"vm",
    parentDir(currentSourcePath),
   
    ] & searchPaths,
    defines = @[("nimscript", "true"), ("nimvm", "true"), ("nuevm", "true")],    
    )
  interpreter.registerErrorHook(onInterpreterError)
  interpreter.implementBaseFunctions()
  interpreter.setupBorrow()
  userSearchPaths = searchPaths
  UE_Log &"NimForUE VM initialized"
  UE_Log &"Search paths: {userSearchPaths}"  

  interpreter

proc evalString(intr: Interpreter; code: string) =
  let stream = llStreamOpen(code)
  intr.evalScript(stream)
  llStreamClose(stream)

proc initInterpreter() {.cdecl.} =   
  measureTime "Initializing VM in background thread":
    interpreter = initInterpreterImpl(@[NimGameDir() / "vm"])
    let initCode = """
import std/[strformat, sequtils, macros, tables, options, sugar, strutils, genasts, json, jsonutils, bitops, typetraits]
import engine/[common, components, gameframework, engine, camera]
import gameplayabilities/[abilities, gameplayabilities, enums]
import enhancedinput
import utils/[ueutils,utils]
  """
    interpreter.evalString(initCode)

proc onInterpreterInit() {.cdecl.} = 
  isInterpreterInit = true
  interpreter.evalScript()

proc initInterpreterInAnotherThread() =   
  executeTaskInBackgroundThread(initInterpreter, onInterpreterInit)

proc reloadScriptImpl() = 
  if not isInterpreterInit:
    UE_Warn "VM not initialized yet."
    initInterpreterInAnotherThread()
    return
  try:    
    measureTime "Reloading Script":
      interpreter.evalScript()
  except:
    let msg = getCurrentExceptionMsg()
    UE_Error msg
    UE_Error getStackTrace()

# var isWatching = false
# var lastModTime = 0


#This can leave in the vm file
uClass UNimVmManager of UObject:
  ufuncs(Static):#Called from the button in UE
    proc reloadScript() =       
      reloadScriptImpl()
    proc implementDelayedBorrow(borrowStr: FString) = 
      let borrowInfo = parseJson(borrowStr).jsonTo(UEBorrowInfo)
      implementNativeFunc(borrowInfo)
    proc init() = 
      initInterpreterInAnotherThread()
#[
  Helper actor to call the vm functions from the editor
  At some point it will part of the UI
]#


uClass ANimVM of AActor:    

  ufunc(CallInEditor, Static):    
    proc evalOnly() = 
      measureTime "Reloading Script":
        reloadScriptImpl()
    proc restartVM() =       
      isInterpreterInit = false
      initInterpreterInAnotherThread()



