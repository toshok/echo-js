/* -*- Mode: js2; tab-width: 4; indent-tabs-mode: nil; -*-
 * vim: set ts=4 sw=4 et tw=99 ft=js:
 */

//
// desugars
//
//   [1, 2, ...foo, 3, 4]
// 
//   o.foo(1, 2, ...foo, 3, 4)
//
// to:
//
//   %arrayFromSpread([1, 2], foo, [3, 4])
//
//   o.foo.apply(o, %arrayFromSpread([1, 2], foo, [3, 4])
//

import { TransformPass } from '../node-visitor';
import * as b from '../ast-builder';
import { intrinsic, is_intrinsic } from '../echo-util';
import { arrayFromSpread_id, apply_id } from '../common-ids';

export class DesugarSpread extends TransformPass {
    visitArrayExpression (n) {
        n = super(n);
        let needs_desugaring = false;
        for (let el of n.elements) {
            if (el.type === b.SpreadElement) {
                needs_desugaring = true;
                break;
            }
        }

        if (!needs_desugaring)
            return n;

        let new_args = [];
        let current_elements = [];
        for (let el of n.elements) {
            if (el.type === b.SpreadElement) {
                if (current_elements.length === 0) {
                    // just push the spread argument into the new args
                    new_args.push(el.argument);
                }
                else {
                    // push the current_elements as an array literal, then the spread.
                    // also reset current_elements to []
                    new_args.push(b.arrayExpression(current_elements));
                    new_args.push(el.argument);
                    current_elements = [];
                }
            }
            else {
                current_elements.push(el);
            }
        }
        if (current_elements.length > 0)
            new_args.push(b.arrayExpression(current_elements));

        // check to see if we've just created an array of nothing but array literals, and flatten them all
        // into one and get rid of the spread altogether
        let all_arrays = true;
        for (let a of new_args) {
            if (a.type !== b.ArrayExpression)
                all_arrays = false;
        }
        
        if (all_arrays) {
            let na = [];
            for (let a of new_args)
                na = na.concat(a.elements);
            n.elements = na;
            return n;
        }
        else {
            return intrinsic(arrayFromSpread_id, new_args);
        }
    }

    visitCallExpression (n) {
        n = super(n);
        let needs_desugaring = false;
        for (let el of n.arguments) {
            if (el.type === b.SpreadElement) {
                needs_desugaring = true;
                break;
            }
        }

        if (!needs_desugaring)
            return n;

        let new_args = [];
        let current_elements = [];
        for (let el of n.arguments) {
            if (is_intrinsic(el, "%arrayFromSpread")) {
                // flatten spreads
                new_args.concat(el.arguments);
            }
            else if (el.type === b.SpreadElement) {
                if (current_elements.length === 0) {
                    // just push the spread argument into the new args
                    new_args.push(el.argument);
                }
                else {
                    // push the current_elements as an array literal, then the spread.
                    // also reset current_elements to []
                    new_args.push(b.arrayExpression(current_elements));
                    new_args.push(el.argument);
                    current_elements = [];
                }
            }
            else {
                current_elements.push(el);
            }
        }

        if (current_elements.length > 0)
            new_args.push(b.arrayExpression(current_elements));

        // check to see if we've just created an array of nothing but array literals, and flatten them all
        // into one and get rid of the spread altogether
        let all_arrays = true;
        for (let a of new_args) {
            if (a.type !== b.ArrayExpression) {
                all_arrays = false;
                break;
            }
        }
        if (all_arrays) {
            let na = [];
            for (let a of new_args)
                na = na.concat(a.elements);

            n.arguments = na;
        }
        else {
            let receiver;

            if (n.callee.type === b.MemberExpression)
                receiver = n.callee.object;
            else
                receiver = b.nullLit();

            n.callee = b.memberExpression(n.callee, apply_id);
            n.arguments = [receiver, intrinsic(arrayFromSpread_id, new_args)];
        }

        return n;
    }
}
