// this class does two things
//
// 1. rewrites all sources to be relative to this.toplevel_path.  i.e. if
//    the following directory structure exists:
//
//    externals/
//      ext1.js
//    root/
//      main.js      (contains: import { foo } from "modules/foo" )
//      modules/
//        foo1.js    (contains: module ext1 from "../../externals/ext1")
//
//    $PWD = root/
//
//      $ ejs main.js
//
//    ejs will rewrite module paths such that main.js is unchanged, and
//    foo1.js's module declaration reads:
//
//      "../externals/ext1"
// 
// 2. builds up a list (this.importList) containing the list of all
//    imported modules
//

import * as node_compat from '../node-compat'

import * as path from '@node-compat/path';
import { TreeVisitor } from '../node-visitor';
import { startGenerator, is_intrinsic, is_string_literal } from '../echo-util';
import * as b, { FunctionDeclaration, ClassDeclaration, VariableDeclaration, VariableDeclarator } from '../ast-builder';

let hasOwn = Object.prototype.hasOwnProperty;

function isInternalModule (source) {
    return source[0] === "@";
}

class GatherImports extends TreeVisitor {
    constructor (filename, path, toplevel_path, exportLists) {
        super();
        this.filename = filename;
        this.path = path;
        this.toplevel_path = toplevel_path;
        this.exportLists = exportLists;

        this.importList = [];
        // remove our .js suffix since all imports are suffix-free
        if (this.filename.lastIndexOf(".js") === this.filename.length - 3)
            this.filename = this.filename.substring(0, this.filename.length-3);
    }
    
    addSource (n) {
        if (!n.source) return n;
        
        if (!is_string_literal(n.source)) throw new Error("import sources must be strings");

        if (isInternalModule(n.source.value)) {
            if (n.source.value.indexOf('@node-compat/') === 0) {
                // add the exports here for node-compat modules
                let module_name = n.source.value.slice('@node-compat/'.length);
                if (!node_compat.modules[module_name])
                    throw new Error(`@node-compat module ${module_name} not found`);
		if (!hasOwn.call(this.exportLists, n.source.value)) {
                    this.exportLists[n.source.value] = Object.create(null);
                    this.exportLists[n.source.value].ids = node_compat.modules[module_name];
		}
                n.source_path = b.literal(n.source.value);
	    }
            // otherwise we just strip off the @
            else {
                n.source_path = b.literal(n.source.value.slice(1));
	    }
	    return n;
        }
        
        let source_path = (n.source[0] === "/") ? n.source.value : path.resolve(this.toplevel_path, `${this.path}/${n.source.value}`);

        if (source_path.indexOf(process.cwd()) === 0)
            source_path = path.relative(process.cwd(), source_path);

        if (this.importList.indexOf(source_path) === -1)
            this.importList.push(source_path);

        n.source_path = b.literal(source_path);
        return n;
    }

    addDefaultExport (path) {
        if (!hasOwn.call(this.exportLists, path)) {
            this.exportLists[path] = Object.create(null);
            this.exportLists[path].ids = new Set();
        }
        this.exportLists[path].has_default = true;
    }
    
    addExportIdentifier (path, id) {
        if (!hasOwn.call(this.exportLists, path)) {
            this.exportLists[path] = Object.create(null);
            this.exportLists[path].ids = new Set();
        }
        if (id === "default")
            this.exportLists[path].has_default = true;
        this.exportLists[path].ids.add(id);
    }
    
    visitImportDeclaration (n) {
        return this.addSource(n);
    }
    
    visitExportDeclaration (n) {
        n = this.addSource(n);

        if (n.default) {
            this.addDefaultExport(this.filename);
        }
        else if (n.source) {
            for (let spec of n.specifiers)
                this.addExportIdentifier(this.filename, spec.name ? spec.name.name : spec.id && spec.id.name);
        }
        else if (Array.isArray(n.declaration)) {
            for (let decl of n.declaration)
                this.addExportIdentifier(this.filename, decl.id.name);
        }
        else if (n.declaration.type === FunctionDeclaration) {
            this.addExportIdentifier(this.filename, n.declaration.id.name) ;
        }
        else if (n.declaration.type === ClassDeclaration) {
            this.addExportIdentifier(this.filename, n.declaration.id.name) ;
        }
        else if (n.declaration.type === VariableDeclaration) {
            for (let decl of n.declaration.declarations)
                this.addExportIdentifier(this.filename, decl.id.name);
        }
        else if (n.declaration.type === VariableDeclarator) {
            this.addExportIdentifier(this.filename, n.declaration.id.name);
        }
        else {
            throw new Error("unhandled case in visitExportDeclaration");
        }

        return n;
    }

    visitModuleDeclaration (n) {
        return this.addSource(n);
    }
}

export function gatherImports (filename, path, top_path, tree, exportLists) {
    let visitor = new GatherImports(filename, path, top_path, exportLists);
    visitor.visit(tree);
    return visitor.importList;
}

