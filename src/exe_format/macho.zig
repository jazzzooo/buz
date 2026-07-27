const std = @import("std");

const bun = @import("bun");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const macho = std.macho;
const mem = std.mem;

const bun_segment_name = "__BUN";
const bun_section_name = "__bun";
const linkedit_segment_name = "__LINKEDIT";
const text_segment_name = "__TEXT";

const bun_alignment: usize = 0x4000;
const signature_alignment: usize = 16;
const signature_identifier = "a.out";

pub fn embedStandalone(
    allocator: Allocator,
    object: []const u8,
    payload: []const u8,
    expected_cpu: macho.cpu_type_t,
) ![]u8 {
    const template = try Template.parse(object, expected_cpu);
    const plan = try EmbedPlan.init(&template, payload.len);
    return plan.emit(allocator, &template, payload);
}

fn Located(comptime T: type) type {
    return struct {
        offset: usize,
        value: T,
    };
}

const LocatedSegment = Located(macho.segment_command_64);
const LocatedSection = Located(macho.section_64);

const FileRange = struct {
    start: usize,
    end: usize,

    fn init(start: u64, size: u64, file_size: usize) !FileRange {
        const end = std.math.add(u64, start, size) catch return error.OffsetOverflow;
        if (end > file_size) return error.OffsetOutOfRange;
        return .{
            .start = std.math.cast(usize, start) orelse return error.OffsetOverflow,
            .end = std.math.cast(usize, end) orelse return error.OffsetOverflow,
        };
    }

    fn len(range: FileRange) usize {
        return range.end - range.start;
    }

    fn contains(range: FileRange, other: FileRange) bool {
        return other.start >= range.start and other.end <= range.end;
    }
};

