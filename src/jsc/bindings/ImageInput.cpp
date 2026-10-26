#include "root.h"
#include "SchemaBindings.h"

JSC::JSValue Bun::Bindgen::Engine::bunBindgenEngine_Image_copyInput(
    EngineCallContext& context,
    const BunBindgenEngine_Image_copyInput_Arguments& args)
{
    return bun_bindgen_class_Image_Image_slot_input_get_value(context.classValue(args.image));
}
