// This script is run when you change anything in src/js/*
//
// Documentation is in src/js/README.md
//
// Originally, the builtin bundler only supported function files, but then the module files were
// added to this, which has made this entire setup extremely convoluted and a mess.
//
// One day, this entire setup should be rewritten, but also it would be cool if Bun natively
// supported macros that aren't json value -> json value. Otherwise, I'd use a real JS parser/ast
// library, instead of RegExp hacks.
import fs from "fs";
import { mkdir, writeFile } from "fs/promises";
import { builtinModules } from "node:module";
import path from "path";
import { sliceSourceCode } from "./builtin-parser";
import { createAssertClientJS, createLogClientJS } from "./client-js";
import { declareASCIILiteral, writeIfNotChanged } from "./helpers";
import { createInternalModuleRegistry } from "./internal-module-registry-scanner";
import { configureBindgenLinkMetadata, getBindgenFunctionTableCPP } from "./native-function-table";
import { define } from "./replacements";

const BASE = path.join(import.meta.dir, "../js");
const debug = process.argv[2] === "--debug=ON";
const CMAKE_BUILD_ROOT = process.argv[3];
const NATIVE_MODULE_MANIFEST = process.argv[4];
const BINDGEN_LINK_METADATA = process.argv[5];

const timeString = 'Bundled "src/js" for ' + (debug ? "development" : "production");
const timeStart = performance.now();

if (!CMAKE_BUILD_ROOT || !NATIVE_MODULE_MANIFEST || !BINDGEN_LINK_METADATA) {
  console.error(
    "Usage: bun bundle-modules.ts --debug=[OFF|ON] <CMAKE_WORK_DIR> <NATIVE_MODULE_MANIFEST> <BINDGEN_LINK_METADATA>",
  );
  process.exit(1);
}

const bindingFingerprint = configureBindgenLinkMetadata(BINDGEN_LINK_METADATA);

globalThis.CMAKE_BUILD_ROOT = CMAKE_BUILD_ROOT;
const bundleBuiltinFunctions = require("./bundle-functions").bundleBuiltinFunctions;

const TMP_DIR = path.join(CMAKE_BUILD_ROOT, "tmp_modules");
const CODEGEN_DIR = path.join(CMAKE_BUILD_ROOT, "codegen");
const JS_DIR = path.join(CMAKE_BUILD_ROOT, "js");

const t = new Bun.Transpiler({ loader: "tsx" });

let start = performance.now();
const silent = process.env.BUN_SILENT === "1" || process.env.CLAUDECODE;
function markVerbose(log: string) {
  const now = performance.now();
  console.log(`${log} (${(now - start).toFixed(0)}ms)`);
  start = now;
}

const mark = silent ? (log: string) => {} : markVerbose;

const { moduleList, moduleDescriptions, requireTransformer, nativeStartIndex, privateSymbols, fingerprint } =
  createInternalModuleRegistry(BASE, NATIVE_MODULE_MANIFEST);
if (fingerprint !== bindingFingerprint)
  throw new Error("Internal module and binding link metadata come from different schemas");
globalThis.requireTransformer = requireTransformer;

// these logs surround a very weird issue where writing files and then bundling sometimes doesn't
// work, so i have lot of debug logs that blow up the console because not sure what is going on.
// that is also the reason for using `retry` when theoretically writing a file the first time
// should actually write the file.
const verbose = Bun.env.VERBOSE ? console.log : () => {};
async function retry(n, fn) {
  var err;
  while (n > 0) {
    try {
      await fn();
      return;
    } catch (e) {
      err = e;
      n--;
      await Bun.sleep(5);
    }
  }
  throw err;
}

const bunRepoRoot = path.join(CMAKE_BUILD_ROOT, "..", "..");

