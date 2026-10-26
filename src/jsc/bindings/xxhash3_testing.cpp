#include "root.h"

#include "SchemaBindings.h"
#include "BunHighway.h"

namespace Bun::Bindgen::Cpp {

uint64_t bunBindgenCpp_bindgen_test_xxHash3ForTesting(
    CppCallContext&,
    const BunBindgenCpp_bindgen_test_xxHash3ForTesting_Arguments& args)
{
    return highway_xxhash3_64(args.view.unsafePtr("The entry frame holds the input lease through synchronous hashing"_s), args.view.size(), args.seed);
}

} // namespace Bun::Bindgen::Cpp
