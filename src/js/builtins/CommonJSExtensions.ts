$visibility = "Private";

export function createAccessor(extensions, extension) {
  return function (module, filename) {
    const callback = extensions[extension];
    return callback.$call(this, module, filename);
  };
}
