/*
 *  Copyright (C) 1999-2001 Harri Porten (porten@kde.org)
 *  Copyright (C) 2003-2020 Apple Inc. All rights reserved.
 *  Copyright (C) 2007 Samuel Weinig <sam@webkit.org>
 *  Copyright (C) 2009 Google, Inc. All rights reserved.
 *  Copyright (C) 2012 Ericsson AB. All rights reserved.
 *  Copyright (C) 2013 Michael Pruett <michael@68k.org>
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License for more details.
 *
 *  You should have received a copy of the GNU Lesser General Public
 *  License along with this library; if not, write to the Free Software
 *  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 */

#pragma once

#include "JSDOMExceptionHandling.h"

namespace WebCore {

// Rewrite all usages of JSC::createNotEnoughArgumentsError to use our own version.
// Our version adds the "code" property from Node.js.
JSC::JSObject* createNotEnoughArgumentsErrorBun(JSC::JSGlobalObject* globalObject);

#ifndef createNotEnoughArgumentsError
#define createNotEnoughArgumentsError WebCore::createNotEnoughArgumentsErrorBun
#endif

void throwNodeRangeError(JSC::JSGlobalObject* lexicalGlobalObject, JSC::ThrowScope& scope, ASCIILiteral message);
void throwNodeRangeError(JSC::JSGlobalObject* lexicalGlobalObject, JSC::ThrowScope& scope, const String& message);

} // namespace WebCore
