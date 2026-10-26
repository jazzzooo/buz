import fs from "fs";
import path from "path";
import { readdirRecursive, resolveSyncOrNull } from "./helpers";

interface NativeModuleManifest {
  version: number;
  fingerprint: string;
  privateSymbols: string[];
  registry: {
    javascriptCount: number;
    modules: InternalModuleDescription[];
  };
}

interface InternalModuleDescription {
  id: number;
  name: string;
  specifier: string;
  source: string | null;
  bundlePath: string | null;
  aliases: string[];
}

export function createInternalModuleRegistry(basedir: string, nativeModuleManifestPath: string) {
  const manifest = JSON.parse(fs.readFileSync(nativeModuleManifestPath, "utf8")) as NativeModuleManifest;
  if (
    manifest.version !== 4 ||
    typeof manifest.fingerprint !== "string" ||
    !Array.isArray(manifest.privateSymbols) ||
    !manifest.privateSymbols.every(name => typeof name === "string") ||
    new Set(manifest.privateSymbols).size !== manifest.privateSymbols.length ||
    !manifest.registry ||
    !Number.isInteger(manifest.registry.javascriptCount) ||
    !Array.isArray(manifest.registry.modules) ||
    manifest.registry.javascriptCount < 0 ||
    manifest.registry.javascriptCount > manifest.registry.modules.length
  ) {
    throw new Error(`Invalid internal module manifest: ${nativeModuleManifestPath}`);
  }

  const moduleList: string[] = [];
  const internalRegistry = new Map<string, number>();
  const moduleDescriptions = new Map<string, InternalModuleDescription>();
  const names = new Set<string>();
  for (const [index, entry] of manifest.registry.modules.entries()) {
    if (
      entry.id !== index ||
      typeof entry.name !== "string" ||
      typeof entry.specifier !== "string" ||
      !Array.isArray(entry.aliases) ||
      !entry.aliases.every(alias => typeof alias === "string") ||
      (index < manifest.registry.javascriptCount ? typeof entry.source !== "string" : entry.source !== null) ||
      (entry.source === null ? entry.bundlePath !== null : typeof entry.bundlePath !== "string") ||
      names.has(entry.name)
    ) {
      throw new Error(`Invalid internal module entry in ${nativeModuleManifestPath}`);
    }
    names.add(entry.name);
    const file = entry.source ?? entry.specifier;
    for (const key of new Set([file, entry.bundlePath].filter((value): value is string => value !== null))) {
      if (moduleDescriptions.has(key)) throw new Error(`Duplicate internal module source or output: ${key}`);
      moduleDescriptions.set(key, entry);
    }
    moduleList.push(file);
    for (const specifier of [entry.specifier, ...entry.aliases]) {
      if (internalRegistry.has(specifier)) throw new Error(`Duplicate internal module specifier: ${specifier}`);
      internalRegistry.set(specifier, entry.id);
    }
  }

  const files = ["bun", "node", "thirdparty", "internal"]
    .flatMap(dir => readdirRecursive(path.join(basedir, dir)))
    .filter(file => file.endsWith(".js") || (file.endsWith(".ts") && !file.endsWith(".d.ts")))
    .map(file => path.relative(basedir, file).replaceAll("\\", "/"));
  for (const file of [...files, "internal-for-testing.ts"]) {
    if (!moduleDescriptions.has(file)) throw new Error(`Internal module has no schema declaration: ${file}`);
  }

  function codegenRequireId(id: number) {
    return `(__intrinsic__getInternalField(__intrinsic__internalModuleRegistry, ${id}) || __intrinsic__createInternalModuleById(${JSON.stringify(manifest.registry.modules[id].specifier)}))`;
  }

  const requireTransformer = (specifier: string, from: string) => {
    const directMatch = internalRegistry.get(specifier);
    if (directMatch !== undefined) return codegenRequireId(directMatch);

    const relativeMatch =
      resolveSyncOrNull(specifier, path.join(basedir, path.dirname(from))) ?? resolveSyncOrNull(specifier, basedir);
    const suffix =
      'Only files in "src/js" besides "src/js/builtins" can be imported here. Note that the "node:" or "bun:" prefix is required here.';
    if (relativeMatch) {
      const found = moduleList.indexOf(path.relative(basedir, relativeMatch).replaceAll("\\", "/"));
      if (found === -1) {
        throw new Error(
          `Builtin Bundler: "${specifier}" cannot be imported from "${from}" because it doesn't get a module ID. ${suffix}`,
        );
      }
      return codegenRequireId(found);
    }
    throw new Error(`Builtin Bundler: Could not resolve "${specifier}" in "${from}". ${suffix}`);
  };

  return {
    requireTransformer,
    moduleDescriptions,
    internalRegistry,
    moduleList,
    nativeStartIndex: manifest.registry.javascriptCount,
    privateSymbols: manifest.privateSymbols,
    fingerprint: manifest.fingerprint,
  } as const;
}
