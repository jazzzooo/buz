#pragma once

#include "ncrypto.h"

namespace Bun::Bindgen {
struct NodeCryptoPrivateKeyExportOptions;
struct NodeCryptoPublicKeyExportOptions;
struct NodeCryptoAsymmetricKeyDetailsResult;
}

namespace JSC {
class JSGlobalObject;
class ThrowScope;
}

namespace Bun {

class KeyObject;

bool parseNodeCryptoPublicKeyExportOptions(
    JSC::JSGlobalObject&,
    const Bindgen::NodeCryptoPublicKeyExportOptions&,
    const KeyObject&,
    ncrypto::EVPKeyPointer::PublicKeyEncodingConfig&);
bool parseNodeCryptoPrivateKeyExportOptions(
    JSC::JSGlobalObject&,
    const Bindgen::NodeCryptoPrivateKeyExportOptions&,
    const KeyObject&,
    ncrypto::EVPKeyPointer::PrivateKeyEncodingConfig&);
Bindgen::NodeCryptoAsymmetricKeyDetailsResult nodeCryptoAsymmetricKeyDetails(
    JSC::JSGlobalObject&,
    JSC::ThrowScope&,
    KeyObject&);

}