const Template = struct {
    bytes: []const u8,
    header: macho.mach_header_64,
    bun_segment: LocatedSegment,
    bun_section: LocatedSection,
    linkedit_segment: LocatedSegment,
    text_segment: ?macho.segment_command_64,
    code_signature: ?macho.linkedit_data_command,
    bun_range: FileRange,
    linkedit_range: FileRange,

    fn parse(bytes: []const u8, expected_cpu: macho.cpu_type_t) !Template {
        var reader = std.Io.Reader.fixed(bytes);
        const header = reader.takeStruct(macho.mach_header_64, .little) catch |err| switch (err) {
            error.ReadFailed => unreachable,
            error.EndOfStream => return error.InvalidMachO,
        };

        if (header.magic != macho.MH_MAGIC_64) return error.InvalidMachO;
        if (expected_cpu != macho.CPU_TYPE_X86_64 and
            expected_cpu != macho.CPU_TYPE_ARM64)
        {
            return error.InvalidObject;
        }
        if (header.filetype != macho.MH_EXECUTE or header.cputype != expected_cpu) {
            return error.InvalidObject;
        }

        var iterator = try macho.LoadCommandIterator.init(
            &header,
            bytes[@sizeOf(macho.mach_header_64)..],
        );
        var bun_segment: ?LocatedSegment = null;
        var bun_section: ?LocatedSection = null;
        var linkedit_segment: ?LocatedSegment = null;
        var text_segment: ?macho.segment_command_64 = null;
        var code_signature: ?macho.linkedit_data_command = null;
        var max_other_file_end: usize = 0;
        var max_other_vm_end: u64 = 0;
        var previous_file_end: usize = 0;

        while (true) {
            const command_offset = @sizeOf(macho.mach_header_64) + iterator.r.seek;
            const entry = try iterator.next() orelse break;
            if (entry.hdr.cmdsize < @sizeOf(macho.load_command) or
                entry.hdr.cmdsize % @alignOf(u64) != 0)
            {
                return error.InvalidMachO;
            }

            switch (entry.hdr.cmd) {
                .SEGMENT_64 => {
                    const segment = entry.cast(macho.segment_command_64) orelse
                        return error.InvalidMachO;
                    const section_bytes = std.math.mul(
                        usize,
                        std.math.cast(usize, segment.nsects) orelse return error.InvalidMachO,
                        @sizeOf(macho.section_64),
                    ) catch return error.InvalidMachO;
                    const expected_size = std.math.add(
                        usize,
                        @sizeOf(macho.segment_command_64),
                        section_bytes,
                    ) catch return error.InvalidMachO;
                    if (entry.data.len != expected_size) return error.InvalidMachO;

                    const segment_range = try FileRange.init(
                        segment.fileoff,
                        segment.filesize,
                        bytes.len,
                    );
                    const segment_vm_end = std.math.add(
                        u64,
                        segment.vmaddr,
                        segment.vmsize,
                    ) catch return error.OffsetOverflow;
                    if (segment.vmsize < segment.filesize) return error.InvalidObject;
                    if (segment_range.len() > 0) {
                        if (segment_range.start < previous_file_end) {
                            return error.OverlappingSegments;
                        }
                        previous_file_end = segment_range.end;
                    }
                    const is_bun = mem.eql(u8, segment.segName(), bun_segment_name);
                    const is_linkedit = mem.eql(
                        u8,
                        segment.segName(),
                        linkedit_segment_name,
                    );
                    const is_text = mem.eql(u8, segment.segName(), text_segment_name);

                    var only_bun_section: ?LocatedSection = null;
                    for (entry.getSections(), 0..) |section, section_index| {
                        const section_offset = command_offset +
                            @sizeOf(macho.segment_command_64) +
                            section_index * @sizeOf(macho.section_64);
                        const section_vm_end = std.math.add(
                            u64,
                            section.addr,
                            section.size,
                        ) catch return error.OffsetOverflow;
                        if (section.addr < segment.vmaddr or section_vm_end > segment_vm_end) {
                            return error.OffsetOutOfRange;
                        }

                        if (!section.isZerofill() and section.size > 0) {
                            const section_range = try FileRange.init(
                                section.offset,
                                section.size,
                                bytes.len,
                            );
                            if (!segment_range.contains(section_range)) {
                                return error.OffsetOutOfRange;
                            }
                        }

                        if (is_bun) {
                            if (!mem.eql(u8, section.sectName(), bun_section_name) or
                                !mem.eql(u8, section.segName(), bun_segment_name))
                            {
                                return error.InvalidObject;
                            }
                            only_bun_section = .{
                                .offset = section_offset,
                                .value = section,
                            };
                        }
                    }

                    if (is_bun) {
                        if (bun_segment != null or segment.nsects != 1) {
                            return error.InvalidObject;
                        }
                        bun_segment = .{ .offset = command_offset, .value = segment };
                        bun_section = only_bun_section orelse return error.InvalidObject;
                    } else if (is_linkedit) {
                        if (linkedit_segment != null) return error.InvalidObject;
                        linkedit_segment = .{ .offset = command_offset, .value = segment };
                    } else {
                        max_other_file_end = @max(max_other_file_end, segment_range.end);
                        max_other_vm_end = @max(max_other_vm_end, segment_vm_end);
                    }

                    if (is_text) {
                        if (text_segment != null) return error.InvalidObject;
                        text_segment = segment;
                    }
                },
                .CODE_SIGNATURE => {
                    const command = entry.cast(macho.linkedit_data_command) orelse
                        return error.InvalidMachO;
                    if (code_signature != null) return error.InvalidObject;
                    code_signature = command;
                },
                else => {},
            }
        }
        if (iterator.r.seek != iterator.r.end) return error.InvalidMachO;

        const commands_end = std.math.add(
            usize,
            @sizeOf(macho.mach_header_64),
            header.sizeofcmds,
        ) catch return error.InvalidMachO;
        const found_bun_segment = bun_segment orelse return error.InvalidObject;
        const found_bun_section = bun_section orelse return error.InvalidObject;
        const found_linkedit = linkedit_segment orelse
            return error.MissingLinkeditSegment;
        const bun_range = try FileRange.init(
            found_bun_segment.value.fileoff,
            found_bun_segment.value.filesize,
            bytes.len,
        );
        const linkedit_range = try FileRange.init(
            found_linkedit.value.fileoff,
            found_linkedit.value.filesize,
            bytes.len,
        );
        const target_page_size = pageSize(expected_cpu);

        if (bun_range.len() == 0 or
            found_bun_segment.value.fileoff != found_bun_section.value.offset or
            found_bun_segment.value.vmaddr != found_bun_section.value.addr or
            found_bun_section.value.size == 0 or
            found_bun_section.value.size > found_bun_segment.value.filesize or
            bun_range.start < commands_end or
            bun_range.start % bun_alignment != 0 or
            bun_range.len() % target_page_size != 0 or
            found_bun_segment.value.vmsize % target_page_size != 0)
        {
            return error.InvalidObject;
        }

        const bun_vm_end = std.math.add(
            u64,
            found_bun_segment.value.vmaddr,
            found_bun_segment.value.vmsize,
        ) catch return error.OffsetOverflow;
        if (max_other_file_end > bun_range.start or
            max_other_vm_end > found_bun_segment.value.vmaddr or
            linkedit_range.start < bun_range.end or
            found_linkedit.value.vmaddr < bun_vm_end or
            linkedit_range.end != bytes.len)
        {
            return error.OffsetOutOfRange;
        }

        const result: Template = .{
            .bytes = bytes,
            .header = header,
            .bun_segment = found_bun_segment,
            .bun_section = found_bun_section,
            .linkedit_segment = found_linkedit,
            .text_segment = text_segment,
            .code_signature = code_signature,
            .bun_range = bun_range,
            .linkedit_range = linkedit_range,
        };
        try result.validateLinkeditReferences();
        return result;
    }

    fn loadCommands(template: *const Template) !macho.LoadCommandIterator {
        return macho.LoadCommandIterator.init(
            &template.header,
            template.bytes[@sizeOf(macho.mach_header_64)..],
        );
    }

    fn validateLinkeditReferences(template: *const Template) !void {
        var iterator = try template.loadCommands();
        while (try iterator.next()) |entry| {
            switch (entry.hdr.cmd) {
                .SEGMENT_64 => {
                    for (entry.getSections()) |section| {
                        const reloc_size = std.math.mul(
                            u64,
                            section.nreloc,
                            @sizeOf(macho.relocation_info),
                        ) catch return error.OffsetOverflow;
                        try validateLinkeditRange(
                            section.reloff,
                            reloc_size,
                            template.linkedit_range,
                        );
                    }
                },
                .SYMTAB => {
                    const command = entry.cast(macho.symtab_command) orelse
                        return error.InvalidMachO;
                    const symbols_size = std.math.mul(
                        u64,
                        command.nsyms,
                        @sizeOf(macho.nlist_64),
                    ) catch return error.OffsetOverflow;
                    try validateLinkeditRange(
                        command.symoff,
                        symbols_size,
                        template.linkedit_range,
                    );
                    try validateLinkeditRange(
                        command.stroff,
                        command.strsize,
                        template.linkedit_range,
                    );
                },
                .DYSYMTAB => {
                    const command = entry.cast(macho.dysymtab_command) orelse
                        return error.InvalidMachO;
                    try validateLinkeditOffset(command.tocoff, template.linkedit_range);
                    try validateLinkeditOffset(command.modtaboff, template.linkedit_range);
                    try validateLinkeditOffset(command.extrefsymoff, template.linkedit_range);
                    try validateLinkeditRange(
                        command.indirectsymoff,
                        std.math.mul(
                            u64,
                            command.nindirectsyms,
                            @sizeOf(u32),
                        ) catch return error.OffsetOverflow,
                        template.linkedit_range,
                    );
                    try validateLinkeditRange(
                        command.extreloff,
                        std.math.mul(
                            u64,
                            command.nextrel,
                            @sizeOf(macho.relocation_info),
                        ) catch return error.OffsetOverflow,
                        template.linkedit_range,
                    );
                    try validateLinkeditRange(
                        command.locreloff,
                        std.math.mul(
                            u64,
                            command.nlocrel,
                            @sizeOf(macho.relocation_info),
                        ) catch return error.OffsetOverflow,
                        template.linkedit_range,
                    );
                },
                .DYLD_INFO, .DYLD_INFO_ONLY => {
                    const command = entry.cast(macho.dyld_info_command) orelse
                        return error.InvalidMachO;
                    try validateLinkeditRange(
                        command.rebase_off,
                        command.rebase_size,
                        template.linkedit_range,
                    );
                    try validateLinkeditRange(
                        command.bind_off,
                        command.bind_size,
                        template.linkedit_range,
                    );
                    try validateLinkeditRange(
                        command.weak_bind_off,
                        command.weak_bind_size,
                        template.linkedit_range,
                    );
                    try validateLinkeditRange(
                        command.lazy_bind_off,
                        command.lazy_bind_size,
                        template.linkedit_range,
                    );
                    try validateLinkeditRange(
                        command.export_off,
                        command.export_size,
                        template.linkedit_range,
                    );
                },
                else => if (isLinkeditDataCommand(entry.hdr.cmd)) {
                    const command = entry.cast(macho.linkedit_data_command) orelse
                        return error.InvalidMachO;
                    try validateLinkeditRange(
                        command.dataoff,
                        command.datasize,
                        template.linkedit_range,
                    );
                },
            }
        }
    }
};

