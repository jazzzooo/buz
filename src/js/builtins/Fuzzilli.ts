$visibility = "Private";

export function fuzzilli(command, payload) {
  if ($argumentCount() === 0) return;
  const kind = $bindgenFn("RuntimeFunctions.schema.zig", "fuzzilliCommand")(command);
  if (kind === "crash") {
    $bindgenFn("RuntimeFunctions.schema.zig", "fuzzilliCrash")(payload);
  } else if (kind === "print" && $argumentCount() > 1) {
    $bindgenFn("RuntimeFunctions.schema.zig", "fuzzilliPrint")(payload);
  }
}
