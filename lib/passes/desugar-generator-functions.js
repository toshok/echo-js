/* -*- Mode: js2; indent-tabs-mode: nil; tab-width: 4; js2-indent-offset: 4; js2-basic-offset: 4; -*-
 * vim: set ts=4 sw=4 et tw=99 ft=js:
 */
// this pass converts all generator functions like this:
//
// function* foo() {
//   yield 1;
//   yield 2;
//   yield 3;
// }
//
// into this:
//
// function foo() {
//   // arrow function so `this` is bound
//   let %gen = %makeGenerator(() => {
//     %generatorYield(%gen, 1);
//     %generatorYield(%gen, 2);
//     %generatorYield(%gen, 3);
//   }
//   return %gen;
// }
//

import { TransformPass } from '../node-visitor';
import * as b from '../ast-builder';
import { makeGenerator_id, generatorYield_id } from '../common-ids';
import { intrinsic, startGenerator } from '../echo-util';
import { reportError, reportWarning } from '../errors';

export class DesugarGeneratorFunctions extends TransformPass {
    
    constructor (options) {
        super(options);
        this.mapping = [];
        this.genGen = startGenerator();
        this.yieldGen = startGenerator();
    }

    visitFunction(n) {
        if (n.generator)
            this.mapping.unshift(b.identifier(`%_gen_${this.genGen()}`));
        n = super.visitFunction(n);
        if (n.generator) {
            let old_body = n.body;
            n.body = b.blockStatement([b.letDeclaration(this.mapping[0], intrinsic(makeGenerator_id, [b.arrowFunctionExpression([], old_body)])), b.returnStatement(this.mapping[0])]);
            n.generator = false;
        }
        this.mapping.shift();
        return n;
    }

    visitYield(n) {
        n.argument = this.visit(n.argument);
        if (n.delegate) {
            let yield_id = b.identifier(`%_yield_${this.genGen()}`);
            return b.forOfStatement(b.letDeclaration(yield_id, null), n.argument, b.blockStatement([intrinsic(generatorYield_id, [this.mapping[0], yield_id])]));
        }
        else {
            return intrinsic(generatorYield_id, [this.mapping[0], n.argument]);
        }
    }
}
