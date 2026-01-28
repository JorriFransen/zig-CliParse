Simple command line argument parser in zig.


Example usage
```zig
const OptionParser = clip.OptionParser(&.{
    clip.option(glfw.Platform.any, "glfw_platform", 'p', "Specify the platform hint for glfw.\n"),
    clip.option(@as(i32, -42), "test_int", 'i', "test integer."),
    clip.option(@as(u32, 42), "test_uint", null, null),
    clip.option(@as(f32, 4.2), "test_float", 'f', "Some float."),
    clip.option(@as([]const u8, "abc"), "test_str", 's', null),
    clip.ArrayOption([]const u8, "name", 'n', "Name\n"),
    clip.option(false, "help", 'h', "Print this help message and exit."),
});

const cli_options = OptionParser.parse(mem.common_arena.allocator(), tmp.allocator()) catch {
    try OptionParser.usage(stderr_writer);
    return; // Exit
};
tmp.release();

if (cli_options.help) {
    try OptionParser.usage(stdout_writer);
    return; // Exit
}
```

The type of cli_options looks like this:
```zig
struct {
    glfw_platform: glfw.Platform = any,
    test_int: i32 = -42,
    test_uint: u32 = 42,
    test_float: f32 = 4.2,
    test_str: []const u8 = "abc",
    name: std.ArrayList([]const u8) = std.ArrayList([]const u8){},
    help: bool = false,
};
```

The parse function inititalizes the result to the default values, so any unset options will have their default value.
When specifying options by their long name (--option_name) a '=' between the name and value is mandatory.
When specifying options by their short name (-o) a '=' between the name and value is optional. When the option is a boolean the value may be omitted,in which case it will be set to the inverse of the default value.

