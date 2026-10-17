#!/usr/bin/env python3
"""Sample a process's CPU usage from outside it.

`ps` and `top` are refused inside the agent sandbox and `proc_pid_rusage` returns zero, so the
only meter available is `proc_pidinfo(PROC_PIDTASKINFO)`, whose user and system fields are Mach
absolute-time ticks. Two readings a known interval apart give a percentage.

    cpumeter.py <pid> [seconds] [samples]

Requires the `--jit` build to have been run: the drawing is Skia's, not this project's.
"""
import ctypes
import struct
import sys
import time


class TimebaseInfo(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def nanosecond_scale():
    """Nanoseconds per Mach tick, which is 1 on Apple silicon and often not elsewhere."""
    libsystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    libsystem.mach_timebase_info.argtypes = [ctypes.POINTER(TimebaseInfo)]
    info = TimebaseInfo()
    libsystem.mach_timebase_info(ctypes.byref(info))
    if info.denom == 0:
        return 1.0
    return info.numer / info.denom


def cpu_ticks(libproc, pid):
    """Absolute CPU time in Mach ticks, or None if the process is gone."""
    buf = ctypes.create_string_buffer(512)
    n = libproc.proc_pidinfo(pid, 4, 0, buf, 512)   # PROC_PIDTASKINFO
    if n <= 0:
        return None
    user, system = struct.unpack_from("<QQ", buf.raw, 16)
    return user + system


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    pid = int(sys.argv[1])
    interval = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
    samples = int(sys.argv[3]) if len(sys.argv) > 3 else 5

    libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    scale = nanosecond_scale()

    prev = cpu_ticks(libproc, pid)
    if prev is None:
        print(f"pid {pid} not found")
        return 1

    print(f"pid={pid}  scale={scale:.4f} ns/tick")
    for i in range(samples):
        time.sleep(interval)
        cur = cpu_ticks(libproc, pid)
        if cur is None:
            print(f"  {i + 1}: process exited")
            break
        pct = 100.0 * (cur - prev) * scale / 1e9 / interval
        print(f"  {i + 1}: {pct:6.1f}% cpu   (total {cur * scale / 1e9:8.2f} s)")
        prev = cur
    return 0


if __name__ == "__main__":
    sys.exit(main())
