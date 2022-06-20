
import ../Core/Containers/unrealstring
import nametypes

include ../definitions

type 
    
    UObject* {.importcpp: "UObject", inheritable, pure .} = object #TODO Create a macro that takes the header path as parameter?
    UObjectPtr* = ptr UObject #This can be autogenerated by a macro

    UStruct* {.importcpp: "UStruct", inheritable, pure .} = object of UObject
    UStructPtr* = ptr UStruct 

    UClass* {.importcpp: "UClass", inheritable, pure .} = object of UStruct
    UClassPtr* = ptr UClass

    UScriptStruct* {.importcpp: "UScriptStruct", inheritable, pure .} = object of UStruct
    UScriptStructPtr* = ptr UScriptStruct

    UFunction* {.importcpp: "UFunction", inheritable, pure .} = object of UStruct
    UFunctionPtr* = ptr UFunction


proc newObject*(cls : UClassPtr) : UObjectPtr {.importcpp: "NewObject<UObject>(GetTransientPackage(), #)".}

proc getClass*(obj : UObjectPtr) : UClassPtr {. importcpp: "#->GetClass()" .}

proc getName*(obj : UObjectPtr) : FString {. importcpp:"#->GetName()" .}

proc findFunctionByName*(cls : UClassPtr, name:FName) : UFunctionPtr {. importcpp: "#.FindFunctionByName(#)"}


# proc staticClass*(_: typedesc[UObject]) : UClassPtr {. importcpp: "#::StaticClass()" .}

#CamelCase
#camelCase



