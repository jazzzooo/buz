import path from "node:path";
import { writeIfNotChanged } from "./helpers.ts";
import { configureBindgenLinkMetadata, getErrorCodeMetadata } from "./native-function-table";

const [outputDir, metadataPath] = process.argv.slice(2);
if (!outputDir || !metadataPath) throw new Error("Expected an output directory and bindgen link metadata");

configureBindgenLinkMetadata(metadataPath);
const builtins = await Bun.file(path.join(import.meta.dir, "..", "js", "builtins.d.ts")).text();
let declarations = "// Generated from normalized binding error-code metadata.\n";
for (const error of getErrorCodeMetadata()) {
  if (new RegExp(`\\bdeclare function \\$${error.tag}\\(`).test(builtins)) continue;
  const result = `${error.constructor} & { name: ${JSON.stringify(error.name)}, code: ${JSON.stringify(error.code)} }`;
  declarations += `declare function $${error.tag}(message: string): ${result};\n`;
}
writeIfNotChanged(path.join(outputDir, "ErrorCode.d.ts"), declarations);
