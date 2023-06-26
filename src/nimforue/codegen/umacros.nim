import std/[sequtils, macros, genasts, sugar, json, jsonutils, strutils, tables, options, strformat, hashes, algorithm]
import uebindcore, models, modelconstructor, enumops
import ../utils/[ueutils,utils]

when defined(nuevm):
  import vmtypes #todo maybe move this to somewhere else so it's in the path without messing vm.nim compilation
  import ../vm/[vmmacros, runtimefield, exposed]  
  include guest
else:
  import ueemit, nuemacrocache, headerparser
  import ../unreal/coreuobject/uobjectflags
 

# import ueemit

macro uEnum*(name:untyped, body : untyped): untyped =       
    let name = name.strVal()
    let metas = getMetasForType(body)
    let fields = body.toSeq().filter(n=>n.kind in [nnkIdent, nnkTupleConstr])
                    .mapIt((if it.kind == nnkIdent: @[it] else: it.children.toSeq()))
                    .foldl(a & b)
                    .mapIt(it.strVal())
                    .mapIt(makeFieldASUEnum(it, name))

    let ueType = makeUEEnum(name, fields, metas)    
    when defined nuevm:
      let types = @[ueType]    
      emitType($(types.toJson()))    
      result = nnkTypeSection.newTree  
      result.add genUEnumTypeDefBinding(ueType, ctVM)
    else:
      addVMType ueType 
      result = emitUEnum(ueType)

    
macro uStruct*(name:untyped, body : untyped) : untyped = 
    var superStruct = ""
    var structTypeName = ""
    case name.kind
    of nnkIdent:
        structTypeName = name.strVal()
    of nnkInfix:
        superStruct = name[^1].strVal()
        structTypeName = name[1].strVal()
    else:
        error("Invalid node for struct name " & repr(name) & " " & $ name.kind)

    let structMetas = getMetasForType(body)
    let ueFields = getUPropsAsFieldsForType(body, structTypeName)
    let structFlags = (STRUCT_NoFlags) #Notice UE sets the flags on the PrepareCppStructOps fn
    let ueType = makeUEStruct(structTypeName, ueFields, superStruct, structMetas, structFlags)
    when defined nuevm:
      let types = @[ueType]    
      # emitType($(types.toJson()))  #TODO needs structOps to be implemented
      result = nnkTypeSection.newTree  
      #TODO gen types
    else:
      addVMType ueType 
      result = emitUStruct(ueType) 


func getClassFlags*(body:NimNode, classMetadata:seq[UEMetadata]) : (EClassFlags, seq[UEMetadata]) = 
    var metas = classMetadata
    var flags = (CLASS_Inherit | CLASS_Native ) #| CLASS_CompiledFromBlueprint
    for meta in classMetadata:
        if meta.name.toLower() == "config": #Game config. The rest arent supported just yet
            flags = flags or CLASS_Config
            metas = metas.filterIt(it.name.toLower() != "config")
        if meta.name.toLower() == "blueprintable":
            metas.add makeUEMetadata("IsBlueprintBase")
        if meta.name.toLower() == "editinlinenew":
            flags = flags or CLASS_EditInlineNew
    (flags, metas)

proc getTypeNodeFromUClassName(name:NimNode) : (string, string, seq[string]) = 
    if name.toSeq().len() < 3:
        error("uClass must explicitly specify the base class. (i.e UMyObject of UObject)", name)
    let className = name[1].strVal()
    case name[^1].kind:
    of nnkIdent: 
        let parent = name[^1].strVal()
        (className, parent, newSeq[string]())
    of nnkCommand:
        let parent = name[^1][0].strVal()        
        var ifaces = 
            name[^1][^1][^1].strVal().split(",") 
        if ifaces[0][0] == 'I':
            ifaces.add ("U" & ifaces[0][1..^1])
        # debugEcho $ifaces

        (className, parent, ifaces)
    else:
        error("Cant parse the uClass " & repr name)
        ("", "", newSeq[string]())



proc uClassImpl*(name:NimNode, body:NimNode): (NimNode, NimNode) = 
    let (className, parent, interfaces) = getTypeNodeFromUClassName(name)    
    let ueProps = getUPropsAsFieldsForType(body, className)
    let (classFlags, classMetas) = getClassFlags(body,  getMetasForType(body))
    var ueType = makeUEClass(className, parent, classFlags, ueProps, classMetas)    
    ueType.interfaces = interfaces
    when defined nuevm:
      let types = @[ueType]    
      emitType($(types.toJson()))       
      let typeSection = nnkTypeSection.newTree(genVMClassTypeDef(ueType))
      let ueTypeNode = 
        genAst(name=ident &"{className}UEType", ueType=newLit ueType):
          let name {.inject.} = ueType

      var members = genUCalls(ueType) 
      members.add ueTypeNode
      result = (typeSection, members)

    else:
      #this may cause a comp error if the file doesnt exist. Make sure it exists first. #TODO PR to fix this 
      ueType.isParentInPCH = ueType.parent in getAllPCHTypes()
      addVMType ueType
      var (typeNode, addEmitterProc) = emitUClass(ueType)
      var procNodes = nnkStmtList.newTree(addEmitterProc)
      #returns empty if there is no block defined
      let defaults = genDefaults(body)
      let declaredConstructor = genDeclaredConstructor(body, className)
      if declaredConstructor.isSome(): #TODO now that Nim support constructors maybe it's a good time to revisit this. 
          procNodes.add declaredConstructor.get()
      elif doesClassNeedsConstructor(className) or defaults.isSome():
          let defaultConstructor = genConstructorForClass(body, className, defaults.get(newEmptyNode()))
          procNodes.add defaultConstructor

      let nimProcs = body.children.toSeq
                      .filterIt(it.kind == nnkProcDef and it.name.strVal notin ["constructor"])
                      .mapIt(it.addSelfToProc(className).processVirtual(parent))
      
      var fns = genUFuncsForUClass(body, className, nimProcs)
      fns.insert(0, procNodes)
      result =  (typeNode, fns)

macro uClass*(name:untyped, body : untyped) : untyped = 
    let (uClassNode, fns) = uClassImpl(name, body)
    nnkStmtList.newTree(@[uClassNode] & fns)
    

macro uSection*(body: untyped): untyped = 
    let uclasses = 
        body.filterIt(it.kind == nnkCommand) 
            .mapIt(uClassImpl(it[1], it[^1]))
    var typs = newSeq[NimNode]()
    var fns = newSeq[NimNode]()
    for uclass in uclasses:
        let (uClassNode, fns) = uclass
        typs.add uClassNode
        fns.add fns
    #TODO allow uStructs in sections
    #set all types in the same typesection
    var typSection = nnkTypeSection.newTree()
    for typ in typs:
        let typDefs = typ[0].children.toSeq()
        typSection.add typDefs
    # let codeReordering = nnkStmtList.newTree nnkPragma.newTree(nnkExprColonExpr.newTree(ident "experimental", newLit "codereordering"))
    result = nnkStmtList.newTree(@[typSection] & fns)


when not defined nuevm:
  macro uForwardDecl*(name : untyped ) : untyped = 
      let (className, parentName, interfaces) = getTypeNodeFromUClassName(name)
      var ueType = UEType(name:className, kind:uetClass, parent:parentName, interfaces:interfaces)
      ueType.interfaces = interfaces
      ueType.isParentInPCH = ueType.parent in getAllPCHTypes()
      let (typNode, addEmitterProc) = emitUClass(ueType)
      result = nnkStmtList.newTree(typNode, addEmitterProc)