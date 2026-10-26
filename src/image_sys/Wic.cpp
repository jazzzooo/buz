#include "BunImage.h"

#if defined(_WIN32)

#include <windows.h>
#include <ocidl.h>

static HRESULT writeProperty(IPropertyBag2* properties, const uint16_t* name, VARIANT& value)
{
    if (!properties || !name) return E_POINTER;
    PROPBAG2 option {};
    option.pstrName = reinterpret_cast<LPOLESTR>(const_cast<uint16_t*>(name));
    const auto status = properties->Write(1, &option, &value);
    VariantClear(&value);
    return status;
}

extern "C" int32_t bun_wic_propbag_write_f32(IPropertyBag2* properties, const uint16_t* name, float value) noexcept
{
    VARIANT variant {};
    variant.vt = VT_R4;
    variant.fltVal = value;
    return writeProperty(properties, name, variant);
}

extern "C" int32_t bun_wic_propbag_write_u8(IPropertyBag2* properties, const uint16_t* name, uint8_t value) noexcept
{
    VARIANT variant {};
    variant.vt = VT_UI1;
    variant.bVal = value;
    return writeProperty(properties, name, variant);
}

extern "C" int32_t bun_wic_stream_size(IStream* stream, uint64_t* outSize) noexcept
{
    if (!stream || !outSize) return E_POINTER;
    STATSTG stat {};
    const auto status = stream->Stat(&stat, STATFLAG_NONAME);
    if (SUCCEEDED(status)) *outSize = stat.cbSize.QuadPart;
    return status;
}

#endif
