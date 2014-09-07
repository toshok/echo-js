esprima = require 'esprima'
escodegen = require 'escodegen'
debug = require 'debug'
path = require 'path'

node_compat = require 'node-compat'

{ Map } = require 'map'

{ ArrayExpression,
  ArrayPattern,
  ArrowFunctionExpression,
  AssignmentExpression,
  BinaryExpression,
  BlockStatement,
  BreakStatement,
  CallExpression,
  CatchClause,
  ClassBody,
  ClassDeclaration,
  ClassExpression,
  ClassHeritage,
  ComprehensionBlock,
  ComprehensionExpression,
  ComputedPropertyKey,
  ConditionalExpression,
  ContinueStatement,
  DebuggerStatement,
  DoWhileStatement,
  EmptyStatement,
  ExportDeclaration,
  ExportBatchSpecifier,
  ExportSpecifier,
  ExpressionStatement,
  ForInStatement,
  ForOfStatement,
  ForStatement,
  FunctionDeclaration,
  FunctionExpression,
  Identifier,
  IfStatement,
  ImportDeclaration,
  ImportSpecifier,
  LabeledStatement,
  Literal,
  LogicalExpression,
  MemberExpression,
  MethodDefinition,
  ModuleDeclaration,
  NewExpression,
  ObjectExpression,
  ObjectPattern,
  Program,
  Property,
  ReturnStatement,
  SequenceExpression,
  SpreadElement,
  SwitchCase,
  SwitchStatement,
  TaggedTemplateExpression,
  TemplateElement,
  TemplateLiteral,
  ThisExpression,
  ThrowStatement,
  TryStatement,
  UnaryExpression,
  UpdateExpression,
  VariableDeclaration,
  VariableDeclarator,
  WhileStatement,
  WithStatement,
  YieldExpression } = esprima.Syntax

{ Stack } = require 'stack'
{ Set } = require 'set'
{ TreeVisitor } = require 'nodevisitor'
closure_conversion = require 'closure-conversion'
optimizations = require 'optimizations'
{ startGenerator, is_intrinsic, is_string_literal } = require 'echo-util'

{ ExitableScope, TryExitableScope, SwitchExitableScope, LoopExitableScope } = require 'exitable-scope'

{ reportError } = require 'errors'

types = require 'types'
consts = require 'consts'
runtime = require 'runtime'
b = require 'ast-builder'

llvm = require 'llvm'
ir = llvm.IRBuilder

BUILTIN_PARAMS = [
  { name: "%env",     llvm_type: types.EjsValue } # should be EjsClosureEnv
  { name: "%this",    llvm_type: types.EjsValue }
  { name: "%argc",    llvm_type: types.int32 }
  { name: "%args",    llvm_type: types.EjsValue.pointerTo() }
]

hasOwn = Object::hasOwnProperty

# our base ABI class assumes that there are no restrictions on
# EjsValue types, and that they can be passed by value and returned by
# value with no modification to signatures or callsites.
#
class ABI
        constructor: () ->
                @ejs_return_type = types.EjsValue
                @ejs_params = [
                  { name: "%env",     llvm_type: types.EjsValue } # should be EjsClosureEnv
                  { name: "%this",    llvm_type: types.EjsValue }
                  { name: "%argc",    llvm_type: types.int32 }
                  { name: "%args",    llvm_type: types.EjsValue.pointerTo() }
                ]
                @env_param_index = 0
                @this_param_index = 1
                @argc_param_index = 2
                @args_param_index = 3

        # this function c&p from LLVMIRVisitor below
        createAlloca: (func, type, name) ->
                saved_insert_point = ir.getInsertBlock()
                ir.setInsertPointStartBB func.entry_bb
                alloca = ir.createAlloca type, name

                # if EjsValue was a pointer value we would be able to use an the llvm gcroot intrinsic here.  but with the nan boxing
                # we kinda lose out as the llvm IR code doesn't permit non-reference types to be gc roots.
                # if type is types.EjsValue
                #        # EjsValues are rooted
                #        @createCall @llvm_intrinsics.gcroot(), [(ir.createPointerCast alloca, types.int8Pointer.pointerTo(), "rooted_alloca"), consts.null types.int8Pointer], ""

                ir.setInsertPoint saved_insert_point
                alloca

        forwardCalleeAttributes: (fromCallee, toCall) ->
                toCall.setDoesNotThrow() if fromCallee.doesNotThrow
                toCall.setDoesNotAccessMemory() if fromCallee.doesNotAccessMemory
                toCall.setOnlyReadsMemory() if not fromCallee.doesNotAccessMemory and fromCallee.onlyReadsMemory
                toCall._ejs_returns_ejsval_bool = fromCallee.returns_ejsval_bool
                
        createCall: (fromFunction, callee, argv, callname) -> ir.createCall callee, argv, callname
        createInvoke: (fromFunction, callee, argv, normal_block, exc_block, callname) -> ir.createInvoke callee, argv, normal_block, exc_block, callname
        createRet: (fromFunction, value) -> ir.createRet value
        createExternalFunction: (inModule, name, ret_type, param_types) -> inModule.getOrInsertExternalFunction name, ret_type, param_types
        createFunction: (inModule, name, ret_type, param_types) -> inModule.getOrInsertFunction name, ret_type, param_types
        createFunctionType: (ret_type, param_types) -> llvm.FunctionType.get ret_type, param_types

# armv7/x86 requires us to pass a pointer to a stack slot for the return value when it's EjsValue.
# so functions that would normally be defined as:
# 
#   ejsval _ejs_normal_func (ejsval env, ejsval this, uint32_t argc, ejsval* args)
#
# are instead expressed as:
# 
#   void _ejs_sret_func (ejsval* sret, ejsval env, ejsval this, uint32_t argc, ejsval* args)
# 
class SRetABI extends ABI
        constructor: () ->
                super
                @ejs_return_type = types.void
                @ejs_params.unshift { name: "%retval", llvm_type: types.EjsValue.pointerTo() }
                @env_param_index += 1
                @this_param_index += 1
                @argc_param_index += 1
                @args_param_index += 1
                
        createCall: (fromFunction, callee, argv, callname) ->
                if callee.hasStructRetAttr()
                        sret_alloca = @createAlloca fromFunction, types.EjsValue, "sret"
                        argv.unshift sret_alloca

                        #sret_as_i8 = ir.createBitCast sret_alloca, types.int8Pointer, "sret_as_i8"
                        #ir.createLifetimeStart sret_as_i8, consts.int64(8) #sizeof(ejsval)
                        call = super fromFunction, callee, argv, ""
                        call.setStructRet()

                        rv = ir.createLoad sret_alloca, callname
                        #ir.createLifetimeEnd sret_as_i8, consts.int64(8) #sizeof(ejsval)
                        rv
                else
                        super

        createInvoke: (fromFunction, callee, argv, normal_block, exc_block, callname) ->
                if callee.hasStructRetAttr()
                        sret_alloca = @createAlloca fromFunction, types.EjsValue, "sret"
                        argv.unshift sret_alloca

                        #sret_as_i8 = ir.createBitCast sret_alloca, types.int8Pointer, "sret_as_i8"
                        #ir.createLifetimeStart sret_as_i8, consts.int64(8) #sizeof(ejsval)
                        call = super fromFunction, callee, argv, normal_block, exc_block, ""
                        call.setStructRet()

                        ir.setInsertPoint normal_block
                        rv = ir.createLoad sret_alloca, callname
                        #ir.createLifetimeEnd sret_as_i8, consts.int64(8) #sizeof(ejsval)
                        rv
                else
                        super

        createRet: (fromFunction, value) ->
                ir.createStore value, fromFunction.args[0]
                ir.createRetVoid()
        
        createExternalFunction: (inModule, name, ret_type, param_types) ->
                @createFunction inModule, name, ret_type, param_types, true
                
        createFunction: (inModule, name, ret_type, param_types, external = false) ->
                if ret_type is types.EjsValue
                        param_types.unshift ret_type.pointerTo()
                        ret_type = types.void
                        sret = true
                if external
                        rv = inModule.getOrInsertExternalFunction name, ret_type, param_types
                else
                        rv = inModule.getOrInsertFunction name, ret_type, param_types
                rv.setStructRet() if sret
                rv

        createFunctionType: (ret_type, param_types) ->
                if ret_type is types.EjsValue
                        param_types.unshift ret_type.pointerTo()
                        ret_type = types.void
                super
                                
        
