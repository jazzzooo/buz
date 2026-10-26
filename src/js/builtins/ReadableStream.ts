/*
 * Copyright (C) 2015 Canon Inc.
 * Copyright (C) 2015 Igalia.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

export function initializeReadableStream(
  this: ReadableStream,
  sourceKind: number,
  underlyingSource: UnderlyingSource,
  nativePtr: unknown,
  autoAllocateChunkSize: number | undefined,
  startMethod: Function | undefined,
  pullMethod: Function | undefined,
  cancelMethod: Function | undefined,
  highWaterMark: number | undefined,
  sizeAlgorithm: Function | undefined,
) {
  $putByIdDirectPrivate(this, "readableStreamBrand", true);
  $putByIdDirectPrivate(this, "state", $streamReadable);
  $putByIdDirectPrivate(this, "reader", undefined);
  $putByIdDirectPrivate(this, "storedError", undefined);
  this.$disturbed = false;
  $putByIdDirectPrivate(this, "readableStreamController", null);
  this.$bunNativePtr = nativePtr;
  $putByIdDirectPrivate(this, "bunNativeType", 0);
  $putByIdDirectPrivate(this, "nativeTransferred", false);
  $putByIdDirectPrivate(this, "transferredNativePtr", undefined);
  $putByIdDirectPrivate(this, "asyncContext", $getInternalField($asyncContext, 0));

  if (sourceKind === 2) {
    $putByIdDirectPrivate(this, "underlyingSource", underlyingSource);
    $putByIdDirectPrivate(this, "highWaterMark", highWaterMark);
    $putByIdDirectPrivate(this, "start", () =>
      $initializeArrayBufferStream.$call(this, underlyingSource, highWaterMark),
    );
  } else if (sourceKind === 3) {
    $putByIdDirectPrivate(this, "highWaterMark", undefined);
    $putByIdDirectPrivate(this, "underlyingSource", undefined);
    $putByIdDirectPrivate(this, "highWaterMark", autoAllocateChunkSize || highWaterMark);

    $putByIdDirectPrivate(this, "start", () => {
      const instance = $lazyLoadStream(this, autoAllocateChunkSize);
      if (instance) {
        $setupReadableStreamDefaultController(
          this,
          instance,
          sizeAlgorithm,
          highWaterMark === undefined ? 1 : highWaterMark,
          instance.start,
          instance.pull,
          instance.cancel,
        );
      }
    });
  } else if (sourceKind === 1) {
    if (sizeAlgorithm !== undefined)
      throw new RangeError("Strategy for a ReadableByteStreamController cannot have a size");
    const normalizedHighWaterMark = highWaterMark === undefined ? 0 : highWaterMark;
    $putByIdDirectPrivate(this, "underlyingSource", undefined);
    $putByIdDirectPrivate(this, "highWaterMark", normalizedHighWaterMark);
    $putByIdDirectPrivate(this, "start", undefined);
    new ReadableByteStreamController(this, normalizedHighWaterMark, underlyingSource);
  } else {
    const normalizedHighWaterMark = highWaterMark === undefined ? 1 : highWaterMark;
    $putByIdDirectPrivate(this, "underlyingSource", undefined);
    $putByIdDirectPrivate(this, "highWaterMark", normalizedHighWaterMark);
    $putByIdDirectPrivate(this, "start", undefined);
    $setupReadableStreamDefaultController(
      this,
      underlyingSource,
      sizeAlgorithm,
      normalizedHighWaterMark,
      startMethod,
      pullMethod,
      cancelMethod,
    );
  }

  return this;
}

$linkTimeConstant;
export function readableStreamToArray(stream: ReadableStream): Promise<unknown[]> {
  return $readableStreamToArrayInternal(stream, false);
}

export function cancel(this, reason) {
  if (!$isReadableStream(this)) return Promise.$reject($ERR_INVALID_THIS("ReadableStream"));

  if ($isReadableStreamLocked(this)) return Promise.$reject($ERR_INVALID_STATE_TypeError("ReadableStream is locked"));

  return $readableStreamCancel(this, reason);
}

export function getReader(this, byob: boolean) {
  if (!byob) {
    var start_ = $getByIdDirectPrivate(this, "start");
    if (start_) {
      $putByIdDirectPrivate(this, "start", undefined);
      start_();
    }

    return new ReadableStreamDefaultReader(this);
  }
  return new ReadableStreamBYOBReader(this);
}

export function pipeThrough(this, readable, internalWritable, preventClose, preventAbort, preventCancel, signal) {
  if ($isReadableStreamLocked(this)) throw $ERR_INVALID_STATE_TypeError("ReadableStream is locked");
  if ($isWritableStreamLocked(internalWritable)) throw $makeTypeError("WritableStream is locked");

  const promise = $readableStreamPipeToWritableStream(
    this,
    internalWritable,
    preventClose,
    preventAbort,
    preventCancel,
    signal,
  );
  $markPromiseAsHandled(promise);

  return readable;
}

export function pipeTo(this, internalDestination, preventClose, preventAbort, preventCancel, signal) {
  if ($isReadableStreamLocked(this)) return Promise.$reject($ERR_INVALID_STATE_TypeError("ReadableStream is locked"));
  if ($isWritableStreamLocked(internalDestination)) return Promise.$reject(new TypeError("WritableStream is locked"));

  return $readableStreamPipeToWritableStream(
    this,
    internalDestination,
    preventClose,
    preventAbort,
    preventCancel,
    signal,
  );
}

export function tee(this) {
  return $readableStreamTee(this, false);
}

$getter;
export function locked(this) {
  return $isReadableStreamLocked(this);
}

export function values(this, preventCancel) {
  const iterator = $bindgenFn("WebCoreStreams.schema.zig", "createReadableStreamIterator")(preventCancel);
  const reader = $acquireReadableStreamDefaultReader(this);
  $putByIdDirectPrivate(iterator, "readableStreamIteratorReader", reader);
  return iterator;
}
