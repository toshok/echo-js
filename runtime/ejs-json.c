/* -*- Mode: C++; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*-
 * vim: set ts=4 sw=4 et tw=99 ft=cpp:
 */

#include <assert.h>

#include "ejs-ops.h"
#include "ejs-value.h"
#include "ejs-function.h"
#include "ejs-json.h"

ejsval _ejs_JSON;

/* 15.12.2 */
static ejsval
_ejs_JSON_parse (ejsval env, ejsval _this, int argc, ejsval *args)
{
    NOT_IMPLEMENTED();
}

/* 15.12.3 */
static ejsval
_ejs_JSON_stringify (ejsval env, ejsval _this, int argc, ejsval *args)
{
    NOT_IMPLEMENTED();
}

void
_ejs_JSON_init(ejsval global)
{
    START_SHADOW_STACK_FRAME;

    ADD_STACK_ROOT(ejsval, tmpobj, _ejs_object_new (_ejs_Object_proto));
    _ejs_JSON = tmpobj;

#define OBJ_METHOD(x) EJS_MACRO_START ADD_STACK_ROOT(ejsval, funcname, _ejs_string_new_utf8(#x)); ADD_STACK_ROOT(ejsval, tmpfunc, _ejs_function_new (_ejs_null, funcname, (EJSClosureFunc)_ejs_JSON_##x)); _ejs_object_setprop (_ejs_JSON, funcname, tmpfunc); EJS_MACRO_END

    OBJ_METHOD(parse);
    OBJ_METHOD(stringify);

#undef OBJ_METHOD

    _ejs_object_setprop_utf8 (global, "JSON", _ejs_JSON);

    END_SHADOW_STACK_FRAME;
}
