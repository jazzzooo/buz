#include "root.h"
#include "SchemaBindings.h"

namespace Bun {

enum class DirEntType : int32_t {
    // These have to match up with uv_dirent_type_t
    Unknown = 0,
    File = 1,
    Directory = 2,
    SymLink = 3,
    NamedPipe = 4,
    UnixDomainSocket = 5,
    CharacterDevice = 6,
    BlockDevice = 7,
    Whiteout = 0,
    Door = 0,
    EventPort = 0
};

namespace Bindgen::Cpp {

template<typename Arguments>
static bool hasType(const Arguments& args, DirEntType expected)
{
    if (!args.bindingThis.is_object())
        return false;
    const auto& type = args.bindingThis.object().type;
    return type && *type == static_cast<int32_t>(expected);
}

bool bunBindgenCpp_NodeDirent_Dirent_method_isBlockDevice(CppCallContext&, const BunBindgenCpp_NodeDirent_Dirent_method_isBlockDevice_Arguments& args)
{
    return hasType(args, DirEntType::BlockDevice);
}

bool bunBindgenCpp_NodeDirent_Dirent_method_isCharacterDevice(CppCallContext&, const BunBindgenCpp_NodeDirent_Dirent_method_isCharacterDevice_Arguments& args)
{
    return hasType(args, DirEntType::CharacterDevice);
}

bool bunBindgenCpp_NodeDirent_Dirent_method_isDirectory(CppCallContext&, const BunBindgenCpp_NodeDirent_Dirent_method_isDirectory_Arguments& args)
{
    return hasType(args, DirEntType::Directory);
}

bool bunBindgenCpp_NodeDirent_Dirent_method_isFIFO(CppCallContext&, const BunBindgenCpp_NodeDirent_Dirent_method_isFIFO_Arguments& args)
{
    return hasType(args, DirEntType::NamedPipe);
}

bool bunBindgenCpp_NodeDirent_Dirent_method_isFile(CppCallContext&, const BunBindgenCpp_NodeDirent_Dirent_method_isFile_Arguments& args)
{
    return hasType(args, DirEntType::File);
}

bool bunBindgenCpp_NodeDirent_Dirent_method_isSocket(CppCallContext&, const BunBindgenCpp_NodeDirent_Dirent_method_isSocket_Arguments& args)
{
    return hasType(args, DirEntType::UnixDomainSocket);
}

bool bunBindgenCpp_NodeDirent_Dirent_method_isSymbolicLink(CppCallContext&, const BunBindgenCpp_NodeDirent_Dirent_method_isSymbolicLink_Arguments& args)
{
    return hasType(args, DirEntType::SymLink);
}

} // namespace Bindgen::Cpp

} // namespace Bun
