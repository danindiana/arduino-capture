# arduino-capture — Deployment Guide

**Binary:** `zig-out/bin/arduino-capture`
**Platform:** Linux (Debian/Ubuntu family, kernel 6.8+)
**Device:** `/dev/ttyACM0` at 9600 baud 8N1
**Output format:** `{unix_timestamp} {16-char-base62-string}` one per line to stdout

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Systemd Service — Persistent Daemon](#2-systemd-service--persistent-daemon)
3. [Kernel Entropy Pool Augmentation](#3-kernel-entropy-pool-augmentation)
4. [Named Pipe (FIFO) — Real-Time Feed](#4-named-pipe-fifo--real-time-feed)
5. [Cryptographic Key and Password Generation](#5-cryptographic-key-and-password-generation)
6. [Seeding Application PRNGs](#6-seeding-application-prngs)
7. [Database and Time-Series Logging](#7-database-and-time-series-logging)
8. [Network Entropy Service](#8-network-entropy-service)
9. [Docker and Container Deployment](#9-docker-and-container-deployment)
10. [Logrotate Integration](#10-logrotate-integration)

---

## 1. Prerequisites

Before any deployment scenario, confirm the following are satisfied.

### 1.1 Device is present

```bash
lsusb | grep 2341
ls -l /dev/ttyACM0
# Expected: crw-rw----+ 1 root dialout 166, 0 ...
```

### 1.2 User is in the dialout group

```bash
groups | grep dialout
```

If not listed, add the user and re-login:

```bash
sudo usermod -aG dialout $USER
# Log out and back in, or: newgrp dialout
```

Never run the binary as root. Group membership is the correct and sufficient fix.

### 1.3 Binary is built

```bash
ls -lh zig-out/bin/arduino-capture
# If missing:
zig build -Doptimize=ReleaseFast
```

### 1.4 Cold-start behavior

Every time the serial port is opened, the Arduino resets (DTR pulse triggers the
bootloader reset circuit). The Entropy library pool then takes approximately 4-6
seconds to fill. Combined with tty line-discipline stabilization, expect roughly
**40 seconds** of noise before clean 16-character strings appear. This applies to
every deployment scenario — factor it into restart policies and timing expectations.

---

## 2. Systemd Service — Persistent Daemon

Run `arduino-capture` as a background service that starts at boot,
auto-restarts on failure, and logs to a persistent file.

### 2.1 Install the binary system-wide

```bash
sudo cp zig-out/bin/arduino-capture /usr/local/bin/arduino-capture
sudo chmod 755 /usr/local/bin/arduino-capture
```

### 2.2 Create the log directory

```bash
sudo mkdir -p /var/log/arduino-entropy
sudo chown root:dialout /var/log/arduino-entropy
sudo chmod 775 /var/log/arduino-entropy
```

### 2.3 Write the unit file

Create `/etc/systemd/system/arduino-capture.service`:

```ini
[Unit]
Description=Arduino Hardware Entropy Capture
Documentation=https://github.com/danindiana/arduino-capture
After=dev-ttyACM0.device
Requires=dev-ttyACM0.device
BindsTo=dev-ttyACM0.device

[Service]
Type=simple
User=nobody
Group=dialout
ExecStart=/usr/local/bin/arduino-capture /var/log/arduino-entropy/entropy.log
Restart=on-failure
RestartSec=10s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=arduino-capture

# Allow up to 90s for cold-start before declaring failure
TimeoutStartSec=90

# BindsTo= causes the service to stop automatically on USB unplug
# and restart (per Restart=) when the device reappears

[Install]
WantedBy=multi-user.target
```

### 2.4 Enable and start

```bash
sudo systemctl daemon-reload
sudo systemctl enable arduino-capture.service
sudo systemctl start arduino-capture.service
```

### 2.5 Verify

```bash
sudo systemctl status arduino-capture.service
sudo journalctl -u arduino-capture -f
tail -f /var/log/arduino-entropy/entropy.log
```

### 2.6 Device-triggered start via udev

Create `/etc/udev/rules.d/99-arduino-capture.rules`:

```
ACTION=="add", SUBSYSTEM=="tty", ATTRS{idVendor}=="2341", ATTRS{idProduct}=="0043", \
    TAG+="systemd", ENV{SYSTEMD_WANTS}="arduino-capture.service"

ACTION=="remove", SUBSYSTEM=="tty", ATTRS{idVendor}=="2341", ATTRS{idProduct}=="0043", \
    RUN+="/bin/systemctl stop arduino-capture.service"
```

```bash
sudo udevadm control --reload-rules
```

---

## 3. Kernel Entropy Pool Augmentation

The Linux kernel's entropy pool (`/dev/random`, `/dev/urandom`) can be
supplemented with the Arduino TRNG output via `rngd` from `rng-tools`.

### 3.1 Install rng-tools

```bash
sudo apt install rng-tools    # Debian/Ubuntu
sudo dnf install rng-tools    # Fedora/RHEL
```

### 3.2 Feed entropy via a named pipe

```bash
mkfifo /run/arduino-entropy.fifo

# Strip timestamps, write raw base-62 bytes to the FIFO
./zig-out/bin/arduino-capture 2>/dev/null \
    | awk '{print $2}' \
    | tr -d '\n' \
    > /run/arduino-entropy.fifo &

# Feed the FIFO into the kernel entropy pool
# --rng-entropy: trust level 0.0–1.0; use 0.5 for base-62 TRNG conservatively
sudo rngd --foreground \
    --rng-device=/run/arduino-entropy.fifo \
    --rng-entropy=0.5 \
    --feed-interval=1
```

### 3.3 Verify entropy pool is growing

```bash
watch -n1 cat /proc/sys/kernel/random/entropy_avail
# Should climb toward ~3000+ bits
```

### 3.4 Alternative: direct ioctl (no rngd required)

```python
#!/usr/bin/env python3
"""feed-entropy.py — write Arduino TRNG bytes directly to /dev/random (requires root)"""
import sys, struct, fcntl

RNDADDENTROPY = 0x40085203   # from <linux/random.h>

def add_entropy(data: bytes, bits: int):
    buf = struct.pack("ii", bits, len(data)) + data
    with open("/dev/random", "wb") as f:
        fcntl.ioctl(f, RNDADDENTROPY, buf)

for line in sys.stdin:
    parts = line.strip().split()
    if len(parts) == 2 and len(parts[1]) == 16:
        add_entropy(parts[1].encode(), 95)
```

```bash
./zig-out/bin/arduino-capture 2>/dev/null | sudo python3 feed-entropy.py
```

---

## 4. Named Pipe (FIFO) — Real-Time Feed

A FIFO lets other programs consume the entropy stream without opening the
serial device directly.

### 4.1 Create and use the FIFO

```bash
mkfifo /tmp/arduino-entropy

# Producer: runs in background, writes to FIFO
./zig-out/bin/arduino-capture 2>/dev/null > /tmp/arduino-entropy &

# Consumer: reads from FIFO
cat /tmp/arduino-entropy

# Consumer: extract strings only (no timestamps)
cat /tmp/arduino-entropy | awk '{print $2}'
```

Note: a FIFO blocks the writer until a reader opens the other end. Start the
consumer before or concurrently with the producer.

### 4.2 Fan out to multiple consumers with tee

```bash
mkfifo /tmp/entropy-a /tmp/entropy-b

./zig-out/bin/arduino-capture 2>/dev/null \
    | tee /tmp/entropy-a /tmp/entropy-b > /dev/null &

cat /tmp/entropy-a &    # reader A
cat /tmp/entropy-b &    # reader B
```

### 4.3 Line-by-line consumer in bash

```bash
while IFS= read -r line; do
    ts=$(echo "$line" | awk '{print $1}')
    str=$(echo "$line" | awk '{print $2}')
    echo "[$ts] Got entropy: $str"
    # application logic here
done < /tmp/arduino-entropy
```

---

## 5. Cryptographic Key and Password Generation

Each 16-char string carries ~95 bits of true entropy. Accumulate strings to
reach your target entropy budget.

### 5.1 256-bit seed (3 strings = ~285 bits)

```bash
SEED=$(./zig-out/bin/arduino-capture 2>/dev/null \
    | grep -m3 -E '^[0-9]+ [0-9A-Za-z]{16}$' \
    | awk '{printf $2}')

echo "Seed (48 chars, ~285 bits): $SEED"

# Hash to 32 bytes for AES-256
KEY=$(echo -n "$SEED" | sha256sum | awk '{print $1}')
echo "Derived key: $KEY"
```

### 5.2 Generate an RSA key seeded from hardware entropy

```bash
# Collect 64 bytes of entropy (~7 strings) as a seed file
./zig-out/bin/arduino-capture 2>/dev/null \
    | grep -m7 -E '^[0-9]+ [0-9A-Za-z]{16}$' \
    | awk '{printf $2}' \
    | head -c 64 > /tmp/entropy.seed

openssl genpkey \
    -algorithm RSA \
    -pkeyopt rsa_keygen_bits:4096 \
    -rand /tmp/entropy.seed \
    -out mykey.pem

rm -f /tmp/entropy.seed
```

### 5.3 One-shot password generation

```bash
# Single 16-char string — already ~95 bits, ready to use
./zig-out/bin/arduino-capture 2>/dev/null \
    | grep -m1 -E '^[0-9]+ [0-9A-Za-z]{16}$' \
    | awk '{print $2}'

# Longer password: concatenate 4 strings with separators
./zig-out/bin/arduino-capture 2>/dev/null \
    | grep -m4 -E '^[0-9]+ [0-9A-Za-z]{16}$' \
    | awk '{printf $2}' \
    | fold -w 16 | paste -sd'-'
# e.g.: xMvcpkmdCS4vp4sY-IQyxht3tup4FmrZi-NliwBFArVd212UXD-kwVzNYd5wDNfitLm
```

### 5.4 Reusable password script

```bash
#!/usr/bin/env bash
# hwpasswd — hardware-entropy password generator
# Usage: ./hwpasswd [length]   (default: 24)
LENGTH="${1:-24}"
NEEDED=$(( (LENGTH + 15) / 16 ))

./zig-out/bin/arduino-capture 2>/dev/null \
    | grep -m"$NEEDED" -E '^[0-9]+ [0-9A-Za-z]{16}$' \
    | awk '{printf $2}' \
    | head -c "$LENGTH"
echo
```

### 5.5 SSH ed25519 key with hardware-seeded pool

```bash
# After feeding entropy into the kernel pool (§3):
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_hw \
    -C "hardware-seeded-$(date +%Y%m%d)"
```

---

## 6. Seeding Application PRNGs

### 6.1 Python — explicit PRNG seed from hardware

```python
#!/usr/bin/env python3
"""seed-python-prng.py — seed Python random from Arduino TRNG via stdin"""
import sys, random

line = sys.stdin.readline().strip()
parts = line.split()
if len(parts) == 2 and len(parts[1]) == 16:
    chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    seed_int = 0
    for ch in parts[1]:
        seed_int = seed_int * 62 + chars.index(ch)
    random.seed(seed_int)
    print(f"Seeded with: {parts[1]}  (int={seed_int})")
    print(f"First random: {random.random():.6f}")
else:
    print("Invalid format", file=sys.stderr)
    sys.exit(1)
```

```bash
./zig-out/bin/arduino-capture 2>/dev/null \
    | grep -m1 -E '^[0-9]+ [0-9A-Za-z]{16}$' \
    | python3 seed-python-prng.py
```

### 6.2 Node.js — consume entropy from the stream

```javascript
// entropy-client.js
process.stdin.resume();
process.stdin.setEncoding('utf8');
let buf = '';
process.stdin.on('data', chunk => {
    buf += chunk;
    const lines = buf.split('\n');
    buf = lines.pop();
    for (const line of lines) {
        const parts = line.trim().split(' ');
        if (parts.length === 2 && /^[0-9A-Za-z]{16}$/.test(parts[1])) {
            console.log('entropy:', parts[1]);
            console.log('hex:', Buffer.from(parts[1], 'ascii').toString('hex'));
            process.exit(0);
        }
    }
});
```

```bash
./zig-out/bin/arduino-capture 2>/dev/null | node entropy-client.js
```

### 6.3 Shell — read N strings as seeds

```bash
N=5
./zig-out/bin/arduino-capture 2>/dev/null \
    | grep -m"$N" -E '^[0-9]+ [0-9A-Za-z]{16}$' \
    | while IFS= read -r line; do
        TS=$(echo "$line" | awk '{print $1}')
        STR=$(echo "$line" | awk '{print $2}')
        echo "[$TS] seed: $STR"
    done
```

---

## 7. Database and Time-Series Logging

### 7.1 SQLite

```bash
# One-time schema creation
sqlite3 /var/db/entropy.db \
    "CREATE TABLE IF NOT EXISTS entropy (
        id       INTEGER PRIMARY KEY AUTOINCREMENT,
        ts       INTEGER NOT NULL,
        string   TEXT    NOT NULL CHECK(length(string) = 16),
        captured DATETIME DEFAULT CURRENT_TIMESTAMP
    );"

# Live ingestion
./zig-out/bin/arduino-capture 2>/dev/null \
    | grep -E '^[0-9]+ [0-9A-Za-z]{16}$' \
    | while IFS=' ' read -r ts str; do
        sqlite3 /var/db/entropy.db \
            "INSERT INTO entropy (ts, string) VALUES ($ts, '$str');"
    done
```

```bash
# Query examples
sqlite3 /var/db/entropy.db "SELECT COUNT(*) FROM entropy;"
sqlite3 /var/db/entropy.db \
    "SELECT ts, string FROM entropy ORDER BY id DESC LIMIT 10;"
```

### 7.2 InfluxDB line protocol

```bash
./zig-out/bin/arduino-capture 2>/dev/null \
    | grep -E '^[0-9]+ [0-9A-Za-z]{16}$' \
    | awk '{
        printf "arduino_entropy,device=ttyACM0 string=\"%s\" %d000000000\n", $2, $1
    }' \
    | curl --silent --request POST \
        "http://localhost:8086/api/v2/write?org=YOUR_ORG&bucket=entropy&precision=ns" \
        --header "Authorization: Token YOUR_TOKEN" \
        --data-binary @-
```

### 7.3 CSV flat-file logging

```bash
echo "datetime,unix_ts,entropy_string" > /var/log/entropy.csv

./zig-out/bin/arduino-capture 2>/dev/null \
    | grep -E '^[0-9]+ [0-9A-Za-z]{16}$' \
    | awk '{
        cmd = "date -d @" $1 " +\"%Y-%m-%dT%H:%M:%SZ\""
        cmd | getline dt; close(cmd)
        printf "%s,%s,%s\n", dt, $1, $2
    }' >> /var/log/entropy.csv
```

---

## 8. Network Entropy Service

Serve the live entropy stream over TCP so other machines can consume it
without USB access to the Arduino.

### 8.1 Simple server with socat (recommended)

```bash
# Server: listen on TCP port 4444, fork a new connection handler per client
./zig-out/bin/arduino-capture 2>/dev/null \
    | socat - TCP-LISTEN:4444,reuseaddr,fork
```

```bash
# Client (any machine on the LAN):
nc 192.168.1.100 4444
```

### 8.2 Simple server with netcat (one client at a time)

```bash
while true; do
    ./zig-out/bin/arduino-capture 2>/dev/null \
        | nc -l -p 4444 -q 1
done
```

### 8.3 Restrict to localhost only

```bash
socat EXEC:"./zig-out/bin/arduino-capture 2>/dev/null" \
    TCP-LISTEN:4444,bind=127.0.0.1,reuseaddr,fork
```

### 8.4 SSH tunnel for remote access (encrypted)

```bash
# Server: bind to localhost
./zig-out/bin/arduino-capture 2>/dev/null \
    | socat - TCP-LISTEN:4444,bind=127.0.0.1,reuseaddr,fork &

# Client: forward via SSH, then read
ssh -L 4444:127.0.0.1:4444 user@server "sleep infinity" &
nc 127.0.0.1 4444
```

### 8.5 Security note

Raw entropy in plaintext is safe to transmit on a trusted LAN (it reveals
nothing about future output). Over untrusted networks, use the SSH tunnel
approach above.

---

## 9. Docker and Container Deployment

### 9.1 Quick run

```bash
# Copy binary to a shared volume
mkdir -p /var/log/arduino-entropy
cp zig-out/bin/arduino-capture /var/log/arduino-entropy/

docker run --rm \
    --device=/dev/ttyACM0 \
    --group-add dialout \
    -v /var/log/arduino-entropy:/data \
    ubuntu:24.04 \
    /data/arduino-capture /data/entropy.log
```

### 9.2 Dockerfile

```dockerfile
FROM ubuntu:24.04

COPY zig-out/bin/arduino-capture /usr/local/bin/arduino-capture
RUN chmod 755 /usr/local/bin/arduino-capture && mkdir -p /data

RUN groupadd -g 20 dialout-host 2>/dev/null || true && \
    useradd -u 1000 -G dialout-host capture

USER capture
VOLUME ["/data"]

ENTRYPOINT ["/usr/local/bin/arduino-capture"]
CMD ["/data/entropy.log"]
```

```bash
docker build -t arduino-capture:latest .

docker run -d \
    --name entropy-daemon \
    --device=/dev/ttyACM0:/dev/ttyACM0 \
    --group-add $(getent group dialout | cut -d: -f3) \
    -v $(pwd)/data:/data \
    arduino-capture:latest
```

### 9.3 Docker Compose

```yaml
# docker-compose.yml
services:
  entropy:
    image: arduino-capture:latest
    restart: unless-stopped
    devices:
      - /dev/ttyACM0:/dev/ttyACM0
    group_add:
      - dialout
    volumes:
      - entropy-data:/data
    command: ["/data/entropy.log"]

volumes:
  entropy-data:
```

```bash
docker compose up -d
docker compose logs -f entropy
```

### 9.4 Device access notes

- The host's `cdc_acm` kernel module manages `/dev/ttyACM0`. The container
  uses `--device` to pass the character device node through — no kernel module
  needed inside the container.
- If the Arduino is unplugged while the container is running, the service
  will error. With `restart: unless-stopped` it will restart and reconnect.
- On cgroups v2 systems, `--device-cgroup-rule` may be needed instead of
  `--device` for finer-grained control.

---

## 10. Logrotate Integration

The program appends to its log file indefinitely. Use logrotate to manage
size and retention.

### 10.1 Logrotate config

Create `/etc/logrotate.d/arduino-capture`:

```
/var/log/arduino-entropy/entropy.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    dateext
    dateformat -%Y%m%d

    postrotate
        # Restart the service so it opens a fresh file at the original path.
        # arduino-capture holds the file open by fd; copytruncate risks data loss.
        systemctl restart arduino-capture.service 2>/dev/null || true
    endscript
}
```

The `postrotate` restart causes a ~40-second cold-start gap per rotation —
acceptable for daily rotation. The `delaycompress` directive keeps yesterday's
rotated file uncompressed for one extra day in case a postrotate failure needs
manual inspection.

### 10.2 Alternative: copytruncate (no restart, small data loss risk)

```
/var/log/arduino-entropy/entropy.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
```

`copytruncate` copies then truncates in-place — the program continues writing to
the same fd, but a small number of lines written between copy and truncate may be
duplicated or lost.

### 10.3 Manual rotation

```bash
sudo systemctl stop arduino-capture.service
sudo mv /var/log/arduino-entropy/entropy.log \
        /var/log/arduino-entropy/entropy-$(date +%Y%m%d).log
sudo gzip /var/log/arduino-entropy/entropy-$(date +%Y%m%d).log
sudo systemctl start arduino-capture.service
```

### 10.4 Test without waiting

```bash
sudo logrotate --debug /etc/logrotate.d/arduino-capture
sudo logrotate --force /etc/logrotate.d/arduino-capture
```
