export function resolve(specifier, from, isESM) {
  const resolveSync = $bindgenFn("BunObject.schema.zig", "resolveSync");
  try {
    return Promise.$resolve(resolveSync.$apply(undefined, arguments));
  } catch (error) {
    return Promise.$reject(error);
  }
}

export async function udpSocket(options) {
  const createSocket = $bindgenFn("BunObject.schema.zig", "udpSocketNative");
  return await createSocket(options);
}

export function cron(expressionOrPath, handlerOrSchedule, title) {
  if ($isCallable(handlerOrSchedule)) {
    return $bindgenFn("CronJob.schema.zig", "registerInProcess")(expressionOrPath, handlerOrSchedule);
  }
  return $bindgenFn("CronJob.schema.zig", "registerSystem")(expressionOrPath, handlerOrSchedule, title);
}

export function build(config) {
  const buildNative = $bindgenFn("BunObject.schema.zig", "buildNative");
  const completion = buildNative(config, config, config);
  return finishBuild(completion);

  async function finishBuild(completion) {
    const nativeResult = await completion;
    const result = {
      outputs: nativeResult.outputs,
      success: nativeResult.success,
      logs: nativeResult.logs,
    };

    if (nativeResult.metafileJSON !== undefined) {
      let metafileJSON = nativeResult.metafileJSON;
      $Object.$defineProperty(result, "metafile", {
        configurable: true,
        enumerable: true,
        get() {
          const value = globalThis.JSON.parse(metafileJSON);
          metafileJSON = undefined;
          $Object.$defineProperty(result, "metafile", {
            configurable: true,
            enumerable: true,
            value,
          });
          return value;
        },
      });
    }

    const callbacks = nativeResult.onEndCallbacks;
    if (callbacks !== undefined) {
      const promises = [];
      for (let i = 0; i < callbacks.length; i++) {
        try {
          const callbackResult = callbacks[i](result);
          if (callbackResult && $isPromise(callbackResult)) {
            $arrayPush(promises, callbackResult);
          }
        } catch (error) {
          $arrayPush(promises, Promise.$reject(error));
        }
      }
      if (promises.length > 0) {
        await Promise.all(promises);
      }
    }

    if (!result.success && nativeResult.throwOnError) {
      throw new globalThis.AggregateError(result.logs, "Bundle failed");
    }
    return result;
  }
}
