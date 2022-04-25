/* -*- Mode: C++; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*-
 * vim: set ts=4 sw=4 et tw=99 ft=cpp:
 */

#include "ejs-llvm.h"
#include "ejs-object.h"
#include "ejs-value.h"
#include "ejs-array.h"
#include "ejs-function.h"
#include "ejs-string.h"
#include "functiontype.h"
#include "type.h"

namespace ejsllvm {

    typedef struct {
        /* object header */
        EJSObject obj;

        /* type specific data */
        llvm::FunctionType *type;
    } FunctionType;

    ejsval _ejs_FunctionType_prototype EJSVAL_ALIGNMENT;
    ejsval _ejs_FunctionType EJSVAL_ALIGNMENT;

    EJSObject* FunctionType_alloc_instance()
    {
        return (EJSObject*)_ejs_gc_new(FunctionType);
    }

    static ejsval
    FunctionType_impl (ejsval env, ejsval _this, int argc, ejsval *args)
    {
        EJS_NOT_IMPLEMENTED();
    }

    ejsval
    FunctionType_new(llvm::FunctionType* llvm_ty)
    {
        EJSObject* result = FunctionType_alloc_instance();
        _ejs_init_object (result, _ejs_FunctionType_prototype, NULL);
        ((FunctionType*)result)->type = llvm_ty;
        return OBJECT_TO_EJSVAL(result);
    }

    static EJS_NATIVE_FUNC(FunctionType_get) {
        REQ_LLVM_TYPE_ARG(0, returnType);
        REQ_ARRAY_ARG(1, argTypes);

        std::vector<llvm::Type*> arg_types;
        for (int i = 0; i < EJSARRAY_LEN(argTypes); i ++) {
            arg_types.push_back (Type_GetLLVMObj(EJSDENSEARRAY_ELEMENTS(argTypes)[i]));
        }

        llvm::FunctionType *FT = llvm::FunctionType::get(returnType,
                                                         arg_types, false);

        EJSObject* result = FunctionType_alloc_instance();
        _ejs_init_object (result, _ejs_FunctionType_prototype, NULL);
        ((FunctionType*)result)->type = FT;
        return OBJECT_TO_EJSVAL(result);
    }

    static EJS_NATIVE_FUNC(FunctionType_prototype_getReturnType) {
        return Type_new (((FunctionType*)EJSVAL_TO_OBJECT(*_this))->type->getReturnType());
    }

    static EJS_NATIVE_FUNC(FunctionType_prototype_getParamType) {
        REQ_INT_ARG(0, i);

        return Type_new (((FunctionType*)EJSVAL_TO_OBJECT(*_this))->type->getParamType(i));
    }

    static EJS_NATIVE_FUNC(FunctionType_prototype_toString) {
        std::string str;
        llvm::raw_string_ostream str_ostream(str);
        ((FunctionType*)EJSVAL_TO_OBJECT(*_this))->type->print(str_ostream);

        return _ejs_string_new_utf8(trim(str_ostream.str()).c_str());
    }

    static EJS_NATIVE_FUNC(FunctionType_prototype_dump) {
        // ((FunctionType*)EJSVAL_TO_OBJECT(*_this))->type->dump();
        return _ejs_undefined;
    }

    void
    FunctionType_init (ejsval exports)
    {
        _ejs_gc_add_root (&_ejs_FunctionType_prototype);
        _ejs_FunctionType_prototype = _ejs_object_create (Type_get_prototype());

        _ejs_FunctionType = _ejs_function_new_utf8_with_proto (_ejs_null, "LLVMFunctionType", (EJSClosureFunc)FunctionType_impl, _ejs_FunctionType_prototype);

        _ejs_object_setprop_utf8 (exports,              "FunctionType", _ejs_FunctionType);

#define OBJ_METHOD(x) EJS_INSTALL_ATOM_FUNCTION(_ejs_FunctionType, x, FunctionType_##x)
#define PROTO_METHOD(x) EJS_INSTALL_ATOM_FUNCTION(_ejs_FunctionType_prototype, x, FunctionType_prototype_##x)

        OBJ_METHOD(get);
        PROTO_METHOD(getReturnType);
        PROTO_METHOD(getParamType);
        PROTO_METHOD(dump);
        PROTO_METHOD(toString);

#undef OBJ_METHOD
#undef PROTO_METHOD
    }

};
