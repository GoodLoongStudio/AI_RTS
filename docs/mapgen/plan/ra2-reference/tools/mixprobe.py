"""Probe RA2 MIX files: decrypt header (Westwood RSA + Blowfish), list entries, resolve names, extract.
Temporary analysis tool; lives outside the repo.
"""
import base64, os, struct, sys, json, zlib
from cryptography.hazmat.decrepit.ciphers.algorithms import Blowfish
from cryptography.hazmat.primitives.ciphers import Cipher, modes
from cryptography.hazmat.backends import default_backend

PUBKEY_STR = "AihRvNoIbTn85FZRYNZRcT+i6KpU+maCsEqr3Q5q+LDB5tH7Tz2qQ38V"
RA2_DIR = r"G:\Command & Conquer Red Alert 2"
OUT = os.path.join(os.path.dirname(__file__), "extract")


def pubkey():
    raw = base64.b64decode(PUBKEY_STR)
    assert raw[0] == 0x02
    ln = raw[1]
    n = int.from_bytes(raw[2:2 + ln], "big")
    return n, 65537


def decrypt_blowfish_key(block80):
    n, e = pubkey()
    out = b""
    for i in range(2):
        chunk = block80[i * 40:(i + 1) * 40]
        c = int.from_bytes(chunk, "little")
        m = pow(c, e, n)
        out += m.to_bytes(40, "little")[:39]
    return out[:56]


def bf_decrypt(key, data, swap):
    if swap:
        data = b"".join(data[i:i + 4][::-1] for i in range(0, len(data), 4))
    cipher = Cipher(Blowfish(key), modes.ECB(), backend=default_backend())
    dec = cipher.decryptor()
    plain = dec.update(data) + dec.finalize()
    if swap:
        plain = b"".join(plain[i:i + 4][::-1] for i in range(0, len(plain), 4))
    return plain


def ra2_crc(name):
    """Westwood CRC32 for TS/RA2 filenames."""
    name = name.upper()
    l = len(name)
    a = l >> 2
    if l & 3:
        name += chr(l - (a << 2))
        name += name[a << 2] * (3 - (l & 3))
    return zlib.crc32(name.encode("latin-1")) & 0xFFFFFFFF


def parse_mix(path):
    data = open(path, "rb").read()
    flags = struct.unpack_from("<HH", data, 0)
    if flags[0] != 0:
        # old style, unencrypted, no flags
        count, size = struct.unpack_from("<HI", data, 0)
        hdr_off = 6
        entries = [struct.unpack_from("<III", data, hdr_off + i * 12) for i in range(count)]
        body = hdr_off + count * 12
        return dict(flags=None, count=count, size=size, entries=entries, body=body, data=data)
    f = flags[1]
    encrypted = bool(f & 0x2)
    checksum = bool(f & 0x1)
    if not encrypted:
        count, size = struct.unpack_from("<HI", data, 4)
        hdr_off = 10
        entries = [struct.unpack_from("<III", data, hdr_off + i * 12) for i in range(count)]
        body = hdr_off + count * 12
        return dict(flags=f, count=count, size=size, entries=entries, body=body, data=data)
    key = decrypt_blowfish_key(data[4:84])
    for swap in (True, False):
        first = bf_decrypt(key, data[84:92], swap)
        count, size = struct.unpack_from("<HI", first, 0)
        if 0 < count < 5000 and size < len(data):
            break
    else:
        raise RuntimeError("cannot decrypt header " + path)
    hdr_bytes = 6 + count * 12
    enc_len = (hdr_bytes + 7) // 8 * 8
    plain = bf_decrypt(key, data[84:84 + enc_len], swap)
    entries = [struct.unpack_from("<III", plain, 6 + i * 12) for i in range(count)]
    body = 84 + enc_len
    return dict(flags=f, count=count, size=size, entries=entries, body=body, data=data, swap=swap)


