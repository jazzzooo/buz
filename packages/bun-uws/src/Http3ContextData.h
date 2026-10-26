#ifndef UWS_H3CONTEXTDATA_H
#define UWS_H3CONTEXTDATA_H

#include "HttpCallback.h"

namespace uWS {

struct Http3Response;
struct Http3Request;

struct Http3ContextData {
    HttpCallback<void (*)(void *, void *, void *)> requestHandler;
};

}

#endif
