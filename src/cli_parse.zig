const std = @import("std");
const log = std.log.scoped(.cli_parse);

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

pub const max_name_length = 20;
const max_type_length = 6;

const Option = struct {
    name: [:0]const u8,
    short: ?u8,

    type: type,
    type_tag: TypeTag,
    default_value_ptr: ?*const anyopaque,
};

const TypeTag = enum {
    bool,
    int,
    uint,
    float,
    string,
    @"enum",
};

pub fn option(default: anytype, name: [:0]const u8, short: ?u8) Option {
    const ValueType = @TypeOf(default);

    if (name.len > max_name_length) {
        @compileError(std.fmt.comptimePrint("Name too long (max {})", .{max_name_length}));
    }

    const tag = validateType(ValueType);

    const result = Option{
        .name = name,
        .short = short,
        .type = ValueType,
        .type_tag = tag,
        .default_value_ptr = @ptrCast(&default),
    };

    return result;
}

pub fn OptionsStruct(comptime options: []const Option) type {
    const fields: [options.len + 2]std.builtin.Type.StructField = blk: {
        var _fields: [options.len + 2]std.builtin.Type.StructField = undefined;

        var tags: [options.len]TypeTag = undefined;
        var short_names: [options.len]?u8 = undefined;

        inline for (options, _fields[0..options.len], &tags, &short_names, 0..) |opt, *field, *tag, *sname, i| {
            // Check for duplicate short name
            if (opt.short) |s| {
                if (std.mem.indexOfScalar(?u8, short_names[0..i], s)) |dup_i| {
                    @compileError(std.fmt.comptimePrint(
                        "Duplicate short name '{c}' (name '{s}'), duplicate of '{c}' (name '{s}')",
                        .{ s, opt.name, short_names[dup_i].?, _fields[dup_i].name },
                    ));
                }
            }

            // Check for duplicate name
            for (_fields[0..i], 0..) |dup_f, dup_i| {
                if (std.mem.eql(u8, opt.name, dup_f.name)) {
                    const short = if (opt.short) |s| std.fmt.comptimePrint(" (short '{c}')", .{s}) else "";
                    const dup_short = if (short_names[dup_i]) |s| std.fmt.comptimePrint(" (short '{c}')", .{s}) else "";
                    @compileError(std.fmt.comptimePrint(
                        "Duplicate name '{s}'{s}, duplicate of '{s}'{s}",
                        .{ opt.name, short, dup_f.name, dup_short },
                    ));
                }
            }

            const otag = validateType(opt.type);
            assert(otag == opt.type_tag);

            field.* = .{
                .name = opt.name,
                .type = opt.type,
                .alignment = @alignOf(opt.type),
                .is_comptime = false,
                .default_value_ptr = opt.default_value_ptr,
            };

            tag.* = otag;
            sname.* = opt.short;
        }

        _fields[_fields.len - 2] = .{
            .name = "__tags",
            .type = [options.len]TypeTag,
            .alignment = @alignOf([options.len]TypeTag),
            .is_comptime = false,
            .default_value_ptr = &tags,
        };

        _fields[_fields.len - 1] = .{
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

fn validateType(comptime T: type) TypeTag {
    return switch (@typeInfo(T)) {
        else => @compileError(std.fmt.comptimePrint("Type not supported '{s}", .{@typeName(T)})),

        .bool => .bool,

        .int => |i| blk: {
            if (i.signedness == .signed) {
                break :blk .int;
            } else break :blk .uint;
        },

        .float => .float,

        .pointer => |ptr| blk: {
            if (ptr.size != .slice or ptr.child != u8 or !ptr.is_const) {
                @compileError(std.fmt.comptimePrint("Type not supported '{s}\nUse @as([]const u8, \"...\") for strings.", .{@typeName(T)}));
            }

            break :blk .string;
        },

        .@"enum" => .@"enum",
    };
}

pub fn parse(comptime OptStruct: type, allocator: Allocator, tmp_allocator: Allocator) !OptStruct {
    var result: OptStruct = .{};

    var arg_it = std.process.argsWithAllocator(tmp_allocator) catch @panic("OOM");

    // First argument is exe path
    _ = arg_it.skip();

    var tokens = Tokenizer.init(&arg_it);

    const opt_info = @typeInfo(OptStruct);
    assert(opt_info == .@"struct");
    const fields = opt_info.@"struct".fields;

    while (!tokens.eof) {
        var used_short = false;

        const field_name: []const u8 = blk: {
            if (tokens.eat("--")) |_| {
                var name = tokens.current();

                if (std.mem.indexOf(u8, name, "=")) |idx| {
                    name = name[0..idx];
                }
                _ = tokens.eat(name);

                break :blk name;
            } else if (tokens.eat("-")) |_| {
                const c = tokens.current();
                if (c.len < 1) {
                    log.err("Invalid short option: '{s}'", .{c});
                    return error.InvalidShortOption;
                }
                const short_name = c[0];
                _ = tokens.eat(c[0..1]);

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

                used_short = true;

                break :blk field_name.?;
            } else {
                log.err("Expected option to start with '--' or '-' got '{s}'", .{tokens.current()});
                return error.InvalidOption;
            }
        };

        var found = false;
        inline for (fields[0 .. fields.len - 2]) |field| {
            if (std.mem.eql(u8, field_name, field.name)) {
                const field_type_info = @typeInfo(field.type);

                var parsed_eq = false;
                if (tokens.eat("=")) |_| {
                    parsed_eq = true;
                }

                if (field_type_info != .bool and !parsed_eq and !used_short) {
                    log.err("Expect '=' after option '--{s}'", .{field.name});
                    return error.InvalidOption;
                }

                var invert_boolean = false;

                if (field_type_info == .bool and
                    !parsed_eq and
                    (tokens.eof or
                        std.mem.startsWith(u8, tokens.current(), "--") or
                        std.mem.startsWith(u8, tokens.current(), "-")))
                {
                    invert_boolean = true;
                }

                const value_token = if (!invert_boolean) tokens.next() else "";

                if (!invert_boolean and value_token.len == 0) {
                    log.err("Missing value for option '--{s}'", .{field.name});
                    return error.MissingValue;
                }

                @field(result, field.name) = switch (field_type_info) {
                    else => unreachable,

                    .bool => if (invert_boolean)
                        !field.defaultValue().?
                    else if (std.mem.eql(u8, value_token, "true"))
                        true
                    else if (std.mem.eql(u8, value_token, "TRUE"))
                        true
                    else if (std.mem.eql(u8, value_token, "false"))
                        false
                    else if (std.mem.eql(u8, value_token, "FALSE"))
                        false
                    else {
                        log.err("Invalid boolean value: '{s}'", .{value_token});
                        return error.InvalidBoolValue;
                    },

                    .int => std.fmt.parseInt(field.type, value_token, 10) catch {
                        log.err("Invalid int value: '{s}'", .{value_token});
                        return error.InvalidIntValue;
                    },

                    .float => std.fmt.parseFloat(field.type, value_token) catch {
                        log.err("Invalid float value: '{s}'", .{value_token});
                        return error.InvalidFloatValue;
                    },

                    .@"enum" => blk: {
                        break :blk std.meta.stringToEnum(field.type, value_token) orelse {
                            log.err("Invalid enum value '{s}'", .{value_token});
                            return error.InvalidEnumValue;
                        };
                    },

                    .pointer => |ptr| blk: {
                        assert(ptr.size == .slice);
                        assert(ptr.child == u8);
                        assert(ptr.is_const);

                        // TODO: Check if we need to handle quotes on windows?
                        const string = try allocator.alloc(u8, value_token.len);
                        @memcpy(string, value_token);

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

const Tokenizer = struct {
    arg_it: *std.process.ArgIterator,
    current_token: []const u8,
    eof: bool,

    pub fn init(arg_it: *std.process.ArgIterator) Tokenizer {
        var ct: []const u8 = "";
        var eof = false;

        if (arg_it.next()) |c| {
            ct = c;
        } else {
            eof = true;
        }

        return .{
            .arg_it = arg_it,
            .current_token = ct,
            .eof = eof,
        };
    }

    pub fn next(it: *Tokenizer) []const u8 {
        const result = it.current_token;

        if (it.arg_it.next()) |n| {
            it.current_token = n;
        } else {
            it.current_token = "";
            it.eof = true;
        }

        return result;
    }

    pub fn current(it: *Tokenizer) []const u8 {
        if (it.current_token.len == 0) {
            _ = it.next();
        }
        return it.current_token;
    }

    pub fn eat(it: *Tokenizer, str: []const u8) ?[]const u8 {
        if (it.current_token.len == 0) {
            _ = it.next();
        }

        if (std.mem.startsWith(u8, it.current_token, str)) {
            it.current_token = it.current_token[str.len..];
            if (it.current_token.len == 0) {
                _ = it.next();
            }
            return str;
        }

        return null;
    }
};

pub fn usage(comptime OptStruct: type, file: std.fs.File) !void {
    var buffer: [2048]u8 = undefined;
    var writer = file.writer(&buffer);
    const w = &writer.interface;

    try w.print("Usage: v10game [OPTION]...", .{});
    try w.print("\nOptions\n", .{});

    const fields = @typeInfo(OptStruct).@"struct".fields;
    const tags = fields[fields.len - 2].defaultValue().?;
    const short_names = fields[fields.len - 1].defaultValue().?;
    var name_pad: [max_name_length]u8 = undefined;
    var type_tag_pad: [max_type_length]u8 = undefined;

    inline for (fields[0 .. fields.len - 2], 0..) |field, i| {
        try w.print("  ", .{});
        if (short_names[i]) |s| try w.print("-{c}, ", .{s}) else try w.print("    ", .{});

        padRight(field.name, &name_pad);
        try w.print("--{s}", .{name_pad});

        padRight(@tagName(tags[i]), &type_tag_pad);
        try w.print(" {s}", .{type_tag_pad});

        try w.print("\n", .{});
    }

    try w.flush();
}

fn padRight(str: []const u8, out_buf: []u8) void {
    assert(str.len <= out_buf.len);
    @memcpy(out_buf[0..str.len], str);
    @memset(out_buf[str.len..], ' ');
}
