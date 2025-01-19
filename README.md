# Zed - Line-based Text Editor
> A step up from using plain cat

A fast, lightweight text editor written in Zig. Designed for efficiency and simplicity, Zed provides essential text editing capabilities through an intuitive command-line interface.

## Features

- Line-based navigation and editing
- Real-time file synchronization
- Automatic file backup
- Context-aware display (shows surrounding lines)
- Command-based interface

## Commands

- `a <text>` - Append text after current line
- `i <col> <text>` - Insert text at specified column
- `w <word> o <text>` - Overwrite the Nth word
- `h` - Show help menu
- `q` - Quit editor
- `n` - Move to next line
- `p` - Move to previous line
- `g <N>` - Go to line N
- `d` - Delete current line
- `r` - Reload file from disk
- `c` - Clear screen and reset cursor

## Build Instructions

```bash
# Clone the repository
git clone [repository-url]

# Build the project
zig build

# The executable will be available at
./zig-out/bin/zed
```

## Usage

```bash
# Open a file with default context (5 lines)
zed filename.txt

# Open a file with custom context lines
zed filename.txt 3
```

## Architecture

Zed is built with performance and reliability in mind:

- **Memory Safety**: Leverages Zig's compile-time safety features
- **Efficient I/O**: Uses buffered I/O for file operations
- **Line Management**: ArrayList-based line storage for efficient insertions and deletions
- **File Handling**: Automatic file synchronization and modification detection
- **Error Handling**: Comprehensive error handling for all operations

### Performance Characteristics

- Maximum line length: 4096 bytes
- Default context display: 5 lines
- Real-time file operations
- Minimal memory footprint

## License

See LICENSE file for details.