class LLVMIRVisitor extends TreeVisitor
        constructor: (@module, @filename, @options, @abi) ->

                @idgen = startGenerator()
                
                if @options.record_types
                        @genRecordId = startGenerator()
                        
                # build up our runtime method table
                @ejs_intrinsics = Object.create null,
                        templateDefaultHandlerCall: value: @handleTemplateDefaultHandlerCall
                        templateCallsite:     value: @handleTemplateCallsite
                        moduleGet:            value: @handleModuleGet
                        moduleImportBatch:    value: @handleModuleImportBatch
                        getLocal:             value: @handleGetLocal
                        setLocal:             value: @handleSetLocal
                        getGlobal:            value: @handleGetGlobal
                        setGlobal:            value: @handleSetGlobal
                        getArg:               value: @handleGetArg
                        slot:                 value: @handleGetSlot
                        setSlot:              value: @handleSetSlot
                        invokeClosure:        value: @handleInvokeClosure
                        makeClosure:          value: @handleMakeClosure
                        makeAnonClosure:      value: @handleMakeAnonClosure
                        createArgScratchArea: value: @handleCreateArgScratchArea
                        makeClosureEnv:       value: @handleMakeClosureEnv
                        typeofIsObject:       value: @handleTypeofIsObject
                        typeofIsFunction:     value: @handleTypeofIsFunction
                        typeofIsString:       value: @handleTypeofIsString
                        typeofIsSymbol:       value: @handleTypeofIsSymbol
                        typeofIsNumber:       value: @handleTypeofIsNumber
                        typeofIsBoolean:      value: @handleTypeofIsBoolean
                        builtinUndefined:     value: @handleBuiltinUndefined
                        isNullOrUndefined:    value: @handleIsNullOrUndefined
                        isUndefined:          value: @handleIsUndefined
                        isNull:               value: @handleIsNull
                        setPrototypeOf:       value: @handleSetPrototypeOf
                        objectCreate:         value: @handleObjectCreate
                        gatherRest:           value: @handleGatherRest
                        arrayFromSpread:      value: @handleArrayFromSpread
                        argPresent:           value: @handleArgPresent

                @opencode_intrinsics =
                        unaryNot          : true

                        templateDefaultHandlerCall: true
                        
                        moduleGet         : true # unused
                        getLocal          : true # unused
                        setLocal          : true # unused
                        getGlobal         : true # unused
                        setGlobal         : true # unused
                        slot              : true
                        setSlot           : true
                
                        invokeClosure     : true
                        makeClosure       : true
                        makeAnonClosure   : true
                        createArgScratchArea : true
                        makeClosureEnv    : true
                
                        typeofIsObject    : true
                        typeofIsFunction  : true
                        typeofIsString    : true
                        typeofIsSymbol    : true
                        typeofIsNumber    : true
                        typeofIsBoolean   : true
                        builtinUndefined  : true
                        isNullOrUndefined : false # causes a crash when self-hosting
                        isUndefined       : true
                        isNull            : true
                
                @llvm_intrinsics =
                        gcroot: -> module.getOrInsertIntrinsic "@llvm.gcroot"

                @ejs_runtime = runtime.createInterface module, @abi
                @ejs_binops = runtime.createBinopsInterface module, @abi
                @ejs_atoms = runtime.createAtomsInterface module
                @ejs_globals = runtime.createGlobalsInterface module
                @ejs_symbols = runtime.createSymbolsInterface module

                @module_atoms = Object.create null
                @literalInitializationFunction = @module.getOrInsertFunction "_ejs_module_init_string_literals_#{@filename}", types.void, []
                
                # this function is only ever called by this module's toplevel
                @literalInitializationFunction.setInternalLinkage()
                
                # initialize the scope stack with the global (empty) scope
                @scope_stack = new Stack new Map

                entry_bb = new llvm.BasicBlock "entry", @literalInitializationFunction
                return_bb = new llvm.BasicBlock "return", @literalInitializationFunction

                @doInsideBBlock entry_bb, => ir.createBr return_bb
                @doInsideBBlock return_bb, =>
                        #@createCall @ejs_runtime.log, [consts.string(ir, "done with literal initialization")], ""
                        ir.createRetVoid()

                @literalInitializationBB = entry_bb

        # lots of helper methods

        # result should be the landingpad's value
        beginCatch: (result) -> @createCall @ejs_runtime.begin_catch, [ir.createPointerCast(result, types.int8Pointer, "")], "begincatch"
        endCatch:            -> @createCall @ejs_runtime.end_catch, [], "endcatch"

        doInsideExitableScope: (scope, f) ->
                scope.enter()
                f()
                scope.leave()
                
        doInsideBBlock: (b, f) ->
                saved = ir.getInsertBlock()
                ir.setInsertPoint b
                f()
                ir.setInsertPoint saved
                b
        
        createLoad: (value, name) ->
                rv = ir.createLoad value, name
                rv.setAlignment 8
                rv

        loadBoolEjsValue: (n) ->
                name = if n then "true" else "false"
                bool_alloca = @createAlloca @currentFunction, types.EjsValue, "#{name}_alloca"
                alloca_as_int64 = ir.createBitCast bool_alloca, types.int64.pointerTo(), "alloca_as_pointer"
                if @options.target_pointer_size is 64
                        ir.createStore consts.int64_lowhi(0xfff98000, if n then 0x00000001 else 0x000000000), alloca_as_int64
                else
                        ir.createStore consts.int64_lowhi(0xffffff83, if n then 0x00000001 else 0x00000000), alloca_as_int64
                rv = ir.createLoad bool_alloca, "#{name}_load"
                rv._ejs_returns_ejsval_bool = true
                rv

        loadDoubleEjsValue: (n) ->
                if @currentFunction["num_#{n}_alloca"]
                        num_alloca = @currentFunction["num_#{n}_alloca"]
                else
                        num_alloca = @createAlloca @currentFunction, types.EjsValue, "num_#{n}_alloca"
                @storeDouble num_alloca, n
                if not @currentFunction["num_#{n}_alloca"]
                        @currentFunction["num_#{n}_alloca"] = num_alloca
                ir.createLoad num_alloca, "numload"
                
        loadNullEjsValue: ->
                if @currentFunction.null_alloca?
                        null_alloca = @currentFunction.null_alloca
                else
                        null_alloca = @createAlloca @currentFunction, types.EjsValue, "null_alloca"
                @storeNull null_alloca
                if not @currentFunction.null_alloca?
                        @currentFunction.null_alloca = null_alloca
                ir.createLoad null_alloca, "nullload"
                
        loadUndefinedEjsValue: ->
                undef_alloca = @createAlloca @currentFunction, types.EjsValue, "undef_alloca"
                @storeUndefined undef_alloca
                ir.createLoad undef_alloca, "undefload"

        storeUndefined: (alloca, name) ->
                alloca_as_int64 = ir.createBitCast alloca, types.int64.pointerTo(), "alloca_as_pointer"
                if @options.target_pointer_size is 64
                        ir.createStore consts.int64_lowhi(0xfff90000, 0x00000000), alloca_as_int64, name
                else # 32 bit
                        ir.createStore consts.int64_lowhi(0xffffff82, 0x00000000), alloca_as_int64, name

        storeNull: (alloca, name) ->
                alloca_as_int64 = ir.createBitCast alloca, types.int64.pointerTo(), "alloca_as_pointer"
                if @options.target_pointer_size is 64
                        ir.createStore consts.int64_lowhi(0xfffb8000, 0x00000000), alloca_as_int64, name
                else # 32 bit
                        ir.createStore consts.int64_lowhi(0xffffff87, 0x00000000), alloca_as_int64, name

        storeDouble: (alloca, jsnum, name) ->
                c = llvm.ConstantFP.getDouble jsnum
                alloca_as_double = ir.createBitCast alloca, types.double.pointerTo(), "alloca_as_pointer"
                ir.createStore c, alloca_as_double, name

        storeBoolean: (alloca, jsbool, name) ->
                alloca_as_int64 = ir.createBitCast alloca, types.int64.pointerTo(), "alloca_as_pointer"
                if @options.target_pointer_size is 64
                        ir.createStore consts.int64_lowhi(0xfff98000, if jsbool then 0x00000001 else 0x000000000), alloca_as_int64, name
                else
                        ir.createStore consts.int64_lowhi(0xffffff83, if jsbool then 0x00000001 else 0x00000000), alloca_as_int64, name

        storeToDest: (dest, arg, name = "") ->
                arg = { type: Literal, value: null } if not arg?
                if arg.type is Literal
                        if arg.value is null
                                @storeNull dest, name
                        else if arg.value is undefined
                                @storeUndefined dest, name
                        else if typeof arg.value is "number"
                                @storeDouble dest, arg.value, name
                        else if typeof arg.value is "boolean"
                                @storeBoolean dest, arg.value, name
                        else # if typeof arg is "string"
                                val = @visit arg
                                ir.createStore val, dest, name
                else
                        val = @visit arg
                        ir.createStore val, dest, name
                
        storeGlobal: (prop, value) ->
                # we store obj.prop, prop is an id
                if prop.type is Identifier
                        gname = prop.name
                else # prop.type is Literal
                        gname = prop.value

                c = @getAtom gname

                debug.log -> "createPropertyStore %global[#{gname}]"
                        
                @createCall @ejs_runtime.global_setprop, [c, value], "globalpropstore_#{gname}"

        loadGlobal: (prop) ->
                gname = prop.name

                if @options.frozen_global
                        return ir.createLoad @ejs_globals[prop.name], "load-#{gname}"

                pname = @getAtom gname
                @createCall @ejs_runtime.global_getprop, [pname], "globalloadprop_#{gname}"

        visitWithScope: (scope, children) ->
                @scope_stack.push scope
                @visit child for child in children
                @scope_stack.pop()

        findIdentifierInScope: (ident) ->
                for scope in @scope_stack.stack
                        if scope.has ident
                                return scope.get ident
                null

                                
        createAlloca: (func, type, name) ->
                saved_insert_point = ir.getInsertBlock()
                ir.setInsertPointStartBB func.entry_bb
                alloca = ir.createAlloca type, name

                # if EjsValue was a pointer value we would be able to use an the llvm gcroot intrinsic here.  but with the nan boxing
                # we kinda lose out as the llvm IR code doesn't permit non-reference types to be gc roots.
                # if type is types.EjsValue
                #        # EjsValues are rooted
                #        @createCall @llvm_intrinsics.gcroot(), [(ir.createPointerCast alloca, types.int8Pointer.pointerTo(), "rooted_alloca"), consts.null types.int8Pointer], ""

                ir.setInsertPoint saved_insert_point
                alloca

        createAllocas: (func, ids, scope) ->
                allocas = []
                new_allocas = []
                
                # the allocas are always allocated in the function entry_bb so the mem2reg opt pass can regenerate the ssa form for us
                saved_insert_point = ir.getInsertBlock()
                ir.setInsertPointStartBB func.entry_bb

                j = 0
                for i in [0...ids.length]
                        name = ids[i].id.name
                        if !scope.has name
                                allocas[j] = ir.createAlloca types.EjsValue, "local_#{name}"
                                allocas[j].setAlignment 8
                                scope.set name, allocas[j]
                                new_allocas[j] = true
                        else
                                allocas[j] = scope.get name
                                new_allocas[j] = false
                        j = j + 1
                                

                # reinstate the IRBuilder to its previous insert point so we can insert the actual initializations
                ir.setInsertPoint saved_insert_point

                { allocas: allocas, new_allocas: new_allocas }

        createPropertyStore: (obj,prop,rhs,computed) ->
                if computed
                        # we store obj[prop], prop can be any value
                        @createCall @ejs_runtime.object_setprop, [obj, @visit(prop), rhs], "propstore_computed"
                else
                        # we store obj.prop, prop is an id
                        if prop.type is Identifier
                                pname = prop.name
                        else # prop.type is Literal
                                pname = prop.value

                        c = @getAtom pname

                        debug.log -> "createPropertyStore #{obj}[#{pname}]"
                        
                        @createCall @ejs_runtime.object_setprop, [obj, c, rhs], "propstore_#{pname}"
                
        createPropertyLoad: (obj,prop,computed,canThrow = true) ->
                if computed
                        # we load obj[prop], prop can be any value
                        loadprop = @visit prop
                        
                        if @options.record_types
                                @createCall @ejs_runtime.record_getprop, [consts.int32(@genRecordId()), obj, loadprop], ""
                                                
                        @createCall @ejs_runtime.object_getprop, [obj, loadprop], "getprop_computed", canThrow
                else
                        # we load obj.prop, prop is an id
                        pname = @getAtom prop.name

                        if @options.record_types
                                @createCall @ejs_runtime.record_getprop, [consts.int32(@genRecordId()), obj, pname], ""

                        @createCall @ejs_runtime.object_getprop, [obj, pname], "getprop_#{prop.name}", canThrow
                

        visitOrNull:      (n) -> @visit(n) || @loadNullEjsValue()
        visitOrUndefined: (n) -> @visit(n) || @loadUndefinedEjsValue()
        
        visitProgram: (n) ->
                # by the time we make it here the program has been
                # transformed so that there is nothing at the toplevel
                # but function declarations.
                @visit func for func in n.body

        visitBlock: (n) ->
                new_scope = new Map

                iife_dest_bb = null
                iife_rv = null

                fromIIFE = n.fromIIFE
                
                if fromIIFE
                        insertBlock = ir.getInsertBlock()
                        insertFunc = insertBlock.parent

                        iife_dest_bb = new llvm.BasicBlock "iife_dest", insertFunc
                        iife_rv = n.ejs_iife_rv

                @iifeStack.push { iife_rv, iife_dest_bb }

                @visitWithScope new_scope, n.body

                @iifeStack.pop()
                
                if fromIIFE

                        ir.createBr iife_dest_bb
                        ir.setInsertPoint iife_dest_bb
                        rv = @createLoad @findIdentifierInScope(n.ejs_iife_rv.name), "%iife_rv_load"
                        return rv
                n

        visitSwitch: (n) ->
                insertBlock = ir.getInsertBlock()
                insertFunc = insertBlock.parent

                # find the default: case first
                defaultCase = null
                (if not _case.test then defaultCase = _case) for _case in n.cases

                # for each case, create 2 basic blocks
                for _case in n.cases
                        if _case isnt defaultCase
                                _case.dest_check = new llvm.BasicBlock "case_dest_check_bb", insertFunc

                for _case in n.cases
                        _case.bb = new llvm.BasicBlock "case_bb", insertFunc

                merge_bb = new llvm.BasicBlock "switch_merge", insertFunc

                discr = @visit n.discriminant

                case_checks = []
                for _case in n.cases
                        if defaultCase isnt _case
                                case_checks.push test: _case.test, dest_check: _case.dest_check, body: _case.bb

                case_checks.push dest_check: if defaultCase? then defaultCase.bb else merge_bb

                @doInsideExitableScope (new SwitchExitableScope merge_bb), =>

                        # insert all the code for the tests
                        ir.createBr case_checks[0].dest_check
                        ir.setInsertPoint case_checks[0].dest_check
                        for casenum in [0...case_checks.length-1]
                                test = @visit case_checks[casenum].test
                                eqop = @ejs_binops["==="]
                                discTest = @createCall eqop, [discr, test], "test", !eqop.doesNotThrow
                        
                                if discTest._ejs_returns_ejsval_bool
                                        disc_cmp = @createEjsvalICmpEq discTest, consts.ejsval_false()
                                else
                                        disc_truthy = @createCall @ejs_runtime.truthy, [discTest], "disc_truthy"
                                        disc_cmp = ir.createICmpEq disc_truthy, consts.false(), "disccmpresult"
                                ir.createCondBr disc_cmp, case_checks[casenum+1].dest_check, case_checks[casenum].body
                                ir.setInsertPoint case_checks[casenum+1].dest_check


                        case_bodies = []
                
                        # now insert all the code for the case consequents
                        for _case in n.cases
                                case_bodies.push bb:_case.bb, consequent:_case.consequent

                        case_bodies.push bb:merge_bb
                
                        for casenum in [0...case_bodies.length-1]
                                ir.setInsertPoint case_bodies[casenum].bb
                                case_bodies[casenum].consequent.forEach (consequent, i) =>
                                        @visit consequent
                                        
                                ir.createBr case_bodies[casenum+1].bb
                        
                        ir.setInsertPoint merge_bb

                merge_bb
                
        visitCase: (n) ->
                throw "we shouldn't get here, case statements are handled in visitSwitch"
                
        visitLabeledStatement: (n) ->
                n.body.label = n.label.name
                @visit n.body

        visitBreak: (n) ->
                return ExitableScope.scopeStack.exitAft true, n.label?.name

        visitContinue: (n) ->
                return ExitableScope.scopeStack.exitFore n.label?.name

        generateCondBr: (exp, then_bb, else_bb) ->
                if exp.type is Literal and typeof exp.value is "boolean"
                        cmp = consts.int1(if exp.value then 0 else 1) # we check for false below, so the then/else branches get swapped
                else
                        exp_value = @visit exp
                        if exp_value._ejs_returns_ejsval_bool
                                cmp = @createEjsvalICmpEq(exp_value, consts.ejsval_false(), "cmpresult")
                        else
                                cond_truthy = @createCall @ejs_runtime.truthy, [exp_value], "cond_truthy"
                                cmp = ir.createICmpEq cond_truthy, consts.false(), "cmpresult"
                ir.createCondBr cmp, else_bb, then_bb
                exp_value

                
        visitFor: (n) ->
                insertBlock = ir.getInsertBlock()
                insertFunc = insertBlock.parent

                init_bb   = new llvm.BasicBlock "for_init",   insertFunc
                test_bb   = new llvm.BasicBlock "for_test",   insertFunc
                body_bb   = new llvm.BasicBlock "for_body",   insertFunc
                update_bb = new llvm.BasicBlock "for_update", insertFunc
                merge_bb  = new llvm.BasicBlock "for_merge",  insertFunc

                ir.createBr init_bb

                @doInsideBBlock init_bb, =>
                        @visit n.init
                        ir.createBr test_bb

                @doInsideBBlock test_bb, =>
                        if n.test
                                @generateCondBr n.test, body_bb, merge_bb
                        else
                                ir.createBr body_bb

                @doInsideExitableScope (new LoopExitableScope n.label, update_bb, merge_bb), =>
                        @doInsideBBlock body_bb, =>
                                @visit n.body
                                ir.createBr update_bb

                        @doInsideBBlock update_bb, =>
                                @visit n.update
                                ir.createBr test_bb

                ir.setInsertPoint merge_bb
                merge_bb

        visitDo: (n) ->
                insertBlock = ir.getInsertBlock()
                insertFunc = insertBlock.parent
                
                body_bb = new llvm.BasicBlock "do_body", insertFunc
                merge_bb = new llvm.BasicBlock "do_merge", insertFunc

                ir.createBr body_bb

                @doInsideExitableScope (new LoopExitableScope n.label, body_bb, merge_bb), =>
                        @doInsideBBlock body_bb, =>
                                @visit n.body
                                @generateCondBr n.test, body_bb, merge_bb
                                
                ir.setInsertPoint merge_bb
                merge_bb

                                
        visitWhile: (n) ->
                insertBlock = ir.getInsertBlock()
                insertFunc = insertBlock.parent
                
                while_bb  = new llvm.BasicBlock "while_start", insertFunc
                body_bb = new llvm.BasicBlock "while_body", insertFunc
                merge_bb = new llvm.BasicBlock "while_merge", insertFunc

                ir.createBr while_bb

                @doInsideBBlock while_bb, =>
                        @generateCondBr n.test, body_bb, merge_bb

                @doInsideExitableScope (new LoopExitableScope n.label, while_bb, merge_bb), =>
                        @doInsideBBlock body_bb, =>
                                @visit n.body
                                ir.createBr while_bb
                                
                ir.setInsertPoint merge_bb
                merge_bb

        visitForIn: (n) ->
                insertBlock = ir.getInsertBlock()
                insertFunc = insertBlock.parent

                iterator = @createCall @ejs_runtime.prop_iterator_new, [@visit n.right], "iterator"

                # make sure we get an alloca if there's a "var"
                if n.left[0]?
                        @visit n.left
                        lhs = n.left[0].declarations[0].id
                else
                        lhs = n.left
                
                forin_bb  = new llvm.BasicBlock "forin_start", insertFunc
                body_bb   = new llvm.BasicBlock "forin_body",  insertFunc
                merge_bb  = new llvm.BasicBlock "forin_merge", insertFunc
                                
                ir.createBr forin_bb

                @doInsideExitableScope (new LoopExitableScope n.label, forin_bb, merge_bb), =>
                        # forin_bb:
                        #     moreleft = prop_iterator_next (iterator, true)
                        #     if moreleft === false
                        #         goto merge_bb
                        #     else
                        #         goto body_bb
                        # 
                        @doInsideBBlock forin_bb, =>
                                moreleft = @createCall @ejs_runtime.prop_iterator_next, [iterator, consts.true()], "moreleft"
                                cmp = ir.createICmpEq moreleft, consts.false(), "cmpmoreleft"
                                ir.createCondBr cmp, merge_bb, body_bb

                        # body_bb:
                        #     current = prop_iteratorcurrent (iterator)
                        #     *lhs = current
                        #      <body>
                        #     goto forin_bb
                        @doInsideBBlock body_bb, =>
                                current = @createCall @ejs_runtime.prop_iterator_current, [iterator], "iterator_current"
                                @storeValueInDest current, lhs
                                @visit n.body
                                ir.createBr forin_bb

                # merge_bb:
                # 
                ir.setInsertPoint merge_bb
                merge_bb

        visitForOf: (n) ->
                throw "for-of statements are not supported yet"
                
        visitUpdateExpression: (n) ->
                result = @createAlloca @currentFunction, types.EjsValue, "%update_result"
                argument = @visit n.argument
                
                one = @loadDoubleEjsValue 1
                
                if not n.prefix
                        # postfix updates store the argument before the op
                        ir.createStore argument, result

                # argument = argument $op 1
                update_op = @ejs_binops[if n.operator is '++' then '+' else '-']
                temp = @createCall update_op, [argument, one], "update_temp", !update_op.doesNotThrow
                
                @storeValueInDest temp, n.argument
                
                # return result
                if n.prefix
                        argument = @visit n.argument
                        # prefix updates store the argument after the op
                        ir.createStore argument, result
                @createLoad result, "%update_result_load"

        visitConditionalExpression: (n) ->
                @visitIfOrCondExp n, true
                        
        visitIf: (n) ->
                @visitIfOrCondExp n, false

        visitIfOrCondExp: (n, load_result) ->

                if load_result
                        cond_val = @createAlloca @currentFunction, types.EjsValue, "%cond_val"
                
                insertBlock = ir.getInsertBlock()
                insertFunc = insertBlock.parent

                then_bb  = new llvm.BasicBlock "then", insertFunc
                else_bb  = new llvm.BasicBlock "else", insertFunc if n.alternate?
                merge_bb = new llvm.BasicBlock "merge", insertFunc

                @generateCondBr n.test, then_bb, (if else_bb? then else_bb else merge_bb)

                @doInsideBBlock then_bb, =>
                        then_val = @visit n.consequent
                        ir.createStore then_val, cond_val if load_result
                        ir.createBr merge_bb

                if n.alternate?
                        @doInsideBBlock else_bb, =>
                                else_val = @visit n.alternate
                                ir.createStore else_val, cond_val if load_result
                                ir.createBr merge_bb

                ir.setInsertPoint merge_bb
                if load_result
                        @createLoad cond_val, "cond_val_load"
                else
                        merge_bb
                
        visitReturn: (n) ->
                if @iifeStack.top.iife_rv?
                        # if we're inside an IIFE, convert the return statement into a store to the iife_rv alloca + a branch to the iife's dest bb
                        if n.argument?
                                ir.createStore @visit(n.argument), @findIdentifierInScope @iifeStack.top.iife_rv.name
                        ir.createBr @iifeStack.top.iife_dest_bb
                else
                        # otherwise generate an llvm IR ret
                        rv = @visitOrUndefined n.argument
                        
                        if @finallyStack.length > 0
                                @currentFunction.returnValueAlloca = @createAlloca @currentFunction, types.EjsValue, "returnValue" unless @currentFunction.returnValueAlloca?
                                ir.createStore rv, @currentFunction.returnValueAlloca
                                ir.createStore consts.int32(ExitableScope.REASON_RETURN), @currentFunction.cleanup_reason
                                ir.createBr @finallyStack[0]
                        else
                                return_alloca = @createAlloca @currentFunction, types.EjsValue, "return_alloca"
                                ir.createStore rv, return_alloca

                                @createRet @createLoad return_alloca, "return_load"
                                                
        visitImportDeclaration: (n) ->
                scope = @scope_stack.top

                {allocas,new_allocas} = @createAllocas @currentFunction, n.specifiers, scope
                
                # XXX more here - initialize the allocas to their import values
                for i in [0...n.specifiers.length]
                        @storeUndefined allocas[i]
                                
        visitVariableDeclaration: (n) ->
                throw new Error("internal compiler error.  'var' declarations should have been transformed to 'let's by this point.") if n.kind is "var"
                        
                scope = @scope_stack.top

                {allocas,new_allocas} = @createAllocas @currentFunction, n.declarations, scope
                for i in [0...n.declarations.length]
                        if not n.declarations[i].init?
                                # there was not an initializer. we only store undefined
                                # if the alloca is newly allocated.
                                if new_allocas[i]
                                        initializer = @visitOrUndefined n.declarations[i].init
                                        ir.createStore initializer, allocas[i]
                        else
                                initializer = @visitOrUndefined n.declarations[i].init
                                ir.createStore initializer, allocas[i]

        visitMemberExpression: (n) ->
                @createPropertyLoad(@visit(n.object), n.property, n.computed)

        storeValueInDest: (rhvalue, lhs) ->
                if lhs.type is Identifier
                        dest = @findIdentifierInScope(lhs.name)
                        if dest?
                                result = ir.createStore(rhvalue, dest)
                        else
                                result = @storeGlobal(lhs, rhvalue)
                        result
                else if lhs.type is MemberExpression
                        result = @createPropertyStore(@visit(lhs.object), lhs.property, rhvalue, lhs.computed)
                else if is_intrinsic(lhs, "%slot")
                        ir.createStore rhvalue, @handleSlotRef(lhs)
                else if is_intrinsic(lhs, "%getLocal")
                        ir.createStore rhvalue, @findIdentifierInScope lhs.arguments[0].name
                else if is_intrinsic(lhs, "%getGlobal")
                        gname = lhs.arguments[0].name

                        @createCall @ejs_runtime.global_setprop, [@getAtom(gname), rhvalue], "globalpropstore_#{lhs.arguments[0].name}"
                else
                        throw new Error "unhandled lhs #{escodegen.generate lhs}"

        visitAssignmentExpression: (n) ->
                lhs = n.left
                rhs = n.right

                rhvalue = @visit rhs

                if n.operator.length is 2
                        throw new Error "binary assignment operators '#{n.operator}' shouldn't exist at this point"
                
                if @options.record_types
                        @createCall @ejs_runtime.record_assignment, [consts.int32(@genRecordId()), rhvalue], ""
                @storeValueInDest rhvalue, lhs

                # we need to visit lhs after the store so that we load the value, but only if it's used
                if not n.result_not_used
                        return rhvalue

        visitFunction: (n) ->
                debug.log -> "        function #{n.ir_name} at #{@filename}:#{if n.loc? then n.loc.start.line else '<unknown>'}" if not n.toplevel?
                
                # save off the insert point so we can get back to it after generating this function
                insertBlock = ir.getInsertBlock()

                for param in n.formal_params
                        if param.type isnt Identifier
                                throw new Error("formal parameters should only be identifiers by this point")

                # XXX this methods needs to be augmented so that we can pass actual types (or the builtin args need
                # to be reflected in jsllvm.cpp too).  maybe we can pass the names to this method and it can do it all
                # there?

                ir_func = n.ir_func
                ir_args = n.ir_func.args
                debug.log ""
                #debug.log -> "ir_func = #{ir_func}"

                #debug.log -> "param #{param.llvm_type} #{param.name}" for param in n.formal_params

                @currentFunction = ir_func

                # Create a new basic block to start insertion into.
                entry_bb = new llvm.BasicBlock "entry", ir_func

                ir.setInsertPoint entry_bb

                new_scope = new Map

                # we save off the top scope and entry_bb of the function so that we can hoist vars there
                ir_func.topScope = new_scope
                ir_func.entry_bb = entry_bb

                ir_func.literalAllocas = Object.create null

                allocas = []

                # create allocas for the builtin args
                for param in n.params
                        alloca = ir.createAlloca param.llvm_type, "local_#{param.name}"
                        alloca.setAlignment 8
                        new_scope.set param.name, alloca
                        allocas.push alloca
                                
                # now create allocas for the formal parameters
                first_formal_index = allocas.length
                for param in n.formal_params
                        alloca = @createAlloca @currentFunction, types.EjsValue, "local_#{param.name}"
                        new_scope.set param.name, alloca
                        allocas.push alloca

                debug.log -> "alloca #{alloca}" for alloca in allocas
        
                # now store the arguments (use .. to include our args array) onto the stack
                for i in [0...n.params.length]
                        store = ir.createStore ir_args[i], allocas[i]
                        debug.log -> "store #{store} *builtin"

                body_bb = new llvm.BasicBlock "body", ir_func
                ir.setInsertPoint body_bb

                #@createCall @ejs_runtime.log, [consts.string(ir, "entering #{n.ir_name}")], ""
                
                if n.toplevel?
                        ir.createCall @literalInitializationFunction, [], ""

                insertFunc = body_bb.parent
        
                @iifeStack = new Stack

                @finallyStack = []
                
                @visitWithScope new_scope, [n.body]

                # XXX more needed here - this lacks all sorts of control flow stuff.
                # Finish off the function.
                @createRet @loadUndefinedEjsValue()

                # insert an unconditional branch from entry_bb to body here, now that we're
                # sure we're not going to be inserting allocas into the entry_bb anymore.
                ir.setInsertPoint entry_bb
                ir.createBr body_bb
                        
                @currentFunction = null

                ir.setInsertPoint insertBlock

                return ir_func

        createRet: (x) ->
                #@createCall @ejs_runtime.log, [consts.string(ir, "leaving #{@currentFunction.name}")], ""
                @abi.createRet @currentFunction, x
                        
        visitUnaryExpression: (n) ->
                debug.log -> "operator = '#{n.operator}'"

                builtin = "unop#{n.operator}"
                callee = @ejs_runtime[builtin]
        
                if n.operator is "delete"
                        throw "unhandled delete syntax" if n.argument.type isnt MemberExpression
                        
                        fake_literal =
                                type: Literal
                                value: n.argument.property.name
                                raw: "'#{n.argument.property.name}'"
                        return @createCall callee, [@visitOrNull(n.argument.object), @visit(fake_literal)], "result"
                                
                else if n.operator is "!"
                        arg_value =  @visitOrNull n.argument
                        if @opencode_intrinsics.unaryNot and @options.target_pointer_size is 64 and arg_value._ejs_returns_ejsval_bool
                                cmp = @createEjsvalICmpEq arg_value, consts.ejsval_true(), "cmpresult"
                                @createEjsBoolSelect cmp, true
                        else
                                @createCall callee, [arg_value], "result"
                else
                        throw new Error "Internal error: unary operator '#{n.operator}' not implemented" if not callee
                        @createCall callee, [@visitOrNull n.argument], "result"
                

        visitSequenceExpression: (n) ->
                rv = null
                for exp in n.expressions
                        rv = @visit exp
                rv
                
        visitBinaryExpression: (n) ->
                debug.log -> "operator = '#{n.operator}'"
                callee = @ejs_binops[n.operator]
                
                throw new Error "Internal error: unhandled binary operator '#{n.operator}'" if not callee

                left_visited = @visit n.left
                right_visited = @visit n.right

                if @options.record_types
                        @createCall @ejs_runtime.record_binop, [consts.int32(@genRecordId()), consts.string(ir, n.operator), left_visited, right_visited], ""

                # call the actual runtime binaryop method
                rv = @createCall callee, [left_visited, right_visited], "result_#{n.operator}", !callee.doesNotThrow
                rv
                
        visitLogicalExpression: (n) ->
                debug.log -> "operator = '#{n.operator}'"
                result = @createAlloca @currentFunction, types.EjsValue, "result_#{n.operator}"

                insertBlock = ir.getInsertBlock()
                insertFunc = insertBlock.parent
        
                left_bb  = new llvm.BasicBlock "cond_left", insertFunc
                right_bb  = new llvm.BasicBlock "cond_right", insertFunc
                merge_bb = new llvm.BasicBlock "cond_merge", insertFunc

                # we invert the test here - check if the condition is false/0
                left_visited = @generateCondBr n.left, left_bb, right_bb

                @doInsideBBlock left_bb, =>
                        # inside the else branch, left was truthy
                        if n.operator is "||"
                                # for || we short circuit out here
                                ir.createStore left_visited, result
                        else if n.operator is "&&"
                                # for && we evaluate the second and store it
                                ir.createStore @visit(n.right), result
                        else
                                throw "Internal error 99.1"
                        ir.createBr merge_bb

                @doInsideBBlock right_bb, =>
                        # inside the then branch, left was falsy
                        if n.operator is "||"
                                # for || we evaluate the second and store it
                                ir.createStore @visit(n.right), result
                        else if n.operator is "&&"
                                # for && we short circuit out here
                                ir.createStore left_visited, result
                        else
                                throw "Internal error 99.1"
                        ir.createBr merge_bb

                ir.setInsertPoint merge_bb
                @createLoad result, "result_#{n.operator}_load"

        visitArgsForCall: (callee, pullThisFromArg0, args) ->
                args = args.slice()
                argv = []

                if callee.takes_builtins
                        if pullThisFromArg0 and args[0].type is MemberExpression
                                thisArg = @visit args[0].object
                                closure = @createPropertyLoad thisArg, args[0].property, args[0].computed
                        else
                                thisArg = @loadUndefinedEjsValue()
                                closure = @visit args[0]

                        args.shift()
                        
                        argv.push closure                     # %closure
                        argv.push thisArg                     # %this
                        argv.push consts.int32 args.length    # %argc

                        if args.length > 0
                                visited = (@visitOrNull(a) for a in args)

                                visited.forEach (a,i) =>
                                        gep = ir.createGetElementPointer @currentFunction.scratch_area, [consts.int32(0), consts.int64(i)], "arg_gep_#{i}"
                                        store = ir.createStore visited[i], gep, "argv[#{i}]-store"

                                argsCast = ir.createGetElementPointer @currentFunction.scratch_area, [consts.int32(0), consts.int64(0)], "call_args_load"

                                argv.push argsCast
                        else
                                argv.push consts.null types.EjsValue.pointerTo()
                                
                else
                        argv.push @visitOrNull arg for arg in args

                argv

        debugLog: (str) ->
                if @options.debug_level > 0
                        @createCall @ejs_runtime.log, [consts.string(ir, str)], ""

        visitArgsForConstruct: (callee, args) ->
                insertBlock = ir.getInsertBlock()
                insertFunc  = insertBlock.parent
                
                args = args.slice()
                argv = []
                # constructors are always .takes_builtins, so we can skip the other case
                # 

                ctor = @visit args[0]
                args.shift()

                # ECMA262 7.3.17 - 7.3.18
                create_ordinary_object_bb = new llvm.BasicBlock("create_ordinary_object_bb", insertFunc)
                creator_is_defined_bb     = new llvm.BasicBlock("creator_is_defined_bb",     insertFunc)
                invalid_obj_bb            = new llvm.BasicBlock("invalid_obj_bb",            insertFunc)
                obj_created_bb            = new llvm.BasicBlock("obj_created_bb",            insertFunc)
                
                this_alloca = @createAlloca @currentFunction, types.EjsValue, "this_alloca"

                creator = @createCall(@ejs_runtime.object_getprop, [ctor, ir.createLoad(@ejs_symbols.create, "load_Symbol_create")], "creator", true)
                cmp_undefined = @isUndefined(creator)
                ir.createCondBr(cmp_undefined, create_ordinary_object_bb, creator_is_defined_bb)

                @doInsideBBlock create_ordinary_object_bb, =>
                        thisArg = @createCall(@ejs_runtime.object_create, [ir.createLoad @ejs_globals.Object_prototype, "load_objproto"], "objtmp", false)
                        ir.createStore thisArg, this_alloca
                        ir.createBr obj_created_bb

                @doInsideBBlock creator_is_defined_bb, =>
                        thisArg = @createCall @ejs_runtime.invoke_closure, [creator, ctor, consts.int32(0), consts.null(types.EjsValue.pointerTo())], "thisArg", true
                        ir.createStore thisArg, this_alloca
                        cmp_object = @isObject(ir.createLoad(this_alloca, "load_this"))
                        ir.createCondBr(cmp_object, obj_created_bb, invalid_obj_bb)

                @doInsideBBlock invalid_obj_bb, =>
                        @emitThrowNativeError 5, "return value from @@create is not an object" # this '5' should be 'EJS_TYPE_ERROR'

                ir.setInsertPoint obj_created_bb
                argv.push ctor                                                      # %closure
                argv.push ir.createLoad(this_alloca, "load_this")                   # %this
                argv.push consts.int32 args.length                                  # %argc

                if args.length > 0
                        visited = (@visitOrNull(a) for a in args)
                                
                        visited.forEach (a,i) =>
                                gep = ir.createGetElementPointer @currentFunction.scratch_area, [consts.int32(0), consts.int64(i)], "arg_gep_#{i}"
                                store = ir.createStore visited[i], gep, "argv[#{i}]-store"

                        argsCast = ir.createGetElementPointer @currentFunction.scratch_area, [consts.int32(0), consts.int64(0)], "call_args_load"

                        argv.push argsCast
                else
                        argv.push consts.null types.EjsValue.pointerTo()

                argv
                                                                
        visitCallExpression: (n) ->
                debug.log -> "visitCall #{JSON.stringify n}"
                debug.log -> "          arguments length = #{n.arguments.length}"
                debug.log -> "          arguments[#{i}] =  #{JSON.stringify n.arguments[i]}" for i in [0...n.arguments.length]

                unescapedName = n.callee.name.slice 1
                intrinsicHandler = @ejs_intrinsics[unescapedName]
                if not intrinsicHandler?
                        throw new Error "Internal error: callee should not be null in visitCallExpression (callee = '#{n.callee.name}', arguments = #{n.arguments.length})"

                intrinsicHandler.call @, n, @opencode_intrinsics[unescapedName], false
                
        visitNewExpression: (n) ->
                if n.callee.type isnt Identifier or n.callee.name[0] isnt '%'
                        throw "invalid ctor #{JSON.stringify n.callee}"

                if n.callee.name isnt "%invokeClosure"
                        throw "new expressions may only have a callee of %invokeClosure, callee = #{n.callee.name}"
                        
                unescapedName = n.callee.name.slice 1
                intrinsicHandler = @ejs_intrinsics[unescapedName]
                if not intrinsicHandler?
                        throw "Internal error: ctor should not be null"

                intrinsicHandler.call @, n, @opencode_intrinsics[unescapedName], true

        visitThisExpression: (n) ->
                debug.log "visitThisExpression"
                @createLoad @findIdentifierInScope("%this"), "load_this"

        visitSpreadElement: (n) ->
                throw new Error("halp")
                
        visitIdentifier: (n) ->
                debug.log -> "identifier #{n.name}"
                val = n.name
                source = @findIdentifierInScope val
                if source?
                        debug.log -> "found identifier in scope, at #{source}"
                        rv = @createLoad source, "load_#{val}"
                        return rv

                # special handling of the arguments object here, so we
                # only initialize/create it if the function is
                # actually going to use it.
                if val is "arguments"
                        arguments_alloca = @createAlloca @currentFunction, types.EjsValue, "local_arguments_object"
                        saved_insert_point = ir.getInsertBlock()
                        ir.setInsertPoint @currentFunction.entry_bb

                        load_argc = @createLoad @currentFunction.topScope.get("%argc"), "argc_load"
                        load_args = @createLoad @currentFunction.topScope.get("%args"), "args_load"

                        args_new = @ejs_runtime.arguments_new
                        arguments_object = @createCall args_new, [load_argc, load_args], "argstmp", !args_new.doesNotThrow
                        ir.createStore arguments_object, arguments_alloca
                        @currentFunction.topScope.set "arguments", arguments_alloca

                        ir.setInsertPoint saved_insert_point
                        rv = @createLoad arguments_alloca, "load_arguments"
                        return rv

                rv = null
                debug.log -> "calling getFunction for #{val}"
                rv = @module.getFunction val

                if not rv?
                        debug.log -> "Symbol '#{val}' not found in current scope"
                        rv = @loadGlobal n

                debug.log -> "returning #{rv}"
                rv

        visitObjectExpression: (n) ->
                obj_proto = ir.createLoad @ejs_globals.Object_prototype, "load_objproto"
                object_create = @ejs_runtime.object_create
                obj = @createCall object_create, [obj_proto], "objtmp", !object_create.doesNotThrow

                accessor_map = new Map()

                # gather all properties so we can emit get+set as a single call to define_accessor_prop.
                for property in n.properties
                        if property.kind is "get" or property.kind is "set"
                                accessor_map.set(property.key, new Map) if not accessor_map.has(property.key)
                                throw new SyntaxError "a '#{property.kind}' method for '#{escodegen.generate property.key}' has already been defined." if accessor_map.get(property.key).has(property.kind)
                                throw new SyntaxError "#{property.key.loc.start.line}: property name #{escodegen.generate property.key} appears once in object literal." if accessor_map.get(property.key).has("init")
                        else if property.kind is "init"
                                throw new SyntaxError "#{property.key.loc.start.line}: property name #{escodegen.generate property.key} appears once in object literal." if accessor_map.get(property.key)
                                accessor_map.set(property.key, new Map)
                        else
                                throw new Error("unrecognized property kind `#{property.kind}'")
                                
                        accessor_map.get(property.key).set(property.kind, property)

                accessor_map.forEach (prop_map, propkey) =>
                        # XXX we need something like this line below to handle computed properties, but those are broken at the moment
                        #key = if property.key.type is Identifier then @getAtom property.key.name else @visit property.key

                        if propkey.type is ComputedPropertyKey
                                propkey = @visit propkey.expression
                        else if propkey.type is Literal
                                propkey = @getAtom String(propkey.value)
                        else if propkey.type is Identifier
                                propkey = @getAtom propkey.name

                        if prop_map.has("init")
                                val = @visit(prop_map.get("init").value)
                                @createCall @ejs_runtime.object_define_value_prop, [obj, propkey, val, consts.int32 0x77], "define_value_prop_#{propkey}"
                        else
                                getter = prop_map.get("get")
                                setter = prop_map.get("set")

                                get_method = if getter then @visit(getter.value) else @loadUndefinedEjsValue()
                                set_method = if setter then @visit(setter.value) else @loadUndefinedEjsValue()

                                @createCall @ejs_runtime.object_define_accessor_prop, [obj, propkey, get_method, set_method, consts.int32 0x19], "define_accessor_prop_#{propkey}"
                                
                obj

        visitArrayExpression: (n) ->
                obj = @createCall @ejs_runtime.array_new, [consts.int32(0), consts.false()], "arrtmp", !@ejs_runtime.array_new.doesNotThrow
                i = 0;
                for el in n.elements
                        val = @visit el
                        index = type: Literal, value: i
                        @createPropertyStore obj, index, val, true
                        i = i + 1
                obj
                
        visitExpressionStatement: (n) ->
                n.expression.result_not_used = true
                @visit n.expression

        generateUCS2: (id, jsstr) ->
                ucsArrayType = llvm.ArrayType.get types.jschar, jsstr.length+1
                array_data = []
                (array_data.push consts.jschar jsstr.charCodeAt i) for i in [0...jsstr.length]
                array_data.push consts.jschar 0
                array = llvm.ConstantArray.get ucsArrayType, array_data
                arrayglobal = new llvm.GlobalVariable @module, ucsArrayType, "ucs2-#{id}", array
                arrayglobal.setAlignment 8
                arrayglobal

        generateEJSPrimString: (id, len) ->
                strglobal = new llvm.GlobalVariable @module, types.EjsPrimString, "primstring-#{id}", llvm.Constant.getAggregateZero types.EjsPrimString
                strglobal.setAlignment 8
                strglobal

        generateEJSValueForString: (id) ->
                name = "ejsval-#{id}"
                strglobal = new llvm.GlobalVariable @module, types.EjsValue, name, llvm.Constant.getAggregateZero(types.EjsValue)
                strglobal.setAlignment 8
                val = @module.getOrInsertGlobal name, types.EjsValue
                val.setAlignment 8
                val
                
        addStringLiteralInitialization: (name, ucs2, primstr, val, len) ->
                saved_insert_point = ir.getInsertBlock()

                ir.setInsertPointStartBB @literalInitializationBB
                strname = consts.string ir, name

                arg0 = strname
                arg1 = val
                arg2 = primstr
                arg3 = ir.createInBoundsGetElementPointer ucs2, [consts.int32(0), consts.int32(0)], "ucs2"

                ir.createCall @ejs_runtime.init_string_literal, [arg0, arg1, arg2, arg3, consts.int32(len)], ""
                ir.setInsertPoint saved_insert_point

        getAtom: (str) ->
                # check if it's an atom (a runtime library constant) first of all
                if hasOwn.call @ejs_atoms, str
                        return @createLoad @ejs_atoms[str], "#{str}_atom_load"

                # XXX we need to prepend the 'atom-' here because str could be === '__proto__' which fouls up our lookup.
                #     this can be fixed when we support ES6 Maps (@module_atoms would be a map).
                key = "atom-#{str}"
                # if it's not, we create a constant and embed it in this module
                if not hasOwn.call @module_atoms, key
                        literalId = @idgen()
                        ucs2_data = @generateUCS2 literalId, str
                        primstring = @generateEJSPrimString literalId, str.length
                        @module_atoms[key] = @generateEJSValueForString str
                        @addStringLiteralInitialization str, ucs2_data, primstring, @module_atoms[key], str.length

                strload = @createLoad @module_atoms[key], "literal_load"
                        
        visitLiteral: (n) ->
                # null literals, load _ejs_null
                if n.value is null
                        debug.log "literal: null"
                        return @loadNullEjsValue()

                        
                # undefined literals, load _ejs_undefined
                if n.value is undefined
                        debug.log "literal: undefined"
                        return @loadUndefinedEjsValue()

                # string literals
                if typeof n.raw is "string" and (n.raw[0] is '"' or n.raw[0] is "'")
                        debug.log -> "literal string: #{n.value}"

                        strload = @getAtom n.value
                        
                        strload.literal = n
                        debug.log -> "strload = #{strload}"
                        return strload

                # regular expression literals
                if typeof n.raw is "string" and n.raw[0] is '/'
                        debug.log -> "literal regexp: #{n.raw}"

                        source = consts.string ir, n.value.source
                        flags = consts.string ir, "#{if n.value.global then 'g' else ''}#{if n.value.multiline then 'm' else ''}#{if n.value.ignoreCase then 'i' else ''}"
                        
                        regexp_new_utf8 = @ejs_runtime.regexp_new_utf8
                        regexpcall = @createCall regexp_new_utf8, [source, flags], "regexptmp", !regexp_new_utf8.doesNotThrow
                        debug.log -> "regexpcall = #{regexpcall}"
                        return regexpcall

                # number literals
                if typeof n.value is "number"
                        debug.log -> "literal number: #{n.value}"
                        return @loadDoubleEjsValue n.value

                # boolean literals
                if typeof n.value is "boolean"
                        debug.log -> "literal boolean: #{n.value}"
                        return @loadBoolEjsValue n.value

                throw "Internal error: unrecognized literal of type #{typeof n.value}"

        createCall: (callee, argv, callname, canThrow=true) ->
                # if we're inside a try block we have to use createInvoke, and pass two basic blocks:
                #   the normal block, which is basically this IR instruction's continuation
                #   the unwind block, where we land if the call throws an exception.
                #
                # Although for builtins we know won't throw, we can still use createCall.
                if TryExitableScope.unwindStack.depth is 0 or callee.doesNotThrow or not canThrow
                        #ir.createCall @ejs_runtime.log, [consts.string(ir, "calling #{callee.name}")], ""
                        calltmp = @abi.createCall @currentFunction, callee, argv, callname
                else
                        normal_block  = new llvm.BasicBlock "normal", @currentFunction
                        #ir.createCall @ejs_runtime.log, [consts.string(ir, "invoking #{callee.name}")], ""
                        calltmp = @abi.createInvoke @currentFunction, callee, argv, normal_block, TryExitableScope.unwindStack.top.getLandingPadBlock(), callname
                        # after we've made our call we need to change the insertion point to our continuation
                        ir.setInsertPoint normal_block
                        
                calltmp
        
        visitThrow: (n) ->
                arg = @visit n.argument
                @createCall @ejs_runtime.throw, [arg], "", true
                ir.createUnreachable()

        visitTry: (n) ->
                insertBlock = ir.getInsertBlock()
                insertFunc = insertBlock.parent

                # the alloca that stores the reason we ended up in the finally block
                @currentFunction.cleanup_reason = @createAlloca @currentFunction, types.int32, "cleanup_reason" unless @currentFunction.cleanup_reason?

                # if we have a finally clause, create finally_block
                if n.finalizer?
                        finally_block = new llvm.BasicBlock "finally_bb", insertFunc
                        @finallyStack.unshift finally_block

                # the merge bb where everything branches to after falling off the end of a catch/finally block
                merge_block = new llvm.BasicBlock "try_merge", insertFunc

                branch_target = if finally_block? then finally_block else merge_block

                scope = new TryExitableScope @currentFunction.cleanup_reason, branch_target, (-> new llvm.BasicBlock "exception", insertFunc), finally_block?
                @doInsideExitableScope scope, =>
                        @visit n.block

                        if n.finalizer?
                                @finallyStack.shift()
                
                        # at the end of the try block branch to our branch_target (either the finally block or the merge block after the try{}) with REASON_FALLOFF
                        scope.exitAft false

                if scope.landing_pad_block? and n.handlers.length > 0
                        catch_block = new llvm.BasicBlock "catch_bb", insertFunc


                if scope.landing_pad_block?
                        # the scope's landingpad block is created if needed by @createCall (using that function we pass in as the last argument to TryExitableScope's ctor.)
                        # if a try block includes no calls, there's no need for an landing pad block as nothing can throw, and we don't bother generating any code for the
                        # catch clause.
                        @doInsideBBlock scope.landing_pad_block, =>

                                landing_pad_type = llvm.StructType.create "", [types.int8Pointer, types.int32]
                                # XXX is it an error to have multiple catch handlers, as JS doesn't allow you to filter by type?
                                clause_count = if n.handlers.length > 0 then 1 else 0
                        
                                casted_personality = ir.createPointerCast @ejs_runtime.personality, types.int8Pointer, "personality"
                                caught_result = ir.createLandingPad landing_pad_type, casted_personality, clause_count, "caught_result"
                                caught_result.addClause ir.createPointerCast @ejs_runtime.exception_typeinfo, types.int8Pointer, ""
                                caught_result.setCleanup true

                                exception = ir.createExtractValue caught_result, 0, "exception"
                                
                                if catch_block?
                                        ir.createBr catch_block
                                else if finally_block?
                                        ir.createBr finally_block
                                else
                                        throw "this shouldn't happen.  a try{} without either a catch{} or finally{}"

                                # if we have a catch clause, create catch_bb
                                if n.handlers.length > 0
                                        @doInsideBBlock catch_block, =>
                                                # call _ejs_begin_catch to return the actual exception
                                                catchval = @beginCatch exception
                                
                                                # create a new scope which maps the catch parameter name (the "e" in "try { } catch (e) { }") to catchval
                                                catch_scope = new Map
                                                if n.handlers[0].param?.name?
                                                        catch_name = n.handlers[0].param.name
                                                        alloca = @createAlloca @currentFunction, types.EjsValue, "local_catch_#{catch_name}"
                                                        catch_scope.set catch_name, alloca
                                                        ir.createStore catchval, alloca

                                                @visitWithScope catch_scope, [n.handlers[0]]

                                                # unsure about this one - we should likely call end_catch if another exception is thrown from the catch block?
                                                @endCatch()

                                                # if we make it to the end of the catch block, branch unconditionally to the branch target (either this try's
                                                # finally block or the merge pointer after the try)
                                                ir.createBr branch_target

                                ###
                                # Unwind Resume Block (calls _Unwind_Resume)
                                unwind_resume_block = new llvm.BasicBlock "unwind_resume", insertFunc
                                @doInsideBBlock unwind_resume_block, =>
                                        ir.createResume caught_result
                                ###

                # Finally Block
                if n.finalizer?
                        @doInsideBBlock finally_block, =>
                                @visit n.finalizer

                                cleanup_reason = @createLoad @currentFunction.cleanup_reason, "cleanup_reason_load"

                                if @currentFunction.returnValueAlloca?
                                        return_tramp = new llvm.BasicBlock "return_tramp", insertFunc
                                        @doInsideBBlock return_tramp, =>
                                
                                                if @finallyStack.length > 0
                                                        ir.createStore consts.int32(ExitableScope.REASON_RETURN), @currentFunction.cleanup_reason
                                                        ir.createBr @finallyStack[0]
                                                else
                                                        @createRet @createLoad @currentFunction.returnValueAlloca, "rv"
                        
                                switch_stmt = ir.createSwitch cleanup_reason, merge_block, scope.destinations.length + 1
                                if @currentFunction.returnValueAlloca?
                                        switch_stmt.addCase consts.int32(ExitableScope.REASON_RETURN), return_tramp

                                falloff_tramp = new llvm.BasicBlock "falloff_tramp", insertFunc
                                @doInsideBBlock falloff_tramp, =>
                                        ir.createBr merge_block
                                switch_stmt.addCase consts.int32(TryExitableScope.REASON_FALLOFF_TRY), falloff_tramp

                                for s in [0...scope.destinations.length]
                                        dest_tramp = new llvm.BasicBlock "dest_tramp", insertFunc
                                        dest = scope.destinations[s]
                                        @doInsideBBlock dest_tramp, =>
                                                if dest.reason == TryExitableScope.REASON_BREAK
                                                        dest.scope.exitAft true
                                                else if dest.reason == TryExitableScope.REASON_CONTINUE
                                                        dest.scope.exitFore()
                                        switch_stmt.addCase dest.id, dest_tramp
                                        
                                        
                                switch_stmt
                        
                ir.setInsertPoint merge_block

        handleTemplateDefaultHandlerCall: (exp, opencode) ->
                # we should probably only inline the construction of the string if substitutions.length < $some-number
                cooked_strings = exp.arguments[0].elements
                substitutions = exp.arguments[1].elements
                
                cooked_i = 0
                sub_i = 0
                strval = null

                concat_string = (s) =>
                        if not strval
                                strval = s
                        else
                                strval = @createCall @ejs_runtime.string_concat, [strval, s], "strconcat"
                
                while cooked_i < cooked_strings.length
                        c = cooked_strings[cooked_i]
                        cooked_i += 1
                        if c.length isnt 0
                                concat_string @getAtom(c.value)
                        if sub_i < substitutions.length
                                sub = @visit substitutions[sub_i]
                                concat_string @createCall(@ejs_runtime.ToString, [sub], "subToString")
                                sub_i += 1

                strval

        handleTemplateCallsite: (exp, opencode) ->
                # we expect to be called with context something of the form:
                #
                #   function generate_callsiteId0 () {
                #       %templateCallsite(%callsiteId_0, {
                #           raw: [],
                #           cooked: []
                #       });
                #   }
                # 
                # and we need to generate something along the lines of:
                #
                #   global const %callsiteId_0 = null; // an llvm IR construct
                #
                #   function generate_callsiteId0 () {
                #       if (!%callsiteId_0) {
                #           _ejs_gc_add_root(&%callsiteId_0);
                #           %callsiteId_0 = { raw: [], cooked: [] };
                #           %callsiteId_0.freeze();
                #       }
                #       return callsiteId_0;
                #   }
                #
                # our containing function already exists, so we just
                # need to replace the intrinsic with the new contents.
                #
                # XXX there's no reason to dynamically create the
                # callsite, other than it being easier for now.  The
                # callsite id's structure is known at compile time so
                # everything could be allocated from the data segment
                # and just used from there (much the same way we do
                # with string literals.)

                callsite_id = exp.arguments[0].value
                callsite_obj_literal = exp.arguments[1]

                insertBlock = ir.getInsertBlock()
                insertFunc = insertBlock.parent

                then_bb   = new llvm.BasicBlock "then",  insertFunc
                merge_bb  = new llvm.BasicBlock "merge", insertFunc

                callsite_alloca = @createAlloca @currentFunction, types.EjsValue, "local_#{callsite_id}"

                callsite_global = new llvm.GlobalVariable @module, types.EjsValue, callsite_id, llvm.Constant.getAggregateZero(types.EjsValue)
                global_callsite_load = @createLoad callsite_global, "load_global_callsite"
                ir.createStore global_callsite_load, callsite_alloca

                callsite_load = ir.createLoad callsite_alloca, "load_local_callsite"

                # this looks wrong but this is how we test for a 0 ejsval
                isnull = @isNumber callsite_load
                ir.createCondBr isnull, then_bb, merge_bb

                @doInsideBBlock then_bb, =>
                        @createCall(@ejs_runtime.gc_add_root, [callsite_global], "");
                        callsite_obj = @visit callsite_obj_literal
                        ir.createStore callsite_obj, callsite_global
                        ir.createStore callsite_obj, callsite_alloca
                        ir.createBr merge_bb
                        
                ir.setInsertPoint merge_bb
                ir.createRet ir.createLoad callsite_alloca, "load_local_callsite"

        handleModuleGet: (exp, opencode) ->
                moduleString = @visit exp.arguments[0]
                @createCall @ejs_runtime.module_get, [moduleString], "moduletmp"

        handleModuleImportBatch: (exp, opencode) ->
                fromImport = @visit exp.arguments[0]
                specifiers = @visit exp.arguments[1]
                toExport = @visit exp.arguments[2]

                @createCall @ejs_runtime.module_import_batch, [fromImport, specifiers, toExport], ""

        handleGetArg: (exp, opencode) ->
                load_args = @createLoad @currentFunction.topScope.get("%args"), "args_load"

                arg_i = exp.arguments[0].value
                arg_ptr = ir.createGetElementPointer load_args, [consts.int32(arg_i)], "arg#{arg_i}_ptr"
                                
                @createLoad arg_ptr, "arg#{arg_i}"
                
        handleGetLocal: (exp, opencode) ->
                source = @findIdentifierInScope exp.arguments[0].name
                if source?
                        return @createLoad source, "load_#{exp.arguments[0].name}"

                # special handling of the arguments object here, so we
                # only initialize/create it if the function is
                # actually going to use it.
                if exp.arguments[0].name is "arguments"
                        if @currentFunction.restArgPresent
                                throw new SyntaxError "'arguments' object may not be used in conjunction with a rest parameter"

                        arguments_alloca = @createAlloca @currentFunction, types.EjsValue, "local_arguments_object"
                        saved_insert_point = ir.getInsertBlock()
                        ir.setInsertPoint @currentFunction.entry_bb

                        load_argc = @createLoad @currentFunction.topScope.get("%argc"), "argc_load"
                        load_args = @createLoad @currentFunction.topScope.get("%args"), "args_load"

                        args_new = @ejs_runtime.arguments_new
                        arguments_object = @createCall args_new, [load_argc, load_args], "argstmp", !args_new.doesNotThrow
                        ir.createStore arguments_object, arguments_alloca
                        @currentFunction.topScope.set "arguments", arguments_alloca

                        ir.setInsertPoint saved_insert_point
                        rv = @createLoad arguments_alloca, "load_arguments"
                        return rv

                reportError(ReferenceError, "identifier not found: #{exp.arguments[0].name}", @filename, exp.arguments[0].loc)

        handleSetLocal: (exp, opencode) ->
                dest = @findIdentifierInScope exp.arguments[0].name
                reportError(ReferenceError, "identifier not found: #{exp.arguments[0].name}", @filename, exp.arguments[0].loc) if not dest?
                arg = exp.arguments[1]
                @storeToDest dest, arg
                ir.createLoad dest, "load_val"
                                
        handleGetGlobal: (exp, opencode) ->
                @loadGlobal exp.arguments[0]
        
        handleSetGlobal: (exp, opencode) ->
                gname = exp.arguments[0].name

                if @options.frozen_global
                        throw new SyntaxError "cannot set global property '#{exp.arguments[0].name}' when using --frozen-global"
                                
                gatom = @getAtom gname
                value = @visit exp.arguments[1]

                @createCall @ejs_runtime.global_setprop, [gatom, value], "globalpropstore_#{gname}"

        # this method assumes it's called in an opencoded context
        emitEjsvalTo: (val, type, prefix) ->
                if @options.target_pointer_size is 64
                        payload = @createEjsvalAnd val, consts.int64_lowhi(0x7fff, 0xffffffff), "#{prefix}_payload"
                        ir.createIntToPtr payload, type, "#{prefix}_load"
                else
                        throw new Error "emitEjsvalTo not implemented for this case"
                        
                
        # this method assumes it's called in an opencoded context
        emitLoadSpecops: (obj) ->
                if @options.target_pointer_size is 64
                        # %1 = getelementptr inbounds %struct._EJSObject* %obj, i64 0, i32 1
                        # %specops_load = load %struct.EJSSpecOps** %1, align 8, !tbaa !0
                        specops_slot = ir.createInBoundsGetElementPointer obj, [consts.int64(0), consts.int32(1)], "specops_slot"
                        ir.createLoad specops_slot, "specops_load"
                else
                        throw new Error "emitLoadSpecops not implemented for this case"

        emitThrowNativeError: (errorCode, errorMessage) ->
                @createCall @ejs_runtime.throw_nativeerror_utf8, [consts.int32(errorCode), consts.string(ir, errorMessage)], "", true
                ir.createUnreachable()

        # this method assumes it's called in an opencoded context
        emitLoadEjsFunctionClosureFunc: (closure) ->
                if @options.target_pointer_size is 64
                        func_slot_gep = ir.createInBoundsGetElementPointer closure, [consts.int64(1)], "func_slot_gep"
                        func_slot = ir.createBitCast func_slot_gep, @abi.createFunctionType(types.EjsValue, [types.EjsValue, types.EjsValue, types.int32, types.EjsValue.pointerTo()]).pointerTo().pointerTo(), "func_slot"
                        ir.createLoad func_slot, "func_load"
                else
                        throw new Error "emitLoadEjsFunctionClosureFunc not implemented for this case"
                
        # this method assumes it's called in an opencoded context
        emitLoadEjsFunctionClosureEnv: (closure) ->
                if @options.target_pointer_size is 64
                        env_slot_gep = ir.createInBoundsGetElementPointer closure, [consts.int64(1), consts.int32(1)], "env_slot_gep"
                        env_slot = ir.createBitCast env_slot_gep, types.EjsValue.pointerTo(), "env_slot"
                        ir.createLoad env_slot, "env_load"
                else
                        throw new Error "emitLoadEjsFunctionClosureEnv not implemented for this case"
                
        handleInvokeClosure: (exp, opencode, ctor_context) ->
                insertBlock = ir.getInsertBlock()
                insertFunc = insertBlock.parent

                if ctor_context
                        argv = @visitArgsForConstruct @ejs_runtime.invoke_closure, exp.arguments
                else
                        argv = @visitArgsForCall @ejs_runtime.invoke_closure, true, exp.arguments

                if opencode and @options.target_pointer_size is 64
                        #
                        # generate basically the following code:
                        #
                        # f = argv[0]
                        # if (EJSVAL_IS_FUNCTION(F)
                        #   f->func(f->env, argv[1], argv[2], argv[3])
                        # else
                        #   _ejs_invoke_closure(...argv)
                        # 
                        candidate_is_object_bb = new llvm.BasicBlock "candidate_is_object_bb", insertFunc
                        direct_invoke_bb = new llvm.BasicBlock "direct_invoke_bb", insertFunc
                        runtime_invoke_bb = new llvm.BasicBlock "runtime_invoke_bb", insertFunc
                        invoke_merge_bb = new llvm.BasicBlock "invoke_merge_bb", insertFunc
                        
                        cmp = @isObject(argv[0])
                        ir.createCondBr cmp, candidate_is_object_bb, runtime_invoke_bb

                        call_result_alloca = @createAlloca @currentFunction, types.EjsValue, "call_result"
                        
                        @doInsideBBlock candidate_is_object_bb, =>
                                closure = @emitEjsvalTo argv[0], types.EjsObject.pointerTo(), "closure"

                                specops_load = @emitLoadSpecops closure
                        
                                cmp = ir.createICmpEq specops_load, @ejs_runtime.function_specops, "function_specops_cmp"
                                ir.createCondBr cmp, direct_invoke_bb, runtime_invoke_bb

                                # in the successful case we modify our argv with the responses and directly invoke the closure func
                                @doInsideBBlock direct_invoke_bb, =>
                                        func_load = @emitLoadEjsFunctionClosureFunc closure
                                        env_load = @emitLoadEjsFunctionClosureEnv closure
                                        call_result = @createCall func_load, [env_load, argv[1], argv[2], argv[3]], "callresult"
                                        ir.createStore call_result, call_result_alloca
                                        ir.createBr invoke_merge_bb

                                @doInsideBBlock runtime_invoke_bb, =>
                                        call_result = @createCall @ejs_runtime.invoke_closure, argv, "callresult", true
                                        ir.createStore call_result, call_result_alloca
                                        ir.createBr invoke_merge_bb

                        ir.setInsertPoint invoke_merge_bb

                        call_result = ir.createLoad call_result_alloca, "call_result_load"
                else
                        call_result = @createCall @ejs_runtime.invoke_closure, argv, "call", true

                return call_result if not ctor_context

                # in the ctor context, we need to check if the return
                # value was an object.  if it was, we return it,
                # otherwise we return argv[0]

                if opencode and @options.target_pointer_size is 64
                        cmp = @createEjsvalICmpUGt call_result, consts.int64_lowhi(0xfffbffff, 0xffffffff), "cmpresult"
                else
                        call_result_is_object = @createCall @ejs_runtime.typeof_is_object, [call_result], "call_result_is_object", false
                        if call_result_is_object._ejs_returns_ejsval_bool
                                cmp = @isTrue(call_result_is_object)
                        else
                                cond_truthy = @createCall @ejs_runtime.truthy, [call_result_is_object], "cond_truthy"
                                cmp = ir.createICmpEq cond_truthy, consts.true(), "cmpresult"

                return ir.createSelect cmp, call_result, argv[@abi.this_param_index], "sel"
                        
                        
        handleMakeClosure: (exp, opencode) ->
                argv = @visitArgsForCall @ejs_runtime.make_closure, false, exp.arguments
                @createCall @ejs_runtime.make_closure, argv, "closure_tmp"

        handleMakeAnonClosure: (exp, opencode) ->
                argv = @visitArgsForCall @ejs_runtime.make_anon_closure, false, exp.arguments
                @createCall @ejs_runtime.make_anon_closure, argv, "closure_tmp"
                
        handleCreateArgScratchArea: (exp, opencode) ->
                argsArrayType = llvm.ArrayType.get types.EjsValue, exp.arguments[0].value
                @currentFunction.scratch_length = exp.arguments[0].value
                @currentFunction.scratch_area = @createAlloca @currentFunction, argsArrayType, "args_scratch_area"
                @currentFunction.scratch_area.setAlignment 8
                @currentFunction.scratch_area

        handleMakeClosureEnv: (exp, opencode) ->
                size = exp.arguments[0].value
                @createCall @ejs_runtime.make_closure_env, [consts.int32 size], "env_tmp"

        handleGetSlot: (exp, opencode) ->
                env = @visitOrNull exp.arguments[0]
                slotnum = exp.arguments[1].value
                #
                #  %ref = handleSlotRef
                #  %ret = load %EjsValueType* %ref, align 8
                #
                slot_ref = @handleSlotRef exp, opencode
                ir.createLoad slot_ref, "slot_ref_load"

        handleSetSlot: (exp, opencode) ->
                if exp.arguments.length is 4
                        new_slot_val = exp.arguments[3]
                else
                        new_slot_val = exp.arguments[2]

                slotref = @handleSlotRef exp, opencode
                
                @storeToDest slotref, new_slot_val
                
                ir.createLoad slotref, "load_slot"

        handleSlotRef: (exp, opencode) ->
                env = @visitOrNull exp.arguments[0]
                slotnum = exp.arguments[1].value

                if opencode and @options.target_pointer_size is 64
                        envp = @emitEjsvalTo env, types.EjsClosureEnv.pointerTo(), "closureenv"
                        ir.createInBoundsGetElementPointer envp, [consts.int64(0), consts.int32(2), consts.int64(slotnum)], "slot_ref"
                else
                        @createCall @ejs_runtime.get_env_slot_ref, [env, consts.int32(slotnum)], "slot_ref_tmp", false

        createEjsBoolSelect: (val, falseval = false) ->
                rv = ir.createSelect val, @loadBoolEjsValue(not falseval), @loadBoolEjsValue(falseval), "sel"
                rv._ejs_returns_ejsval_bool = true
                rv

        getEjsvalBits: (arg) ->
                if @currentFunction.bits_alloca
                        bits_alloca = @currentFunction.bits_alloca
                else
                        bits_alloca = @createAlloca @currentFunction, types.EjsValue, "bits_alloca"
                ir.createStore arg, bits_alloca
                bits_ptr = ir.createBitCast bits_alloca, types.int64.pointerTo(), "bits_ptr"
                if not @currentFunction.bits_alloca
                        @currentFunction.bits_alloca = bits_alloca
                ir.createLoad bits_ptr, "bits_load"
                
        createEjsvalICmpUGt: (arg, i64_const, name) -> ir.createICmpUGt @getEjsvalBits(arg), i64_const, name
        createEjsvalICmpULt: (arg, i64_const, name) -> ir.createICmpULt @getEjsvalBits(arg), i64_const, name
        createEjsvalICmpEq:  (arg, i64_const, name) -> ir.createICmpEq  @getEjsvalBits(arg), i64_const, name
        createEjsvalAnd:     (arg, i64_const, name) -> ir.createAnd     @getEjsvalBits(arg), i64_const, name

        isObject: (val) ->
                if @options.target_pointer_size is 64
                        @createEjsvalICmpUGt val, consts.int64_lowhi(0xfffbffff, 0xffffffff), "cmpresult"
                else
                        mask = @createEjsvalAnd(val, consts.int64_lowhi(0xffffffff, 0x00000000), "mask.i")
                        ir.createICmpEq(mask, consts.int64_lowhi(0xffffff88, 0x00000000), "cmpresult")

        isString: (val) ->
                if @options.target_pointer_size is 64
                        mask = @createEjsvalAnd val, consts.int64_lowhi(0xffff8000, 0x00000000), "mask.i"
                        ir.createICmpEq mask, consts.int64_lowhi(0xfffa8000, 0x00000000), "cmpresult"
                else
                        mask = @createEjsvalAnd(val, consts.int64_lowhi(0xffffffff, 0x00000000), "mask.i")
                        ir.createICmpEq(mask, consts.int64_lowhi(0xffffff85, 0x00000000), "cmpresult")

        isNumber: (val) ->
                if @options.target_pointer_size is 64
                        @createEjsvalICmpULt val, consts.int64_lowhi(0xfff80001, 0x00000000), "cmpresult"
                else
                        throw "not implemented yet"
                
        isBoolean: (val) ->
                if @options.target_pointer_size is 64
                        mask = @createEjsvalAnd val, consts.int64_lowhi(0xffff8000, 0x00000000), "mask.i"
                        ir.createICmpEq mask, consts.int64_lowhi(0xfff98000, 0x00000000), "cmpresult"
                else
                        mask = @createEjsvalAnd(val, consts.int64_lowhi(0xffffffff, 0x00000000), "mask.i")
                        ir.createICmpEq(mask, consts.int64_lowhi(0xffffff83, 0x00000000), "cmpresult")

        # these two could/should be changed to check for the specific bitpattern of _ejs_true/_ejs_false
        isTrue: (val) -> ir.createICmpEq val, consts.ejsval_true(), "cmpresult"
        isFalse: (val) -> ir.createICmpEq val, consts.ejsval_false(), "cmpresult"
                        
        isUndefined: (val) ->
                if @options.target_pointer_size is 64
                        @createEjsvalICmpEq(val, consts.int64_lowhi(0xfff90000, 0x00000000), "cmpresult")
                else
                        mask = @createEjsvalAnd(val, consts.int64_lowhi(0xffffffff, 0x00000000), "mask.i")
                        ir.createICmpEq(mask, consts.int64_lowhi(0xffffff82, 0x00000000), "cmpresult")

        isNull: (val) ->
                if @options.target_pointer_size is 64
                        @createEjsvalICmpEq val, consts.int64_lowhi(0xfffb8000, 0x00000000), "cmpresult"
                else
                        mask = @createEjsvalAnd(val, consts.int64_lowhi(0xffffffff, 0x00000000), "mask.i")
                        ir.createICmpEq(mask, consts.int64_lowhi(0xffffff87, 0x00000000), "cmpresult")

        handleTypeofIsObject: (exp, opencode) ->
                arg = @visitOrNull exp.arguments[0]
                @createEjsBoolSelect(@isObject(arg))

        handleTypeofIsFunction: (exp, opencode) ->
                arg = @visitOrNull exp.arguments[0]
                if opencode and @options.target_pointer_size is 64
                        insertBlock = ir.getInsertBlock()
                        insertFunc  = insertBlock.parent
                        
                        typeofIsFunction_alloca = @createAlloca @currentFunction, types.EjsValue, "typeof_is_function"
                        
                        failure_bb   = new llvm.BasicBlock "typeof_function_false",     insertFunc
                        is_object_bb = new llvm.BasicBlock "typeof_function_is_object", insertFunc
                        success_bb   = new llvm.BasicBlock "typeof_function_true",      insertFunc
                        merge_bb     = new llvm.BasicBlock "typeof_function_merge",     insertFunc

                        cmp = @isObject(arg, true)
                        ir.createCondBr cmp, is_object_bb, failure_bb

                        @doInsideBBlock is_object_bb, =>
                                obj = @emitEjsvalTo arg, types.EjsObject.pointerTo(), "obj"
                                specops_load = @emitLoadSpecops(obj)
                                cmp = ir.createICmpEq specops_load, @ejs_runtime.function_specops, "function_specops_cmp"
                                ir.createCondBr cmp, success_bb, failure_bb

                        @doInsideBBlock success_bb, =>
                                @storeBoolean(typeofIsFunction_alloca, true, "store_typeof")
                                ir.createBr merge_bb
                                
                        @doInsideBBlock failure_bb, =>
                                @storeBoolean(typeofIsFunction_alloca, false, "store_typeof")
                                ir.createBr merge_bb

                        ir.setInsertPoint merge_bb
                        
                        rv = ir.createLoad typeofIsFunction_alloca, "typeof_is_function"
                        rv._ejs_returns_ejsval_bool = true
                        rv
                else
                        @createCall @ejs_runtime.typeof_is_function, [arg], "is_function", false

        handleTypeofIsSymbol: (exp, opencode) ->
                arg = @visitOrNull exp.arguments[0]
                if opencode and @options.target_pointer_size is 64
                        insertBlock = ir.getInsertBlock()
                        insertFunc  = insertBlock.parent
                        
                        typeofIsSymbol_alloca = @createAlloca @currentFunction, types.EjsValue, "typeof_is_symbol"
                        
                        failure_bb   = new llvm.BasicBlock "typeof_symbol_false",     insertFunc
                        is_object_bb = new llvm.BasicBlock "typeof_symbol_is_object", insertFunc
                        success_bb   = new llvm.BasicBlock "typeof_symbol_true",      insertFunc
                        merge_bb     = new llvm.BasicBlock "typeof_symbol_merge",     insertFunc
                        
                        cmp = @isObject(arg, true)
                        ir.createCondBr cmp, is_object_bb, failure_bb

                        @doInsideBBlock is_object_bb, =>
                                obj = @emitEjsvalTo(arg, types.EjsObject.pointerTo(), "obj")
                                specops_load = @emitLoadSpecops(obj)
                                cmp = ir.createICmpEq specops_load, @ejs_runtime.symbol_specops, "symbol_specops_cmp"
                                ir.createCondBr cmp, success_bb, failure_bb

                        @doInsideBBlock success_bb, =>
                                @storeBoolean(typeofIsSymbol_alloca, true, "store_typeof")
                                ir.createBr merge_bb
                                
                        @doInsideBBlock failure_bb, =>
                                @storeBoolean(typeofIsSymbol_alloca, false, "store_typeof")
                                ir.createBr merge_bb

                        ir.setInsertPoint merge_bb
                        
                        rv = ir.createLoad typeofIsSymbol_alloca, "typeof_is_symbol"
                        rv._ejs_returns_ejsval_bool = true
                        rv
                else
                        @createCall @ejs_runtime.typeof_is_symbol, [arg], "is_symbol", false

        handleTypeofIsString: (exp, opencode) ->
                arg = @visitOrNull exp.arguments[0]
                @createEjsBoolSelect(@isString(arg))
                                
        handleTypeofIsNumber:    (exp, opencode) ->
                arg = @visitOrNull exp.arguments[0]
                @createEjsBoolSelect(@isNumber(arg))

        handleTypeofIsBoolean:   (exp, opencode) ->
                arg = @visitOrNull exp.arguments[0]
                @createEjsBoolSelect(@isBoolean(arg))

        handleIsUndefined: (exp, opencode) ->
                arg = @visitOrNull exp.arguments[0]
                @createEjsBoolSelect(@isUndefined(arg))
                
        handleIsNull: (exp, opencode) ->
                arg = @visitOrNull exp.arguments[0]
                @createEjsBoolSelect(@isNull(arg))
                        
        handleIsNullOrUndefined: (exp, opencode) ->
                arg = @visitOrNull exp.arguments[0]
                if opencode
                        @createEjsBoolSelect(ir.createOr(@isNull(arg), @isUndefined(arg), "or"))
                else
                        @createCall @ejs_binops["=="],   [@loadNullEjsValue(), arg], "is_null_or_undefined", false
                
                
        handleBuiltinUndefined:  (exp) -> @loadUndefinedEjsValue()

        handleSetPrototypeOf:  (exp) ->
                obj   = @visitOrNull exp.arguments[0]
                proto = @visitOrNull exp.arguments[1]
                @createCall @ejs_runtime.object_set_prototype_of, [obj, proto], "set_prototype_of", true
                # we should check the return value of set_prototype_of

        handleObjectCreate:  (exp) ->
                proto = @visitOrNull exp.arguments[0]
                @createCall @ejs_runtime.object_create, [proto], "object_create", true
                # we should check the return value of object_create

        handleGatherRest: (exp) ->
                rest_name = exp.arguments[0].value
                formal_params_length = exp.arguments[1].value
                
                has_rest_bb = new llvm.BasicBlock "has_rest_bb", @currentFunction
                no_rest_bb = new llvm.BasicBlock "no_rest_bb", @currentFunction
                rest_merge_bb = new llvm.BasicBlock "rest_merge", @currentFunction
                        
                rest_alloca = @createAlloca @currentFunction, types.EjsValue, "local_rest_object"

                load_argc = @createLoad @currentFunction.topScope.get("%argc"), "argc_load"

                cmp = ir.createICmpSGt load_argc, consts.int32(formal_params_length), "argcmpresult"
                ir.createCondBr cmp, has_rest_bb, no_rest_bb

                ir.setInsertPoint has_rest_bb
                # we have > args than are declared, shove the rest into the rest parameter
                load_args = @createLoad @currentFunction.topScope.get("%args"), "args_load"
                gep = ir.createInBoundsGetElementPointer load_args, [consts.int32(formal_params_length)], "rest_arg_gep"
                load_argc = ir.createNswSub load_argc, consts.int32(formal_params_length)
                rest_value = @createCall @ejs_runtime.array_new_copy, [load_argc, gep], "argstmp", !@ejs_runtime.array_new_copy.doesNotThrow
                ir.createStore rest_value, rest_alloca
                ir.createBr rest_merge_bb

                ir.setInsertPoint no_rest_bb
                # we have <= args than are declared, so the rest parameter is just an empty array
                rest_value = @createCall @ejs_runtime.array_new, [consts.int32(0), consts.false()], "arrtmp", !@ejs_runtime.array_new.doesNotThrow
                ir.createStore rest_value, rest_alloca
                ir.createBr rest_merge_bb

                ir.setInsertPoint rest_merge_bb
                
                @currentFunction.topScope.set rest_name, rest_alloca
                @currentFunction.restArgPresent = true

                ir.createLoad rest_alloca, "load_rest"

        handleArrayFromSpread: (exp) ->
                arg_count = exp.arguments.length
                if @currentFunction.scratch_area? and @currentFunction.scratch_length < arg_count
                        spreadArrayType = llvm.ArrayType.get types.EjsValue, arg_count
                        @currentFunction.scratch_area = @createAlloca @currentFunction, spreadArrayType, "args_scratch_area"
                        @currentFunction.scratch_area.setAlignment 8

                # reuse the scratch area
                spread_alloca = @currentFunction.scratch_area
                visited = (@visitOrNull(a) for a in exp.arguments)
                visited.forEach (a, i) =>
                        gep = ir.createGetElementPointer spread_alloca, [consts.int32(0), consts.int64(i)], "spread_gep_#{i}"
                        store = ir.createStore visited[i], gep, "spread[#{i}]-store"

                argsCast = ir.createGetElementPointer spread_alloca, [consts.int32(0), consts.int64(0)], "spread_call_args_load"

                argv = [consts.int32(arg_count), argsCast]
                @createCall @ejs_runtime.array_from_iterables, argv, "spread_arr"

        handleArgPresent: (exp) ->
                load_argc = @createLoad @currentFunction.topScope.get("%argc"), "argc_n_load"

                cmp = ir.createICmpUGE load_argc, consts.int32(exp.arguments[0].value), "argcmpresult"

                @createEjsBoolSelect cmp
                                
