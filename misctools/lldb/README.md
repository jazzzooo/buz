# LLDB Pretty Printers for Bun

This directory contains LLDB pretty printers for various Bun data structures to improve the debugging experience.

## Files

- `bun_pretty_printer.py` - Pretty printers for Bun-specific types (bun.String, WTFStringImpl, BabyList)
- `lldb_pretty_printers.py` - Pretty printers for Zig language types from the Zig project
- `lldb_webkit.py` - Pretty printers for WebKit/JavaScriptCore types
- `init.lldb` - LLDB initialization commands

## Supported Types

### bun.String Types
- `bun.String` (`string.string.String` in Zig debug information) - The main Zig string type
- `WTFStringImpl` / `WTFStringImplStruct` - Opaque Zig handles to WebKit strings (Latin1/UTF16)

The Bun category matches these types explicitly. WebKit's own string types use
the separate formatters in `lldb_webkit.py`.

### Display Format

The pretty printers show string content directly, with additional metadata:

```
[latin1] "Hello, World!"
[utf16] "Unicode string 🎉"
""                                # Empty bun.String
<dead>                            # Dead/invalid string tag
<null string>                     # Null implementation handle
```

Long strings display at most 200 Unicode characters, followed by `<truncated>`.
Their `length` metadata counts the original Latin1 or UTF16 code units. Memory
reads are bounded by the display limit, and control characters are escaped.

## Usage

### Option 1: Manual Loading
In your LLDB session:
```lldb
command script import /path/to/bun/misctools/lldb/bun_pretty_printer.py
```

### Option 2: Add to ~/.lldbinit
Add the following line to your `~/.lldbinit` file to load automatically:
```lldb
command script import /path/to/bun/misctools/lldb/bun_pretty_printer.py
```

### Option 3: Use init.lldb
```lldb
command source /path/to/bun/misctools/lldb/init.lldb
```

## Testing

To test the pretty printers:

1. Build a debug version of Bun:
```bash
./zig build
```

2. Debug a JavaScript program with LLDB:
```bash
lldb ./zig-out/bin/bun-debug
(lldb) command script import misctools/lldb/bun_pretty_printer.py
(lldb) breakpoint set --file <native_source_file> --line <line_number>
(lldb) run your_script.js
(lldb) frame variable
```

Keep `bun-debug.dbg` beside the executable so LLDB can load the debug symbols.

## Implementation Details

### Opaque String Handles

The formatter reads the engine-exported `Bun__WTFStringImpl__lengthOffset`,
`dataOffset`, `flagsOffset`, and `flagIs8Bit` constants from the stopped target.
It does not require fields on the Zig opaque type or call into the debuggee.
UTF16 decoding uses the target's byte order. Missing symbols and unreadable
memory produce an explicit `<string unavailable: ...>` summary.

### bun.String Tag Union
bun.String is a tagged union with these variants:
- Dead (0): Invalid/freed string
- WTFStringImpl (1): WebKit string
- Empty (4): Empty string ""

The Zig wrapper stores its handle in `value.WTFStringImpl`.

## Troubleshooting

If the pretty printers don't work:

1. Verify the Python script loaded:
```lldb
(lldb) script print("Python works")
```

2. Check if the category is enabled:
```lldb
(lldb) type category list
```

3. Enable the Bun category manually:
```lldb
(lldb) type category enable bun
```

4. For `<string unavailable: ...>`, check the reported symbol or memory error.
   The string formatters report failures rather than treating failed reads as
   empty strings.
