#include "node-llvm.h"
#include "type.h"
#include "value.h"
#include "basicblock.h"
#include "instruction.h"
#include "allocainst.h"

using namespace node;
using namespace v8;

namespace jsllvm {


  
  Nan::Persistent<v8::FunctionTemplate> AllocaInst::constructor;
  Nan::Persistent<v8::Function> AllocaInst::constructor_func;

  void AllocaInst::Init(Handle<Object> target) {
    Nan::HandleScope scope;

    Local<v8::FunctionTemplate> ctor = Nan::New<v8::FunctionTemplate>(New);
    constructor.Reset(ctor);

    ctor->Inherit (Nan::New<v8::FunctionTemplate>(Instruction::constructor));

    ctor->InstanceTemplate()->SetInternalFieldCount(1);
    ctor->SetClassName(Nan::New("AllocaInst").ToLocalChecked());

    Nan::SetPrototypeMethod(ctor, "dump", AllocaInst::Dump);
    Nan::SetPrototypeMethod(ctor, "toString", AllocaInst::ToString);
    Nan::SetPrototypeMethod(ctor, "setAlignment", AllocaInst::SetAlignment);

    Local<v8::Function> ctor_func = ctor->GetFunction();
    constructor_func.Reset(ctor_func);
    target->Set(Nan::New("AllocaInst").ToLocalChecked(), ctor_func);
  }

  NAN_METHOD(AllocaInst::New) {
    if (info.This()->InternalFieldCount() == 0)
      return Nan::ThrowTypeError("Cannot Instantiate without new");

    auto ai = new AllocaInst();
    ai->Wrap(info.This());
    info.GetReturnValue().Set(info.This());
  }

  NAN_METHOD(AllocaInst::Dump) {
    auto ai = Unwrap(info.This());
    ai->llvm_obj->dump();
  }

  NAN_METHOD(AllocaInst::ToString) {
    auto ai = Unwrap(info.This());

    std::string str;
    llvm::raw_string_ostream str_ostream(str);
    ai->llvm_obj->print(str_ostream);

    info.GetReturnValue().Set(Nan::New(trim(str_ostream.str()).c_str()).ToLocalChecked());
  }

  NAN_METHOD(AllocaInst::SetAlignment) {
    auto ai = Unwrap(info.This());

    REQ_INT_ARG (0, alignment);

    ai->llvm_obj->setAlignment(alignment);
  }
}