class AddFunctionsVisitor extends TreeVisitor
        constructor: (@module, @abi) ->

        visitFunction: (n) ->
                n.ir_name = "_ejs_anonymous"
                if n?.id?.name?
                        n.ir_name = n.id.name

                # at this point n.params includes %env as its first param, and is followed by all the formal parameters from the original
                # script source.  we remove the %env parameter and save off he rest of the formal parameter names, and replace the list with
                # our runtime parameters.

                # remove %env from the formal parameter list, but save its name first
                env_name = n.params[0].name
                n.params.splice 0, 1
                # and store the JS formal parameters someplace else
                n.formal_params = n.params

                n.params = ({ type: Identifier, name: param.name, llvm_type: param.llvm_type } for param in @abi.ejs_params)
                n.params[@abi.env_param_index].name = env_name

                # create the llvm IR function using our platform calling convention
                n.ir_func = types.takes_builtins @abi.createFunction @module, n.ir_name, @abi.ejs_return_type, (param.llvm_type for param in n.params)
                n.ir_func.setInternalLinkage() if not n.toplevel

                ir_args = n.ir_func.args
                ir_args[i].setName(n.params[i].name) for i in [0...n.params.length]

                # we don't need to recurse here since we won't have nested functions at this point
                n

sanitize_with_regexp = (filename) ->
        filename.replace /[.,-\/\\]/g, "_" # this is insanely inadequate

