#if defined(_WIN32)

#include "BunResources.h"
#include "rescle.h"
#include <cwchar>

extern "C" int32_t rescle__setIcon(const WCHAR* exeFilename, const WCHAR* iconFilename) noexcept
{
    rescle::ResourceUpdater updater;
    if (!updater.Load(exeFilename))
        return -1;
    if (!updater.SetIcon(iconFilename))
        return -2;
    if (!updater.Commit())
        return -3;
    return 0;
}

extern "C" int32_t rescle__setWindowsMetadata(
    const WCHAR* exeFilename,
    const WCHAR* iconFilename,
    const WCHAR* title,
    const WCHAR* publisher,
    const BunResourceVersion* version,
    const WCHAR* description,
    const WCHAR* copyright) noexcept
{
    rescle::ResourceUpdater updater;

    if (!updater.Load(exeFilename))
        return -1;

    if (iconFilename && *iconFilename) {
        if (!updater.SetIcon(iconFilename))
            return -2;
    }

    if (title && *title) {
        if (!updater.SetVersionString(RU_VS_PRODUCT_NAME, title))
            return -3;
    }

    if (publisher && *publisher) {
        if (!updater.SetVersionString(RU_VS_COMPANY_NAME, publisher))
            return -4;
    }

    if (description && *description) {
        if (!updater.SetVersionString(RU_VS_FILE_DESCRIPTION, description))
            return -5;
    }

    if (copyright && *copyright) {
        if (!updater.SetVersionString(RU_VS_LEGAL_COPYRIGHT, copyright))
            return -6;
    }

    if (version) {
        if (!updater.SetFileVersion(version->major, version->minor, version->patch, version->revision))
            return -7;
        if (!updater.SetProductVersion(version->major, version->minor, version->patch, version->revision))
            return -8;
        WCHAR normalizedVersion[32];
        swprintf_s(normalizedVersion, 32, L"%hu.%hu.%hu.%hu", version->major, version->minor, version->patch, version->revision);
        if (!updater.SetVersionString(RU_VS_FILE_VERSION, normalizedVersion))
            return -9;
        if (!updater.SetVersionString(RU_VS_PRODUCT_VERSION, normalizedVersion))
            return -10;
    }

    // Remove the "Original Filename" field by setting it to empty
    // This prevents the compiled executable from showing "bun.exe" as the original filename
    if (!updater.SetVersionString(RU_VS_ORIGINAL_FILENAME, L""))
        return -13;

    if (!updater.Commit())
        return -12;

    return 0;
}

#endif
