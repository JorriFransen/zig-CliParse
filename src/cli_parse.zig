const std = @import("std");
const log = std.log.scoped(.cli_parse);

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

pub const max_name_length = 20;
const max_type_length = 10;

const Option = struct {
    name: [:0]const u8,
    short: ?u8,

    type: type,
    type_tag: TypeTag,
    is_array: bool,
    default_value_ptr: ?*const anyopaque,

    description: ?[]const u8,
};

const TypeTag = enum {
    bool,
    int,
    uint,
    float,
    string,
    @"enum",
};

pub fn option(default: anytype, name: [:0]const u8, short: ?u8, description: ?[]const u8) Option {
    const ValueType = @TypeOf(default);

    if (name.len > max_name_length) {
        @compileError(std.fmt.comptimePrint("Name too long (max {})", .{max_name_length}));
    }

    const tag = validateType(ValueType);

    return .{
        .name = name,
        .short = short,
        .type = ValueType,
        .type_tag = tag,
        .is_array = false,
        .default_value_ptr = @ptrCast(&default),
        .description = description,
    };
}

pub fn arrayOption(comptime ElemType: type, name: [:0]const u8, short: ?u8, description: ?[]const u8) Option {
    if (name.len > max_name_length) {
        @compileError(std.fmt.comptimePrint("Name too long (max {})", .{max_name_length}));
    }

    const tag = validateType(ElemType);
    const default = std.ArrayList(ElemType){};

    return .{
        .name = name,
        .short = short,
        .type = ElemType,
        .type_tag = tag,
        .is_array = true,
        .default_value_ptr = @ptrCast(&default),
        .description = description,
    };
}