insert_toplevel_func = (tree, filename) ->
        toplevel =
                type: FunctionDeclaration,
                id:   b.identifier("_ejs_toplevel_#{sanitize_with_regexp filename}")
                params: [b.identifier("exports")], # XXX this 'exports' should be '%exports' if the module has ES6 module declarations
                defaults: []
                body:
                        type: BlockStatement
                        body: tree.body
                toplevel: true

        tree.body = [toplevel]
        tree

exports.compile = (tree, base_output_filename, source_filename, export_lists, options) ->
        abi = if (options.target_arch is "armv7" or options.target_arch is "armv7s" or options.target_arch is "x86") then new SRetABI() else new ABI()

        tree = insert_toplevel_func tree, source_filename

        debug.log -> escodegen.generate tree

        toplevel_name = tree.body[0].id.name
        
        #debug.log 1, "before closure conversion"
        #debug.log 1, -> escodegen.generate tree

        tree = closure_conversion.convert tree, path.basename(source_filename), export_lists, options

        debug.log 1, "after closure conversion"
        debug.log 1, -> escodegen.generate tree

        ###
        tree = typeinfer.run tree
        
        debug.log 1, "after type inference"
        debug.log 1, -> escodegen.generate tree
        ###             
        tree = optimizations.run tree
        
        debug.log 1, "after optimization"
        debug.log 1, -> escodegen.generate tree

        module = new llvm.Module base_output_filename
        
        module.toplevel_name = toplevel_name

        visitor = new AddFunctionsVisitor module, abi
        tree = visitor.visit tree

        debug.log -> escodegen.generate tree

        visitor = new LLVMIRVisitor module, source_filename, options, abi
        visitor.visit tree

        module

