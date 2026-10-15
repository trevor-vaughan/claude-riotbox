#!/usr/bin/env python3
"""Bring the loopback interface up in a fresh network namespace.

`unshare -n` starts with lo down and the test image has no `ip`; this is the
SIOCGIFFLAGS/SIOCSIFFLAGS pair `ip link set lo up` uses (IFF_UP|IFF_RUNNING).
Used by in_other_container (tests/lib/headroom-fakes.sh).
"""

import fcntl, socket, struct
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
SIOCGIFFLAGS, SIOCSIFFLAGS = 0x8913, 0x8914
ifr = fcntl.ioctl(s, SIOCGIFFLAGS, struct.pack("16sh", b"lo", 0) + b"\0" * 22)
flags = struct.unpack("16sh", ifr[:18])[1] | 0x1 | 0x40
fcntl.ioctl(s, SIOCSIFFLAGS, struct.pack("16sh", b"lo", flags) + b"\0" * 22)
