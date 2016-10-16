#include "node-llvm.h"
#include "allocainst.h"
#include "type.h"
#include "functiontype.h"
#include "structtype.h"
#include "arraytype.h"
#include "value.h"
#include "instruction.h"
#include "function.h"
#include "globalvariable.h"
#include "basicblock.h"
#include "phinode.h"
#include "irbuilder.h"
#include "dibuilder.h"
#include "module.h"
#include "constant.h"
#include "constantagg.h"
#include "constantarray.h"
#include "constantfp.h"
#include "landingpad.h"
#include "switch.h"
#include "callinvoke.h"
#include "loadinst.h"
#include "metadata.h"

std::string& trim(std::string& str)
{
  str.erase(0, str.find_first_not_of(" \n"));       //prefixing spaces
  str.erase(str.find_last_not_of(" \n")+1);         //surfixing spaces
  return str;
}

NAN_MODULE_INIT(Init) {
    jsllvm::Type::Init(target);
    jsllvm::FunctionType::Init(target);
    jsllvm::StructType::Init(target);
    jsllvm::ArrayType::Init(target);
    jsllvm::Value::Init(target);
    jsllvm::Instruction::Init(target);
    jsllvm::LoadInst::Init(target);
    jsllvm::AllocaInst::Init(target);
    jsllvm::Function::Init(target);
    jsllvm::GlobalVariable::Init(target);
    jsllvm::BasicBlock::Init(target);
    jsllvm::PHINode::Init(target);
    jsllvm::IRBuilder::Init(target);
    jsllvm::Module::Init(target);
    jsllvm::Constant::Init(target);
    jsllvm::ConstantAggregateZero::Init(target);
    jsllvm::ConstantArray::Init(target);
    jsllvm::ConstantFP::Init(target);
    jsllvm::LandingPad::Init(target);
    jsllvm::Switch::Init(target);
    jsllvm::Call::Init(target);
    jsllvm::Invoke::Init(target);

#if notyet
    jsllvm::MDNode::Init(target);
    jsllvm::MDString::Init(target);
#endif
    jsllvm::DIBuilder::Init(target);
    jsllvm::DIType::Init(target);
    jsllvm::DIScope::Init(target);
    jsllvm::DISubprogram::Init(target);
    jsllvm::DICompileUnit::Init(target);
    jsllvm::DIFile::Init(target);
    jsllvm::DILexicalBlock::Init(target);
    jsllvm::DebugLoc::Init(target);
}

NODE_MODULE(llvm, Init)
