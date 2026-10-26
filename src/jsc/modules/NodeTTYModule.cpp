#include "root.h"
#include "SchemaBindings.h"

using namespace JSC;

bool Bun::Bindgen::Cpp::bunBindgenCpp_ProcessTTY_isatty(
    Bun::Bindgen::CppCallContext&,
    const Bun::Bindgen::Cpp::BunBindgenCpp_ProcessTTY_isatty_Arguments& args)
{
    if (!args.fd)
        return false;

#if !OS(WINDOWS)
    return ::isatty(*args.fd);
#else
    bool isTTY = false;
    switch (uv_guess_handle(*args.fd)) {
    case UV_TTY:
        isTTY = true;
        break;
    default:
        break;
    }
    return isTTY;
#endif
}

