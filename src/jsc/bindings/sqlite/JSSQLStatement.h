/*
 * Copyright (C) 2023 Codeblog Corp
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1.  Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 * 2.  Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE AND ITS CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE OR ITS CONTRIBUTORS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include "root.h"
#ifndef LAZY_LOAD_SQLITE_DEFAULT_SETTING
#if defined(__APPLE__)
#define LAZY_LOAD_SQLITE_DEFAULT_SETTING 1
#endif
#endif

#ifndef LAZY_LOAD_SQLITE
#ifdef LAZY_LOAD_SQLITE_DEFAULT_SETTING
#define LAZY_LOAD_SQLITE LAZY_LOAD_SQLITE_DEFAULT_SETTING
#endif
#endif

#ifndef LAZY_LOAD_SQLITE
#define LAZY_LOAD_SQLITE 0
#endif

#include "sqlite3_local.h"

namespace WebCore {

class JSVMClientData;
class SQLiteDatabaseData;
class SQLiteStatementData;
class SQLiteControlHandleData;
void closeSQLiteDatabasesForVM(JSVMClientData&);

} // namespace WebCore
