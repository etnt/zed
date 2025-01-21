const std = @import("std");
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const process = std.process;
const heap = std.heap;
const os = std.os;
const builtin = @import("builtin");

const MAX_LINE_LEN = 4096;
const DEFAULT_CONTEXT_LINES = 5;

const WindowSize = struct {
    width: u16,
    height: u16,
};

// Cross-platform terminal size detection
fn getWindowSize() !WindowSize {
    if (builtin.os.tag == .windows) {
        const HANDLE = std.os.windows.HANDLE;
        const CONSOLE_SCREEN_BUFFER_INFO = std.os.windows.CONSOLE_SCREEN_BUFFER_INFO;
        const kernel32 = struct {
            extern "kernel32" fn GetConsoleScreenBufferInfo(
                console: HANDLE,
                info: *CONSOLE_SCREEN_BUFFER_INFO,
            ) callconv(.Stdcall) std.os.windows.BOOL;
        };

        const h_stdout = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch return error.NoTty;
        var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (kernel32.GetConsoleScreenBufferInfo(h_stdout, &info) == 0) {
            return error.NoTty;
        }
        return WindowSize{
            .width = @intCast(info.srWindow.Right - info.srWindow.Left + 1),
            .height = @intCast(info.srWindow.Bottom - info.srWindow.Top + 1),
        };
    } else {
        if (builtin.os.tag != .linux) {
            return WindowSize{ .width = 80, .height = 24 }; // fallback for non-Linux
        }

        var ws: os.linux.winsize = undefined;
        const fd = std.io.getStdOut().handle;
        const rc = os.linux.ioctl(fd, os.linux.TIOCGWINSZ, @intFromPtr(&ws));
        if (rc == -1) return error.NoTty;

        return WindowSize{
            .width = ws.ws_col,
            .height = ws.ws_row,
        };
    }
}

fn generateRuler(width: usize, prefix_width: usize) ![]u8 {
        var ruler = std.ArrayList(u8).init(std.heap.page_allocator);
        defer ruler.deinit();

        // Add spaces for the line number prefix alignment
        var p: usize = 0;
        while (p < prefix_width) : (p += 1) {
            try ruler.append(' ');
        }

        var i: usize = 1;
        while (i < width) : (i += 1) {
            if (i % 10 == 0) {
                try ruler.append('|');
            } else if (i % 5 == 0) {
                try ruler.append('+');
            } else {
                try ruler.append('-');
            }
        }

        return ruler.toOwnedSlice();
    }

const EditorError = error{
    InvalidCommand,
    InvalidLineNumber,
    InvalidColumnNumber,
    InvalidWordNumber,
    FileModified,
    EmptyFile,
} || fs.File.OpenError || fs.File.WriteError || fs.File.ReadError;

