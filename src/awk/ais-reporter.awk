# ais-reporter.awk - encode a synthetic AIS !AIVDM Type 1 (Class A position
# report) sentence from GPS fields.
#
# Usage:
#   awk -v mmsi=235000000 -v navstatus=15 \
#       -v lat=55.772557 -v lon=-4.857950 -v sog=0.3 -v cog=128.5 -v sec=16 \
#       -f ais-reporter.awk </dev/null
#
# lat/lon: signed decimal degrees. sog: knots. cog: degrees true.
# sec: UTC seconds (0-59) of the fix, or omit/leave blank for "not available".
#
# Pure POSIX awk (no gawk extensions: no strtonum(), no and()/or()/xor()) so
# it runs under busybox awk.

function round(x) {
    return (x >= 0) ? int(x + 0.5) : -int(-x + 0.5)
}

# Two's complement representation of a signed value in `width` bits.
function twos(value, width,    p) {
    p = 2 ^ width
    if (value < 0) value += p
    return value
}

# MSB-first binary string of `value` (already non-negative, < 2^width) in `width` bits.
function to_bin(value, width,    b, i) {
    value = twos(value, width)
    b = ""
    for (i = width - 1; i >= 0; i--)
        b = b (int(value / (2 ^ i)) % 2)
    return b
}

function bin2dec(s,    v, i) {
    v = 0
    for (i = 1; i <= length(s); i++)
        v = v * 2 + (substr(s, i, 1) + 0)
    return v
}

function xor8(a, b,    r, i, abit, bbit) {
    r = 0
    for (i = 0; i < 8; i++) {
        abit = int(a / (2 ^ i)) % 2
        bbit = int(b / (2 ^ i)) % 2
        if (abit != bbit) r += 2 ^ i
    }
    return r
}

function sixbit_armor(v) {
    v = v % 64
    return (v < 40) ? sprintf("%c", v + 48) : sprintf("%c", v + 56)
}

function nmea_checksum(body,    cs, i) {
    cs = 0
    for (i = 1; i <= length(body); i++)
        cs = xor8(cs, ord[substr(body, i, 1)])
    return sprintf("%02X", cs)
}

BEGIN {
    for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
    if (navstatus == "") navstatus = 15
    if (sec == "") sec = 60

    bits = ""
    bits = bits to_bin(1, 6)                 # message id: 1 (position report, Class A)
    bits = bits to_bin(0, 2)                 # repeat indicator
    bits = bits to_bin(mmsi + 0, 30)         # mmsi
    bits = bits to_bin(navstatus + 0, 4)     # nav status
    bits = bits to_bin(-128, 8)              # rate of turn: not available

    sog10 = round((sog + 0) * 10)
    if (sog10 > 1022) sog10 = 1022
    bits = bits to_bin(sog10, 10)

    bits = bits to_bin(0, 1)                 # position accuracy (0 = low/autonomous)
    bits = bits to_bin(round((lon + 0) * 600000), 28)
    bits = bits to_bin(round((lat + 0) * 600000), 27)

    cog10 = round((cog + 0) * 10) % 3600
    bits = bits to_bin(cog10, 12)
    bits = bits to_bin(511, 9)               # true heading: not available
    bits = bits to_bin(sec + 0, 6)
    bits = bits to_bin(0, 2)                 # special manoeuvre indicator
    bits = bits to_bin(0, 3)                 # spare
    bits = bits to_bin(0, 1)                 # RAIM flag
    bits = bits to_bin(0, 19)                # communication state (unused)

    padlen = (6 - length(bits) % 6) % 6
    for (i = 0; i < padlen; i++) bits = bits "0"

    payload = ""
    for (i = 1; i <= length(bits); i += 6)
        payload = payload sixbit_armor(bin2dec(substr(bits, i, 6)))

    body = "AIVDM,1,1,,A," payload "," padlen
    printf "!%s*%s\r\n", body, nmea_checksum(body)
}
