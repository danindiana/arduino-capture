const std = @import("std");
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
});

const DEVICE = "/dev/ttyACM0";

fn configureSerial(fd: c_int) !void {
    var tty: c.struct_termios = std.mem.zeroes(c.struct_termios);

    if (c.tcgetattr(fd, &tty) < 0) {
        _ = c.write(2, "tcgetattr failed\n", 17);
        return error.TcgetattrFailed;
    }

    _ = c.cfsetispeed(&tty, c.B9600);
    _ = c.cfsetospeed(&tty, c.B9600);

    // 8N1
    tty.c_cflag = (tty.c_cflag & ~@as(c_uint, c.CSIZE)) | c.CS8;
    tty.c_cflag &= ~(@as(c_uint, c.PARENB) | @as(c_uint, c.CSTOPB) | @as(c_uint, c.CRTSCTS));
    tty.c_cflag |= @as(c_uint, c.CLOCAL | c.CREAD);

    // Raw input: no echo, no canonical, no signals
    tty.c_lflag &= ~@as(c_uint, c.ECHO | c.ECHONL | c.ICANON | c.ISIG | c.IEXTEN);

    // Raw output
    tty.c_oflag &= ~@as(c_uint, c.OPOST);

    // Input: disable CR/NL translation and software flow control
    tty.c_iflag &= ~@as(c_uint, c.ICRNL | c.INLCR | c.IGNCR | c.IXON | c.IXOFF | c.IXANY);

    // Block until at least 1 byte arrives, no timeout
    tty.c_cc[c.VMIN] = 1;
    tty.c_cc[c.VTIME] = 0;

    if (c.tcsetattr(fd, c.TCSANOW, &tty) < 0) {
        _ = c.write(2, "tcsetattr failed\n", 17);
        return error.TcsetattrFailed;
    }
}

/// Write a formatted line to fd 1 (stdout) and optionally to a log file.
fn writeLine(log_file: ?std.fs.File, ts: i64, line: []const u8) !void {
    var buf: [300]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "{d} {s}\n", .{ ts, line });
    _ = c.write(1, msg.ptr, msg.len);
    if (log_file) |f| try f.writeAll(msg);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var log_file: ?std.fs.File = null;
    defer if (log_file) |f| f.close();

    if (args.len > 1) {
        log_file = try std.fs.cwd().createFile(args[1], .{ .truncate = false });
        if (log_file) |f| try f.seekFromEnd(0);
        _ = c.write(2, "Logging to file\n", 16);
    }

    const fd = c.open(DEVICE, c.O_RDWR | c.O_NOCTTY, @as(c_int, 0));
    if (fd < 0) {
        _ = c.write(2, "Failed to open " ++ DEVICE ++ "\n", 16 + DEVICE.len + 1);
        return error.OpenFailed;
    }
    defer _ = c.close(fd);

    try configureSerial(fd);
    // Flush accumulated bytes from the kernel rx buffer before reading
    _ = c.tcflush(fd, c.TCIFLUSH);
    _ = c.write(2, "Capturing from " ++ DEVICE ++ " at 9600 baud. Ctrl+C to stop.\n", 57);

    var raw_buf: [256]u8 = undefined;
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(alloc);

    while (true) {
        const n = c.read(fd, &raw_buf, raw_buf.len);
        if (n < 0) {
            _ = c.write(2, "read error\n", 11);
            return error.ReadFailed;
        }
        if (n == 0) continue;

        for (raw_buf[0..@intCast(n)]) |byte| {
            if (byte == '\r' or byte == '\n') {
                // Flush on any line-end byte; skip if buffer is empty
                // (handles \r\n, \n, and \r without double-flushing)
                if (line_buf.items.len > 0) {
                    try writeLine(log_file, std.time.timestamp(), line_buf.items);
                    line_buf.clearRetainingCapacity();
                }
            } else {
                try line_buf.append(alloc, byte);
            }
        }
    }
}