/// # Example usage
/// ```zig
/// const OptionParser = clip.OptionParser(&.{
///     clip.option(glfw.Platform.any, "glfw_platform", 'p', "Specify the platform hint for glfw.\n"),
///     clip.option(@as(i32, -42), "test_int", 'i', "test integer."),
///     clip.option(@as(u32, 42), "test_uint", null, null),
///     clip.option(@as(f32, 4.2), "test_float", 'f', "Some float."),
///     clip.option(@as([]const u8, "abc"), "test_str", 's', null),
///     clip.ArrayOption([]const u8, "name", 'n', "Name\n"),
///     clip.option(false, "help", 'h', "Print this help message and exit."),
/// });
///
/// const cli_options = OptionParser.parse(mem.common_arena.allocator(), tmp.allocator()) catch { try OptionParser.usage(std.fs.File.stderr());
///     return; // Exit
/// };
/// tmp.release();
///
/// if (cli_options.help) {
///     try OptionParser.usage(std.fs.File.stdout());
///     return; // Exit
/// }
/// ```
///
/// The type of cli_options looks like this:
/// ```zig
/// struct {
///     glfw_platform: glfw.Platform = any,
///     test_int: i32 = -42,
///     test_uint: u32 = 42,
///     test_float: f32 = 4.2,
///     test_str: []const u8 = "abc",
///     name: std.ArrayList([]const u8) = std.ArrayList([]const u8){},
///     help: bool = false,
/// };
/// ```
///
/// The parse function inititalizes the result to the default values, so any
///  unset options will have their default value.
/// When specifying options by their long name (--option_name) a '=' between
///  the name and value is mandatory.
/// When specifying options by their short name (-o) a '=' between the name
/// and value is optional. When the option is a boolean the value may be
/// omitted,in which case it will be set to the inverse of the default value.
pub fn OptionParser(program_name: []const u8, comptime options: []const Option) type {
    const Info = struct {
        program_name: []const u8,
        fields: [options.len]std.builtin.Type.StructField,
        options: [options.len]Option,
    };

    const info: Info = blk: {
        var fields: [options.len]std.builtin.Type.StructField = undefined;
        var options_copy: [options.len]Option = undefined;

        inline for (options, &fields, &options_copy, 0..) |opt, *field, *oc, i| {
            oc.* = opt;

            // Check for duplicate short name
            if (opt.short) |s| {
                for (options[0..i]) |o| {
                    if (o.short == s) {
                        @compileError(std.fmt.comptimePrint(
                            "Duplicate short name '{c}' (name '{s}'), duplicate of '{c}' (name '{s}')",
                            .{ s, opt.name, o.short.?, o.name },
                        ));
                    }
                }
            }

            // Check for duplicate name
            for (fields[0..i], options[0..i]) |dup_f, o| {
                if (std.mem.eql(u8, opt.name, dup_f.name)) {
                    const short = if (opt.short) |s| std.fmt.comptimePrint(" (short '{c}')", .{s}) else "";
                    const dup_short = if (o.short) |s| std.fmt.comptimePrint(" (short '{c}')", .{s}) else "";
                    @compileError(std.fmt.comptimePrint(
                        "Duplicate name '{s}'{s}, duplicate of '{s}'{s}",
                        .{ opt.name, short, dup_f.name, dup_short },
                    ));
                }
            }

            const otag = validateType(opt.type);
            assert(otag == opt.type_tag);

            const member_type = if (opt.is_array) std.ArrayList(opt.type) else opt.type;
            field.* = .{
                .name = opt.name,
                .type = member_type,
                .alignment = @alignOf(member_type),
                .is_comptime = false,
                .default_value_ptr = opt.default_value_ptr,
            };
        }

        break :blk .{ .program_name = program_name, .fields = fields, .options = options_copy };
    };

    const OptionStruct = @Type(.{ .@"struct" = .{
        .layout = .auto,
        .is_tuple = false,
        .decls = &.{},
        .fields = &info.fields,
    } });

    return struct {
        /// Result of the parse operation, struct containing all option fields
        pub const Options = OptionStruct;

        /// Original options passed into OptionParser()
        pub const from_options = info.options;

        pub fn parse(allocator: Allocator, tmp_allocator: Allocator) !Options {
            var result: Options = .{};

            var arg_it = std.process.argsWithAllocator(tmp_allocator) catch @panic("OOM");

            // First argument is exe path
            _ = arg_it.skip();

            var tokens = Tokenizer.init(&arg_it);

            const opt_info = @typeInfo(Options);
            assert(opt_info == .@"struct");

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
                        inline for (from_options) |o| {
                            if (short_name == o.short) {
                                field_name = o.name;
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
                inline for (from_options, @typeInfo(Options).@"struct".fields) |o, field| {
                    if (std.mem.eql(u8, field_name, o.name)) {
                        const field_type_info = @typeInfo(o.type);

                        const parsed_eq = tokens.eat("=") != null;

                        if (field_type_info != .bool and !parsed_eq and !used_short) {
                            log.err("Expect '=' after option '--{s}'", .{o.name});
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
                            log.err("Missing value for option '--{s}'", .{o.name});
                            return error.MissingValue;
                        }

                        const value = switch (field_type_info) {
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

                            .int => std.fmt.parseInt(o.type, value_token, 10) catch {
                                log.err("Invalid int value: '{s}'", .{value_token});
                                return error.InvalidIntValue;
                            },

                            .float => std.fmt.parseFloat(o.type, value_token) catch {
                                log.err("Invalid float value: '{s}'", .{value_token});
                                return error.InvalidFloatValue;
                            },

                            .@"enum" => blk: {
                                break :blk std.meta.stringToEnum(o.type, value_token) orelse {
                                    log.err("Invalid enum value '{s}'", .{value_token});
                                    return error.InvalidEnumValue;
                                };
                            },

                            .pointer => |ptr| blk: {
                                assert(ptr.size == .slice);
                                assert(ptr.child == u8);
                                assert(ptr.is_const);

                                const string = try allocator.alloc(u8, value_token.len);
                                @memcpy(string, value_token);

                                break :blk string;
                            },
                        };

                        if (o.is_array) {
                            try @field(result, o.name).append(allocator, value);
                        } else {
                            @field(result, o.name) = value;
                        }

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

        pub fn usage(file: std.fs.File) !void {
            var buffer: [2048]u8 = undefined;
            var writer = file.writer(&buffer);
            const w = &writer.interface;

            try w.print("Usage: {s} [OPTION]...", .{info.program_name});
            try w.print("\nOptions\n", .{});

            var name_pad: [max_name_length]u8 = undefined;
            var type_tag_pad: [max_type_length]u8 = undefined;

            inline for (from_options) |opt| {
                try w.print("  ", .{});
                if (opt.short) |s| try w.print("-{c}, ", .{s}) else try w.print("    ", .{});

                padRight(opt.name, &name_pad);
                try w.print("--{s}", .{name_pad});

                if (opt.is_array) {
                    type_tag_pad[0] = '[';
                    type_tag_pad[1] = ']';
                    padRight(@tagName(opt.type_tag), type_tag_pad[2..]);
                } else {
                    padRight(@tagName(opt.type_tag), &type_tag_pad);
                }
                try w.print(" {s}", .{type_tag_pad});

                if (opt.description) |d| try w.print(" {s}", .{d});

                try w.print("\n", .{});
            }

            try w.flush();
        }
    };
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

fn padRight(str: []const u8, out_buf: []u8) void {
    assert(str.len <= out_buf.len);
    @memcpy(out_buf[0..str.len], str);
    @memset(out_buf[str.len..], ' ');
}
