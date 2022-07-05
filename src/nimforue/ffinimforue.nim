

include unreal/prelude


import macros/[ffi, uebind]
import std/[times]
import strformat
import manualtests/manualtestsarray

#define on config.nims
const genFilePath* {.strdefine.} : string = ""

proc fromTheEditor() : void  {.ffi:genFilePath}  = 
    scratchpadEditor()

proc testCallUFuncOn(obj:pointer) : void  {.ffi:genFilePath}  = 
    let executor = cast[UObjectPtr](obj)
    testArrayEntryPoint(executor)
    # testVectorEntryPoint(executor)
    scratchpad(executor)

#function called right after the dyn lib is load
#when n == 0 means it's the first time. So first editor load
#called from C++ NimForUE Module
proc onNimForUELoaded(n:int32) : void {.ffi:genFilePath} = 
    UE_Log(fmt "Nim loaded for {n} times")
    discard

#called right before it is unloaded
#called from the host library
proc onNimForUEUnloaded() : void {.ffi:genFilePath}  = 
    UE_Log("Nim for UE unloaded")
    discard