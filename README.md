# Zed - Line-based Text Editor
> A step up from using plain cat or ed

How many times haven't I started to enter text into a new file with `cat`?
Then what? `ed` is just to awkward, nano fast but too confusingly similar to Emacs,
Emacs is great but a bit heavy to start, Vim or Helix is ok I guess...but still...

So here is `zed` , a lightweight text editor written in Zig.

`zed` is a line-based text editor that uses a simple command-line interface to
perform common text operations. It is designed to be fast, simple to use and
the most important thing, it was fun to write.

## Commands

### Navigate

- `<num>` - Set the current column position
- `g <N>` - Go to line N
- `n` - Move to next line
- `p` - Move to previous line
- `N` - Move to next page
- `P` - Move to previous page

### Edit

- `a <text>` - Append text after current line
- `b <text>` - Insert text before current line
- `i <text>` - Insert text at current column
- `x` - Delete character at current column
- `d` - Delete current line
- `w <n> <op> <text>` - Word operations at word: <n>:
  - `d`: delete the word
  - `o`: overwrite the word
  - `a`: append after the word
  - `i`: insert before the word

### Save and Quit

- `s` - Save changes to disk
- `q` - Quit editor

### Misc

- `h` - Show help menu
- `r` - Reload file from disk
- `c` - Clear screen and reset cursor

## Build Instructions

```bash
# Clone the repository
git clone [repository-url]

# Build the project
zig build

# The executable will be available at (copy it to your $PATH)
./zig-out/bin/zed
```

## Usage

```bash
# Open a file with default context (5 lines)
zed filename.txt

# Open a file with custom context lines
zed filename.txt 3
```

## Warranty

`zed` come with absolutely no warranty. Use it at your own risk.

## License

See LICENSE file for details.
