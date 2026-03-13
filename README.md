# arduino-serial-capture
**Date:** 2026-03-13
**Platform:** Linux 6.8.12, Debian/Ubuntu

---

## What is this?

A ~109-line Zig program that sits between your Arduino and your filesystem.
The Arduino generates hardware true-random strings using Watchdog Timer jitter.
This program reads those strings off the USB serial port, stamps each one with
the current Unix time, and prints them to your terminal (or saves them to a file).

That's it. No network, no daemon, no config file. One binary, one USB cable.

---

## What does the Zig program actually do?

Here's the whole flow in plain terms:

**1. Parse arguments**
It checks if you gave it a filename on the command line. If yes, it opens that
file for appending (creates it if it doesn't exist). If no, output goes to your
terminal only.

**2. Open the serial port**
It calls the C function `open("/dev/ttyACM0", O_RDWR | O_NOCTTY)`. That's the
USB device file the kernel creates when the Arduino plugs in. `O_NOCTTY` tells
Linux "don't make this port take over my terminal."

**3. Configure the serial port (termios)**
Raw serial ports default to cooked mode — line editing, echo, signal handling,
all the stuff that makes sense for a keyboard but not for a data stream. The
program calls `tcgetattr` to read the current settings, then reconfigures the
port to:
- **9600 baud** — matching what the Arduino sketch uses
- **8N1** — 8 data bits, No parity, 1 stop bit (the universal default)
- **Raw mode** — no echo, no canonical line editing, no Ctrl+C signal handling
- **No flow control** — neither software (XON/XOFF) nor hardware (RTS/CTS)
- **VMIN=1, VTIME=0** — block on `read()` until at least 1 byte arrives;
  never timeout. This means zero CPU spin while waiting for data.

**4. Flush the receive buffer**
`tcflush(fd, TCIFLUSH)` throws away any bytes that accumulated in the kernel's
serial buffer before we opened the port. Without this, you can get a burst of
stale or partial strings at startup.

**5. Read in a loop**
The main loop calls `read(fd, buf, 256)` which blocks until the Arduino sends
something. When bytes arrive, it scans them one at a time:
- If the byte is `\r` or `\n` (line ending): flush the current line buffer,
  print it with a timestamp, clear the buffer, move on.
- Any other byte: append it to the line buffer.

The dual `\r`/`\n` check handles all variants: `\r\n`, `\n`-only, and `\r`-only,
without double-printing. (The Arduino sends `\r\n` but the tty driver's buffering
sometimes splits or translates them.)

**6. Write output**
Each complete line gets formatted as `{timestamp} {string}\n` using
`std.fmt.bufPrint` into a stack buffer, then written to stdout via `c.write(1,…)`
and optionally to the log file via `file.writeAll(…)`.

---

## Files in this folder

```
2026-03-13_arduino-serial-capture/
├── src/main.zig          The program (~109 lines, all logic lives here)
├── build.zig             Zig build script (how to compile it)
├── zig-out/bin/
│   └── arduino-capture   Compiled binary — run this
├── demo.sh               Live demo runner with preflight checks + summary
├── analyze.sh            Post-capture log file analyzer
├── sample_output.txt     38 real strings captured 2026-03-13
├── README.md             This file
├── HOWTO.md              Full user manual (prerequisites, build, troubleshooting)
└── GITHUB_README.md      Public-facing README for a git repo
```

---

## Build it (one command)

```bash
cd 2026-03-13_arduino-serial-capture/
zig build
```

The binary lands at `zig-out/bin/arduino-capture`. Done.

---

## Run it from the CLI

### The simplest thing

```bash
./zig-out/bin/arduino-capture
```

Status messages print to stderr (your terminal). Data prints to stdout
(also your terminal). You'll see something like:

```
Capturing from /dev/ttyACM0 at 9600 baud. Ctrl+C to stop.
1773445130 xMvcpkmdCS4vp4sY
1773445132 IQyxht3tup4FmrZi
1773445134 NliwBFArVd212UXD
```

Press `Ctrl+C` to stop. It runs forever otherwise.

### The cold-start wait

The first ~40 seconds after connecting are noisy. The Arduino resets when
the serial port opens (a hardware quirk — the DTR line briefly pulses and
triggers the bootloader), then the Entropy library's pool takes ~4-6 seconds
to fill. During this time you'll see short, merged, or garbled strings.
**This is normal.** After about 40 seconds the output locks into clean 16-char
strings at a steady ~0.3 strings/sec.

### Save output to a file

```bash
./zig-out/bin/arduino-capture entropy.log
```

The program prints to your terminal AND appends every line to `entropy.log`.
If the file already exists it appends — it never truncates.

### Capture in the background

```bash
nohup ./zig-out/bin/arduino-capture /var/log/entropy.log &
```

`nohup` keeps it running after you close the terminal. Find its PID with
`pgrep arduino-capture` and stop it with `kill <pid>`.

### Redirect data without status messages

Status messages (stderr) and data (stdout) are on separate streams, so:

```bash
# data to file, status to terminal
./zig-out/bin/arduino-capture > entropy.log

# data to another program, status to terminal
./zig-out/bin/arduino-capture | grep "^17734"

# both streams to separate files
./zig-out/bin/arduino-capture > data.log 2> status.log
```

---

## Demo and analysis scripts

```bash
# Capture 60 seconds live, print summary at the end
./demo.sh

# Capture 120 seconds AND save to a file, then analyze
./demo.sh 120 entropy.log

# Analyze an existing log file
./analyze.sh entropy.log
./analyze.sh sample_output.txt   # run against the included sample
```

---

## Output format

```
<unix_timestamp_seconds> <16-char-string>
```

Example:

```
1773445130 xMvcpkmdCS4vp4sY
1773445132 IQyxht3tup4FmrZi
```

- **Timestamp** — whole seconds since 1970-01-01 00:00:00 UTC. Convert with
  `date -d @1773445130` or `python3 -c "import datetime; print(datetime.datetime.utcfromtimestamp(1773445130))"`
- **String** — 16 characters drawn from `[0-9A-Za-z]` (62 possible values each),
  giving log₂(62¹⁶) ≈ **95 bits of true entropy** per record.

---

## Permissions

The device `/dev/ttyACM0` requires the `dialout` group:

```bash
# Check
groups | grep dialout

# Fix (then log out and back in)
sudo usermod -aG dialout $USER
```

Never run as root. Group membership is the right fix.

---

## Related files

- `../arduino_entropy/` — Arduino library + sketches
- `../2026-03-13_arduino-uno-r3-usb-detection.md` — board detection notes
- `HOWTO.md` — full manual with prerequisites, build options, troubleshooting, code internals