const Editor = struct {
    filename: []const u8,
    context_lines: usize,
    lines: std.ArrayList([]u8),
    current_line: usize,
    current_column: usize = 0,  // Add current column tracking
    allocator: mem.Allocator,
    file: fs.File,
    stat: fs.File.Stat,
    page_size: usize = 5, // Number of lines to display in the context

    fn countDigits(num: usize) usize {
        var digits: usize = 1;
        var n = num;
        while (n >= 10) : (n /= 10) {
            digits += 1;
        }
        return digits;
    }

    pub fn init(allocator: mem.Allocator, filename: []const u8, context_lines: usize) !Editor {
        const file = try fs.cwd().openFile(filename, .{ .mode = .read_write });
        const stat = try file.stat();

        var lines = std.ArrayList([]u8).init(allocator);
        var buf_reader = io.bufferedReader(file.reader());
        var reader = buf_reader.reader();

        while (true) {
            const line = reader.readUntilDelimiterAlloc(allocator, '\n', MAX_LINE_LEN) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            try lines.append(line);
        }

        if (lines.items.len == 0) {
            try lines.append(try allocator.dupe(u8, ""));
        }

        return Editor{
            .filename = filename,
            .context_lines = context_lines,
            .lines = lines,
            .current_line = 0,
            .allocator = allocator,
            .file = file,
            .stat = stat,
        };
    }

    pub fn deinit(self: *Editor) void {
        for (self.lines.items) |line| {
            self.allocator.free(line);
        }
        self.lines.deinit();
        self.file.close();
    }

    /// Save the current file contents to disk
    fn saveFile(self: *Editor) !void {
        // Move the file cursor to the beginning
        try self.file.seekTo(0);

        // Create a writer for the file
        var writer = self.file.writer();

        // Iterate through all lines in the editor
        for (self.lines.items, 0..) |line, i| {
            // Write the current line to the file
            try writer.writeAll(line);

            // Add a newline character after each line, except for the last one
            if (i < self.lines.items.len - 1) {
                try writer.writeByte('\n');
            }
        }

        // Set the end of the file to the current position
        // This effectively truncates the file if it was previously longer
        try self.file.setEndPos(try self.file.getPos());

        // Ensure all data is written to the file on disk
        try self.file.sync();
    }

    /// Set the number of lines to display in the context
    fn setPageSize(self: *Editor, page_size: usize) !void {
        if (page_size > 0) {
            self.page_size = page_size;
        }
    }

    /// Display the current file contents with a prompt at the bottom
    pub fn display(self: *Editor) !void {
        const stdout = io.getStdOut().writer();

        // Always show 5 lines with current line in the middle (position 3)
        const total_lines = self.lines.items.len;
        var start: usize = 0;

        if (total_lines <= self.page_size) {
            // If we have 5 or fewer lines, show all of them
            start = 0;
        } else {
            // Calculate start position to keep current line in middle
            if (self.current_line < 2) {
                start = 0;
            } else if (self.current_line > total_lines - 3) {
                start = total_lines - 5;
            } else {
                start = self.current_line - 2;
            }
        }

        const end = @min(start + self.page_size, total_lines);

        // Calculate the width needed for line numbers
        const max_line_number = self.lines.items.len;
        const line_number_width = blk: {
            var width: usize = 1;
            var num = max_line_number;
            while (num >= 10) : (num /= 10) {
                width += 1;
            }
            break :blk width;
        };

        // Display lines with right-aligned numbers
        var padding_buf: [20]u8 = undefined;
        for (start..end) |i| {
            const num_width = countDigits(i + 1);
            const padding_len = line_number_width - num_width;

            // Fill padding buffer with spaces
            var j: usize = 0;
            while (j < padding_len) : (j += 1) {
                padding_buf[j] = ' ';
            }
            // For the current line, we need to handle reverse video for the current column
            if (i == self.current_line) {
                const line = self.lines.items[i];
                try stdout.print("{s}{d}: ", .{
                    padding_buf[0..padding_len],
                    i + 1,
                });

                // Print up to the current column
                if (self.current_column > 0) {
                    try stdout.writeAll(line[0..@min(self.current_column, line.len)]);
                }

                // Print the character at current column in reverse video
                if (self.current_column < line.len) {
                    try stdout.writeAll("\x1b[7m"); // Enter reverse video mode
                    try stdout.writeByte(line[self.current_column]);
                    try stdout.writeAll("\x1b[27m"); // Exit reverse video mode

                    // Print the rest of the line
                    if (self.current_column + 1 < line.len) {
                        try stdout.writeAll(line[self.current_column + 1..]);
                    }
                }
                try stdout.writeByte('\n');
            } else {
                try stdout.print("{s}{d}: {s}\n", .{
                    padding_buf[0..padding_len],
                    i + 1,
                    self.lines.items[i]
                });
            }
        }

        // Add empty lines if we have fewer than 5 lines
        if (end - start < self.page_size) {
            var i: usize = 0;
            while (i < self.page_size - (end - start)) : (i += 1) {
                try stdout.writeAll("\n");
            }
        }

        // Get terminal width and generate ruler
        const window_size = try getWindowSize();
        const prefix_width = line_number_width + 2; // +2 for ": "
        const ruler = try generateRuler(@intCast(window_size.width), prefix_width);
        defer std.heap.page_allocator.free(ruler);

        // Show ruler and prompt at the bottom
        try stdout.print("{s}\n", .{ruler});
        try stdout.print("({d})> ", .{self.current_line + 1});
    }

    pub fn handleCommand(self: *Editor, cmd: []const u8) !bool {
        var iter = mem.split(u8, cmd, " ");
        const command = iter.next() orelse return error.InvalidCommand;

        if (mem.eql(u8, command, "q")) {
            return false;
        } else if (mem.eql(u8, command, "s")) {
            try self.saveFile();
        } else if (mem.eql(u8, command, "h")) {
            try self.showHelp();
        } else if (mem.eql(u8, command, "c")) {
            // Clear screen and reset cursor
            try self.clearScreen();
        } else if (mem.eql(u8, command, "z")) {
            const page_size_str = iter.next() orelse return error.InvalidCommand;
            const page_size = try std.fmt.parseInt(usize, page_size_str, 10);
            try self.setPageSize(page_size);
        } else if (mem.eql(u8, command, "n")) {
            if (self.current_line < self.lines.items.len - 1) {
                self.current_line += 1;
            }
        } else if (mem.eql(u8, command, "p")) {
            if (self.current_line > 0) {
                self.current_line -= 1;
            }
        } else if (mem.eql(u8, command, "N")) {
            const new_line = self.current_line + self.page_size;
            if (new_line < self.lines.items.len) {
                self.current_line = new_line;
            } else {
                self.current_line = self.lines.items.len - 1;
            }
        } else if (mem.eql(u8, command, "P")) {
            if (self.current_line >= self.page_size) {
                self.current_line -= self.page_size;
            } else {
                self.current_line = 0;
            }
        } else if (mem.eql(u8, command, "g")) {
            const line_str = iter.next() orelse return error.InvalidCommand;
            const line_num = try std.fmt.parseInt(usize, line_str, 10);
            if (line_num == 0 or line_num > self.lines.items.len) {
                return error.InvalidLineNumber;
            }
            self.current_line = line_num - 1;
        } else if (mem.eql(u8, command, "d")) {
            const line = self.lines.orderedRemove(self.current_line);
            self.allocator.free(line);
            if (self.lines.items.len == 0) {
                try self.lines.append(try self.allocator.dupe(u8, ""));
            }
            if (self.current_line >= self.lines.items.len) {
                self.current_line = self.lines.items.len - 1;
            }
        } else if (mem.eql(u8, command, "i")) {
            var col = self.current_column;
            const text = iter.rest();
            if (text.len == 0) return error.InvalidCommand;

            const line = self.lines.items[self.current_line];

            // Column can't go past the end of the line
            if (col > line.len) col = line.len;

            var new_line = try self.allocator.alloc(u8, line.len + text.len);
            @memcpy(new_line[0..col], line[0..col]);
            @memcpy(new_line[col .. col + text.len], text);
            @memcpy(new_line[col + text.len ..], line[col..]);

            self.allocator.free(line);
            self.lines.items[self.current_line] = new_line;
        } else if (mem.eql(u8, command, "w")) {
            const word_str = iter.next() orelse return error.InvalidCommand;
            const operation = iter.next() orelse return error.InvalidCommand;
            const text = iter.rest();
            if ((text.len == 0) and (operation[0] != 'd')) return error.InvalidCommand;

            const word_num = try std.fmt.parseInt(usize, word_str, 10);
            if (operation.len != 1 or !mem.eql(u8, operation, "d") and !mem.eql(u8, operation, "o") and !mem.eql(u8, operation, "a") and !mem.eql(u8, operation, "i"))
                return error.InvalidCommand;

            var word_iter = mem.split(u8, self.lines.items[self.current_line], " ");
            var word_count: usize = 0;
            var word_start: usize = 0;
            var word_end: usize = 0;

            while (word_iter.next()) |word| {
                word_count += 1;
                if (word_count == word_num) {
                    const line = self.lines.items[self.current_line];
                    word_end = word_start + word.len;
                    const new_len = if (operation[0] == 'd')
                        line.len - (word_end - word_start) - if (word_end < line.len) @as(usize, 1) else 0
                    else if (operation[0] == 'o')
                        line.len - word.len + text.len
                    else
                        line.len + text.len;

                    var new_line = try self.allocator.alloc(u8, new_len);

                    if (operation[0] == 'd') {
                        @memcpy(new_line[0..word_start], line[0..word_start]);
                        if (word_end < line.len - 1) {
                            @memcpy(new_line[word_start..], line[word_end + 1..]);
                        }
                    } else if (operation[0] == 'o') {
                        @memcpy(new_line[0..word_start], line[0..word_start]);
                        @memcpy(new_line[word_start .. word_start + text.len], text);
                        @memcpy(new_line[word_start + text.len ..], line[word_end..]);
                    } else if (operation[0] == 'a') {
                        @memcpy(new_line[0..word_end], line[0..word_end]);
                        @memcpy(new_line[word_end .. word_end + text.len], text);
                        @memcpy(new_line[word_end + text.len ..], line[word_end..]);
                    } else { // 'i'
                        @memcpy(new_line[0..word_start], line[0..word_start]);
                        @memcpy(new_line[word_start .. word_start + text.len], text);
                        @memcpy(new_line[word_start + text.len ..], line[word_start..]);
                    }

                    self.allocator.free(line);
                    self.lines.items[self.current_line] = new_line;
                    break;
                }
                word_start += word.len + 1;
            }

            if (word_count < word_num) return error.InvalidWordNumber;
        } else if (mem.eql(u8, command, "r")) {
            try self.reload();
        } else if (mem.eql(u8, command, "b")) {
            const text = iter.rest();
            if (text.len == 0) return error.InvalidCommand;

            const new_line = try self.allocator.dupe(u8, text);
            try self.lines.insert(self.current_line, new_line);
        } else if (mem.eql(u8, command, "a")) {
            const text = iter.rest();
            if (text.len == 0) return error.InvalidCommand;

            const new_line = try self.allocator.dupe(u8, text);
            try self.lines.insert(self.current_line + 1, new_line);
            self.current_line += 1;
        } else if (mem.eql(u8, command, "x")) {
            const line = self.lines.items[self.current_line];
            if (self.current_column < line.len and line.len > 0) {
                var new_line = try self.allocator.alloc(u8, line.len - 1);
                @memcpy(new_line[0..self.current_column], line[0..self.current_column]);
                if (self.current_column < line.len - 1) {
                    @memcpy(new_line[self.current_column..], line[self.current_column + 1..]);
                }
                self.allocator.free(line);
                self.lines.items[self.current_line] = new_line;
            }
        } else {
            // Now check if it is just a number, i.e set the current column
            if (command.len > 0) {
                const num = try std.fmt.parseInt(usize, command, 10);
                if (num > 0) {
                    self.current_column = num - 1;
                    return true;
                } else {
                    return error.InvalidColumnNumber;
                }
            }
            return error.InvalidCommand;
        }

        return true;
    }

    pub fn clearScreen(self: *Editor) !void {
        _ = self;
        const stdout = io.getStdOut().writer();
        try stdout.writeAll("\x1B[2J\x1B[H");
    }

    pub fn showHelp(self: *Editor) !void {
        _ = self;
        const stdout = io.getStdOut().writer();
        try stdout.writeAll(
            \\Commands:
            \\  h                     - Show this help message
            \\  <num>                 - Set the current column
            \\  i <text>              - Insert text at current column
            \\  x                     - Delete character at current column
            \\  w <word> <op> <text>  - Word operations at position N:
            \\                          <op> = d/o/a/i : delete, overwrite,
            \\                          append after, insert before
            \\  a/b <text>            - Append or insert text after/before
            \\                          current line
            \\  d                     - Delete current line
            \\  n/N                   - Move to next line/page
            \\  p/P                   - Move to previous line/page
            \\  g <N>                 - Go to line N 
            \\  z <N>                 - Set page size to N lines
            \\  r                     - Reload file from disk
            \\  c                     - Clear screen and reset cursor
            \\  s                     - Save changes to disk
            \\  q                     - Quit editor
            \\
        );
    }

    fn reload(self: *Editor) !void {
        const new_stat = try self.file.stat();
        if (new_stat.mtime != self.stat.mtime) {
            return error.FileModified;
        }

        // Clear existing lines
        for (self.lines.items) |line| {
            self.allocator.free(line);
        }
        self.lines.clearRetainingCapacity();

        // Re-read the file
        try self.file.seekTo(0);
        var buf_reader = io.bufferedReader(self.file.reader());
        var reader = buf_reader.reader();

        while (true) {
            const line = reader.readUntilDelimiterAlloc(self.allocator, '\n', MAX_LINE_LEN) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            try self.lines.append(line);
        }

        if (self.lines.items.len == 0) {
            try self.lines.append(try self.allocator.dupe(u8, ""));
        }

        if (self.current_line >= self.lines.items.len) {
            self.current_line = self.lines.items.len - 1;
        }

        self.stat = new_stat;
    }
};

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    if (args.len < 2) {
        const stderr = io.getStdErr().writer();
        try stderr.writeAll("Usage: editor <filename> [context_lines]\n");
        process.exit(1);
    }

    const context_lines = if (args.len > 2)
        try std.fmt.parseInt(usize, args[2], 10)
    else
        DEFAULT_CONTEXT_LINES;

    var editor = try Editor.init(allocator, args[1], context_lines);
    defer editor.deinit();

    const stdin = io.getStdIn().reader();
    var buf: [MAX_LINE_LEN]u8 = undefined;

    while (true) {
        try editor.display();

        const input = try stdin.readUntilDelimiter(&buf, '\n');
        if (input.len == 0) continue;

        const should_continue = editor.handleCommand(input) catch |err| {
            const stderr = io.getStdErr().writer();
            switch (err) {
                error.InvalidCommand => try stderr.writeAll("Error: Invalid command\n"),
                error.InvalidLineNumber => try stderr.writeAll("Error: Invalid line number\n"),
                error.InvalidColumnNumber => try stderr.writeAll("Error: Invalid column number\n"),
                error.InvalidWordNumber => try stderr.writeAll("Error: Invalid word number\n"),
                error.FileModified => try stderr.writeAll("Error: File has been modified externally\n"),
                else => try stderr.print("Error: {s}\n", .{@errorName(err)}),
            }
            // Wait for user input before continuing
            _ = try stdin.readUntilDelimiter(&buf, '\n');
            continue;
        };

        if (!should_continue) break;
    }
}
