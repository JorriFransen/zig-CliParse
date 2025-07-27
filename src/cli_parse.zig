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
                unreachable;
            }

            unreachable;
        };

        // handle 'name =value', 'name= value', 'name = value'
        if (token.len == 0) {
            token = arg_it.next() orelse return error.ExpectedValue;

            if (std.mem.startsWith(u8, token, "=")) {
                token = token[1..];
            }

            // handle 'name = value'
            if (token.len == 0) {
                token = arg_it.next() orelse return error.ExpectedValue;
            }
        }

        log.debug("field_name: '{s}'", .{field_name});
        log.debug("token: '{s}'", .{token});

        inline for (opt_info.@"struct".fields[0 .. opt_info.@"struct".fields.len - 1]) |field| {
            if (std.mem.eql(u8, field_name, field.name)) {
                @field(result, field.name) = switch (@typeInfo(field.type)) {
                    else => @compileError(std.fmt.comptimePrint("Unhandled type '{s}'", .{@typeName(field.type)})),
                    .bool => unreachable,
                    .int => unreachable,
                    .float => unreachable,
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

    // // Combine all into a single string
    // var first = true;
    // var args = std.ArrayList(u8).init(tmp_allocator);
    // while (arg_it.next()) |arg| {
    //     if (first) {
    //         first = false;
    //     } else {
    //         try args.append(' ');
    //     }
    //     try args.appendSlice(arg);
    // }
    //
    // const opt_info = @typeInfo(OptStruct);
    // assert(opt_info == .@"struct");
    //
    //
    // // TODO: Don't think we need to tokenize?
    // var it = std.mem.tokenizeAny(u8, args.items, &std.ascii.whitespace);
    //
    // while (it.next()) |token| {
    //     if (std.mem.startsWith(u8, token, "--")) {
    //         const name = token[2..];
    //
    //         // Last field is __short_names
    //         inline for (opt_info.@"struct".fields[0 .. opt_info.@"struct".fields.len - 1]) |field| {
    //             if (std.mem.startsWith(u8, name, field.name)) {
    //                 log.debug("Matched option: {s}", .{field.name});
    //
    //                 const next = if (name.len == field.name.len)
    //                     it.next() orelse return error.ExpectedValue
    //                 else
    //                     name[field.name.len..];
    //
    //                 log.debug("next: '{s}'", .{next});
    //                 var value = if (std.mem.startsWith(u8, next, "="))
    //                     next[1..]
    //                 else
    //                     next;
    //
    //                 if (value.len == 0)
    //                     value = it.next() orelse return error.ExpectedValue;
    //
    //                 log.debug("value: '{s}'", .{value});
    //
    //                 @field(result, field.name) = switch (@typeInfo(field.type)) {
    //                     else => @compileError(std.fmt.comptimePrint("Unhandled type '{s}'", .{@typeName(field.type)})),
    //                     .@"enum" => std.meta.stringToEnum(field.type, value) orelse {
    //                         log.err("Invalid enum value '{s}'", .{value});
    //                         return error.InvalidEnumValue;
    //                     },
    //                     .bool => unreachable,
    //                     .int => unreachable,
    //                     .float => unreachable,
    //                 };
    //                 break;
    //             }
    //         }
    //     } else if (std.mem.startsWith(u8, token, "-")) {}
    // }
    //
    // return result;
}
