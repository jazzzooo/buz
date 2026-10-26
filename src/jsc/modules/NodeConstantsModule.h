#pragma once

#include "root.h"

#include <cerrno>
#include <csignal>
#include <fcntl.h>
#include <limits>
#include <openssl/ec.h>
#include <openssl/ssl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <uv.h>
#include <zlib.h>

#if !defined(_MSC_VER)
#include <unistd.h>
#endif

#if defined(_WIN32)
#include <io.h>
#ifndef S_IRUSR
#define S_IRUSR _S_IREAD
#endif
#ifndef S_IWUSR
#define S_IWUSR _S_IWRITE
#endif
#else
#include <dlfcn.h>
#endif
