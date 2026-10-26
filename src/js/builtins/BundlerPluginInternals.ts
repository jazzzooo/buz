// @internal

$linkTimeConstant;
export function chainPendingPluginPromise(promise: Promise<unknown>): Promise<unknown> {
  if ($peekPromiseStatus(promise) !== 0) return promise;

  const capability = $newPromiseCapability($Promise);
  try {
    // Completion comes from the callbacks, independently of a replaced then's return value.
    promise.then(capability.resolve, capability.reject);
  } catch (error) {
    $markPromiseAsHandled(capability.promise);
    throw error;
  }
  return capability.promise;
}
