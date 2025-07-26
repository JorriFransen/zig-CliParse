const std = @import("std");
const log = std.log.scoped(.cli_parse);

const Allocator = std.mem.Allocator;

const Option = struct {
    name: [:0]const u8,
    short: ?u8,

    type: type,
    value: union(enum) {
        bool: bool,
        int: i64,
        uint: u64,
        float: f32,
        @"enum": u64,
    },
};

pub fn option(default: anytype, name: [:0]const u8, short: ?u8) Option {
    const ValueType = @TypeOf(default);
    const ValueTypeInfo = @typeInfo(ValueType);

    const result = Option{
        .name = name,
        .short = short,
        .type = ValueType,
        .value = switch (ValueTypeInfo) {
            else => @compileError(std.fmt.comptimePrint("Invalid option type '{s}'", .{@tagName(ValueTypeInfo)})),

            .bool => .{ .bool = default },
            .int => |int| if (int.signedness == .signed) .{ .int = default } else .{ .uint = default },
            .float => .{ .float = default },
            .@"enum" => .{ .@"enum" = @intFromEnum(default) },
        },
    };

    return result;
}

pub fn OptionsStruct(comptime options: []const Option) type {
    const fields: [options.len]std.builtin.Type.StructField = blk: {
        var _fields: [options.len]std.builtin.Type.StructField = undefined;
        inline for (options, &_fields) |opt, *field| {
            field.* = .{
                .name = opt.name,
                .type = opt.type,
                .alignment = @alignOf(opt.type),
                .is_comptime = false,

                // TODO: Do this in fn option, store the default_value_ptr in the Option struct
                .default_value_ptr = pblk: switch (opt.value) {
                    .bool => |b| break :pblk &b,
                    .int => |i| break :pblk &i,
                    .uint => |u| break :pblk &u,
                    .float => |f| break :pblk &f,
                    .@"enum" => |e| break :pblk &e,
                },
            };
        }

        break :blk _fields;
    };

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .is_tuple = false,
        .decls = &.{},
        .fields = &fields,
    } });
}

pub fn parse(comptime OptStruct: type, allocator: Allocator) OptStruct {
    _ = allocator;
    unreachable;
}