# this class does two things
#
# 1. rewrites all sources to be relative to @toplevel_path.  i.e. if
#    the following directory structure exists:
#
#    externals/
#      ext1.js
#    root/
#      main.js      (contains: import { foo } from "modules/foo" )
#      modules/
#        foo1.js    (contains: module ext1 from "../../externals/ext1")
#
#    $PWD = root/
#
#      $ ejs main.js
#
#    ejs will rewrite module paths such that main.js is unchanged, and
#    foo1.js's module declaration reads:
#
#      "../externals/ext1"
# 
# 2. builds up a list (@importList) containing the list of all
#    imported modules
#
class GatherImports extends TreeVisitor
        constructor: (@filename, @path, @toplevel_path, @exportLists) ->
                @importList = []
                # remove our .js suffix since all imports are suffix-free
                if @filename.lastIndexOf(".js") == @filename.length - 3
                        @filename = @filename.substring(0, @filename.length-3)
                
        isInternalModule = (source) -> source[0] is "@"
                
        addSource: (n) ->
                return n if not n.source?
                
                throw new Error("import sources must be strings") if not is_string_literal(n.source)

                if isInternalModule(n.source.value)
                        if n.source.value.indexOf('@node-compat/') is 0
                                # add the exports here for node-compat modules
                                module_name = n.source.value.slice('@node-compat/'.length)
                                if not node_compat.modules[module_name]?
                                        throw new Error("@node-compat module #{module_name} not found")
                                if not hasOwn.call @exportLists, n.source.value
                                        @exportLists[n.source.value] = Object.create(null)
                                        @exportLists[n.source.value].ids = node_compat.modules[module_name]
                                n.source_path = b.literal(n.source.value)

                        # otherwise we just strip off the @
                        else
                                n.source_path = b.literal(n.source.value.slice(1))

                        return n
                
                if n.source[0] is "/"
                        source_path = n.source.value
                else
                        source_path = path.resolve @toplevel_path, "#{@path}/#{n.source.value}"

                if source_path.indexOf(process.cwd()) is 0
                        source_path = path.relative(process.cwd(), source_path)
                        
                @importList.push(source_path) if @importList.indexOf(source_path) is -1

                n.source_path = b.literal(source_path)
                n

        addDefaultExport: (path) ->
                if not hasOwn.call @exportLists, path
                        @exportLists[path] = Object.create(null)
                        @exportLists[path].ids = new Set()
                @exportLists[path].has_default = true
                
        addExportIdentifier: (path, id) ->
                if not hasOwn.call @exportLists, path
                        @exportLists[path] = Object.create(null)
                        @exportLists[path].ids = new Set()
                if id is "default"
                        @exportLists[path].has_default = true
                @exportLists[path].ids.add(id)
                
        visitImportDeclaration: (n) ->
                @addSource(n)
                
        visitExportDeclaration: (n) ->
                n = @addSource(n)

                if n.default
                        @addDefaultExport(@filename)
                else if n.source?
                        for spec in n.specifiers
                                @addExportIdentifier(@filename, spec.name?.name or spec.id?.name)
                else if Array.isArray(n.declaration)
                        for decl in n.declaration
                                @addExportIdentifier(@filename, decl.id.name)
                else if n.declaration.type is FunctionDeclaration
                        @addExportIdentifier(@filename, n.declaration.id.name) 
                else if n.declaration.type is ClassDeclaration
                        @addExportIdentifier(@filename, n.declaration.id.name) 
                else if n.declaration.type is VariableDeclaration
                        for decl in n.declaration.declarations
                                @addExportIdentifier(@filename, decl.id.name)
                else if n.declaration.type is VariableDeclarator
                        @addExportIdentifier(@filename, n.declaration.id.name)
                else
                        throw new Error("unhandled case in visitExportDeclaration");
                n
        visitModuleDeclaration: (n) -> @addSource(n)

exports.gatherImports = (filename, path, top_path, tree, exportLists) ->
        visitor = new GatherImports(filename, path, top_path, exportLists)
        visitor.visit(tree)
        visitor.importList
        
