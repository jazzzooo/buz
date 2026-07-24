// Option handling shared by `fs.cpSync`, `fs.cp` and `fs.promises.cp`.

const { validateBoolean, validateFunction, validateInteger, validateObject } = require("internal/validators");

const constants = $processBindingConstants.fs;
const maximumCopyMode = constants.COPYFILE_EXCL | constants.COPYFILE_FICLONE | constants.COPYFILE_FICLONE_FORCE;

// Frozen because callers with no options are handed this instance rather than a
// copy of it.
const defaults = Object.freeze({
  __proto__: null,
  dereference: false,
  errorOnExist: false,
  filter: undefined,
  force: true,
  mode: 0,
  preserveTimestamps: false,
  recursive: false,
  verbatimSymlinks: false,
});

/**
 * Fills in the defaults and rejects options `cp` cannot act on.
 *
 * Spreading over the defaults means an explicit `undefined` is validated like
 * any other value, so `{ recursive: undefined }` is an error while omitting the
 * key is not. `mode` is the exception, taking its default from a null or
 * undefined value the way `copyFile` does.
 */
function validateCpOptions(options) {
  if (options === undefined) return defaults;
  validateObject(options, "options");

  const validated = { __proto__: null, ...defaults, ...options };
  validateBoolean(validated.dereference, "options.dereference");
  validateBoolean(validated.errorOnExist, "options.errorOnExist");
  validateBoolean(validated.force, "options.force");
  validateBoolean(validated.preserveTimestamps, "options.preserveTimestamps");
  validateBoolean(validated.recursive, "options.recursive");
  validateBoolean(validated.verbatimSymlinks, "options.verbatimSymlinks");
  if (validated.filter !== undefined) validateFunction(validated.filter, "options.filter");

  if (validated.mode == null) validated.mode = defaults.mode;
  else validateInteger(validated.mode, "mode", 0, maximumCopyMode);

  if (validated.dereference && validated.verbatimSymlinks) {
    throw $ERR_INCOMPATIBLE_OPTION_PAIR("dereference", "verbatimSymlinks");
  }

  return validated;
}

/** Whether these options need the JavaScript copier; the native one cannot honour them. */
function needsJavaScriptCopier(options) {
  return (
    options.dereference || options.preserveTimestamps || options.verbatimSymlinks || options.filter !== undefined
  );
}

export default { validateCpOptions, needsJavaScriptCopier };
