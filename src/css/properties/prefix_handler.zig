pub const css = @import("../css_parser.zig");

const VendorPrefix = css.VendorPrefix;

const PropertyIdTag = css.PropertyIdTag;
const Property = css.Property;
const UnparsedProperty = css.css_properties.custom.UnparsedProperty;

/// *NOTE* The struct field names must match their corresponding names in `Property`!
pub const FallbackHandler = struct {
    color: ?usize = null,
    @"text-shadow": ?usize = null,
    // TODO: add these back plz
    // filter: ?usize = null,
    // @"backdrop-filter": ?usize = null,
    // fill: ?usize = null,
    // stroke: ?usize = null,
    // @"caret-color": ?usize = null,
    // caret: ?usize = null,

    const field_names = std.meta.fieldNames(FallbackHandler);
    const field_count = field_names.len;

    pub fn handleProperty(
        this: *FallbackHandler,
        property: *const Property,
        dest: *css.DeclarationList,
        context: *css.PropertyHandlerContext,
    ) bool {
        inline for (field_names) |field_name| {
            if (@backingInt(@field(PropertyIdTag, field_name)) == @backingInt(@as(PropertyIdTag, property.*))) {
                const has_vendor_prefix = comptime PropertyIdTag.hasVendorPrefix(@field(PropertyIdTag, field_name));
                var val = if (comptime has_vendor_prefix)
                    @field(property, field_name)[0].deepClone(context.allocator)
                else
                    @field(property, field_name).deepClone(context.allocator);

                if (@field(this, field_name) == null) {
                    const fallbacks = val.getFallbacks(context.allocator, context.targets);
                    const has_fallbacks = !fallbacks.isEmpty();

                    for (fallbacks.slice()) |fallback| {
                        dest.append(
                            context.allocator,
                            @unionInit(
                                Property,
                                field_name,
                                if (comptime has_vendor_prefix)
                                    .{ fallback, @field(property, field_name)[1] }
                                else
                                    fallback,
                            ),
                        ) catch |err| bun.handleOom(err);
                    }
                    if (comptime has_vendor_prefix) {
                        if (has_fallbacks and @field(property, field_name)[1].contains(VendorPrefix{ .none = true })) {
                            @field(property, field_name)[1] = css.VendorPrefix{ .none = true };
                        }
                    }
                }

                if (@field(this, field_name) == null or
                    context.targets.browsers != null and !val.isCompatible(context.targets.browsers.?))
                {
                    @field(this, field_name) = dest.items.len;
                    dest.append(
                        context.allocator,
                        @unionInit(
                            Property,
                            field_name,
                            if (comptime has_vendor_prefix)
                                .{ val, @field(property, field_name)[1] }
                            else
                                val,
                        ),
                    ) catch |err| bun.handleOom(err);
                } else if (@field(this, field_name) != null) {
                    const index = @field(this, field_name).?;
                    dest.items[index] = @unionInit(
                        Property,
                        field_name,
                        if (comptime has_vendor_prefix)
                            .{ val, @field(property, field_name)[1] }
                        else
                            val,
                    );
                } else {
                    val.deinit(context.allocator);
                }

                return true;
            }
        }

        if (@as(PropertyIdTag, property.*) == .unparsed) {
            const val: *const UnparsedProperty = &property.unparsed;
            var unparsed, const index = unparsed_and_index: {
                inline for (field_names) |field_name| {
                    if (@backingInt(@field(PropertyIdTag, field_name)) == @backingInt(val.property_id)) {
                        const has_vendor_prefix = comptime PropertyIdTag.hasVendorPrefix(@field(PropertyIdTag, field_name));
                        const newval = newval: {
                            if (comptime has_vendor_prefix) {
                                if (@field(val.property_id, field_name)[1].contains(VendorPrefix{ .none = true }))
                                    break :newval val.getPrefixed(context.targets, @field(css.prefixes.Feature, field_name));
                            }
                            break :newval val.deepClone(context.allocator);
                        };
                        break :unparsed_and_index .{ newval, &@field(this, field_name) };
                    }
                }
                return false;
            };

            context.addUnparsedFallbacks(&unparsed);
            if (index.*) |i| {
                dest.items[i] = Property{ .unparsed = unparsed };
            } else {
                index.* = dest.items.len;
                bun.handleOom(dest.append(context.allocator, Property{ .unparsed = unparsed }));
            }

            return true;
        }

        return false;
    }

    pub fn finalize(this: *FallbackHandler, _: *css.DeclarationList, _: *css.PropertyHandlerContext) void {
        inline for (field_names) |field_name| {
            @field(this, field_name) = null;
        }
    }
};

const bun = @import("bun");
const std = @import("std");