// Preprocess builtins
const bundledEntryPoints: string[] = [];
for (let i = 0; i < nativeStartIndex; i++) {
  try {
    const file = path.join(BASE, moduleList[i]);
    let input = fs.readFileSync(file, "utf8");

    if (!/\bexport\s+(?:function|class|const|default|{)/.test(input)) {
      if (input.includes("module.exports")) {
        throw new Error(
          "Do not use CommonJS module.exports in ESM modules. Use `export default { ... }` instead. See src/js/README.md",
        );
      } else {
        throw new Error(
          `Internal modules must have at least one ESM export statement in '${path.relative(bunRepoRoot, file)}' — see src/js/README.md`,
        );
      }
    }

    // TODO: there is no reason this cannot be converted automatically.
    // import { ... } from '...' -> `const { ... } = require('...')`
    const scannedImports = t.scan(input);
    for (const imp of scannedImports.imports) {
      if (imp.kind === "import-statement") {
        var isBuiltin = true;
        try {
          if (!builtinModules.includes(imp.path)) {
            requireTransformer(imp.path, moduleList[i]);
          }
        } catch {
          isBuiltin = false;
        }
        if (isBuiltin) {
          const err = new Error(
            `Cannot use ESM import statement within builtin modules. Use require("${imp.path}") instead. See src/js/README.md (from ${moduleList[i]})`,
          );
          err.name = "BunError";
          err["fileName"] = moduleList[i];
          throw err;
        }
      }
    }

    if (scannedImports.exports.includes("default") && scannedImports.exports.length > 1) {
      const err = new Error(
        `Using \`export default\` AND named exports together in builtin modules is unsupported. See src/js/README.md (from ${moduleList[i]})`,
      );
      err.name = "BunError";
      err["fileName"] = moduleList[i];
      throw err;
    }
    let importStatements: string[] = [];

    const processed = sliceSourceCode(
      "{" +
        input
          .replace(
            /\bimport(\s*type)?\s*(\{[^}]*\}|(\*\s*as)?\s[a-zA-Z0-9_$]+)\s*from\s*['"][^'"]+['"]/g,
            stmt => (importStatements.push(stmt), ""),
          )
          .replace(/export\s*{\s*}\s*;/g, ""),
      true,
      x => requireTransformer(x, moduleList[i]),
    );
    let fileToTranspile = `// GENERATED TEMP FILE - DO NOT EDIT
// Sourced from src/js/${moduleList[i]}
${importStatements.join("\n")}

${processed.result.slice(1).trim()}
;$$EXPORT$$(__intrinsic__exports).$$EXPORT_END$$;
`;

    // Attempt to optimize "$exports = ..." to a variableless return
    // otherwise, declare $exports so it works.
    let exportOptimization = false;
    fileToTranspile = fileToTranspile.replace(
      /__intrinsic__exports\s*=\s*(.*|.*\{[^\}]*}|.*\([^\)]*\))\n+\s*\$\$EXPORT\$\$\(__intrinsic__exports\).\$\$EXPORT_END\$\$;/,
      (_, a) => {
        exportOptimization = true;
        return "$$EXPORT$$(" + a.replace(/;$/, "") + ").$$EXPORT_END$$;";
      },
    );
    if (!exportOptimization) {
      fileToTranspile = `var $;` + fileToTranspile.replaceAll("__intrinsic__exports", "$");
    }
    const outputPath = path.join(TMP_DIR, moduleList[i].slice(0, -3) + ".ts");

    await mkdir(path.dirname(outputPath), { recursive: true });
    if (!fs.existsSync(path.dirname(outputPath))) {
      verbose("directory did not exist after mkdir twice:", path.dirname(outputPath));
    }

    fileToTranspile = "// @ts-nocheck\n" + fileToTranspile;

    try {
      await writeFile(outputPath, fileToTranspile);
      if (!fs.existsSync(outputPath)) {
        verbose("file did not exist after write:", outputPath);
        throw new Error("file did not exist after write: " + outputPath);
      }
      verbose("wrote to", outputPath, "successfully");
    } catch {
      await retry(3, async () => {
        await mkdir(path.dirname(outputPath), { recursive: true });
        await writeFile(outputPath, fileToTranspile);
        if (!fs.existsSync(outputPath)) {
          verbose("file did not exist after write:", outputPath);
          throw new Error("file did not exist after write: " + outputPath);
        }
        verbose("wrote to", outputPath, "successfully later");
      });
    }
    bundledEntryPoints.push(outputPath);
  } catch (error) {
    console.error(error);
    console.error(`While processing: ${moduleList[i]}`);
    process.exit(1);
  }
}