def candidate_names():
    names = ["local mix database.dat", "missions.pkt", "missionsmd.pkt", "rmg.ini", "rules.ini", "art.ini",
             "temperat.ini", "snow.ini", "urban.ini", "temperatmd.ini", "snowmd.ini", "urbanmd.ini",
             "mpmodes.ini", "mpbattle.ini", "ai.ini", "sound.ini", "ui.ini", "uimd.ini", "ra2.csf",
             "wdt.ini", "wdtmaps.ini", "wdt.pkt", "loadscreen.pkt", "battle.ini", "battlemd.ini"]
    for i in range(0, 60):
        for p in range(1, 9):
            names.append(f"mp{i:02d}t{p}.map")
            names.append(f"mp{i:02d}t{p}.mpr")
            names.append(f"mp{i:02d}t{p}.pkt")
            names.append(f"mp{i:02d}t{p}.yrm")
        names.append(f"mp{i:02d}.map")
        names.append(f"wdt{i:02d}.map")
        names.append(f"wdt{i:02d}t4.map")
    for side in ("all", "sov", "ali", "yur"):
        for i in range(1, 20):
            names.append(f"{side}{i:02d}.map")
            names.append(f"{side}{i:02d}umd.map")
            names.append(f"{side}{i:02d}md.map")
    for i in range(1, 30):
        names.append(f"c{i:02d}.map")
        names.append(f"tut{i:02d}.map")
    return names


def read_lmd(blob):
    """Parse 'local mix database.dat' (XCC format): 32-byte header + count + zero-terminated names."""
    if not blob.startswith(b"XCC by Olaf van der Spek"):
        return []
    # header: 32 bytes id, uint32 size, uint32 type, uint32 version, uint32 game, uint32 count
    count = struct.unpack_from("<I", blob, 48)[0]
    names = blob[52:].split(b"\0")
    return [n.decode("latin-1") for n in names if n][:count]


def main():
    os.makedirs(OUT, exist_ok=True)
    report = {}
    cand = {ra2_crc(n): n for n in candidate_names()}
    for fn in ["MULTI.MIX", "Maps01.MIX", "Maps02.mix", "WDT.MIX", "cameo.mix"]:
        path = os.path.join(RA2_DIR, fn)
        try:
            mx = parse_mix(path)
        except Exception as ex:
            report[fn] = {"error": repr(ex)}
            print(fn, "ERROR", ex)
            continue
        data, body = mx["data"], mx["body"]
        names = dict(cand)
        # local mix database
        lmd_id = ra2_crc("local mix database.dat")
        for (eid, off, size) in mx["entries"]:
            if eid == lmd_id:
                for n in read_lmd(data[body + off: body + off + size]):
                    names[ra2_crc(n)] = n
        listing = []
        resolved = 0
        outdir = os.path.join(OUT, fn.split(".")[0])
        os.makedirs(outdir, exist_ok=True)
        for (eid, off, size) in sorted(mx["entries"], key=lambda e: e[1]):
            blob = data[body + off: body + off + size]
            name = names.get(eid)
            head = blob[:8]
            kind = "?"
            if blob[:5] == b"MIX1" or (len(blob) > 4 and blob[:2] == b"\0\0" and blob[2] in (1, 2, 3)):
                kind = "mix"
            elif b"[Map]" in blob[:4096] or b"[Basic]" in blob[:4096] or b"IsoMapPack5" in blob[:65536]:
                kind = "map-ini"
            elif blob[:4] == b"\x00\x00\x00\x00" and size > 1000:
                kind = "bin"
            elif blob.startswith(b"XCC by"):
                kind = "lmd"
            elif all(32 <= b < 127 or b in (9, 10, 13) for b in blob[:256]):
                kind = "text"
            if name:
                resolved += 1
            listing.append({"id": f"{eid:08X}", "offset": off, "size": size, "name": name, "kind": kind,
                            "head": head.hex()})
            fname = name if name else f"{eid:08X}.{kind if kind != '?' else 'bin'}"
            with open(os.path.join(outdir, fname), "wb") as fo:
                fo.write(blob)
        report[fn] = {"flags": mx["flags"], "count": mx["count"], "body_size": mx["size"], "resolved": resolved,
                      "entries": listing}
        print(f"{fn}: flags={mx['flags']:#x} count={mx['count']} body={mx['size']} resolved={resolved}")
    with open(os.path.join(OUT, "report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
