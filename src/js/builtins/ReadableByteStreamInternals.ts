/// <reference path="../builtins.d.ts" />
/**
 * ## References
 * - [ReadableStream - `ReadableByteStreamController`](https://streams.spec.whatwg.org/#rbs-controller-class)
 */
/*
 * Copyright (C) 2016 Canon Inc. All rights reserved.
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
// @internal

export function privateInitializeReadableByteStreamController(
  this,
  stream,
  underlyingByteSource,
  highWaterMark,
  autoAllocateChunkSize,
  startMethod,
  pullMethod,
  cancelMethod,
) {
  // readableStreamController is initialized with null value.
  if ($getByIdDirectPrivate(stream, "readableStreamController") !== null)
    throw new TypeError("ReadableStream already has a controller");

  $putByIdDirectPrivate(this, "controlledReadableStream", stream);
  $putByIdDirectPrivate(this, "byteControllerBrand", true);
  $putByIdDirectPrivate(this, "pullAgain", false);
  $putByIdDirectPrivate(this, "pulling", false);
  $readableByteStreamControllerClearPendingPullIntos(this);
  $putByIdDirectPrivate(this, "queue", $newQueue());
  $putByIdDirectPrivate(this, "started", 0);
  $putByIdDirectPrivate(this, "closeRequested", false);

  if (highWaterMark !== highWaterMark || highWaterMark < 0)
    throw new RangeError("highWaterMark value is negative or not a number");
  $putByIdDirectPrivate(this, "strategyHWM", highWaterMark);

  if (autoAllocateChunkSize === 0) throw new TypeError("autoAllocateChunkSize must be greater than zero");
  $putByIdDirectPrivate(this, "autoAllocateChunkSize", autoAllocateChunkSize);
  $putByIdDirectPrivate(this, "pendingPullIntos", $createFIFO());

  $putByIdDirectPrivate(this, "pullAlgorithm", () =>
    $promiseInvokeOrNoopMethod(underlyingByteSource, pullMethod, [this]),
  );
  $putByIdDirectPrivate(this, "cancelAlgorithm", reason =>
    $promiseInvokeOrNoopMethod(underlyingByteSource, cancelMethod, [reason]),
  );
  $putByIdDirectPrivate(this, "cancel", $readableByteStreamControllerCancel);
  $putByIdDirectPrivate(this, "pull", $readableByteStreamControllerPull);
  $putByIdDirectPrivate(stream, "readableStreamController", this);

  const controller = this;
  $promiseInvokeOrNoopMethodNoCatch(underlyingByteSource, startMethod, [controller]).$then(
    () => {
      $putByIdDirectPrivate(controller, "started", 1);
      $assert(!$getByIdDirectPrivate(controller, "pulling"));
      $assert(!$getByIdDirectPrivate(controller, "pullAgain"));
      $readableByteStreamControllerCallPullIfNeeded(controller);
    },
    error => {
      if ($getByIdDirectPrivate(stream, "state") === $streamReadable)
        $readableByteStreamControllerError(controller, error);
    },
  );

  return this;
}

export function isReadableByteStreamController(controller) {
  return $bindgenFn("NativeTypePredicates.schema.zig", "isReadableByteStreamController")(controller);
}

export function isReadableStreamBYOBRequest(byobRequest) {
  return $bindgenFn("NativeTypePredicates.schema.zig", "isReadableStreamBYOBRequest")(byobRequest);
}

export function isReadableStreamBYOBReader(reader) {
  return $bindgenFn("NativeTypePredicates.schema.zig", "isReadableStreamBYOBReader")(reader);
}

export function readableByteStreamControllerCancel(controller, reason) {
  var pendingPullIntos = $getByIdDirectPrivate(controller, "pendingPullIntos");
  var first: PullIntoDescriptor | undefined = pendingPullIntos.peek();
  if (first) first.bytesFilled = 0;

  $putByIdDirectPrivate(controller, "queue", $newQueue());
  const result = $getByIdDirectPrivate(controller, "cancelAlgorithm")(reason);
  $readableByteStreamControllerClearAlgorithms(controller);
  return result;
}

export function readableByteStreamControllerClearAlgorithms(controller) {
  $putByIdDirectPrivate(controller, "pullAlgorithm", undefined);
  $putByIdDirectPrivate(controller, "cancelAlgorithm", undefined);
}

export function readableByteStreamControllerRelease(controller) {
  const pending = $getByIdDirectPrivate(controller, "pendingPullIntos");
  const first = pending.peek();
  if (first === undefined) return;
  const remaining = $createFIFO();
  remaining.push(first);
  first.readerType = "none";
  $putByIdDirectPrivate(controller, "pendingPullIntos", remaining);
}

export function readableByteStreamControllerError(controller, e) {
  $assert(
    $getByIdDirectPrivate($getByIdDirectPrivate(controller, "controlledReadableStream"), "state") === $streamReadable,
  );
  $readableByteStreamControllerClearPendingPullIntos(controller);
  $putByIdDirectPrivate(controller, "queue", $newQueue());
  $readableByteStreamControllerClearAlgorithms(controller);
  $readableStreamError($getByIdDirectPrivate(controller, "controlledReadableStream"), e);
}

export function readableByteStreamControllerClose(controller) {
  $assert(!$getByIdDirectPrivate(controller, "closeRequested"));
  $assert(
    $getByIdDirectPrivate($getByIdDirectPrivate(controller, "controlledReadableStream"), "state") === $streamReadable,
  );

  if ($getByIdDirectPrivate(controller, "queue").size > 0) {
    $putByIdDirectPrivate(controller, "closeRequested", true);
    return;
  }

  var first: PullIntoDescriptor | undefined = $getByIdDirectPrivate(controller, "pendingPullIntos")?.peek();
  if (first) {
    if (first.bytesFilled % first.elementSize !== 0) {
      const e = $makeTypeError("Close requested while there remain pending bytes");
      $readableByteStreamControllerError(controller, e);
      throw e;
    }
  }

  $readableStreamCloseIfPossible($getByIdDirectPrivate(controller, "controlledReadableStream"));
}

export function readableByteStreamControllerClearPendingPullIntos(controller) {
  $readableByteStreamControllerInvalidateBYOBRequest(controller);
  var existing: Dequeue<PullIntoDescriptor> = $getByIdDirectPrivate(controller, "pendingPullIntos");
  if (existing !== undefined) {
    existing.clear();
  } else {
    $putByIdDirectPrivate(controller, "pendingPullIntos", $createFIFO());
  }
}

export function readableByteStreamControllerGetDesiredSize(controller) {
  const stream = $getByIdDirectPrivate(controller, "controlledReadableStream");
  const state = $getByIdDirectPrivate(stream, "state");

  if (state === $streamErrored) return null;
  if (state === $streamClosed) return 0;

  return $getByIdDirectPrivate(controller, "strategyHWM") - $getByIdDirectPrivate(controller, "queue").size;
}

export function readableStreamHasBYOBReader(stream) {
  const reader = $getByIdDirectPrivate(stream, "reader");
  return reader !== undefined && $isReadableStreamBYOBReader(reader);
}

export function readableStreamHasDefaultReader(stream) {
  const reader = $getByIdDirectPrivate(stream, "reader");
  return reader !== undefined && $isReadableStreamDefaultReader(reader);
}

export function readableByteStreamControllerHandleQueueDrain(controller) {
  $assert(
    $getByIdDirectPrivate($getByIdDirectPrivate(controller, "controlledReadableStream"), "state") === $streamReadable,
  );
  if (!$getByIdDirectPrivate(controller, "queue").size && $getByIdDirectPrivate(controller, "closeRequested")) {
    $readableStreamCloseIfPossible($getByIdDirectPrivate(controller, "controlledReadableStream"));
  } else $readableByteStreamControllerCallPullIfNeeded(controller);
}

export function readableByteStreamControllerPull(controller) {
  const stream = $getByIdDirectPrivate(controller, "controlledReadableStream");
  $assert($readableStreamHasDefaultReader(stream));
  if ($getByIdDirectPrivate(controller, "queue").content?.isNotEmpty()) {
    const entry = $getByIdDirectPrivate(controller, "queue").content.shift();
    $getByIdDirectPrivate(controller, "queue").size -= entry.byteLength;
    $readableByteStreamControllerHandleQueueDrain(controller);
    let view;
    try {
      view = new Uint8Array(entry.buffer, entry.byteOffset, entry.byteLength);
    } catch (error) {
      return Promise.$reject(error);
    }
    return $createFulfilledPromise({ value: view, done: false });
  }

  if ($getByIdDirectPrivate(controller, "autoAllocateChunkSize") !== undefined) {
    let buffer;
    try {
      buffer = $createUninitializedArrayBuffer($getByIdDirectPrivate(controller, "autoAllocateChunkSize"));
    } catch (error) {
      return Promise.$reject(error);
    }
    const pullIntoDescriptor: PullIntoDescriptor = {
      buffer,
      bufferByteLength: $getByIdDirectPrivate(controller, "autoAllocateChunkSize"),
      byteOffset: 0,
      byteLength: $getByIdDirectPrivate(controller, "autoAllocateChunkSize"),
      bytesFilled: 0,
      minimumFill: 1,
      elementSize: 1,
      ctor: Uint8Array,
      readerType: "default",
    };
    $getByIdDirectPrivate(controller, "pendingPullIntos").push(pullIntoDescriptor);
  }

  const promise = $readableStreamAddReadRequest(stream);
  $readableByteStreamControllerCallPullIfNeeded(controller);
  return promise;
}

export function readableByteStreamControllerShouldCallPull(controller) {
  $assert(controller);
  const stream = $getByIdDirectPrivate(controller, "controlledReadableStream");
  if (!stream) {
    return false;
  }

  if ($getByIdDirectPrivate(stream, "state") !== $streamReadable) return false;
  if ($getByIdDirectPrivate(controller, "closeRequested")) return false;
  if (!($getByIdDirectPrivate(controller, "started") > 0)) return false;
  const reader = $getByIdDirectPrivate(stream, "reader");

  if (reader && ($getByIdDirectPrivate(reader, "readRequests")?.isNotEmpty() || !!reader.$bunNativePtr)) return true;
  if (
    $readableStreamHasBYOBReader(stream) &&
    $getByIdDirectPrivate($getByIdDirectPrivate(stream, "reader"), "readIntoRequests")?.isNotEmpty()
  )
    return true;
  if ($readableByteStreamControllerGetDesiredSize(controller) > 0) return true;
  return false;
}

export function readableByteStreamControllerCallPullIfNeeded(controller) {
  $assert(controller);
  if (!$readableByteStreamControllerShouldCallPull(controller)) return;

  if ($getByIdDirectPrivate(controller, "pulling")) {
    $putByIdDirectPrivate(controller, "pullAgain", true);
    return;
  }

  $assert(!$getByIdDirectPrivate(controller, "pullAgain"));
  $putByIdDirectPrivate(controller, "pulling", true);
  $getByIdDirectPrivate(controller, "pullAlgorithm")().$then(
    () => {
      $putByIdDirectPrivate(controller, "pulling", false);
      if ($getByIdDirectPrivate(controller, "pullAgain")) {
        $putByIdDirectPrivate(controller, "pullAgain", false);
        $readableByteStreamControllerCallPullIfNeeded(controller);
      }
    },
    error => {
      if (
        $getByIdDirectPrivate($getByIdDirectPrivate(controller, "controlledReadableStream"), "state") ===
        $streamReadable
      )
        $readableByteStreamControllerError(controller, error);
    },
  );
}

export function transferBufferToCurrentRealm(buffer) {
  return $bindgenFn("WebCoreStreams.schema.zig", "transferByteStreamBuffer")(buffer);
}

export function readableByteStreamControllerEnqueue(controller, chunk) {
  const stream = $getByIdDirectPrivate(controller, "controlledReadableStream");
  $assert(!$getByIdDirectPrivate(controller, "closeRequested"));
  $assert($getByIdDirectPrivate(stream, "state") === $streamReadable);

  const transferredBuffer = $transferBufferToCurrentRealm(chunk.buffer);
  const pendingPullIntos = $getByIdDirectPrivate(controller, "pendingPullIntos");
  if (pendingPullIntos.isNotEmpty()) {
    const first = pendingPullIntos.peek();
    const buffer = $transferBufferToCurrentRealm(first.buffer);
    $readableByteStreamControllerInvalidateBYOBRequest(controller);
    first.buffer = buffer;
    if (first.readerType === "none") {
      $readableByteStreamControllerEnqueueDetachedPullInto(controller, first);
    }
  }

  if ($readableStreamHasDefaultReader(stream)) {
    const requests = $getByIdDirectPrivate($getByIdDirectPrivate(stream, "reader"), "readRequests");
    const queue = $getByIdDirectPrivate(controller, "queue");
    while (requests.isNotEmpty() && queue.content.isNotEmpty()) {
      const request = requests.shift();
      const entry = queue.content.shift();
      queue.size -= entry.byteLength;
      $readableByteStreamControllerHandleQueueDrain(controller);
      $fulfillPromise(request, { value: new Uint8Array(entry.buffer, entry.byteOffset, entry.byteLength), done: false });
    }
    if (requests.isEmpty()) {
      $readableByteStreamControllerEnqueueChunk(controller, transferredBuffer, chunk.byteOffset, chunk.byteLength);
    } else {
      if (pendingPullIntos.isNotEmpty()) $readableByteStreamControllerShiftPendingDescriptor(controller);
      const transferredView = new Uint8Array(transferredBuffer, chunk.byteOffset, chunk.byteLength);
      $readableStreamFulfillReadRequest(stream, transferredView, false);
    }
  } else {
    $readableByteStreamControllerEnqueueChunk(controller, transferredBuffer, chunk.byteOffset, chunk.byteLength);
    if ($readableStreamHasBYOBReader(stream)) $readableByteStreamControllerProcessPullDescriptors(controller);
  }
  $readableByteStreamControllerCallPullIfNeeded(controller);
}

// Spec name: readableByteStreamControllerEnqueueChunkToQueue.
export function readableByteStreamControllerEnqueueChunk(controller, buffer, byteOffset, byteLength) {
  $getByIdDirectPrivate(controller, "queue").content.push({
    buffer: buffer,
    byteOffset: byteOffset,
    byteLength: byteLength,
  });
  $getByIdDirectPrivate(controller, "queue").size += byteLength;
}

export function readableByteStreamControllerEnqueueClonedChunk(controller, buffer, byteOffset, byteLength) {
  let copy;
  try {
    copy = $cloneArrayBuffer(buffer, byteOffset, byteLength);
  } catch (error) {
    $readableByteStreamControllerError(controller, error);
    throw error;
  }
  $readableByteStreamControllerEnqueueChunk(controller, copy, 0, byteLength);
}

export function readableByteStreamControllerEnqueueDetachedPullInto(controller, descriptor) {
  $assert(descriptor.readerType === "none");
  if (descriptor.bytesFilled > 0)
    $readableByteStreamControllerEnqueueClonedChunk(controller, descriptor.buffer, descriptor.byteOffset, descriptor.bytesFilled);
  $readableByteStreamControllerShiftPendingDescriptor(controller);
}

export function readableByteStreamControllerRespondWithNewView(controller, view) {
  $assert($getByIdDirectPrivate(controller, "pendingPullIntos").isNotEmpty());

  const info = $bindgenFn("WebCoreStreams.schema.zig", "byteStreamViewInfo")(view);
  const firstDescriptor = $getByIdDirectPrivate(controller, "pendingPullIntos").peek();
  const state = $getByIdDirectPrivate($getByIdDirectPrivate(controller, "controlledReadableStream"), "state");
  if (state === $streamClosed) {
    if (info.byteLength !== 0) throw new TypeError("The view must be empty for a closed stream");
  } else {
    $assert(state === $streamReadable);
    if (info.byteLength === 0) throw new TypeError("The view must not be empty for a readable stream");
  }
  if (firstDescriptor.byteOffset + firstDescriptor.bytesFilled !== info.byteOffset)
    throw new RangeError("Invalid value for view.byteOffset");
  if (firstDescriptor.bufferByteLength !== info.bufferByteLength)
    throw new RangeError("The replacement buffer has a different byte length");
  if (firstDescriptor.bytesFilled + info.byteLength > firstDescriptor.byteLength)
    throw new RangeError("The view exceeds the remaining byte length");

  firstDescriptor.buffer = $transferBufferToCurrentRealm(info.buffer);
  $readableByteStreamControllerRespondInternal(controller, info.byteLength);
}

export function readableByteStreamControllerRespond(controller, bytesWritten) {
  $assert($getByIdDirectPrivate(controller, "pendingPullIntos").isNotEmpty());

  const stream = $getByIdDirectPrivate(controller, "controlledReadableStream");
  const state = $getByIdDirectPrivate(stream, "state");
  if (state === $streamClosed) {
    if (bytesWritten !== 0) throw new TypeError("bytesWritten must be zero for a closed stream");
  } else {
    $assert(state === $streamReadable);
    if (bytesWritten === 0) throw new TypeError("bytesWritten must be greater than zero for a readable stream");
  }

  const firstDescriptor = $getByIdDirectPrivate(controller, "pendingPullIntos").peek();
  if (firstDescriptor.bytesFilled + bytesWritten > firstDescriptor.byteLength)
    throw new RangeError("bytesWritten value is too great");
  firstDescriptor.buffer = $transferBufferToCurrentRealm(firstDescriptor.buffer);
  $readableByteStreamControllerRespondInternal(controller, bytesWritten);
}

export function readableByteStreamControllerRespondInternal(controller, bytesWritten) {
  let firstDescriptor: PullIntoDescriptor | undefined = $getByIdDirectPrivate(controller, "pendingPullIntos").peek();
  let stream = $getByIdDirectPrivate(controller, "controlledReadableStream");
  $readableByteStreamControllerInvalidateBYOBRequest(controller);

  if ($getByIdDirectPrivate(stream, "state") === $streamClosed) {
    $readableByteStreamControllerRespondInClosedState(controller, firstDescriptor);
  } else {
    $assert($getByIdDirectPrivate(stream, "state") === $streamReadable);
    $readableByteStreamControllerRespondInReadableState(controller, bytesWritten, firstDescriptor);
  }
  $readableByteStreamControllerCallPullIfNeeded(controller);
}

export function readableByteStreamControllerRespondInReadableState(controller, bytesWritten, pullIntoDescriptor) {
  $assert(
    $getByIdDirectPrivate(controller, "pendingPullIntos").isEmpty() ||
      $getByIdDirectPrivate(controller, "pendingPullIntos").peek() === pullIntoDescriptor,
  );
  pullIntoDescriptor.bytesFilled += bytesWritten;

  if (pullIntoDescriptor.readerType === "none") {
    $readableByteStreamControllerEnqueueDetachedPullInto(controller, pullIntoDescriptor);
    $readableByteStreamControllerProcessPullDescriptors(controller);
    return;
  }

  if (pullIntoDescriptor.bytesFilled < pullIntoDescriptor.minimumFill) return;

  $readableByteStreamControllerShiftPendingDescriptor(controller);
  const remainderSize = pullIntoDescriptor.bytesFilled % pullIntoDescriptor.elementSize;

  if (remainderSize > 0) {
    const end = pullIntoDescriptor.byteOffset + pullIntoDescriptor.bytesFilled;
    $readableByteStreamControllerEnqueueClonedChunk(controller, pullIntoDescriptor.buffer, end - remainderSize, remainderSize);
  }

  pullIntoDescriptor.bytesFilled -= remainderSize;
  $readableByteStreamControllerCommitDescriptor(
    $getByIdDirectPrivate(controller, "controlledReadableStream"),
    pullIntoDescriptor,
  );
  $readableByteStreamControllerProcessPullDescriptors(controller);
}

export function readableByteStreamControllerRespondInClosedState(controller, firstDescriptor) {
  $assert(firstDescriptor.bytesFilled % firstDescriptor.elementSize === 0);
  if (firstDescriptor.readerType === "none") $readableByteStreamControllerShiftPendingDescriptor(controller);

  if ($readableStreamHasBYOBReader($getByIdDirectPrivate(controller, "controlledReadableStream"))) {
    while (
      $getByIdDirectPrivate(
        $getByIdDirectPrivate($getByIdDirectPrivate(controller, "controlledReadableStream"), "reader"),
        "readIntoRequests",
      )?.isNotEmpty()
    ) {
      let pullIntoDescriptor = $readableByteStreamControllerShiftPendingDescriptor(controller);
      $readableByteStreamControllerCommitDescriptor(
        $getByIdDirectPrivate(controller, "controlledReadableStream"),
        pullIntoDescriptor,
      );
    }
  }
}

// Spec name: readableByteStreamControllerProcessPullIntoDescriptorsUsingQueue (shortened for readability).
export function readableByteStreamControllerProcessPullDescriptors(controller) {
  $assert(!$getByIdDirectPrivate(controller, "closeRequested"));
  while ($getByIdDirectPrivate(controller, "pendingPullIntos").isNotEmpty()) {
    if ($getByIdDirectPrivate(controller, "queue").size === 0) return;
    let pullIntoDescriptor: PullIntoDescriptor = $getByIdDirectPrivate(controller, "pendingPullIntos").peek();
    if ($readableByteStreamControllerFillDescriptorFromQueue(controller, pullIntoDescriptor)) {
      $readableByteStreamControllerShiftPendingDescriptor(controller);
      $readableByteStreamControllerCommitDescriptor(
        $getByIdDirectPrivate(controller, "controlledReadableStream"),
        pullIntoDescriptor,
      );
    }
  }
}

// Spec name: readableByteStreamControllerFillPullIntoDescriptorFromQueue (shortened for readability).
export function readableByteStreamControllerFillDescriptorFromQueue(
  controller,
  pullIntoDescriptor: PullIntoDescriptor,
) {
  const maxBytesToCopy =
    $getByIdDirectPrivate(controller, "queue").size < pullIntoDescriptor.byteLength - pullIntoDescriptor.bytesFilled
      ? $getByIdDirectPrivate(controller, "queue").size
      : pullIntoDescriptor.byteLength - pullIntoDescriptor.bytesFilled;
  const maxBytesFilled = pullIntoDescriptor.bytesFilled + maxBytesToCopy;
  const maxAlignedBytes = maxBytesFilled - (maxBytesFilled % pullIntoDescriptor.elementSize);
  let totalBytesToCopyRemaining = maxBytesToCopy;
  let ready = false;

  if (maxAlignedBytes >= pullIntoDescriptor.minimumFill) {
    totalBytesToCopyRemaining = maxAlignedBytes - pullIntoDescriptor.bytesFilled;
    ready = true;
  }

  while (totalBytesToCopyRemaining > 0) {
    let headOfQueue = $getByIdDirectPrivate(controller, "queue").content.peek();
    const bytesToCopy =
      totalBytesToCopyRemaining < headOfQueue.byteLength ? totalBytesToCopyRemaining : headOfQueue.byteLength;
    const destStart = pullIntoDescriptor.byteOffset + pullIntoDescriptor.bytesFilled;
    $bindgenFn("WebCoreStreams.schema.zig", "copyByteStreamBytes")(
      pullIntoDescriptor.buffer,
      destStart,
      headOfQueue.buffer,
      headOfQueue.byteOffset,
      bytesToCopy,
    );

    if (headOfQueue.byteLength === bytesToCopy) $getByIdDirectPrivate(controller, "queue").content.shift();
    else {
      headOfQueue.byteOffset += bytesToCopy;
      headOfQueue.byteLength -= bytesToCopy;
    }

    $getByIdDirectPrivate(controller, "queue").size -= bytesToCopy;
    $assert(
      $getByIdDirectPrivate(controller, "pendingPullIntos").isEmpty() ||
        $getByIdDirectPrivate(controller, "pendingPullIntos").peek() === pullIntoDescriptor,
    );
    $readableByteStreamControllerInvalidateBYOBRequest(controller);
    pullIntoDescriptor.bytesFilled += bytesToCopy;
    totalBytesToCopyRemaining -= bytesToCopy;
  }

  if (!ready) {
    $assert($getByIdDirectPrivate(controller, "queue").size === 0);
    $assert(pullIntoDescriptor.bytesFilled > 0);
    $assert(pullIntoDescriptor.bytesFilled < pullIntoDescriptor.minimumFill);
  }

  return ready;
}

// Spec name: readableByteStreamControllerShiftPendingPullInto (renamed for consistency).
export function readableByteStreamControllerShiftPendingDescriptor(controller): PullIntoDescriptor | undefined {
  let descriptor: PullIntoDescriptor | undefined = $getByIdDirectPrivate(controller, "pendingPullIntos").shift();
  $readableByteStreamControllerInvalidateBYOBRequest(controller);
  return descriptor;
}

export function readableByteStreamControllerInvalidateBYOBRequest(controller) {
  if ($getByIdDirectPrivate(controller, "byobRequest") === undefined) return;
  const byobRequest = $getByIdDirectPrivate(controller, "byobRequest");
  $putByIdDirectPrivate(byobRequest, "associatedReadableByteStreamController", null);
  $putByIdDirectPrivate(byobRequest, "view", null);
  $putByIdDirectPrivate(controller, "byobRequest", undefined);
}

// Spec name: readableByteStreamControllerCommitPullIntoDescriptor (shortened for readability).
export function readableByteStreamControllerCommitDescriptor(stream, pullIntoDescriptor) {
  $assert($getByIdDirectPrivate(stream, "state") !== $streamErrored);
  let done = false;
  if ($getByIdDirectPrivate(stream, "state") === $streamClosed) {
    $assert(pullIntoDescriptor.bytesFilled % pullIntoDescriptor.elementSize === 0);
    done = true;
  }
  let filledView = $readableByteStreamControllerConvertDescriptor(pullIntoDescriptor);
  if (pullIntoDescriptor.readerType === "default") $readableStreamFulfillReadRequest(stream, filledView, done);
  else {
    $assert(pullIntoDescriptor.readerType === "byob");
    $readableStreamFulfillReadIntoRequest(stream, filledView, done);
  }
}

// Spec name: readableByteStreamControllerConvertPullIntoDescriptor (shortened for readability).
export function readableByteStreamControllerConvertDescriptor(pullIntoDescriptor) {
  $assert(pullIntoDescriptor.bytesFilled <= pullIntoDescriptor.byteLength);
  $assert(pullIntoDescriptor.bytesFilled % pullIntoDescriptor.elementSize === 0);

  return new pullIntoDescriptor.ctor(
    $transferBufferToCurrentRealm(pullIntoDescriptor.buffer),
    pullIntoDescriptor.byteOffset,
    pullIntoDescriptor.bytesFilled / pullIntoDescriptor.elementSize,
  );
}

export function readableStreamFulfillReadIntoRequest(stream, chunk, done) {
  const readIntoRequest = $getByIdDirectPrivate($getByIdDirectPrivate(stream, "reader"), "readIntoRequests").shift();
  $fulfillPromise(readIntoRequest, { value: chunk, done: done });
}

export function readableStreamBYOBReaderRead(reader, info, minimum) {
  const stream = $getByIdDirectPrivate(reader, "ownerReadableStream");
  $assert(!!stream);

  $putByIdDirectPrivate(stream, "disturbed", true);
  if ($getByIdDirectPrivate(stream, "state") === $streamErrored)
    return Promise.$reject($getByIdDirectPrivate(stream, "storedError"));

  return $readableByteStreamControllerPullInto($getByIdDirectPrivate(stream, "readableStreamController"), info, minimum);
}

export function readableByteStreamControllerPullInto(controller, info, minimum) {
  const stream = $getByIdDirectPrivate(controller, "controlledReadableStream");
  let buffer;
  try {
    buffer = $transferBufferToCurrentRealm(info.buffer);
  } catch (error) {
    return Promise.$reject(error);
  }
  const ctor = info.ctor;

  const pullIntoDescriptor: PullIntoDescriptor = {
    buffer,
    bufferByteLength: info.bufferByteLength,
    byteOffset: info.byteOffset,
    byteLength: info.byteLength,
    bytesFilled: 0,
    minimumFill: minimum * info.elementSize,
    elementSize: info.elementSize,
    ctor,
    readerType: "byob",
  };

  var pending = $getByIdDirectPrivate(controller, "pendingPullIntos");
  if (pending?.isNotEmpty()) {
    pending.push(pullIntoDescriptor);
    return $readableStreamAddReadIntoRequest(stream);
  }

  if ($getByIdDirectPrivate(stream, "state") === $streamClosed) {
    const emptyView = new ctor(pullIntoDescriptor.buffer, pullIntoDescriptor.byteOffset, 0);
    return $createFulfilledPromise({ value: emptyView, done: true });
  }

  if ($getByIdDirectPrivate(controller, "queue").size > 0) {
    if ($readableByteStreamControllerFillDescriptorFromQueue(controller, pullIntoDescriptor)) {
      const filledView = $readableByteStreamControllerConvertDescriptor(pullIntoDescriptor);
      $readableByteStreamControllerHandleQueueDrain(controller);
      return $createFulfilledPromise({ value: filledView, done: false });
    }
    if ($getByIdDirectPrivate(controller, "closeRequested")) {
      const e = $makeTypeError("Closing stream has been requested");
      $readableByteStreamControllerError(controller, e);
      return Promise.$reject(e);
    }
  }

  $getByIdDirectPrivate(controller, "pendingPullIntos").push(pullIntoDescriptor);
  const promise = $readableStreamAddReadIntoRequest(stream);
  $readableByteStreamControllerCallPullIfNeeded(controller);
  return promise;
}

export function readableStreamAddReadIntoRequest(stream) {
  $assert($isReadableStreamBYOBReader($getByIdDirectPrivate(stream, "reader")));
  $assert(
    $getByIdDirectPrivate(stream, "state") === $streamReadable ||
      $getByIdDirectPrivate(stream, "state") === $streamClosed,
  );

  const readRequest = $newPromise();
  $getByIdDirectPrivate($getByIdDirectPrivate(stream, "reader"), "readIntoRequests").push(readRequest);

  return readRequest;
}

/**
 * ## References
 * - [Spec](https://streams.spec.whatwg.org/#pull-into-descriptor)
 */
