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
        .default_value_ptr = &default,
    };

    return result;
}

pub fn OptionsStruct(comptime options: []const Option) type {
    const fields: [options.len + 1]std.builtin.Type.StructField = blk: {
        var _fields: [options.len + 1]std.builtin.Type.StructField = undefined;
        var short_names: [options.len]?u8 = undefined;

        inline for (options, _fields[0..options.len], &short_names) |opt, *field, *sname| {
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
    _ = allocator;

    var result: OptStruct = .{};

    var arg_it = std.process.argsWithAllocator(tmp_allocator) catch @panic("OOM");

    const opt_info = @typeInfo(OptStruct);
    assert(opt_info == .@"struct");
    const fields = opt_info.@"struct".fields;

    // First argument is exe path
    _ = arg_it.skip();

    while (arg_it.next()) |arg| {
        var token = arg;
        var field_index_opt: ?usize = 0;

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
                inline for (@field(result, "__short_names"), 0..) |n, i| {
                    if (short_name == n) {
                        field_name = fields[i].name;
                        field_index_opt = i;
                        break;
                    }
                }

                if (field_name == null) {
                    log.err("Invalid short option: '-{c}'", .{short_name});
                    return error.InvalidShortOption;
                }

                break :blk field_name.?;
            }

            unreachable;
        };

        if (field_index_opt == null) {
            var found = false;
            inline for (fields[0 .. fields.len - 1], 0..) |field, i| {
                if (std.mem.eql(u8, field_name, field.name)) {
                    field_index_opt = i;
                    found = true;
                    break;
                }
            }
            if (!found) {
                log.err("Invalid option name '{s}'", .{field_name});
                return error.InvalidOptionName;
            }
        }

        // handle 'name =value', 'name= value', 'name = value'
        if (token.len == 0) {
            token = arg_it.next() orelse {
                log.err("Expected value after option '{s}'", .{field_name});
                return error.ExpectedValue;
            };

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

        inline for (fields[0 .. fields.len - 1], 0..) |field, i| {
            if (i == field_index_opt.?) {
                @field(result, field.name) = switch (@typeInfo(field.type)) {
                    else => @compileError(std.fmt.comptimePrint("Unhandled type '{s}'", .{@typeName(field.type)})),
                    .bool => if (std.mem.eql(u8, token, "true") or std.mem.eql(u8, token, "TRUE"))
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
                };
                break;
            }
        }
    }

    return result;
}
