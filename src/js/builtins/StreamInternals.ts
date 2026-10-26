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

// @internal

export function markPromiseAsHandled(promise: Promise<unknown>) {
  $assert($isPromise(promise));
  $pokePromiseAsHandled(promise);
}

export function shieldingPromiseResolve(result) {
  const promise = Promise.$resolve(result);
  if (promise.$then === undefined) promise.$then = $Promise.prototype.$then;
  return promise;
}

export function promiseInvokeOrNoopMethodNoCatch(object, method, args) {
  if (method === undefined) return Promise.$resolve();
  return $shieldingPromiseResolve(method.$apply(object, args));
}

export function promiseInvokeOrNoopMethod(object, method, args) {
  try {
    return $promiseInvokeOrNoopMethodNoCatch(object, method, args);
  } catch (error) {
    return Promise.$reject(error);
  }
}

export function validateAndNormalizeQueuingStrategy(size, highWaterMark) {
  if (highWaterMark !== highWaterMark || highWaterMark < 0)
    throw new RangeError("highWaterMark value is negative or not a number");

  return { size: size, highWaterMark: highWaterMark };
}

import type Dequeue from "internal/fifo";
$linkTimeConstant;
export function createFIFO<T>(): Dequeue<T> {
  const Dequeue = require("internal/fifo");
  return new Dequeue();
}

export function newQueue() {
  return { content: $createFIFO(), size: 0 };
}

export function dequeueValue(queue) {
  const record = queue.content.shift();
  queue.size -= record.size;
  // As described by spec, below case may occur due to rounding errors.
  if (queue.size < 0) queue.size = 0;
  return record.value;
}

export function enqueueValueWithSize(queue, value, size: number) {
  if (size !== size || size === Infinity || size < 0) throw new RangeError("size has an incorrect value");

  queue.content.push({ value, size });
  queue.size += size;
}

export function peekQueueValue(queue) {
  return queue.content.peek()?.value;
}

export function resetQueue(queue) {
  $assert("content" in queue);
  $assert("size" in queue);
  queue.content.clear();
  queue.size = 0;
}

export function createFulfilledPromise(value) {
  const promise = $newPromise();
  $fulfillPromise(promise, value);
  return promise;
}
