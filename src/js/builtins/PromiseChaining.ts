$visibility = "Private";

export function chain(promise, onFulfilled, onRejected) {
  const result = $newPromise();
  $performPromiseThen(promise, onFulfilled, onRejected, result);
  return result;
}