mark("Preprocess modules");

// directory caching stuff breaks this sometimes. CLI rules
const config_cli = [
  process.execPath,
  "build",
  ...bundledEntryPoints,
  ...(debug ? [] : ["--minify-syntax", "--keep-names"]),
  "--root",
  TMP_DIR,
  "--target",
  "bun",
  ...builtinModules.map(x => ["--external", x]).flat(),
  ...Object.keys(define)
    .map(x => [`--define`, `${x}=${define[x]}`])
    .flat(),
  "--define",
  `IS_BUN_DEVELOPMENT=${String(!!debug)}`,
  "--define",
  `__intrinsic__debug=${debug ? "$debug_log_enabled" : "false"}`,
  "--outdir",
  path.join(TMP_DIR, "modules_out"),
];
verbose("running: ", config_cli);
const out = Bun.spawnSync({
  cmd: config_cli,
  cwd: process.cwd(),
  env: process.env,
  stdio: ["pipe", "pipe", "pipe"],
});
if (out.exitCode !== 0) {
  console.error(out.stderr.toString());
  process.exit(out.exitCode);
}

mark("Bundle modules");

const outputs = new Map();

for (const entrypoint of bundledEntryPoints) {
  const file_path = entrypoint.slice(TMP_DIR.length + 1).replace(/\.ts$/, ".js");
  const file = Bun.file(path.join(TMP_DIR, "modules_out", file_path));
  const output = await file.text();
  let captured = `(function (){${output.replace("// @bun\n", "").trim()}})`;
  let usesDebug = output.includes("$debug_log");
  let usesAssert = output.includes("$assert");
  captured =
    captured
      .replace(/\$\$EXPORT\$\$\((.*)\).\$\$EXPORT_END\$\$;/, "return $1")
      .replace(/]\s*,\s*__(debug|assert)_end__\)/g, ")")
      .replace(/]\s*,\s*__debug_end__\)/g, ")")
      .replace(/import.meta.require\((.*?)\)/g, (expr, specifier) => {
        throw new Error(`Builtin Bundler: do not use import.meta.require() (in ${file_path}))`);
      })
      .replace(/return \$\nexport /, "return")
      .replace(/__intrinsic__/g, "@")
      .replace(/__no_intrinsic__/g, "") + "\n";
  captured = captured.replace(
    /function\s*\(.*?\)\s*{/,
    '$&"use strict";' +
      (usesDebug
        ? createLogClientJS(
            file_path.replace(".js", ""),
            idToPublicSpecifierOrEnumName(file_path).replace(/^node:|^bun:/, ""),
          )
        : "") +
      (usesAssert ? createAssertClientJS(idToPublicSpecifierOrEnumName(file_path).replace(/^node:|^bun:/, "")) : ""),
  );
  const errors = [...captured.matchAll(/@bundleError\((.*)\)/g)];
  if (errors.length) {
    throw new Error(`Errors in ${entrypoint}:\n${errors.map(x => x[1]).join("\n")}`);
  }

  const outputPath = path.join(JS_DIR, file_path);
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, captured);
  outputs.set(file_path.replace(".js", ""), captured);
}

mark("Postprocesss modules");

function idToEnumName(id: string) {
  const entry = moduleDescriptions.get(id);
  if (!entry) throw new Error(`Module has no schema declaration: ${id}`);
  return entry.name;
}

function idToPublicSpecifierOrEnumName(id: string) {
  const entry = moduleDescriptions.get(id);
  if (!entry) throw new Error(`Module has no schema declaration: ${id}`);
  return entry.specifier;
}

await bundleBuiltinFunctions({
  requireTransformer,
  schemaPrivateNames: privateSymbols,
});

mark("Bundle Functions");

