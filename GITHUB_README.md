# arduino-capture

A ~109-line Zig program that reads a hardware true-random entropy stream from
an Arduino UNO R3 over USB serial, timestamps each line, and writes output to
stdout and/or a log file.

The Arduino runs the
[Entropy library](https://github.com/pmjdebruijn/Arduino-Entropy-Library)
`Generate_Alphanumeric` sketch, which exploits Watchdog Timer jitter on the
ATmega328P to produce hardware true random numbers — no PRNG, no seed.

---

## Demo

Real output from a live session (2026-03-13):

```
$ ./zig-out/bin/arduino-capture
Capturing from /dev/ttyACM0 at 9600 baud. Ctrl+C to stop.
1773445130 xMvcpkmdCS4vp4sY
1773445132 IQyxht3tup4FmrZi
1773445134 NliwBFArVd212UXD
1773445136 kwVzNYd5wDNfitLm
1773445138 9xmcFTCeG4EhVmD4
1773445140 ammmnmeWYsFOBNxV
^C
```

Each line: Unix timestamp + 16-character base-62 string ≈ **95 bits of true
entropy** per record. See `sample_output.txt` for 38 captured records.

> **Cold-start note:** expect ~40 seconds of noise after first connect before
> clean 16-char strings appear. The Arduino resets on DTR and the entropy pool
> needs ~4-6 seconds to fill. See [HOWTO.md](HOWTO.md) for details.

---

## Hardware

- **Arduino UNO R3** (ATmega328P, USB VID/PID `2341:0043`)
- Standard USB-A to USB-B cable
- Appears as `/dev/ttyACM0` on Linux (kernel driver: `cdc_acm`)

---

## Requirements

| Requirement | Notes |
|---|---|
| **Zig** ≥ 0.16.0-dev.164 | [ziglang.org/download](https://ziglang.org/download/) |
| **libc headers** | `sudo apt install libc6-dev` |
| **dialout group** | `sudo usermod -aG dialout $USER` |
| **Arduino sketch** | `Generate_Alphanumeric` from Entropy library |

---

## Build

```bash
git clone <this-repo>
cd arduino-capture
zig build
```

Binary: `zig-out/bin/arduino-capture`

Release build:

```bash
zig build -Doptimize=ReleaseFast
```

---

## Usage

```bash
# Stream to terminal (Ctrl+C to stop)
./zig-out/bin/arduino-capture

# Stream to terminal AND append to a log file
./zig-out/bin/arduino-capture entropy.log

# Data on stdout, status on stderr — pipe freely
./zig-out/bin/arduino-capture | tee entropy.log | wc -l

# Background capture
nohup ./zig-out/bin/arduino-capture /var/log/entropy.log &
```

---

## Demo and analysis scripts

```bash
# 60-second live demo with preflight checks and summary
./demo.sh

# Custom duration + save to file, analyze at end
./demo.sh 120 entropy.log

# Analyze any captured log
./analyze.sh entropy.log
./analyze.sh sample_output.txt
```

`demo.sh` output:

```
────────────────────────────────────────────────────
  arduino-capture — hardware entropy demo
────────────────────────────────────────────────────
  Device : /dev/ttyACM0
  Capture: 60s
  NOTE: ~40s cold-start before clean output appears.
────────────────────────────────────────────────────
  ...live output...
────────────────────────────────────────────────────
  SUMMARY  (60s elapsed)
  Total records  : 12
  Clean (16-char): 9
  Entropy (est.) : ~855 bits
  Rate           : 0.15 strings/sec
────────────────────────────────────────────────────
```

---

## Output format

```
<unix_timestamp> <16-char base-62 string>
```

- Timestamp: `i64` seconds since UTC epoch
- String: `[0-9A-Za-z]{16}`, ~95.3 bits true entropy each
- Steady-state rate: ~0.3 strings/sec after cold start

From `sample_output.txt` (38 real records, 117 seconds, ~3610 bits):

```
1773445147 YnGlLmmzrJQe3Fby
1773445149 3e91nEKULrIsnpod
1773445151 FTDjoVD2nwE0NyrI
1773445153 2MRvJc8qwRYo09XF
1773445155 7zzTr8NIZfGfyZY8
```

---

## How it works

The program opens `/dev/ttyACM0` and configures it using POSIX termios via
Zig's `@cImport`:

- **9600 baud, 8N1, raw mode** — no echo, no canonical processing, no signal
  handling, no CR/NL translation, no flow control
- **Blocking reads** (`VMIN=1, VTIME=0`) — `read()` sleeps until a byte
  arrives; zero CPU spin while idle
- **`tcflush(TCIFLUSH)`** after configuration — discards bytes accumulated in
  the kernel rx buffer during startup
- **Dual `\r`/`\n` line-end detection** — flushes the line buffer on either
  byte, skipping empties; handles `\r\n`, `\n`-only, and `\r`-only without
  double-printing

Incoming bytes accumulate in a `std.ArrayList(u8)`. On each line ending, the
line is formatted as `"{timestamp} {string}\n"` via `std.fmt.bufPrint` into a
stack buffer, then written atomically to stdout and (if given) a log file.

### Why `@cImport` for termios?

Zig's standard library doesn't expose `cfsetispeed`/`cfsetospeed` or the full
termios constant set as native Zig APIs. `@cImport` pulls in `termios.h` at
compile time — no C source files, no Makefile, just Zig calling POSIX directly.

---

## Entropy source

The Arduino sketch uses Walter Anderson's Entropy library:

- Repurposes the AVR Watchdog Timer (WDT) as a true entropy source
- WDT fires every ~16ms; timing jitter is collected (32 bytes), hashed with
  Jenkins' one-at-a-time, fed into an 8-entry 32-bit circular pool
- `Entropy.random(62)` uses rejection sampling on raw bytes: acceptance rate
  96.9%, wastes <3.2% of pool — near-optimal for base-62
- Each 16-char string draws 16 independent calls: **log₂(62¹⁶) ≈ 95.3 bits**

Pool fill time: ~4-6 seconds cold. DTR reset on port open adds another ~2
seconds of bootloader, making practical cold-start ~40 seconds total before
output stabilizes.

---

## Project layout

```
arduino-capture/
├── src/main.zig          All program logic (~109 lines)
├── build.zig             Zig build script
├── demo.sh               Live demo runner with preflight + summary
├── analyze.sh            Post-capture log file analyzer
├── sample_output.txt     38 real strings captured 2026-03-13
├── README.md             Quickstart + newbie CLI guide
├── HOWTO.md              Full user manual (prereqs, build, debug, internals)
└── GITHUB_README.md      This file
```

---

## Zig version compatibility

Written against **Zig 0.16.0-dev.164**. Breaking changes from 0.13/0.14:

| API | Old | New |
|---|---|---|
| `addExecutable` | `.root_source_file = b.path(…)` | `.root_module = b.createModule(…)` |
| Standard I/O | `std.io.getStdOut().writer()` | `std.io` removed; use `c.write(1,…)` |
| ArrayList init | `ArrayList(T).init(alloc)` | `var x: ArrayList(T) = .empty` |
| ArrayList ops | `list.append(item)` | `list.append(alloc, item)` |

See [HOWTO.md §12](HOWTO.md#12-zig-version-notes) for the full table and
porting instructions to older Zig.

---

## License

MIT — do whatever you want with it.
