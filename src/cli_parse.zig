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
/// const cli_options = OptionParser.parse(mem.common_arena.allocator(), tmp.allocator()) catch {
///     try OptionParser.usage(stderr_writer);
///     return; // Exit
/// };
/// tmp.release();
///
/// if (cli_options.help) {
///     try OptionParser.usage(stdout_writer);
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
        field_names: [options.len][]const u8,
        field_types: [options.len]type,
        field_attrs: [options.len]std.builtin.Type.StructField.Attributes,
        options: [options.len]Option,
    };

    const info: Info = blk: {
        var field_names: [options.len][]const u8 = undefined;
        var field_types: [options.len]type = undefined;
        var field_attrs: [options.len]std.builtin.Type.StructField.Attributes = undefined;
        var options_copy: [options.len]Option = undefined;

        inline for (options, &field_names, &field_types, &field_attrs, &options_copy, 0..) |opt, *fname, *ftype, *fattr, *oc, i| {
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
            for (field_names[0..i], options[0..i]) |dup_f_name, o| {
                if (std.mem.eql(u8, opt.name, dup_f_name)) {
                    const short = if (opt.short) |s| std.fmt.comptimePrint(" (short '{c}')", .{s}) else "";
                    const dup_short = if (o.short) |s| std.fmt.comptimePrint(" (short '{c}')", .{s}) else "";
                    @compileError(std.fmt.comptimePrint(
                        "Duplicate name '{s}'{s}, duplicate of '{s}'{s}",
                        .{ opt.name, short, dup_f_name, dup_short },
                    ));
                }
            }

            const otag = validateType(opt.type);
            assert(otag == opt.type_tag);

            fname.* = opt.name;
            ftype.* = if (opt.is_array) std.ArrayList(opt.type) else opt.type;
            fattr.* = .{ .default_value_ptr = opt.default_value_ptr };
        }

        break :blk .{
            .program_name = program_name,
            .field_names = field_names,
            .field_types = field_types,
            .field_attrs = field_attrs,
            .options = options_copy,
        };
    };

    const OptionStruct = @Struct(.auto, null, &info.field_names, &info.field_types, &info.field_attrs);

    return struct {
        /// Result of the parse operation, struct containing all option fields
        pub const Options = OptionStruct;

        /// Original options passed into OptionParser()
        pub const from_options = info.options;

        pub fn freeOptions(o: *Options, allocator: Allocator) void {
            _ = .{ o, allocator };

            const o_info = @typeInfo(Options);
            assert(o_info == .@"struct");
            assert(o_info.@"struct".fields.len == from_options.len);

            inline for (from_options, o_info.@"struct".fields) |oo, field_info| {
                if (!oo.is_array) {
                    if (oo.type_tag == .string) allocator.free(@field(o, field_info.name));
                } else {
                    const arraylist = &@field(o, field_info.name);

                    if (oo.type_tag == .string) for (arraylist.items) |s| allocator.free(s);

                    arraylist.deinit(allocator);
                }
            }
        }

        // TODO: Handle duplicate non array options (disallow or overwrite and free previous)
        pub fn parse(args: std.process.Args, allocator: Allocator, tmp_allocator: Allocator) !Options {
            var result: Options = .{};

            var arg_it = args.iterateAllocator(tmp_allocator) catch @panic("OOM");

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

        pub fn usage(writer: *std.Io.Writer) !void {
            try writer.print("Usage: {s} [OPTION]...", .{info.program_name});
            try writer.print("\nOptions\n", .{});

            var name_pad: [max_name_length]u8 = undefined;
            var type_tag_pad: [max_type_length]u8 = undefined;

            inline for (from_options) |opt| {
                try writer.print("  ", .{});
                if (opt.short) |s| try writer.print("-{c}, ", .{s}) else try writer.print("    ", .{});

                padRight(opt.name, &name_pad);
                try writer.print("--{s}", .{name_pad});

                if (opt.is_array) {
                    type_tag_pad[0] = '[';
                    type_tag_pad[1] = ']';
                    padRight(@tagName(opt.type_tag), type_tag_pad[2..]);
                } else {
                    padRight(@tagName(opt.type_tag), &type_tag_pad);
                }
                try writer.print(" {s}", .{type_tag_pad});

                if (opt.description) |d| try writer.print(" {s}", .{d});

                try writer.print("\n", .{});
            }
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
    arg_it: *std.process.Args.Iterator,
    current_token: []const u8,
    eof: bool,

    pub fn init(arg_it: *std.process.Args.Iterator) Tokenizer {
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