const EmbedPlan = struct {
    bun_segment: macho.segment_command_64,
    bun_section: macho.section_64,
    linkedit_segment: macho.segment_command_64,
    bun_size: usize,
    file_delta: usize,
    output_size: usize,
    signature: ?AdhocSignaturePlan,

    fn init(template: *const Template, payload_size: usize) !EmbedPlan {
        const content_size = std.math.add(usize, @sizeOf(u64), payload_size) catch
            return error.OffsetOverflow;
        const new_bun_size = try alignForward(usize, content_size, bun_alignment);
        const old_bun_size = template.bun_range.len();
        if (new_bun_size < old_bun_size) return error.InvalidObject;
        const file_delta = new_bun_size - old_bun_size;

        const old_bun_vm_size = std.math.cast(
            usize,
            template.bun_segment.value.vmsize,
        ) orelse return error.OffsetOverflow;
        if (new_bun_size < old_bun_vm_size) return error.InvalidObject;
        const vm_delta = new_bun_size - old_bun_vm_size;

        var bun_segment = template.bun_segment.value;
        bun_segment.vmsize = new_bun_size;
        bun_segment.filesize = new_bun_size;
        bun_segment.maxprot = .{ .READ = true, .WRITE = true };
        bun_segment.initprot = .{ .READ = true, .WRITE = true };

        var bun_section = template.bun_section.value;
        bun_section.size = content_size;
        bun_section.@"align" = @intCast(std.math.log2(bun_alignment));
        bun_section.reloff = 0;
        bun_section.nreloc = 0;
        bun_section.flags = macho.S_REGULAR | macho.S_ATTR_NO_DEAD_STRIP;
        bun_section.reserved1 = 0;
        bun_section.reserved2 = 0;
        bun_section.reserved3 = 0;

        var linkedit_segment = template.linkedit_segment.value;
        linkedit_segment.fileoff = std.math.add(
            u64,
            linkedit_segment.fileoff,
            file_delta,
        ) catch return error.OffsetOverflow;
        linkedit_segment.vmaddr = std.math.add(
            u64,
            linkedit_segment.vmaddr,
            vm_delta,
        ) catch return error.OffsetOverflow;

        const should_sign = template.header.cputype == macho.CPU_TYPE_ARM64 and
            !bun.feature_flag.BUN_NO_CODESIGN_MACHO_BINARY.get();
        var signature: ?AdhocSignaturePlan = null;
        var output_size = std.math.add(usize, template.bytes.len, file_delta) catch
            return error.OffsetOverflow;

        if (should_sign) {
            const target_page_size = pageSize(template.header.cputype);
            const old_signature = template.code_signature orelse
                return error.MissingRequiredSegment;
            const old_signature_range = try FileRange.init(
                old_signature.dataoff,
                old_signature.datasize,
                template.bytes.len,
            );
            if (old_signature_range.end != template.linkedit_range.end or
                old_signature_range.start % signature_alignment != 0)
            {
                return error.InvalidObject;
            }

            const signature_start = std.math.add(
                usize,
                old_signature_range.start,
                file_delta,
            ) catch return error.OffsetOverflow;
            const text = template.text_segment orelse
                return error.MissingRequiredSegment;
            const signature_plan = try AdhocSignaturePlan.init(
                signature_start,
                target_page_size,
                text.fileoff,
                text.filesize,
            );
            signature = signature_plan;

            const linkedit_prefix_size =
                old_signature_range.start - template.linkedit_range.start;
            linkedit_segment.filesize = std.math.add(
                u64,
                linkedit_prefix_size,
                signature_plan.storage_size,
            ) catch return error.OffsetOverflow;
            linkedit_segment.vmsize = try alignForward(
                u64,
                linkedit_segment.filesize,
                target_page_size,
            );
            output_size = std.math.add(
                usize,
                signature_start,
                signature_plan.storage_size,
            ) catch return error.OffsetOverflow;
        }

        return .{
            .bun_segment = bun_segment,
            .bun_section = bun_section,
            .linkedit_segment = linkedit_segment,
            .bun_size = new_bun_size,
            .file_delta = file_delta,
            .output_size = output_size,
            .signature = signature,
        };
    }

    fn emit(
        plan: *const EmbedPlan,
        allocator: Allocator,
        template: *const Template,
        payload: []const u8,
    ) ![]u8 {
        const output = try allocator.alloc(u8, plan.output_size);
        errdefer allocator.free(output);
        @memset(output, 0);

        @memcpy(output[0..template.bun_range.start], template.bytes[0..template.bun_range.start]);
        std.mem.writeInt(
            u64,
            output[template.bun_range.start..][0..@sizeOf(u64)],
            payload.len,
            .little,
        );
        @memcpy(
            output[template.bun_range.start + @sizeOf(u64) ..][0..payload.len],
            payload,
        );

        const suffix_end = if (plan.signature) |_|
            std.math.cast(
                usize,
                template.code_signature.?.dataoff,
            ) orelse return error.OffsetOverflow
        else
            template.bytes.len;
        const new_bun_end = template.bun_range.start + plan.bun_size;
        @memcpy(
            output[new_bun_end..][0 .. suffix_end - template.bun_range.end],
            template.bytes[template.bun_range.end..suffix_end],
        );

        try plan.patchLoadCommands(template, output);
        if (plan.signature) |signature| try signature.write(output);
        return output;
    }

    fn patchLoadCommands(
        plan: *const EmbedPlan,
        template: *const Template,
        output: []u8,
    ) !void {
        var iterator = try template.loadCommands();
        while (true) {
            const command_offset = @sizeOf(macho.mach_header_64) + iterator.r.seek;
            const entry = try iterator.next() orelse break;
            switch (entry.hdr.cmd) {
                .SEGMENT_64 => {
                    if (command_offset == template.bun_segment.offset) {
                        try writeStructAt(output, command_offset, plan.bun_segment);
                        try writeStructAt(
                            output,
                            template.bun_section.offset,
                            plan.bun_section,
                        );
                        continue;
                    }
                    if (command_offset == template.linkedit_segment.offset) {
                        try writeStructAt(output, command_offset, plan.linkedit_segment);
                        continue;
                    }

                    for (entry.getSections(), 0..) |original_section, section_index| {
                        var section = original_section;
                        section.reloff = try shiftLinkeditOffset(
                            section.reloff,
                            plan.file_delta,
                            template.linkedit_range,
                        );
                        try writeStructAt(
                            output,
                            command_offset +
                                @sizeOf(macho.segment_command_64) +
                                section_index * @sizeOf(macho.section_64),
                            section,
                        );
                    }
                },
                .SYMTAB => {
                    var command = entry.cast(macho.symtab_command).?;
                    command.symoff = try shiftLinkeditOffset(
                        command.symoff,
                        plan.file_delta,
                        template.linkedit_range,
                    );
                    command.stroff = try shiftLinkeditOffset(
                        command.stroff,
                        plan.file_delta,
                        template.linkedit_range,
                    );
                    try writeStructAt(output, command_offset, command);
                },
                .DYSYMTAB => {
                    var command = entry.cast(macho.dysymtab_command).?;
                    inline for (.{
                        "tocoff",
                        "modtaboff",
                        "extrefsymoff",
                        "indirectsymoff",
                        "extreloff",
                        "locreloff",
                    }) |field| {
                        @field(command, field) = try shiftLinkeditOffset(
                            @field(command, field),
                            plan.file_delta,
                            template.linkedit_range,
                        );
                    }
                    try writeStructAt(output, command_offset, command);
                },
                .DYLD_INFO, .DYLD_INFO_ONLY => {
                    var command = entry.cast(macho.dyld_info_command).?;
                    inline for (.{
                        "rebase_off",
                        "bind_off",
                        "weak_bind_off",
                        "lazy_bind_off",
                        "export_off",
                    }) |field| {
                        @field(command, field) = try shiftLinkeditOffset(
                            @field(command, field),
                            plan.file_delta,
                            template.linkedit_range,
                        );
                    }
                    try writeStructAt(output, command_offset, command);
                },
                else => if (isLinkeditDataCommand(entry.hdr.cmd)) {
                    var command = entry.cast(macho.linkedit_data_command).?;
                    command.dataoff = try shiftLinkeditOffset(
                        command.dataoff,
                        plan.file_delta,
                        template.linkedit_range,
                    );
                    if (entry.hdr.cmd == .CODE_SIGNATURE) {
                        if (plan.signature) |signature| {
                            command.dataoff = std.math.cast(
                                u32,
                                signature.start,
                            ) orelse return error.OffsetOverflow;
                            command.datasize = std.math.cast(
                                u32,
                                signature.storage_size,
                            ) orelse return error.OffsetOverflow;
                        }
                    }
                    try writeStructAt(output, command_offset, command);
                },
            }
        }
    }
};

