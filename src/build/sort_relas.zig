//! Sorts every SHT_RELA section of an ELF64 relocatable object by r_offset
//! and writes the result to a second path.
//!
//!   sort-relas <in.o> <out.o>
//!
//! The incremental ELF flush (zig-upstream/src/link/Elf2.zig) emits rela
//! sections out of offset order, and mold rejects a TLS group (TLSLD + its
//! __tls_get_addr PLT32 call) that is not adjacent and in order — with or
//! without relaxation. Offset order is the layout a from-scratch flush
//! produces.

const std = @import("std");
const elf = std.elf;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    const usage = "usage: sort-relas <in.o> <out.o>";
    const in_path = args.next() orelse @panic(usage);
    const out_path = args.next() orelse @panic(usage);

    const cwd = std.Io.Dir.cwd();
    const buf = try cwd.readFileAlloc(io, in_path, gpa, .unlimited);
    defer gpa.free(buf);

    try sortRelaSections(gpa, buf);

    var out = try cwd.createFileAtomic(io, out_path, .{ .make_path = true, .replace = true });
    defer out.deinit(io);
    try out.file.writeStreamingAll(io, buf);
    try out.replace(io);
}

fn sortRelaSections(gpa: std.mem.Allocator, buf: []u8) !void {
    if (!std.mem.startsWith(u8, buf, elf.MAGIC)) @panic("not an ELF file");
    if (buf[elf.EI_CLASS] != elf.ELFCLASS64 or buf[elf.EI_DATA] != elf.ELFDATA2LSB)
        @panic("expected little-endian ELF64");
    const ehdr = std.mem.bytesAsValue(elf.Elf64_Ehdr, buf[0..@sizeOf(elf.Elf64_Ehdr)]);

    const shoff: usize = @intCast(ehdr.e_shoff);
    // Extended numbering: the real count lives in section 0's sh_size.
    const shnum: usize = if (ehdr.e_shnum != 0) ehdr.e_shnum else @intCast(shdrAt(buf, shoff).sh_size);

    for (0..shnum) |i| {
        const shdr = shdrAt(buf, shoff + i * ehdr.e_shentsize);
        if (shdr.sh_type != elf.SHT_RELA) continue;
        if (shdr.sh_entsize != @sizeOf(elf.Elf64_Rela)) @panic("unexpected rela entry size");
        const bytes = buf[@intCast(shdr.sh_offset)..][0..@intCast(shdr.sh_size)];

        // sh_offset carries no alignment guarantee, so sort an aligned copy.
        // Stable, so same-offset relocations keep their order.
        const entries = try gpa.alloc(elf.Elf64_Rela, bytes.len / @sizeOf(elf.Elf64_Rela));
        defer gpa.free(entries);
        @memcpy(std.mem.sliceAsBytes(entries), bytes);
        std.mem.sort(elf.Elf64_Rela, entries, {}, lessByOffset);
        @memcpy(bytes, std.mem.sliceAsBytes(entries));
    }
}

fn shdrAt(buf: []const u8, offset: usize) *align(1) const elf.Elf64_Shdr {
    return std.mem.bytesAsValue(elf.Elf64_Shdr, buf[offset..][0..@sizeOf(elf.Elf64_Shdr)]);
}

fn lessByOffset(_: void, a: elf.Elf64_Rela, b: elf.Elf64_Rela) bool {
    return a.r_offset < b.r_offset;
}
