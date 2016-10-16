/* -*- Mode: js2; indent-tabs-mode: nil; tab-width: 4; js2-indent-offset: 4; js2-basic-offset: 4; -*-
 * vim: set ts=4 sw=4 et tw=99 ft=js:
 */

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

import { reportError } from '../errors';
import * as path from '@node-compat/path';
import * as fs from   '@node-compat/fs';
import { TreeVisitor } from '../node-visitor';
import { startGenerator, is_intrinsic, is_string_literal, underline } from '../echo-util';
import { JSModuleInfo, NativeModuleInfo } from '../module-info';
import * as b from '../ast-builder';
import * as esprima from '../../external-deps/esprima/esprima-es6';

let hasOwn = Object.prototype.hasOwnProperty;

function isNativeModule (source) {
    return source[0] === "@";
}

let allModules = new Map();
let nativeModules = new Map();

class GatherImports extends TreeVisitor {
    constructor (filename, p, toplevel_path, import_vars) {
        super();
        this.filename = filename;
        this.path = p;
        this.toplevel_path = toplevel_path;
        this.import_vars = import_vars;

        this.importList = [];
        // remove our .js suffix since all imports are suffix-free
        if (path.extname(this.filename) === ".js")
            this.filename = this.filename.substring(0, this.filename.length-3);

        this.moduleInfo = new JSModuleInfo(this.filename);
        allModules.set(this.filename, this.moduleInfo);
    }
    
    addSource (n) {
        if (!n.source) return n;
        
        if (!is_string_literal(n.source)) throw new Error("import sources must be strings");

        let source_path = n.source.value;

        for (let v of this.import_vars) {
            source_path = source_path.replace(`$${v.variable}`, v.value);
        }

        if (isNativeModule(source_path)) {
            if (this.importList.indexOf(source_path) === -1)
                this.importList.push(source_path);
            this.moduleInfo.addImportSource(source_path);

            n.source_path = b.literal(source_path);
            return n;
        }
        
        if (source_path[0] !== '/')
            source_path = path.resolve(this.toplevel_path, this.path, source_path);

        if (source_path.indexOf(process.cwd()) === 0)
            source_path = path.relative(process.cwd(), source_path);

        if (this.importList.indexOf(source_path) === -1)
            this.importList.push(source_path);
        this.moduleInfo.addImportSource(source_path);

        n.source_path = b.literal(source_path);
        return n;
    }

    addDefaultExport (path) {
        this.moduleInfo.addExport("default");
        this.moduleInfo.setHasDefaultExport();
    }
    
    addExportIdentifier (id, constval) {
        if (id === 'default')
            this.moduleInfo.setHasDefaultExport();
        this.moduleInfo.addExport(id, constval);
    }
    
    visitImportDeclaration (n) {
        return this.addSource(n);
    }

    visitExportDefaultDeclaration (n) {
        // XXX more here?
        this.addDefaultExport();
    }

    visitExportNamedDeclaration (n) {
        if (n.declaration && (n.specifiers.length > 0 || n.source)) {
            reportError(Error, "invalid state in ExportNamedDeclaration", this.filename, n.loc);
        }

        n = this.addSource(n);

        if (n.specifiers.length > 0) {
            for (let spec of n.specifiers) {
                this.addExportIdentifier(spec.exported.name);
            }
        }
        else if (n.declaration) {
            let declaration = n.declaration;
            if (Array.isArray(declaration)) {
                for (let decl of declaration) {
                    this.addExportIdentifier(decl.id.name);
                }
            }
            else if (declaration.type === b.FunctionDeclaration) {
                this.addExportIdentifier(declaration.id.name) ;
            }
            else if (declaration.type === b.ClassDeclaration) {
                this.addExportIdentifier(declaration.id.name) ;
            }
            else if (declaration.type === b.VariableDeclaration) {
                for (let decl of declaration.declarations) {
                    this.addExportIdentifier(decl.id.name, declaration.kind === 'const' && decl.init.type === b.Literal ? decl.init : undefined);
                }
            }
            else if (declaration.type === b.VariableDeclarator) {
                this.addExportIdentifier(declaration.id.name);
            }
            else {
                throw new Error("unhandled case in visitExportNamedDeclaration");
            }
        }
        else {
            throw new Error("unhandled case in visitExportNamedDeclaration");
        }
    }

    visitExportAllDeclaration (n) {
        throw new Error("GatherImports#visitExportAllDeclaration unimplemented");
    }

    visitModuleDeclaration (n) {
        return this.addSource(n);
    }
}

export function getAllModules () { return allModules; }

function dumpModule(m) {
    console.log(`'${m.path}'`);
    console.log(`   has default: ${m.hasDefaultExport()}`);
    if (m.exports.size > 0) {
        console.log('   slots:');
        m.exports.forEach ((v, k) => {
            console.log(`      ${k}: ${v.slot_num}`);
        });
    }
}