const AdhocSignaturePlan = struct {
    start: usize,
    page_size: usize,
    page_count: usize,
    hash_offset: usize,
    code_directory_size: usize,
    blob_size: usize,
    storage_size: usize,
    text_fileoff: u64,
    text_filesize: u64,

    fn init(
        start: usize,
        target_page_size: usize,
        text_fileoff: u64,
        text_filesize: u64,
    ) !AdhocSignaturePlan {
        if (start % signature_alignment != 0) return error.InvalidObject;
        _ = std.math.cast(u32, start) orelse return error.OffsetOverflow;

        const page_count = std.math.divCeil(
            usize,
            start,
            target_page_size,
        ) catch return error.OffsetOverflow;
        const hash_offset = std.math.add(
            usize,
            @sizeOf(macho.CodeDirectory),
            signature_identifier.len + 1,
        ) catch return error.OffsetOverflow;
        const hashes_size = std.math.mul(
            usize,
            page_count,
            Sha256.digest_length,
        ) catch return error.OffsetOverflow;
        const code_directory_size = std.math.add(
            usize,
            hash_offset,
            hashes_size,
        ) catch return error.OffsetOverflow;
        const blob_size = std.math.add(
            usize,
            @sizeOf(macho.SuperBlob) + @sizeOf(macho.BlobIndex),
            code_directory_size,
        ) catch return error.OffsetOverflow;
        const storage_size = try alignForward(usize, blob_size, @sizeOf(u64));
        _ = std.math.cast(u32, page_count) orelse return error.OffsetOverflow;
        _ = std.math.cast(u32, hash_offset) orelse return error.OffsetOverflow;
        _ = std.math.cast(u32, code_directory_size) orelse return error.OffsetOverflow;
        _ = std.math.cast(u32, blob_size) orelse return error.OffsetOverflow;
        _ = std.math.cast(u32, storage_size) orelse return error.OffsetOverflow;

        return .{
            .start = start,
            .page_size = target_page_size,
            .page_count = page_count,
            .hash_offset = hash_offset,
            .code_directory_size = code_directory_size,
            .blob_size = blob_size,
            .storage_size = storage_size,
            .text_fileoff = text_fileoff,
            .text_filesize = text_filesize,
        };
    }

    fn write(plan: AdhocSignaturePlan, output: []u8) !void {
        const signature_end = std.math.add(
            usize,
            plan.start,
            plan.storage_size,
        ) catch return error.OffsetOverflow;
        if (signature_end != output.len) return error.InvalidObject;

        var writer = std.Io.Writer.fixed(output[plan.start..][0..plan.blob_size]);
        try writer.writeStruct(macho.SuperBlob{
            .magic = macho.CSMAGIC_EMBEDDED_SIGNATURE,
            .length = @intCast(plan.blob_size),
            .count = 1,
        }, .big);
        try writer.writeStruct(macho.BlobIndex{
            .type = macho.CSSLOT_CODEDIRECTORY,
            .offset = @sizeOf(macho.SuperBlob) + @sizeOf(macho.BlobIndex),
        }, .big);
        try writer.writeStruct(macho.CodeDirectory{
            .magic = macho.CSMAGIC_CODEDIRECTORY,
            .length = @intCast(plan.code_directory_size),
            .version = macho.CS_SUPPORTSEXECSEG,
            .flags = macho.CS_ADHOC | macho.CS_LINKER_SIGNED,
            .hashOffset = @intCast(plan.hash_offset),
            .identOffset = @sizeOf(macho.CodeDirectory),
            .nSpecialSlots = 0,
            .nCodeSlots = @intCast(plan.page_count),
            .codeLimit = @intCast(plan.start),
            .hashSize = Sha256.digest_length,
            .hashType = macho.CS_HASHTYPE_SHA256,
            .platform = 0,
            .pageSize = @as(u8, @truncate(std.math.log2(plan.page_size))),
            .spare2 = 0,
            .scatterOffset = 0,
            .teamOffset = 0,
            .spare3 = 0,
            .codeLimit64 = 0,
            .execSegBase = plan.text_fileoff,
            .execSegLimit = plan.text_filesize,
            .execSegFlags = macho.CS_EXECSEG_MAIN_BINARY,
        }, .big);
        try writer.writeAll(signature_identifier);
        try writer.writeByte(0);

        var page_start: usize = 0;
        while (page_start < plan.start) {
            const page_end = page_start + @min(
                plan.page_size,
                plan.start - page_start,
            );
            var digest: [Sha256.digest_length]u8 = undefined;
            Sha256.hash(output[page_start..page_end], &digest, .{});
            try writer.writeAll(&digest);
            page_start = page_end;
        }
        std.debug.assert(writer.end == plan.blob_size);
    }
};

