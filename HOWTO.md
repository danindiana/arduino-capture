# arduino-capture — User Manual
**Date:** 2026-03-13
**Binary:** `zig-out/bin/arduino-capture`
**Platform:** Linux (tested on 6.8.12, Debian/Ubuntu family)

---

## Table of Contents

1. [What this is](#1-what-this-is)
2. [Prerequisites](#2-prerequisites)
3. [Hardware setup](#3-hardware-setup)
4. [Arduino sketch setup](#4-arduino-sketch-setup)
5. [Building from source](#5-building-from-source)
6. [Running the program](#6-running-the-program)
7. [Output format](#7-output-format)
8. [Logging to a file](#8-logging-to-a-file)
9. [Permissions](#9-permissions)
10. [Troubleshooting](#10-troubleshooting)
11. [Code internals](#11-code-internals)
12. [Zig version notes](#12-zig-version-notes)
13. [Scripts](#13-scripts)

---

## 1. What this is

`arduino-capture` is a Zig program that reads a continuous stream of
true-random alphanumeric strings from an Arduino UNO R3 over USB serial,
timestamps each line, and writes output to stdout. Optionally it appends
the same output to a log file.

The Arduino runs the `Generate_Alphanumeric` sketch from the
[Entropy library](https://github.com/pmjdebruijn/Arduino-Entropy-Library),
which uses Watchdog Timer jitter to generate hardware true random numbers,
encoded as 16-character base-62 strings (~95.3 bits of entropy each).

---

## 2. Prerequisites

### Required

| Item | Notes |
|---|---|
| Arduino UNO R3 | Vendor 0x2341, Product 0x0043 |
| USB-A to USB-B cable | Standard Arduino cable |
| Zig compiler | 0.16.0-dev.164+ (see §12 for version notes) |
| libc headers | Needed for termios — standard on any Linux with build tools |

### Check Zig is installed

```bash
zig version
# Expected: 0.16.0-dev.164+bc7955306 (or newer)
```

If Zig is not installed, download a pre-built binary from
https://ziglang.org/download/ and extract it somewhere on your `PATH`.
No package manager needed — Zig ships as a single self-contained tarball.

### Check libc headers

```bash
ls /usr/include/termios.h
```

If missing, install with:

```bash
sudo apt install libc6-dev     # Debian/Ubuntu
sudo dnf install glibc-devel   # Fedora/RHEL
```

---

## 3. Hardware setup

1. Connect the Arduino UNO R3 to a USB port.
2. Verify it is detected:

```bash
lsusb | grep 2341
# Arduino SA Uno R3 (CDC ACM)

ls /dev/ttyACM*
# /dev/ttyACM0
```

The kernel driver `cdc_acm` creates the `/dev/ttyACM0` device node
automatically. No additional drivers are needed on Linux.

If you have multiple Arduino boards connected, the port number increments:
`/dev/ttyACM1`, `/dev/ttyACM2`, etc. The program is hardcoded to
`/dev/ttyACM0` — edit `src/main.zig` line 9 if your port differs.

---

## 4. Arduino sketch setup

The program expects the Arduino to be running the `Generate_Alphanumeric`
sketch. This sketch:

- Outputs one 16-character alphanumeric string per line via `Serial.println()`
- Baud rate: **9600**
- Character set: `0-9`, `A-Z`, `a-z` (base-62, 62 possible chars)
- Rate: ~2 strings per second (limited by the entropy pool fill rate)

### Flash the sketch

The sketch lives at:
```
../arduino_entropy/library/Entropy/examples/Generate_Alphanumeric/Generate_Alphanumeric.ino
```

Flash it with the Arduino CLI:
```bash
arduino --upload \
  --port /dev/ttyACM0 \
  --board arduino:avr:uno \
  ../arduino_entropy/library/Entropy/examples/Generate_Alphanumeric/Generate_Alphanumeric.ino
```

Or via the Arduino IDE: open the `.ino` file, select **Tools → Board → Arduino UNO**,
select **Tools → Port → /dev/ttyACM0**, click **Upload**.

### Verify the sketch is running

```bash
# Quick sanity check — should see 16-char strings scrolling by
timeout 5 cat /dev/ttyACM0
```

Example output:
```
xK7mQpN3wZvR5tL9
Yc2bHdJeUfAg0sOi
```

If nothing appears, the sketch may not be loaded or the baud rate
may not match. See §10 Troubleshooting.

---

## 5. Building from source

### Project layout

```
2026-03-13_arduino-serial-capture/
├── build.zig             ← Zig build script
├── src/
│   └── main.zig          ← all program logic (~109 lines)
├── demo.sh               ← live demo runner with preflight + summary
├── analyze.sh            ← post-capture log file analyzer
├── sample_output.txt     ← 38 real strings captured 2026-03-13
├── HOWTO.md              ← this file
├── GITHUB_README.md      ← public-facing README for a git repo
├── README.md             ← quickstart + newbie CLI guide
└── zig-out/
    └── bin/
        └── arduino-capture   ← compiled binary (after build)
```

### Build

```bash
cd 2026-03-13_arduino-serial-capture/
zig build
```

The binary is placed at `zig-out/bin/arduino-capture`. There is no install
step needed — run it in place.

### Build options

```bash
# Debug build (default) — includes safety checks, larger binary
zig build

# Release — optimized, smaller, faster
zig build -Doptimize=ReleaseFast

# Cross-compile to another target (example: ARM Linux)
zig build -Dtarget=aarch64-linux-gnu
```

### Run directly via build system

```bash
zig build run
# or with a log file:
zig build run -- entropy.log
```

---

## 6. Running the program

### Stdout only

```bash
./zig-out/bin/arduino-capture
```

Status messages go to **stderr**, timestamped data goes to **stdout**.
This lets you pipe or redirect data independently:

```bash
# Redirect data to a file, watch status on terminal
./zig-out/bin/arduino-capture > entropy.log

# Pipe data into another program
./zig-out/bin/arduino-capture | grep "^17"
```

Press **Ctrl+C** to stop. The program runs indefinitely.

### Cold start timing

Expect roughly **40 seconds** of noise before clean output appears. The
delay has two parts:

1. **DTR reset (~2s):** Opening the serial port asserts the DTR line, which
   triggers the Arduino's hardware reset circuit. The Optiboot bootloader
   runs briefly before handing off to the sketch.

2. **Entropy pool fill (~4–6s):** `Entropy.initialize()` in `setup()` starts
   the Watchdog Timer interrupt and waits for the 8-entry pool to fill. Each
   entry takes ~16ms of jitter collection × 32 bytes = ~0.5s per entry ×
   8 entries ≈ 4 seconds.

3. **tty stabilization (~30s):** During initial reads the kernel tty driver
   may have stale termios settings from previous `cat`/`stty` calls on the
   same port. `tcflush(TCIFLUSH)` discards the kernel rx buffer at open time,
   but the first several strings may still have short, merged, or split content
   while the line-discipline state settles.

After the cold-start period, output locks into clean 16-character strings at
a steady rate of roughly **0.3 strings/second** (observed; entropy pool is
the bottleneck, not baud rate).

The `demo.sh` script warns about this and the `analyze.sh` script reports
how many of your captured records passed the 16-char length check.

---

## 7. Output format

Each line printed to stdout:

```
<unix_timestamp> <16-char string>
```

Example:

```
1773442646 Smq0CVOTvdrZ0Fz
1773442650 ASxQkb89eBLvAHSm
1773442652 nR3pT7uW1qXjMvK8
```

- **unix_timestamp**: seconds since epoch (UTC), `i64`, from `std.time.timestamp()`
- **string**: exactly 16 characters, base-62 (`[0-9A-Za-z]`), from the Arduino

Strings are separated by newlines. No header, no footer.

---

## 8. Logging to a file

Pass a filename as the first argument:

```bash
./zig-out/bin/arduino-capture entropy.log
```

The program:
- Creates the file if it does not exist
- **Appends** to the file if it already exists (never truncates)
- Writes the same `timestamp string\n` format as stdout

To collect a long-running dataset:

```bash
# Run in background, append forever
nohup ./zig-out/bin/arduino-capture /var/log/entropy.log &

# Watch the file grow
tail -f /var/log/entropy.log
```

### Rotating logs manually

Since the program always appends, you can rotate by stopping it,
moving/archiving the file, and restarting:

```bash
kill %1                        # stop background job
mv entropy.log entropy_old.log
./zig-out/bin/arduino-capture entropy.log &
```

---

## 9. Permissions

The device `/dev/ttyACM0` is owned by `root:dialout`:

```
crw-rw----+ 1 root dialout 166, 0  /dev/ttyACM0
```

Your user must be in the `dialout` group:

```bash
groups | grep dialout
```

If not listed:

```bash
sudo usermod -aG dialout $USER
# Log out and back in for the group change to take effect
```

Verify after re-login:

```bash
groups
# should include: dialout
```

Do **not** run the program with `sudo` — group membership is the correct fix.

---

## 10. Troubleshooting

### "Failed to open /dev/ttyACM0"

**Cause:** Device not present or permission denied.

```bash
# Check device exists
ls -l /dev/ttyACM*

# Check your groups
groups | grep dialout

# Check what's using the port
fuser /dev/ttyACM0
```

If `fuser` shows a PID, another program (Arduino IDE serial monitor,
`screen`, another `cat`) has the port open. Close it first.

---

### No output / program hangs silently

**Cause A:** Arduino sketch not loaded or running a different sketch.

```bash
timeout 5 cat /dev/ttyACM0   # should show 16-char strings
```

If blank, re-flash the `Generate_Alphanumeric` sketch (§4).

**Cause B:** Cold-start delay. Wait up to ~40 seconds after the program
starts — see §6 for the full breakdown of why.

**Cause C:** Port baud rate mismatch. The program sets 9600 in termios;
the sketch must also use `Serial.begin(9600)`. Confirm in the `.ino` file.

---

### Garbled / binary-looking output

**Cause:** Baud rate mismatch or wrong sketch.

Check:
```bash
stty -F /dev/ttyACM0
# Should show: speed 9600 baud
```

If the speed shown is wrong, another program may have changed it.
Unplug and replug the Arduino to reset the tty state, then rerun.

---

### "tcgetattr failed" or "tcsetattr failed"

**Cause:** The file descriptor is not a tty (e.g., testing with a regular
file) or a permissions issue at the OS level.

Confirm the device is a character device:
```bash
file /dev/ttyACM0
# /dev/ttyACM0: character special (166/0)
```

---

### Build fails: "libc headers not available"

```bash
sudo apt install libc6-dev
zig build
```

---

### Build fails: "no field named 'root_source_file'"

You are running a Zig version older than approximately 0.14.0-dev where
`addExecutable` still took `root_source_file` directly. The `build.zig`
in this project uses the newer `root_module` API. Either update Zig, or
rewrite `build.zig` to match your version's API.

---

## 11. Code internals

`src/main.zig` is ~109 lines. Here is what each section does.

### `@cImport` block (lines 2–7)

Imports four C headers via Zig's C interop:
- `termios.h` — serial port configuration structs and constants
- `fcntl.h` — `O_RDWR`, `O_NOCTTY` flags for `open()`
- `unistd.h` — `open()`, `read()`, `close()`, `write()`
- `errno.h` — `__errno_location()` for error codes

Zig's `@cImport` runs the C preprocessor and makes all symbols available
as `c.CONSTANT` / `c.function()`.

### `configureSerial(fd)` (lines 11–44)

Sets up the tty in **raw 8N1 mode** at 9600 baud:

| Setting | Meaning |
|---|---|
| `cfsetispeed / cfsetospeed` | Set baud rate to B9600 |
| `c_cflag`: CS8 | 8 data bits |
| `~PARENB` | No parity |
| `~CSTOPB` | 1 stop bit |
| `~CRTSCTS` | No hardware flow control |
| `CLOCAL \| CREAD` | Ignore modem lines, enable receiver |
| `c_lflag`: `~(ECHO\|ICANON\|ISIG\|IEXTEN)` | Raw mode: no echo, no line editing, no signals |
| `c_oflag`: `~OPOST` | No output processing |
| `c_iflag`: `~(ICRNL\|IXON\|...)` | No CR→NL translation, no flow control |
| `VMIN=1, VTIME=0` | Block `read()` until at least 1 byte |

The `TCSANOW` flag applies settings immediately.

### `writeLine(log_file, ts, line)` (lines 47–52)

Formats `"{ts} {line}\n"` into a stack buffer via `std.fmt.bufPrint`,
then calls `c.write(1, ...)` for stdout and optionally `File.writeAll`
for the log file. Uses the C `write()` syscall for stdout because
`std.io` was removed in Zig 0.16.0-dev (see §12).

### `main()` (lines 54–108)

1. Initializes a `GeneralPurposeAllocator` for the line buffer
2. Parses args — if arg[1] exists, opens it as an append-mode log file
3. Opens `/dev/ttyACM0` with `O_RDWR | O_NOCTTY`
4. Calls `configureSerial`
5. Calls `tcflush(fd, TCIFLUSH)` to discard bytes accumulated in the
   kernel rx buffer between the Arduino connecting and this program opening
   the port — prevents a burst of stale/partial data at startup
6. Enters a `while(true)` read loop:
   - Calls blocking `c.read()` — waits for data (VMIN=1), zero CPU spin
   - Iterates received bytes one at a time
   - Accumulates non-line-ending bytes in an `ArrayList(u8)` line buffer
   - On **`\r` or `\n`**: if the buffer is non-empty, timestamps and prints
     the line, then clears the buffer. Skips the flush if the buffer is empty,
     which prevents double-printing from `\r\n` pairs.

The dual `\r`/`\n` detection (rather than `\n`-only with trimRight) was added
after observing that the cdc_acm kernel driver occasionally delivers the `\r`
and `\n` of a `\r\n` pair in separate reads, or with inconsistent translation
depending on prior tty state. Handling either byte as a flush trigger makes
the program robust to all three variants: `\r\n`, `\n`-only, `\r`-only.

---

## 12. Zig version notes

This project was written against **Zig 0.16.0-dev.164+bc7955306**.
The 0.16.0-dev branch introduced several breaking API changes from 0.13/0.14:

| API | Old (≤0.13) | New (0.16.0-dev) |
|---|---|---|
| `addExecutable` | `.root_source_file = b.path(...)` | `.root_module = b.createModule(...)` |
| Standard I/O | `std.io.getStdOut().writer()` | `std.io` removed; use `std.fs.File.stdout()` or C `write()` |
| ArrayList init | `std.ArrayList(T).init(alloc)` | `var x: std.ArrayList(T) = .empty` |
| ArrayList methods | `list.append(item)` | `list.append(alloc, item)` |
| ArrayList deinit | `list.deinit()` | `list.deinit(alloc)` |

If you need to port this to an older Zig version, the main changes are:
1. Revert `build.zig` to use `root_source_file`
2. Replace `c.write(1, ...)` with `std.io.getStdOut().writer().print(...)`
3. Revert ArrayList to managed style with `init(alloc)` / `append(item)` / `deinit()`

---

## 13. Scripts

Two bash helper scripts live alongside the binary.

### `demo.sh` — live demo runner

```bash
./demo.sh              # capture 60s, print summary
./demo.sh 120          # capture 120s
./demo.sh 60 out.log   # capture 60s, save to file, analyze at end
```

**What it does:**
1. Preflight checks: verifies the binary exists, device is present, user is
   in the `dialout` group
2. Prints a header with device, duration, and cold-start warning
3. Runs `arduino-capture` via `timeout`, piping through `tee` to capture
   output while still printing to the terminal live
4. On exit, analyzes the captured lines:
   - Total vs. clean (16-char) records
   - Entropy estimate, rate, character frequency table, last 5 strings

### `analyze.sh` — post-capture log analyzer

```bash
./analyze.sh entropy.log
./analyze.sh sample_output.txt    # included 38-record sample
```

**What it reports:**
- Total / clean / noise record counts
- Timespan (first → last timestamp, human-readable dates)
- Rate (strings/sec) and bits/sec estimate
- String length distribution (shows how many records are clean vs. merged)
- Character frequency: total chars sampled, expected per char (uniform),
  top 10 most frequent, bottom 10 least frequent
- Sample strings (first 5 and last 5 clean)

### `sample_output.txt`

38 real records captured on 2026-03-13 during a 117-second session after
the cold-start period. All are clean 16-char strings. Useful for testing
`analyze.sh` without a live Arduino.

```
1773445130 xMvcpkmdCS4vp4sY
1773445132 IQyxht3tup4FmrZi
...
1773445197 6bc4YzZhjD4hYYfO
```

Aggregate: 608 characters, ~3610 bits of true entropy, 0.32 strings/sec.
