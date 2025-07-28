const std = @import("std");
const log = std.log.scoped(.cli_parse);

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

const Option = struct {
    name: [:0]const u8,
    short: ?u8,

    type: type,
    default_value_ptr: ?*const anyopaque,
};

pub fn option(default: anytype, name: [:0]const u8, short: ?u8) Option {
    const ValueType = @TypeOf(default);

    const result = Option{
        .name = name,
        .short = short,
        .type = ValueType,
        .default_value_ptr = @ptrCast(&default),
    };

    return result;
}

pub fn OptionsStruct(comptime options: []const Option) type {
    const fields: [options.len + 1]std.builtin.Type.StructField = blk: {
        var _fields: [options.len + 1]std.builtin.Type.StructField = undefined;
        var short_names: [options.len]?u8 = undefined;

        // TODO: Check for duplicate names/short names
        inline for (options, _fields[0..options.len], &short_names) |opt, *field, *sname| {
            switch (@typeInfo(opt.type)) {
                else => @compileError(std.fmt.comptimePrint("Type not supported '{s}", .{@typeName(opt.type)})),
                .bool, .int, .float, .@"enum" => {}, // ok
                .pointer => |ptr| {
                    if (ptr.size != .slice or ptr.child != u8 or !ptr.is_const) {
                        @compileError(std.fmt.comptimePrint("Type not supported '{s}\nUse @as([]const u8, \"...\") for strings.", .{@typeName(opt.type)}));
                    }
                },
            }

            field.* = .{
                .name = opt.name,
                .type = opt.type,
                .alignment = @alignOf(opt.type),
                .is_comptime = false,
                .default_value_ptr = opt.default_value_ptr,
            };

            sname.* = opt.short;
        }

        _fields[options.len] = .{
            .name = "__short_names",
            .type = [options.len]?u8,
            .alignment = @alignOf([options.len]?u8),
            .is_comptime = false,
            .default_value_ptr = &short_names,
        };

        break :blk _fields;
    };

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .is_tuple = false,
        .decls = &.{},
        .fields = &fields,
    } });
}

pub fn parse(comptime OptStruct: type, allocator: Allocator, tmp_allocator: Allocator) !OptStruct {
    var result: OptStruct = .{};

    var arg_it = std.process.argsWithAllocator(tmp_allocator) catch @panic("OOM");

    const opt_info = @typeInfo(OptStruct);
    assert(opt_info == .@"struct");
    const fields = opt_info.@"struct".fields;

    // First argument is exe path
    _ = arg_it.skip();

    while (arg_it.next()) |arg| {
        var token = arg;

        const field_name: []const u8 = blk: {
            if (std.mem.startsWith(u8, token, "--")) {
                var name: []const u8 = undefined;

                if (std.mem.indexOf(u8, token, "=")) |idx| {
                    name = token[2..idx];
                    token = token[idx + 1 ..];
                } else {
                    name = token[2..];
                    token = "";
                }

                break :blk name;
            } else if (std.mem.startsWith(u8, token, "-")) {
                if (token.len < 2) {
                    log.err("Invalid short option: '{s}'", .{token});
                    return error.InvalidShortOption;
                }
                const short_name = token[1];

                token = token[2..];
                if (std.mem.startsWith(u8, token, "=")) {
                    token = token[1..];
                }

                var field_name: ?[]const u8 = null;
                // TODO: Move this to the top of the loop below?
                inline for (@field(result, "__short_names"), 0..) |n, i| {
                    if (short_name == n) {
                        field_name = fields[i].name;
                        break;
                    }
                }

                if (field_name == null) {
                    log.err("Invalid short option: '-{c}'", .{short_name});
                    return error.InvalidShortOption;
                }

                break :blk field_name.?;
            } else {
                log.err("Expected option to start with '--' or '-' got '{s}'", .{token});
                return error.InvalidOption;
            }

            unreachable;
        };

        var found = false;
        inline for (fields[0 .. fields.len - 1]) |field| {
            if (std.mem.eql(u8, field_name, field.name)) {
                const field_type_info = @typeInfo(field.type);
                log.debug("Field name: '{s}' - '{s}'", .{ field_name, field.name });

                var invert_boolean = false;

                // handle ' value', ' =value', ' = value'
                blk: {
                    if (token.len == 0) {
                        if (arg_it.next()) |n| {
                            token = n;
                        } else if (field_type_info == .bool) {
                            invert_boolean = true;
                            break :blk;
                        } else {
                            log.err("Expected value after option '{s}'", .{field_name});
                            return error.ExpectedValue;
                        }

                        // handle ' =value', ' = value'
                        if (std.mem.startsWith(u8, token, "=")) {
                            token = token[1..];
                        }

                        // handle 'name = value'
                        if (token.len == 0) {
                            token = arg_it.next() orelse {
                                log.err("Expected value after option '{s}'", .{field_name});
                                return error.ExpectedValue;
                            };
                        }
                    }
                }

                @field(result, field.name) = switch (field_type_info) {
                    else => unreachable,

                    .bool => if (invert_boolean)
                        !@field(result, field.name)
                    else if (std.mem.eql(u8, token, "true") or std.mem.eql(u8, token, "TRUE"))
                        true
                    else if (std.mem.eql(u8, token, "false") or std.mem.eql(u8, token, "FALSE"))
                        false
                    else {
                        log.err("Invalid boolean value: '{s}'", .{token});
                        return error.InvalidBoolValue;
                    },

                    .int => std.fmt.parseInt(field.type, token, 10) catch {
                        log.err("Invalid int value: '{s}'", .{token});
                        return error.InvalidIntValue;
                    },

                    .float => std.fmt.parseFloat(field.type, token) catch {
                        log.err("Invalid float value: '{s}'", .{token});
                        return error.InvalidFloatValue;
                    },

                    .@"enum" => std.meta.stringToEnum(field.type, token) orelse {
                        log.err("Invalid enum value '{s}'", .{token});
                        return error.InvalidEnumValue;
                    },

                    .pointer => |ptr| blk: {
                        assert(ptr.size == .slice);
                        assert(ptr.child == u8);
                        assert(ptr.is_const);

                        // TODO: Check if we need to handle quotes on windows?
                        const string = try allocator.alloc(u8, token.len);
                        @memcpy(string, token);

                        break :blk string;
                    },
                };

                found = true;
                break;
            }
        }

        if (!found) {
            log.err("Invalid option: '{s}'", .{field_name});
            return error.InvalidOption;
        }
    }

    return result;
}

pub fn usage(comptime OptStruct: type) void {
    // TODO: writer argument

    log.info("usage: ", .{});

    const fields = @typeInfo(OptStruct).@"struct".fields;
    inline for (fields[0 .. fields.len - 1]) |field| {
        log.info("  --{s:<20}", .{field.name});
    }
}
