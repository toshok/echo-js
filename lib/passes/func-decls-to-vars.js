/* -*- Mode: js2; indent-tabs-mode: nil; tab-width: 4; js2-indent-offset: 4; js2-basic-offset: 4; -*-
 * vim: set ts=4 sw=4 et tw=99 ft=js:
 */

// convert all function declarations to variable assignments
// with named function expressions.
// 
// i.e. from:
//   function foo() { }
// to:
//   var foo = function foo() { }
// 

import * as b from '../ast-builder';
import { TransformPass } from '../node-visitor';

export class FuncDeclsToVars extends TransformPass {
    visitFunctionDeclaration (n) {
        if (n.toplevel) {
            n.body = this.visit(n.body);
            return n;
        }
        else {
            let func_exp = n;
            func_exp.type = b.FunctionExpression;
            func_exp.body = this.visit(func_exp.body);
            return b.varDeclaration(b.identifier(n.id.name), func_exp);
        }
    }
}
