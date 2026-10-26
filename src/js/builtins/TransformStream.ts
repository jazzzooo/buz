// @ts-nocheck
/*
 * Copyright (C) 2020 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

export function initializeTransformStream(
  this,
  internal,
  transformer,
  startMethod,
  transformMethod,
  flushMethod,
  writableHighWaterMark,
  writableSizeAlgorithm,
  readableHighWaterMark,
  readableSizeAlgorithm,
) {
  if (internal) return this;

  if (writableSizeAlgorithm === undefined) writableSizeAlgorithm = () => 1;
  if (readableSizeAlgorithm === undefined) readableSizeAlgorithm = () => 1;

  const startPromiseCapability = $newPromiseCapability(Promise);
  $initializeTransformStream(
    this,
    startPromiseCapability.promise,
    writableHighWaterMark,
    writableSizeAlgorithm,
    readableHighWaterMark,
    readableSizeAlgorithm,
  );
  $setUpTransformStreamDefaultControllerFromTransformer(this, transformer, transformMethod, flushMethod);

  if (startMethod !== undefined) {
    const controller = $getByIdDirectPrivate(this, "controller");
    const startAlgorithm = () => $promiseInvokeOrNoopMethodNoCatch(transformer, startMethod, [controller]);
    startAlgorithm().$then(
      () => {
        // FIXME: We probably need to resolve start promise with the result of the start algorithm.
        startPromiseCapability.resolve.$call();
      },
      error => {
        startPromiseCapability.reject.$call(undefined, error);
      },
    );
  } else startPromiseCapability.resolve.$call();

  return this;
}

$getter;
export function readable() {
  if (!$isTransformStream(this)) throw $ERR_INVALID_THIS("TransformStream");

  return $getByIdDirectPrivate(this, "readable");
}

export function writable() {
  if (!$isTransformStream(this)) throw $ERR_INVALID_THIS("TransformStream");

  return $getByIdDirectPrivate(this, "writable");
}
