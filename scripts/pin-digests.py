#!/usr/bin/env python3
"""Writes the table of digests the hashing tests hold the package's own SHA-1 and SHA-256 to:
Tests/XitDBHashingTests/Resources/digests.txt.

One line a message: its length, its seed ("-" for the pattern), its SHA-1 and its SHA-256 in hex, computed
here by Python's hashlib. The messages are the tests' own, made the same way as in
Tests/XitDBHashingTests/Hex.swift: the pattern at every length from 0 to 300, then the seeded messages. On
macOS a test holds the system's routine to the same table, so a table that disagreed with this script's
messages, or with the system, fails there; on every platform the package's own code is held to it.

The table in the repository was made on macOS by the system's python3, Python 3.9.6, whose hashlib is
LibreSSL 2.8.3. Any Python 3 with hashlib makes the same table.

Run it from the package's root, and look at the diff before committing it:

    python3 scripts/pin-digests.py
"""
import hashlib

MASK = (1 << 64) - 1
MULTIPLIER = 6_364_136_223_846_793_005
INCREMENT = 1_442_695_040_888_963_407


def pattern(count):
    """`pattern(count:)` of Hex.swift."""
    state = 0x9E37_79B9_7F4A_7C15
    out = bytearray()
    for _ in range(count):
        state = (state * MULTIPLIER + INCREMENT) & MASK
        out.append(state >> 56)
    return bytes(out)


def seeded_message(count, seed):
    """`seededMessage(count:seed:)` of Hex.swift."""
    state = (seed * 0x9E37_79B9_7F4A_7C15 + count) & MASK
    out = bytearray()
    for _ in range(count):
        state = (state * MULTIPLIER + INCREMENT) & MASK
        out.append((state >> 33) & 0xFF)
    return bytes(out)


def seeded_messages():
    """`seededMessages` of Hex.swift: (length, seed) for three thousand messages."""
    state = 42
    for round_ in range(3000):
        state = (state * MULTIPLIER + INCREMENT) & MASK
        bound = 65_537 if round_ % 50 == 0 else (8_193 if round_ % 5 == 0 else 1_025)
        yield (state >> 40) % bound, round_


lines = []
for length in range(301):
    message = pattern(length)
    lines.append("%d - %s %s" % (length, hashlib.sha1(message).hexdigest(), hashlib.sha256(message).hexdigest()))
for length, seed in seeded_messages():
    message = seeded_message(length, seed)
    lines.append("%d %d %s %s" % (length, seed, hashlib.sha1(message).hexdigest(), hashlib.sha256(message).hexdigest()))
path = "Tests/XitDBHashingTests/Resources/digests.txt"
with open(path, "w") as table:
    table.write("\n".join(lines) + "\n")
print("%d digests in %s" % (len(lines), path))
