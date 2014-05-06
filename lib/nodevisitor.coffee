esprima = require 'esprima'
debug = require 'debug'

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

exports.TreeVisitor = class TreeVisitor
        # for collections, returns all non-null.  for single item properties,
        # just always returns the item.
        filter = (x) ->
                return x if not Array.isArray x
        
                rv = []
                for y in x when y?
                        if Array.isArray y
                                rv = rv.concat y
                        else
                                rv.push y
                rv

        # a rather disgusting in-place filter+flatten visitor
        visitArray: (arr, args...) ->
                i = 0
                e = arr.length
                while i < e
                        tmp = @visit arr[i], args...
                        if tmp is null
                                arr.splice i, 1
                                e = arr.length
                        else if Array.isArray tmp
                                tmplen = tmp.length
                                if tmplen > 0
                                        tmp.unshift 1
                                        tmp.unshift i
                                        arr.splice.apply arr, tmp
                                        i += tmplen
                                        e = arr.length
                                else
                                        arr.splice i, 1
                                        e = arr.length
                        else
                                arr[i] = tmp
                                i += 1
                arr
                
                
        visit: (n, args...) ->
                return null if not n?

                return @visitArray n, args... if Array.isArray n

                #debug.indent()
                #debug.log -> "#{n.type}>"
                
                switch n.type
                        when ArrayExpression         then rv = @visitArrayExpression n, args...
                        when ArrayPattern            then rv = @visitArrayPattern n, args...
                        when ArrowFunctionExpression then rv = @visitArrowFunctionExpression n, args...
                        when AssignmentExpression    then rv = @visitAssignmentExpression n, args...
                        when BinaryExpression        then rv = @visitBinaryExpression n, args...
                        when BlockStatement          then rv = @visitBlock n, args...
                        when BreakStatement          then rv = @visitBreak n, args...
                        when CallExpression          then rv = @visitCallExpression n, args...
                        when CatchClause             then rv = @visitCatchClause n, args...
                        when ClassBody               then rv = @visitClassBody n, args...
                        when ClassDeclaration        then rv = @visitClassDeclaration n, args...
                        when ClassExpression         then throw new Error "Unhandled AST node type: #{n.type}"
                        when ClassHeritage           then throw new Error "Unhandled AST node type: #{n.type}"
                        when ComprehensionBlock      then throw new Error "Unhandled AST node type: #{n.type}"
                        when ComprehensionExpression then throw new Error "Unhandled AST node type: #{n.type}"
                        when ConditionalExpression   then rv = @visitConditionalExpression n, args...
                        when ContinueStatement       then rv = @visitContinue n, args...
                        when DebuggerStatement       then throw new Error "Unhandled AST node type: #{n.type}"
                        when DoWhileStatement        then rv = @visitDo n, args...
                        when EmptyStatement          then rv = @visitEmptyStatement n, args...
                        when ExportDeclaration       then rv = @visitExportDeclaration n, args...
                        when ExportBatchSpecifier    then throw new Error "Unhandled AST node type: #{n.type}"
                        when ExportSpecifier         then throw new Error "Unhandled AST node type: #{n.type}"
                        when ExpressionStatement     then rv = @visitExpressionStatement n, args...
                        when ForInStatement          then rv = @visitForIn n, args...
                        when ForOfStatement          then rv = @visitForOf n, args...
                        when ForStatement            then rv = @visitFor n, args...
                        when FunctionDeclaration     then rv = @visitFunctionDeclaration n, args...
                        when FunctionExpression      then rv = @visitFunctionExpression n, args...
                        when Identifier              then rv = @visitIdentifier n, args...
                        when IfStatement             then rv = @visitIf n, args...
                        when ImportDeclaration       then rv = @visitImportDeclaration n, args...
                        when ImportSpecifier         then rv = @visitImportSpecifier n, args...
                        when LabeledStatement        then rv = @visitLabeledStatement n, args...
                        when Literal                 then rv = @visitLiteral n, args...
                        when LogicalExpression       then rv = @visitLogicalExpression n, args...
                        when MemberExpression        then rv = @visitMemberExpression n, args...
                        when MethodDefinition        then rv = @visitMethodDefinition n, args...
                        when ModuleDeclaration       then rv = @visitModuleDeclaration n, args...
                        when NewExpression           then rv = @visitNewExpression n, args...
                        when ObjectExpression        then rv = @visitObjectExpression n, args...
                        when ObjectPattern           then rv = @visitObjectPattern n, args...
                        when Program                 then rv = @visitProgram n, args...
                        when Property                then rv = @visitProperty n, args...
                        when ReturnStatement         then rv = @visitReturn n, args...
                        when SequenceExpression      then rv = @visitSequenceExpression n, args...
                        when SpreadElement           then rv = @visitSpreadElement n, args...
                        when SwitchCase              then rv = @visitCase n, args...
                        when SwitchStatement         then rv = @visitSwitch n, args...
                        when TaggedTemplateExpression then rv = @visitTaggedTemplateExpression n, args...
                        when TemplateElement         then rv = @visitTemplateElement n, args...
                        when TemplateLiteral         then rv = @visitTemplateLiteral n, args...
                        when ThisExpression          then rv = @visitThisExpression n, args...
                        when ThrowStatement          then rv = @visitThrow n, args...
                        when TryStatement            then rv = @visitTry n, args...
                        when UnaryExpression         then rv = @visitUnaryExpression n, args...
                        when UpdateExpression        then rv = @visitUpdateExpression n, args...
                        when VariableDeclaration     then rv = @visitVariableDeclaration n, args...
                        when VariableDeclarator      then rv = @visitVariableDeclarator n, args...
                        when WhileStatement          then rv = @visitWhile n, args...
                        when WithStatement           then rv = @visitWith n, args...
                        when YieldExpression         then rv = @visitYield n, args...
                        else
                            throw new Error "PANIC: unknown parse node type #{n.type}"
                
                #debug.log -> "<#{n.type}, rv = #{if rv then rv.type else 'null'}"
                #debug.unindent()

                return n if rv is undefined or rv is n
                return rv

        visitProgram: (n, args...) ->
                n.body = @visitArray n.body, args...
                n
                
        visitFunction: (n, args...) ->
                n.params = @visitArray n.params, args...
                n.body   = @visit n.body, args...
                n

        visitFunctionDeclaration: (n, args...) ->
                @visitFunction n, args...
                
        visitFunctionExpression: (n, args...) ->
                @visitFunction n, args...

        visitArrowFunctionExpression: (n, args...) ->
                @visitFunction n, args...

        visitBlock: (n, args...) ->
                n.body = @visitArray n.body, args...
                n

        visitEmptyStatement: (n) ->
                n

        visitExpressionStatement: (n, args...) ->
                n.expression = @visit n.expression, args...
                n
                
        visitSwitch: (n, args...) ->
                n.discriminant = @visit n.discriminant, args...
                n.cases        = @visitArray n.cases, args...
                n
                
        visitCase: (n, args...) ->
                n.test       = @visit n.test, args...
                n.consequent = @visit n.consequent, args...
                n
                
        visitFor: (n, args...) ->
                n.init   = @visit n.init, args...
                n.test   = @visit n.test, args...
                n.update = @visit n.update, args...
                n.body   = @visit n.body, args...
                n
                
        visitWhile: (n, args...) ->
                n.test = @visit n.test, args...
                n.body = @visit n.body, args...
                n
                
        visitIf: (n, args...) ->
                n.test       = @visit n.test, args...
                n.consequent = @visit n.consequent, args...
                n.alternate  = @visit n.alternate, args...
                n
                
        visitForIn: (n, args...) ->
                n.left  = @visit n.left, args...
                n.right = @visit n.right, args...
                n.body  = @visit n.body, args...
                n
                
        visitForOf: (n, args...) ->
                n.left  = @visit n.left, args...
                n.right = @visit n.right, args...
                n.body  = @visit n.body, args...
                n
                
        visitDo: (n, args...) ->
                n.body = @visit n.body, args...
                n.test = @visit n.test, args...
                n
                
        visitIdentifier: (n) -> n
        visitLiteral: (n) -> n
        visitThisExpression: (n) -> n
        visitBreak: (n) -> n
        visitContinue: (n) -> n
                
        visitTry: (n, args...) ->
                n.block = @visit n.block, args...
                if n.handlers?
                        n.handlers = @visit n.handlers, args...
                else
                        n.handlers = null
                n.finalizer = @visit n.finalizer, args...
                n

        visitCatchClause: (n, args...) ->
                n.param = @visit n.param, args...
                n.guard = @visit n.guard, args...
                n.body = @visit n.body, args...
                n
                
        visitThrow: (n, args...) ->
                n.argument = @visit n.argument, args...
                n
                
        visitReturn: (n, args...) ->
                n.argument = @visit n.argument, args...
                n
                
        visitWith: (n, args...) ->
                n.object = @visit n.object, args...
                n.body   = @visit n.body, args...
                n

        visitYield: (n, args...) ->
                n.argument = @visit n.argument, args...
                n
                
        visitVariableDeclaration: (n, args...) ->
                n.declarations = @visitArray n.declarations, args...
                n

        visitVariableDeclarator: (n, args...) ->
                n.id   = @visit n.id, args...
                n.init = @visit n.init, args...
                n
                                
        visitLabeledStatement: (n, args...) ->
                n.label = @visit n.label, args...
                n.body  = @visit n.body, args...
                n
                
        visitAssignmentExpression: (n, args...) ->
                n.left  = @visit n.left, args...
                n.right = @visit n.right, args...
                n
                
        visitConditionalExpression: (n, args...) ->
                n.test       = @visit n.test, args...
                n.consequent = @visit n.consequent, args...
                n.alternate  = @visit n.alternate, args...
                n
                
        visitLogicalExpression: (n, args...) ->
                n.left  = @visit n.left, args...
                n.right = @visit n.right, args...
                n
                
        visitBinaryExpression: (n, args...) ->
                n.left  = @visit n.left, args...
                n.right = @visit n.right, args...
                n

        visitUnaryExpression: (n, args...) ->
                n.argument = @visit n.argument, args...
                n

        visitUpdateExpression: (n, args...) ->
                n.argument = @visit n.argument, args...
                n

        visitMemberExpression: (n, args...) ->
                n.object = @visit n.object, args...
                if n.computed
                        n.property = @visit n.property, args...
                n
                
        visitSequenceExpression: (n, args...) ->
                n.expressions = @visitArray n.expressions, args...
                n

        visitSpreadElement: (n, args...) ->
                n.arguments = @visit n.argument, args...
                n

        visitNewExpression: (n, args...) ->
                n.callee    = @visit n.callee, args...
                n.arguments = @visitArray n.arguments, args...
                n

        visitObjectExpression: (n, args...) ->
                n.properties = @visitArray n.properties, args...
                n

        visitArrayExpression: (n, args...) ->
                n.elements = @visitArray n.elements, args...
                n

        visitProperty: (n, args...) ->
                n.key   = @visit n.key, args...
                n.value = @visit n.value, args...
                n
                                
        visitCallExpression: (n, args...) ->
                n.callee    = @visit n.callee, args...
                n.arguments = @visitArray n.arguments, args...
                n

        visitClassDeclaration: (n, args...) ->
                n.body = @visit n.body, args...
                n

        visitClassBody: (n, args...) ->
                n.body = @visitArray n.body, args...
                n

        visitMethodDefinition: (n, args...) ->
                n.value = @visit n.value, args...
                n

        visitModuleDeclaration: (n, args...) ->
                n.id = @visit n.id, args...
                n.body = @visit n.body, args...
                n

        visitExportDeclaration: (n, args...) ->
                n.declaration = @visit n.declaration, args...
                n
                
        visitImportDeclaration: (n, args...) ->
                n.specifiers = @visitArray n.specifiers, args...
                n

        visitImportSpecifier: (n, args...) ->
                n.id = @visit n.id, args...
                n

        visitArrayPattern: (n, args...) ->
                n.elements = @visitArray n.elements, args...
                n

        visitObjectPattern: (n, args...) ->
                n.properties = @visitArray n.properties, args...
                n

        visitTaggedTemplateExpression: (n, args...) ->
                n.quasi = @visit n.quasi, args...
                n

        visitTemplateLiteral: (n, args...) ->
                n.quasis      = @visitArray n.quasis, args...
                n.expressions = @visitArray n.expressions, args...
                n

        visitTemplateElement: (n, args...) ->
                n

        toString: () -> "TreeVisitor"