fn isLinkeditDataCommand(command: macho.LC) bool {
    return switch (command) {
        .CODE_SIGNATURE,
        .SEGMENT_SPLIT_INFO,
        .FUNCTION_STARTS,
        .DATA_IN_CODE,
        .DYLIB_CODE_SIGN_DRS,
        .LINKER_OPTIMIZATION_HINT,
        .DYLD_EXPORTS_TRIE,
        .DYLD_CHAINED_FIXUPS,
        => true,
        else => false,
    };
}

fn validateLinkeditOffset(offset: u32, linkedit: FileRange) !void {
    if (offset == 0) return;
    if (offset < linkedit.start or offset > linkedit.end) {
        return error.OffsetOutOfRange;
    }
}

fn validateLinkeditRange(offset: u32, size: u64, linkedit: FileRange) !void {
    if (size == 0) return validateLinkeditOffset(offset, linkedit);
    if (offset == 0) return error.OffsetOutOfRange;
    const range = try FileRange.init(offset, size, linkedit.end);
    if (!linkedit.contains(range)) return error.OffsetOutOfRange;
}

fn shiftLinkeditOffset(offset: u32, amount: usize, linkedit: FileRange) !u32 {
    try validateLinkeditOffset(offset, linkedit);
    if (offset == 0) return 0;
    const shifted = std.math.add(u64, offset, amount) catch
        return error.OffsetOverflow;
    return std.math.cast(u32, shifted) orelse error.OffsetOverflow;
}

fn writeStructAt(output: []u8, offset: usize, value: anytype) !void {
    const end = std.math.add(usize, offset, @sizeOf(@TypeOf(value))) catch
        return error.OffsetOverflow;
    if (end > output.len) return error.OffsetOutOfRange;
    var writer = std.Io.Writer.fixed(output[offset..end]);
    try writer.writeStruct(value, .little);
}

fn pageSize(cpu: macho.cpu_type_t) usize {
    return switch (cpu) {
        macho.CPU_TYPE_X86_64 => 0x1000,
        macho.CPU_TYPE_ARM64 => 0x4000,
        else => unreachable,
    };
}

fn alignForward(
    comptime T: type,
    value: T,
    alignment: T,
) !T {
    _ = std.math.add(T, value, alignment - 1) catch return error.OffsetOverflow;
    return std.mem.alignForward(T, value, alignment);
}
