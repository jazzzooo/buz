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
//
// For explanation on this, please nag @paperclover to write documentation on how everything works.
//
// The output is intended to be similar to what WebCore does internally with a couple differences:
//
// - We concatenate all the sources into one big string, which then createsa
// single JSC::SourceProvider and pass start/end positions to each function's
// JSC::SourceCode. JSC does this, but WebCore does not seem to.
import assert from "assert";
import { readdirSync, rmSync } from "fs";
import path from "path";
import { createSourceFile, isFunctionDeclaration, isIdentifier, isTypeAliasDeclaration, ScriptKind, ScriptTarget, SyntaxKind } from "typescript";
import { sliceSourceCode } from "./builtin-parser";
import { createAssertClientJS, createLogClientJS } from "./client-js";
import { addCPPCharArray, cap, low, writeIfNotChanged } from "./helpers";
import { applyGlobalReplacements, define } from "./replacements";

const PARALLEL = false;
const KEEP_TMP = true;

if (import.meta.main) {
  throw new Error("This script is not meant to be run directly");
}

const CMAKE_BUILD_ROOT = globalThis.CMAKE_BUILD_ROOT;
if (!CMAKE_BUILD_ROOT) {
  throw new Error("CMAKE_BUILD_ROOT is not defined");
}

const SRC_DIR = path.join(import.meta.dir, "../js/builtins");
const CODEGEN_DIR = path.join(CMAKE_BUILD_ROOT, "./codegen");
const TMP_DIR = path.join(CMAKE_BUILD_ROOT, "./tmp_functions");

interface ParsedBuiltin {
  name: string;
  params: string[];
  directives: Record<string, any>;
  source: string;
  async: boolean;
  enums: string[];
}

interface BundledBuiltin {
  name: string;
  directives: Record<string, any>;
  isGetter: boolean;
  constructAbility: string;
  constructKind: string;
  isLinkTimeConstant: boolean;
  intrinsic: string;
  overriddenName: string;
  source: string;
  params: string[];
  visibility: string;
  sourceOffset: number;
}

/**
 * Source .ts file --> Array<bundled js function code>
 */