export function dumpModules () {
    console.log(underline('modules'));
    allModules.forEach ((m) => dumpModule(m));
}

function gatherImports (filename, path, top_path, tree, import_vars) {
    let visitor = new GatherImports(filename, path, top_path, import_vars);
    visitor.visit(tree);
    return visitor.importList;
}

function parseFile(filename, content, options) {
    try {
        if (!options.quiet) {
            // loop over import variables, replacing their values with
            // their names for output
            let output_name = filename;
            for (let ivar of options.import_variables) {
                output_name = output_name.replace(ivar.value, `$${ivar.variable}`);
            }
            options.stdout_writer.write(`PARSE ${output_name}`);
        }
        return esprima.parse(content, { loc: true, raw: true, tolerant: true });
    }
    catch (e) {
        console.warn(`${filename}: ${e}:`);
        process.exit(-1);
    }
}

function getModuleFile(module_info, platform) {
    if (typeof(module_info.module_file) == 'string')
        return module_info.module_file;
    if (!module_info.module_file[platform])
        throw new Error(`module ${module_info.module_name} doesn't have a module file for platform ${platform}`);
    return module_info.module_file[platform];
}

function getModuleLinkFlags(module_info, platform) {
    if (typeof(module_info.link_flags) == 'string')
        return module_info.link_flags;
    if (!module_info.link_flags[platform])
        throw new Error(`module ${module_info.module_name} doesn't have a link flags for platform ${platform}`);
    return module_info.link_flags[platform];
}

function registerNativeModuleInfo(ejs_dir, module_name, link_flags, module_files, module_info, platform) {
    if (module_info.link_flags) link_flags = link_flags.concat(getModuleLinkFlags(module_info, platform));
    if (module_info.module_file) module_files = module_files.concat(getModuleFile(module_info, platform));

    if (module_info.init_function) {
        // this module can be imported
        let m = new NativeModuleInfo(module_name, module_info.init_function, link_flags, module_files, ejs_dir);
        if (module_info.exports)
            module_info.exports.forEach( (v) => m.addExport(v));

        nativeModules.set(module_name, m);
    }
    if (module_info.submodules) {
        for (let sm of module_info.submodules) {
            if (!sm.module_name)
                throw new Error(`${module_name} submodule missing module_name property`);
            registerNativeModuleInfo(ejs_dir, `${module_name}/${sm.module_name}`, link_flags, module_files, sm);
        }
    }
}

function gatherNativeModuleInfo(ejs_file, platform) {
    let module_info = JSON.parse(fs.readFileSync(ejs_file, 'utf-8'));
    let module_name = module_info.module_name || path.basename(ejs_file, ".ejs");

    registerNativeModuleInfo(path.dirname(ejs_file), module_name, [], [], module_info, platform);
}

function gatherAllNativeModules(module_dirs, platform) {
    // gather a list of all native modules, flattening their submodule lists
    for (let mdir of module_dirs) {
        try {
            let files = fs.readdirSync(mdir);
            files.forEach( (f) => {
                if (path.extname(f) === '.ejs') {
                    try {
                        gatherNativeModuleInfo(path.resolve(mdir, f), platform);
                    }
                    catch (e) {
                        console.warn(`parsing of module file ${f} failed: ${e}`);
                    }
                }
            });
        }
        catch (e) {
        }
    }
}

export function gatherAllModules(file_args, options) {
    let work_list = file_args.slice();
    let files = [];

    gatherAllNativeModules(options.native_module_dirs, options.target_platform + '-' + options.target_arch);

    // starting at the main file, gather all files we'll need
    while (work_list.length !== 0) {
        let file = work_list.pop();

        let found = false;
        let jsfile = file;
        if (path.extname(jsfile) !== ".js")
            jsfile = jsfile + '.js';

        try {
            found = fs.statSync(jsfile).isFile();
        }
        catch (e) {
            found = false;
        }

        if (!found) {
            try {
                if (fs.statSync(file).isDirectory()) {
                    jsfile = path.join(file, "index.js");
                    found = fs.statSync(jsfile).isFile();
                }
            }
            catch (e) {
                found = false;
            }
        }
    
        if (found) {
            let file_contents = fs.readFileSync(jsfile, 'utf-8');
            let file_ast = parseFile(jsfile, file_contents, options);

            let imports = gatherImports(file, path.dirname(jsfile), process.cwd(), file_ast, options.import_variables);

            files.push({file_name: file, file_ast: file_ast});

            for (let i of imports) {
                if (work_list.indexOf(i) === -1 && !files.some((el) => el.file_name === i))
                    work_list.push(i);
            }
        }
        else {
            // check if the file is a native module
            if (!allModules.has(file)) {
                if (file[0] != '@') {
                    throw new Error(`module ${file} not found`);
                }
                let native_path = file.slice(1);
                if (!nativeModules.has(native_path)) {
                    throw new Error(`native module ${file} not found`);
                }

                allModules.set(file, nativeModules.get(native_path));
            }
        }
    }

    return files;
}