// This header is used by InternalModuleRegistry.cpp, and should only be included in that file.
// It inlines all the strings for the module IDs.
//
// We cannot use ASCIILiteral's `_s` operator for the module source code because for long
// strings it fails a constexpr assert. Instead, we do that assert in JS before we format the string
if (!debug) {
  writeIfNotChanged(
    path.join(CODEGEN_DIR, "InternalModuleRegistryConstants.h"),
    `// clang-format off
#pragma once

namespace Bun {
namespace InternalModuleRegistryConstants {
  ${moduleList
    .slice(0, nativeStartIndex)
    .map((id, n) => {
      const out = outputs.get(id.slice(0, -3).replaceAll("/", path.sep));
      if (!out) {
        throw new Error(`Missing output for ${id}`);
      }
      return declareASCIILiteral(`${idToEnumName(id)}Code`, out);
    })
    .join("\n")}
}
}`,
  );
} else {
  // In debug builds, we write empty strings to prevent recompilation. These are loaded from disk instead.
  writeIfNotChanged(
    path.join(CODEGEN_DIR, "InternalModuleRegistryConstants.h"),
    `// clang-format off
#pragma once

namespace Bun {
namespace InternalModuleRegistryConstants {
  ${moduleList
    .slice(0, nativeStartIndex)
    .map((id, n) => `${declareASCIILiteral(`${idToEnumName(id)}Code`, "")}`)
    .join("\n")}
}
}`,
  );
}

writeIfNotChanged(path.join(CODEGEN_DIR, "BindgenFunctionTable.h"), getBindgenFunctionTableCPP());

const generatedDTSPath = path.join(CODEGEN_DIR, "generated.d.ts");
writeIfNotChanged(
  generatedDTSPath,
  (() => {
    let dts = `
// GENERATED TEMP FILE - DO NOT EDIT
// generated by ${import.meta.path}

declare module "module" {
  global {
    interface PropertyDescriptor {
      __proto__?: any;
    }

    interface Function {
      readonly $call: Function.prototype["call"];
      readonly $apply: Function.prototype["apply"];
    }

    namespace NodeJS {
      interface Require {

`;

    dts += `        (id: "bun"): typeof import("bun");\n`;
    dts += `        (id: "bun:test"): typeof import("bun:test");\n`;
    dts += `        (id: "bun:jsc"): typeof import("bun:jsc");\n`;

    for (let i = 0; i < nativeStartIndex; i++) {
      const id = moduleList[i];
      const out = outputs.get(id.slice(0, -3).replaceAll("/", path.sep));
      if (!out) {
        throw new Error(`Missing output for ${id}`);
      }
      let internalName = idToPublicSpecifierOrEnumName(id);
      if (internalName.startsWith("internal:")) internalName = internalName.replace(":", "/");

      dts += `        (id: "${internalName}"): typeof import("${path.join(BASE, id)}").default;\n`;
    }

    dts += `
      }
    }
  }
}
`;

    return dts;
  })(),
);

mark("Generate Code");

const evalFiles = new Bun.Glob(path.join(BASE, "eval", "*.ts")).scanSync();
for (const file of evalFiles) {
  const {
    outputs: [output],
  } = await Bun.build({
    entrypoints: [file],

    // Shrink it.
    minify: !debug,

    target: "bun",
    format: "esm",
    env: "disable",
    define: {
      "process.platform": JSON.stringify(process.env.TARGET_PLATFORM ?? process.platform),
      "process.arch": JSON.stringify(process.env.TARGET_ARCH ?? process.arch),
    },
  });
  writeIfNotChanged(path.join(CODEGEN_DIR, "eval", path.basename(file)), await output.text());
}

if (!silent) {
  console.log("");
  console.log(`[${((performance.now() - timeStart) / 1000).toFixed(2)}s] ${timeString}`);
  console.log(
    `  %s kb`,
    Math.floor(
      (moduleList
        .slice(0, nativeStartIndex)
        .reduce((a, b) => a + outputs.get(b.slice(0, -3).replaceAll("/", path.sep)).length, 0) +
        globalThis.internalFunctionJSSize) /
        1000,
    ),
  );
  console.log(`  %s internal modules`, nativeStartIndex);
  console.log(`  %s native modules`, moduleList.length - nativeStartIndex);
  console.log(
    `  %s internal functions across %s files`,
    globalThis.internalFunctionCount,
    globalThis.internalFunctionFileCount,
  );
}