async function processFileSplit(filename: string): Promise<{ functions: BundledBuiltin[]; internal: boolean }> {
  const basename = path.basename(filename, ".ts");
  let contents = await Bun.file(filename).text();

  contents = applyGlobalReplacements(contents);
  const originalContents = contents;
  const parsedSource = createSourceFile(filename, originalContents, ScriptTarget.Latest, false, ScriptKind.TS);
  const typeDeclarationEnds = new Map(
    parsedSource.statements
      .filter(isTypeAliasDeclaration)
      .map(statement => [statement.getStart(parsedSource), statement.end]),
  );
  const functionDeclarations = new Map(
    parsedSource.statements
      .filter(isFunctionDeclaration)
      .map(statement => [statement.getStart(parsedSource), statement]),
  );

  // first approach doesnt work perfectly because we actually need to split each function declaration
  // and then compile those separately

  const consumeWhitespace = /^\s*/;
  const consumeTopLevelContent =
    /^(\/\*|\/\/|(?:export )?type\b|import|interface|\$|const enum|export (?:async )?function|(?:async )?function)/;

  const functions: ParsedBuiltin[] = [];
  let directives: Record<string, any> = {};
  const bundledFunctions: BundledBuiltin[] = [];
  let internal = false;
  const topLevelEnums: { name: string; code: string }[] = [];

  while (contents.length) {
    contents = contents.replace(consumeWhitespace, "");
    if (!contents.length) break;
    const match = contents.match(consumeTopLevelContent);
    if (!match) {
      const pos = originalContents.length - contents.length;
      let lineNumber = 1;
      let columnNumber = 1;
      let lineStartPos = 0;
      for (let i = 0; i < pos; i++) {
        if (originalContents[i] === "\n") {
          lineNumber++;
          columnNumber = 1;
          lineStartPos = i + 1;
        } else {
          columnNumber++;
        }
        if (i === pos) {
          break;
        }
      }
      const lineEndPos = lineStartPos + originalContents.slice(lineStartPos).indexOf("\n");
      throw new SyntaxError(
        "Could not process input:\n" +
          originalContents.slice(lineStartPos, lineEndPos) +
          "\n" +
          " ".repeat(pos - lineStartPos) +
          "^" +
          "\n    at " +
          filename +
          ":" +
          lineNumber +
          ":" +
          columnNumber,
      );
    }
    contents = contents.slice(match.index!);
    if (match[1] === "import") {
      // TODO: we may want to do stuff with these
      const i = contents.indexOf(";");
      contents = contents.slice(i + 1);
    } else if (match[1] === "/*") {
      const i = contents.indexOf("*/") + 2;
      internal ||= contents.slice(0, i).includes("@internal");
      contents = contents.slice(i);
    } else if (match[1] === "//") {
      const i = contents.indexOf("\n") + 1;
      internal ||= contents.slice(0, i).includes("@internal");
      contents = contents.slice(i);
    } else if (match[1] === "type" || match[1] === "export type") {
      const end = typeDeclarationEnds.get(originalContents.length - contents.length);
      if (end === undefined) throw new SyntaxError(`Could not parse type declaration in ${filename}`);
      contents = originalContents.slice(end);
    } else if (match[1] === "interface") {
      contents = sliceSourceCode(contents, false).rest;
    } else if (match[1] === "const enum") {
      const { result, rest } = sliceSourceCode(contents, false);
      const i = result.indexOf("{\n");
      // Support const enums in module scope.
      topLevelEnums.push({
        name: result.slice("const enum ".length, i).trim(),
        code: "\n" + result,
      });

      contents = rest;
    } else if (match[1] === "$") {
      const directive = contents.match(/^\$([a-zA-Z0-9]+)(?:\s*=\s*([^\r\n]+?))?\s*;?\r?\n/);
      if (!directive) {
        throw new SyntaxError("Could not parse directive:\n" + contents.slice(0, contents.indexOf("\n")));
      }
      const name = directive[1];
      let value;
      try {
        value = directive[2] ? JSON.parse(directive[2]) : true;
      } catch (error) {
        throw new SyntaxError("Could not parse directive value " + directive[2] + " (must be JSON parsable)");
      }
      if (name === "constructor") {
        directives.ConstructAbility = "CanConstruct";
      } else if (name === "nakedConstructor") {
        directives.ConstructAbility = "CanConstruct";
        directives.ConstructKind = "Naked";
      } else {
        directives[name] = value;
      }
      contents = contents.slice(directive[0].length);
    } else if (match[1] === "export function" || match[1] === "export async function") {
      const declaration = functionDeclarations.get(originalContents.length - contents.length);
      if (!declaration?.name || !declaration.body)
        throw new SyntaxError(`Could not parse builtin function in ${filename}`);
      const name = declaration.name.text;
      const async = declaration.modifiers?.some(modifier => modifier.kind === SyntaxKind.AsyncKeyword) ?? false;
      if (!directives.sloppy && declaration.parameters.some(parameter =>
        parameter.initializer || parameter.dotDotDotToken || !isIdentifier(parameter.name))) {
        throw new SyntaxError(`Strict builtin ${basename}.${name} requires simple parameters; initialize or unpack arguments in the body`);
      }
      const params = declaration.parameters
        .filter(parameter => parameter.name.getText(parsedSource) !== "this")
        .map(parameter =>
          (parameter.dotDotDotToken ? "..." : "") + parameter.name.getText(parsedSource) +
          (parameter.initializer ? " = " + parameter.initializer.getText(parsedSource) : ""),
        );

      const { result, rest } = sliceSourceCode(originalContents.slice(declaration.body.getStart(parsedSource)), true, x =>
        globalThis.requireTransformer(x, SRC_DIR + "/" + basename),
      );

      const source = result.trim().slice(1, -1);
      const constEnumsUsedInFunction: string[] = [];
      if (topLevelEnums.length) {
        // If the function references a top-level const enum let's add the code
        // to the top-level scope of the function so that the transpiler will
        // inline all the values and strip out the enum object.
        for (const { name, code } of topLevelEnums) {
          // Only include const enums which are referenced in the function source.
          if (source.includes(name)) {
            constEnumsUsedInFunction.push(code);
          }
        }
      }

      functions.push({
        name,
        params,
        directives,
        source,
        async,
        enums: constEnumsUsedInFunction,
      });
      contents = rest;
      directives = {};
    } else if (match[1] === "function" || match[1] === "async function") {
      const fnname = contents.match(/^function ([a-zA-Z0-9]+)\(([^)]*)\)(?:\s*:\s*([^{\n]+))?\s*{?/)![1];
      throw new SyntaxError("All top level functions must be exported: " + fnname);
    } else {
      throw new Error("TODO: parse " + match[1]);
    }
  }

  for (const fn of functions) {
    const tmpFile = path.join(TMP_DIR, `${basename}.${fn.name}.ts`);

    // not sure if this optimization works properly in jsc builtins
    // const useThis = fn.usesThis;
    const useThis = true;

    // TODO: we should use format=IIFE so we could bundle imports and extra functions.
    await Bun.write(
      tmpFile,
      `// @ts-nocheck
// GENERATED TEMP FILE - DO NOT EDIT
// Sourced from ${path.relative(TMP_DIR, filename)}
${fn.enums.join("\n")}
// do not allow the bundler to rename a symbol to $
($);

$$capture_start$$(${fn.async ? "async " : ""}${
        useThis
          ? `function(${fn.params.join(",")})`
          : `${fn.params.length === 1 ? fn.params[0] : `(${fn.params.join(",")})`}=>`
      } {${fn.source}}).$$capture_end$$;
`,
    );
    await Bun.sleep(1);
    const build = await Bun.build({
      entrypoints: [tmpFile],
      define,
      target: "bun",
      minify: { syntax: true, whitespace: false, keepNames: true },
    });
    // TODO: Wait a few versions before removing this
    if (!build.success) {
      throw new AggregateError(build.logs, "Failed bundling builtin function " + fn.name + " from " + basename + ".ts");
    }
    if (build.outputs.length !== 1) {
      throw new Error("expected one output");
    }
    let output = (await build.outputs[0].text()).replaceAll("// @bun\n", "");
    let usesDebug = output.includes("$debug_log");
    let usesAssert = output.includes("$assert");
    const captured = output.match(/\$\$capture_start\$\$([\s\S]+)\.\$\$capture_end\$\$/)![1];
    const finalReplacement =
      (fn.directives.sloppy
        ? captured
        : captured.replace(
            /function\s*\(.*?\)\s*{/,
            '$&"use strict";' +
              (usesDebug ? createLogClientJS("BUILTINS", fn.name) : "") +
              (usesAssert ? createAssertClientJS(fn.name) : ""),
          )
      )
        .replace(/^\((async )?function\(/, "($1function (")
        .replace(/__intrinsic__/g, "@")
        .replace(/__no_intrinsic__/g, "") + "\n";

    const errors = [...finalReplacement.matchAll(/@bundleError\((.*)\)/g)];
    if (errors.length) {
      throw new Error(`Errors in ${basename}.ts:\n${errors.map(x => x[1]).join("\n")}`);
    }

    const usesAwait = fn.async && /\bawait\b/.test(finalReplacement);

    bundledFunctions.push({
      name: fn.name,
      directives: fn.directives,
      source: finalReplacement,
      params: fn.params,
      // Parser::parseFunctionBody upgrades async wrappers to Private when they use await.
      visibility: fn.directives.visibility ?? (fn.directives.linkTimeConstant || usesAwait ? "Private" : "Public"),
      isGetter: !!fn.directives.getter,
      constructAbility: fn.directives.ConstructAbility ?? "CannotConstruct",
      constructKind: fn.directives.ConstructKind ?? "None",
      isLinkTimeConstant: !!fn.directives.linkTimeConstant,
      intrinsic: fn.directives.intrinsic ?? "NoIntrinsic",

      // Not known yet.
      sourceOffset: 0,

      overriddenName: fn.directives.getter
        ? `"get ${fn.name}"_s`
        : fn.directives.overriddenName
          ? `"${fn.directives.overriddenName}"_s`
          : "ASCIILiteral()",
    });
  }

  return {
    functions: bundledFunctions.sort((a, b) => a.name.localeCompare(b.name)),
    internal,
  };
}

const files: Array<{ basename: string; functions: BundledBuiltin[]; internal: boolean }> = [];
async function processFunctionFile(x: string) {
  const basename = path.basename(x, ".ts");
  try {
    files.push({
      basename,
      ...(await processFileSplit(path.join(SRC_DIR, x))),
    });
  } catch (error) {
    console.error("Failed to process file: " + basename + ".ts");
    console.error(error);
    process.exit(1);
  }
}

interface BundleBuiltinFunctionsArgs {
  requireTransformer: (x: string, filename: string) => string;
  schemaPrivateNames: readonly string[];
}

export async function bundleBuiltinFunctions({ requireTransformer, schemaPrivateNames }: BundleBuiltinFunctionsArgs) {
  const filesToProcess = readdirSync(SRC_DIR)
    .filter(x => x.endsWith(".ts") && !x.endsWith(".d.ts"))
    .sort();

  // Bun seems to crash if this is parallelized, :(
  if (PARALLEL) {
    await Promise.all(filesToProcess.map(processFunctionFile));
  } else {
    for (const x of filesToProcess) {
      await processFunctionFile(x);
    }
  }

  let combinedSourceCodeChars = "";
  let combinedSourceCodeLength = 0;
  // Compute source offsets
  {
    for (const { basename, functions } of files) {
      for (const fn of functions) {
        fn.sourceOffset = combinedSourceCodeLength;
        combinedSourceCodeLength += fn.source.length;
        if (combinedSourceCodeChars && !combinedSourceCodeChars.endsWith(",")) {
          combinedSourceCodeChars += ",";
        }
        combinedSourceCodeChars += addCPPCharArray(fn.source, false);

        // If you want to see the individual function sources:
        // if (true) {
        //   Bun.write(CODEGEN_DIR + "/functions/" + low(basename) + cap(fn.name) + ".js", fn.source + "\n");
        // }
      }
    }
  }

  const additionalPrivateNames = new Set<string>(schemaPrivateNames);
  for (const { internal, functions } of files) {
    if (internal) for (const fn of functions) additionalPrivateNames.add(fn.name);
  }

  // C++ codegen
  let bundledCPP = `// Generated by ${import.meta.path}
    #include "root.h"
    #include "config.h"
    #include "ZigGlobalObject.h"
    #include "JSDOMGlobalObject.h"
    #include "WebCoreJSClientData.h"
    #include "WebCoreJSBuiltins.h"
    #include <JavaScriptCore/JSObjectInlines.h>
    #include "BunBuiltinNames.h"

    namespace WebCore {
        static const Latin1Character combinedSourceCodeBuffer[${combinedSourceCodeLength + 1}] = { ${combinedSourceCodeChars}, 0 };
        static const std::span<const Latin1Character> internalCombinedSource = { combinedSourceCodeBuffer, ${combinedSourceCodeLength} };
    `;

  for (const { basename, functions } of files) {
    bundledCPP += `
#pragma mark ${basename}
`;

    const lowerBasename = low(basename);
    for (const fn of functions) {
      const name = `${basename}${cap(fn.name)}`;
      bundledCPP += `
JSC::FunctionExecutable* ${lowerBasename}${cap(fn.name)}CodeGenerator(JSC::VM& vm)
{
    auto &builtins = static_cast<JSVMClientData*>(vm.clientData)->builtinFunctions().${lowerBasename}Builtins();
    auto *executable = builtins.${lowerBasename}${cap(fn.name)}CodeExecutable();
    return executable->link(vm, nullptr, builtins.${lowerBasename}${cap(fn.name)}CodeSource(), std::nullopt, JSC::NoIntrinsic);
}
`;
    }
  }

  const initializeSourceCodeFn = (fn: BundledBuiltin, basename: string) => {
    const name = `${low(basename)}${cap(fn.name)}CodeSource`;
    return `m_${name}(SourceCode(sourceProvider.copyRef(), ${fn.sourceOffset}, ${fn.source.length + fn.sourceOffset}, 1, 1))`;
  };
  for (const { basename, functions } of files) {
    bundledCPP += `
#pragma mark ${basename}

${basename}BuiltinsWrapper::${basename}BuiltinsWrapper(JSC::VM& vm, RefPtr<JSC::SourceProvider> sourceProvider)
    : m_vm(vm)`;

    bundledCPP += `, ${functions.map(fn => initializeSourceCodeFn(fn, basename)).join(",\n   ")} {}
`;
  }

  bundledCPP += `
RefPtr<JSC::SourceProvider> createBuiltinsSourceProvider() {
    return JSC::StringSourceProvider::create(StringImpl::createWithoutCopying(internalCombinedSource), SourceOrigin(), String(), SourceTaintedOrigin());
}
`;

  bundledCPP += `
JSBuiltinFunctions::JSBuiltinFunctions(JSC::VM& vm, RefPtr<JSC::SourceProvider> provider)
    : ${files.map(({ basename }) => `m_${low(basename)}Builtins(vm, provider)`).join(", ")}
{}
`;

  bundledCPP += `

JSBuiltinInternalFunctions::JSBuiltinInternalFunctions(JSC::VM& vm) : m_vm(vm)
    `;

  for (const { basename, internal } of files) {
    if (internal) {
      bundledCPP += `    , m_${low(basename)}(vm)\n`;
    }
  }

  bundledCPP += `{
      UNUSED_PARAM(vm);
  }

    template<typename Visitor>
    void JSBuiltinInternalFunctions::visit(Visitor& visitor)
    {
    `;
  for (const { basename, internal } of files) {
    if (internal) bundledCPP += `    m_${low(basename)}.visit(visitor);\n`;
  }

  bundledCPP += `
        UNUSED_PARAM(visitor);
    }

    template void JSBuiltinInternalFunctions::visit(AbstractSlotVisitor&);
    template void JSBuiltinInternalFunctions::visit(SlotVisitor&);
    `;

  for (const { basename, internal } of files) {
    if (internal) {
      bundledCPP += `    template void ${basename}BuiltinFunctions::visit(JSC::AbstractSlotVisitor&);
    template void ${basename}BuiltinFunctions::visit(JSC::SlotVisitor&);
`;
    }
  }

  bundledCPP += `
    SUPPRESS_ASAN void JSBuiltinInternalFunctions::initialize(Zig::GlobalObject& globalObject)
    {
        UNUSED_PARAM(globalObject);
    `;

  for (const { basename, internal } of files) {
    if (internal) {
      bundledCPP += `    m_${low(basename)}.init(globalObject);\n`;
    }
  }

  bundledCPP += `
        JSVMClientData& clientData = *static_cast<JSVMClientData*>(m_vm.clientData);
        Zig::GlobalObject::GlobalPropertyInfo staticGlobals[] = {
    `;

  for (const { basename, internal } of files) {
    if (internal) {
      bundledCPP += `#define DECLARE_GLOBAL_STATIC(name) \\
        Zig::GlobalObject::GlobalPropertyInfo( \\
            clientData.builtinNames().name##PrivateName(), ${low(basename)}().m_##name##Function.get() , JSC::PropertyAttribute::DontDelete | JSC::PropertyAttribute::ReadOnly),
        WEBCORE_FOREACH_${basename.toUpperCase()}_BUILTIN_FUNCTION_NAME(DECLARE_GLOBAL_STATIC)
      #undef DECLARE_GLOBAL_STATIC
      `;
    }
  }

  bundledCPP += `
        };
        globalObject.addStaticGlobals(staticGlobals);
        UNUSED_PARAM(clientData);
    }

    } // namespace WebCore
    `;

  // C++ Header codegen
  let bundledHeader = `// Generated by ${import.meta.path}
    // Do not edit by hand.
    #pragma once
    namespace Zig { class GlobalObject; }
    #include "root.h"
    #include <JavaScriptCore/BuiltinUtils.h>
    #include <JavaScriptCore/Identifier.h>
    #include <JavaScriptCore/JSFunction.h>
    #include <JavaScriptCore/UnlinkedFunctionExecutable.h>
    #include <JavaScriptCore/VM.h>
    #include <JavaScriptCore/WeakInlines.h>

    namespace JSC {
    class FunctionExecutable;
    }

    namespace WebCore {
    `;
  for (const { basename, functions, internal } of files) {
    bundledHeader += `/* ${basename}.ts */
    `;
    const lowerBasename = low(basename);

    for (const fn of functions) {
      const name = `${lowerBasename}${cap(fn.name)}Code`;
      bundledHeader += `// ${fn.name}
    #define WEBCORE_BUILTIN_${basename.toUpperCase()}_${fn.name.toUpperCase()} 1
    static constexpr JSC::ConstructAbility s_${name}ConstructAbility = JSC::ConstructAbility::${fn.constructAbility};
    static constexpr JSC::InlineAttribute s_${name}InlineAttribute = JSC::InlineAttribute::${fn.directives.alwaysInline ? "Always" : "None"};
    static constexpr JSC::ConstructorKind s_${name}ConstructorKind = JSC::ConstructorKind::${fn.constructKind};
    static constexpr JSC::ImplementationVisibility s_${name}ImplementationVisibility = JSC::ImplementationVisibility::${fn.visibility};

    `;
    }
    bundledHeader += `#define WEBCORE_FOREACH_${basename.toUpperCase()}_BUILTIN_DATA(macro) \\\n`;
    for (const fn of functions) {
      bundledHeader += `    macro(${fn.name}, ${lowerBasename}${cap(fn.name)}, ${fn.params.length}) \\\n`;
    }
    bundledHeader += "\n";
    bundledHeader += `#define WEBCORE_FOREACH_${basename.toUpperCase()}_BUILTIN_CODE(macro) \\\n`;
    for (const fn of functions) {
      const name = `${lowerBasename}${cap(fn.name)}Code`;
      bundledHeader += `    macro(${name}, ${fn.name}, ${fn.overriddenName}, s_${name}Length) \\\n`;
    }
    bundledHeader += "\n";
    bundledHeader += `#define WEBCORE_FOREACH_${basename.toUpperCase()}_BUILTIN_FUNCTION_NAME(macro) \\\n`;
    for (const fn of functions) {
      bundledHeader += `    macro(${fn.name}) \\\n`;
    }
    bundledHeader += `
    #define DECLARE_BUILTIN_GENERATOR(codeName, functionName, overriddenName, argumentCount) \\
        JSC::FunctionExecutable* codeName##Generator(JSC::VM&);

    WEBCORE_FOREACH_${basename.toUpperCase()}_BUILTIN_CODE(DECLARE_BUILTIN_GENERATOR)
    #undef DECLARE_BUILTIN_GENERATOR

    class ${basename}BuiltinsWrapper : private JSC::WeakHandleOwner {
    public:
        explicit ${basename}BuiltinsWrapper(JSC::VM& vm, RefPtr<JSC::SourceProvider> sourceProvider);

    #define EXPOSE_BUILTIN_EXECUTABLES(name, functionName, overriddenName, length) \\
        JSC::UnlinkedFunctionExecutable* name##Executable(); \\
        const JSC::SourceCode& name##Source() const { return m_##name##Source; }
        WEBCORE_FOREACH_${basename.toUpperCase()}_BUILTIN_CODE(EXPOSE_BUILTIN_EXECUTABLES)
    #undef EXPOSE_BUILTIN_EXECUTABLES

    private:
        [[maybe_unused]] JSC::VM& m_vm;

    #define DECLARE_BUILTIN_SOURCE_MEMBERS(name, functionName, overriddenName, length) \\
        JSC::SourceCode m_##name##Source;\\
        JSC::Weak<JSC::UnlinkedFunctionExecutable> m_##name##Executable;
        WEBCORE_FOREACH_${basename.toUpperCase()}_BUILTIN_CODE(DECLARE_BUILTIN_SOURCE_MEMBERS)
    #undef DECLARE_BUILTIN_SOURCE_MEMBERS

    };

    #define DEFINE_BUILTIN_EXECUTABLES(name, functionName, overriddenName, length) \\
    inline JSC::UnlinkedFunctionExecutable* ${basename}BuiltinsWrapper::name##Executable() \\
    {\\
        if (!m_##name##Executable) {\\
            auto executableName = JSC::Identifier::fromString(m_vm, overriddenName ? overriddenName : #functionName ""_s);\\
            m_##name##Executable = JSC::Weak<JSC::UnlinkedFunctionExecutable>(JSC::createBuiltinExecutable(m_vm, m_##name##Source, executableName, s_##name##ImplementationVisibility, s_##name##ConstructorKind, s_##name##ConstructAbility, s_##name##InlineAttribute), this, &m_##name##Executable);\\
        }\\
        return m_##name##Executable.get();\\
    }
    WEBCORE_FOREACH_${basename.toUpperCase()}_BUILTIN_CODE(DEFINE_BUILTIN_EXECUTABLES)
    #undef DEFINE_BUILTIN_EXECUTABLES

    `;

    if (internal) {
      bundledHeader += `class ${basename}BuiltinFunctions {
    public:
        explicit ${basename}BuiltinFunctions(JSC::VM& vm) : m_vm(vm) { }

        void init(JSC::JSGlobalObject&);
        template<typename Visitor> void visit(Visitor&);

    public:
        [[maybe_unused]] JSC::VM& m_vm;

    #define DECLARE_BUILTIN_SOURCE_MEMBERS(functionName) \\
        JSC::WriteBarrier<JSC::JSFunction> m_##functionName##Function;
        WEBCORE_FOREACH_${basename.toUpperCase()}_BUILTIN_FUNCTION_NAME(DECLARE_BUILTIN_SOURCE_MEMBERS)
    #undef DECLARE_BUILTIN_SOURCE_MEMBERS
    };

    inline void ${basename}BuiltinFunctions::init(JSC::JSGlobalObject& globalObject)
    {
    #define EXPORT_FUNCTION(codeName, functionName, overriddenName, length) \\
        m_##functionName##Function.set(m_vm, &globalObject, JSC::JSFunction::create(m_vm, &globalObject, codeName##Generator(m_vm), &globalObject));
        WEBCORE_FOREACH_${basename.toUpperCase()}_BUILTIN_CODE(EXPORT_FUNCTION)
    #undef EXPORT_FUNCTION
    }

    template<typename Visitor>
    inline void ${basename}BuiltinFunctions::visit(Visitor& visitor)
    {
    #define VISIT_FUNCTION(name) visitor.append(m_##name##Function);
        WEBCORE_FOREACH_${basename.toUpperCase()}_BUILTIN_FUNCTION_NAME(VISIT_FUNCTION)
    #undef VISIT_FUNCTION
    }

    extern template void ${basename}BuiltinFunctions::visit(JSC::AbstractSlotVisitor&);
    extern template void ${basename}BuiltinFunctions::visit(JSC::SlotVisitor&);
        `;
    }
  }
  bundledHeader += `class JSBuiltinFunctions {
        WTF_DEPRECATED_MAKE_FAST_ALLOCATED(JSBuiltinFunctions);
    public:
        explicit JSBuiltinFunctions(JSC::VM& vm, RefPtr<JSC::SourceProvider> provider);

    `;

  for (const { basename } of files) {
    bundledHeader += `    ${basename}BuiltinsWrapper& ${low(basename)}Builtins() { return m_${low(
      basename,
    )}Builtins; }\n`;
  }

  bundledHeader += `
    private:
    `;

  for (const { basename } of files) {
    bundledHeader += `    ${basename}BuiltinsWrapper m_${low(basename)}Builtins;\n`;
  }

  bundledHeader += `;
    };

    class JSBuiltinInternalFunctions {
        WTF_DEPRECATED_MAKE_FAST_ALLOCATED(JSBuiltinInternalFunctions);
    public:
        explicit JSBuiltinInternalFunctions(JSC::VM&);

        template<typename Visitor> void visit(Visitor&);
        void initialize(Zig::GlobalObject&);
    `;

  for (const { basename, internal } of files) {
    if (internal) {
      bundledHeader += `    ${basename}BuiltinFunctions& ${low(basename)}() { return m_${low(basename)}; }\n`;
    }
  }

  bundledHeader += `
    private:
        [[maybe_unused]] JSC::VM& m_vm;
    `;

  for (const { basename, internal } of files) {
    if (internal) {
      bundledHeader += `    ${basename}BuiltinFunctions m_${low(basename)};\n`;
    }
  }

  bundledHeader += `
    };

    } // namespace WebCore
    `;
  // Handle builtin names
  {
    const BunBuiltinNamesHeader = require("fs").readFileSync(
      path.join(import.meta.dir, "../js/builtins/BunBuiltinNames.h"),
      "utf8",
    );
    let definedBuiltinNamesStartI = BunBuiltinNamesHeader.indexOf(
      "#define BUN_COMMON_PRIVATE_IDENTIFIERS_EACH_PROPERTY_NAME",
    );
    let definedBuiltinNamesMacroEndI = BunBuiltinNamesHeader.indexOf(
      "--- END of BUN_COMMON_PRIVATE_IDENTIFIERS_EACH_PROPERTY_NAME ---",
    );
    const definedBuiltinNames = BunBuiltinNamesHeader.slice(definedBuiltinNamesStartI, definedBuiltinNamesMacroEndI)
      .split("\n")
      .map(x => x.trim())
      .filter(x => x.startsWith("macro("))
      .map(x => x.slice(x.indexOf("(") + 1, x.indexOf(")")))
      .map(x => x.trim())
      .sort();

    const uniqueDefinedBuiltinNames = new Set();
    for (let name of definedBuiltinNames) {
      const prevSize = uniqueDefinedBuiltinNames.size;
      uniqueDefinedBuiltinNames.add(name);
      if (uniqueDefinedBuiltinNames.size === prevSize) {
        throw new Error(`Duplicate private name "${name}" in BunBuiltinNames.h`);
      }
    }
    for (let additionalPrivateName of additionalPrivateNames) {
      if (uniqueDefinedBuiltinNames.has(additionalPrivateName)) {
        additionalPrivateNames.delete(additionalPrivateName);
      }
    }

    let additionalPrivateNamesHeader = `// Generated by ${import.meta.path}
#pragma once

#ifndef BUN_ADDITIONAL_BUILTIN_NAMES
#define BUN_ADDITIONAL_BUILTIN_NAMES(macro) \\
  ${Array.from(additionalPrivateNames)
    .map(x => `macro(${x})`)
    .join(" \\\n  ")}
#endif
`;

    writeIfNotChanged(path.join(CODEGEN_DIR, "BunBuiltinNames+extras.h"), additionalPrivateNamesHeader);
  }
  writeIfNotChanged(path.join(CODEGEN_DIR, "WebCoreJSBuiltins.h"), bundledHeader);
  writeIfNotChanged(path.join(CODEGEN_DIR, "WebCoreJSBuiltins.cpp"), bundledCPP);

  // Generate TS types
  let dts = `// Generated by \`bun src/js/builtins/codegen\`
    // Do not edit by hand.
    type RemoveThis<F> = F extends (this: infer T, ...args: infer A) => infer R ? (...args: A) => R : F;
    `;

  for (const { basename, functions, internal } of files) {
    if (internal) {
      dts += `\n// ${basename}.ts\n`;
      for (const fn of functions) {
        dts += `declare const \$${fn.name}: RemoveThis<typeof import("${path.relative(
          CODEGEN_DIR,
          path.join(SRC_DIR, basename),
        )}")[${JSON.stringify(fn.name)}]>;\n`;
      }
    }
  }

  writeIfNotChanged(path.join(CODEGEN_DIR, "WebCoreJSBuiltins.d.ts"), dts);

  const totalJSSize = files.reduce(
    (acc, { functions }) => acc + functions.reduce((acc, fn) => acc + fn.source.length, 0),
    0,
  );

  if (!KEEP_TMP) {
    await rmSync(TMP_DIR, { recursive: true });
  }

  globalThis.internalFunctionJSSize = totalJSSize;
  globalThis.internalFunctionCount = files.reduce((acc, { functions }) => acc + functions.length, 0);
  globalThis.internalFunctionFileCount = files.length;
}