interface PullIntoDescriptor {
  /**
   * An {@link ArrayBuffer}
   */
  buffer: ArrayBuffer;
  bufferByteLength: number;

  /**
   * A nonnegative integer byte offset into the {@link buffer} where the
   * underlying byte source will start writing
   */
  byteOffset: number;
  /**
   * A positive integer number of bytes which can be written into the
   * {@link buffer}
   */
  byteLength: number;
  /**
   * A nonnegative integer number of bytes that have been written into the
   * {@link buffer} so far
   */
  bytesFilled: number;
  minimumFill: number;

  /**
   * A positive integer representing the number of bytes that can be written
   * into the {@link buffer} at a time, using views of the type described by the
   * view constructor
   */
  elementSize: number;
  /**
   * `view constructor`
   *
   * A {@link NodeJS.TypedArray typed array constructor} or
   * {@link NodeJS.DataView `%DataView%`}, which will be used for constructing a
   * view with which to write into the {@link buffer}
   *
   * ## References
   * - [`TypedArray` Constructors](https://tc39.es/ecma262/#table-49)
   */
  ctor: ArrayBufferViewConstructor;
  /**
   * Either "default" or "byob", indicating what type of readable stream reader
   * initiated this request, or "none" if the initiating reader was released
   */
  readerType: "default" | "byob" | "none";
}

type TypedArrayConstructor =
  | Uint8ArrayConstructor
  | Uint8ClampedArrayConstructor
  | Uint16ArrayConstructor
  | Uint32ArrayConstructor
  | Int8ArrayConstructor
  | Int16ArrayConstructor
  | Int32ArrayConstructor
  | BigUint64ArrayConstructor
  | BigInt64ArrayConstructor
  | Float32ArrayConstructor
  | Float64ArrayConstructor;
type ArrayBufferViewConstructor = TypedArrayConstructor | DataViewConstructor;
