#!/usr/bin/env python3
# 构造一条合成的 allowlist 探测条目（复制 com.android.shell 记录，仅改 key/current_uid）
# 用途：验证 KSU 授权持久化的「读 + 写」两条路径
import struct, sys, hashlib

SRC = sys.argv[1] if len(sys.argv) > 1 else '_work/al_before.bin'
OUT = sys.argv[2] if len(sys.argv) > 2 else '_work/al_probe.bin'
FAKE_PKG = b'com.example.persistprobe'
FAKE_UID = 19999

d = open(SRC, 'rb').read()
magic, version = struct.unpack_from('<II', d, 0)
print('magic=0x%08x ("%s")  version=%d  size=%d' % (magic, d[:3].decode(), version, len(d)))
assert d[:3] == b'USK', 'magic mismatch'
HDR = 8
REC = (len(d) - HDR) // ((len(d) - HDR) // 776)  # placeholder
REC = 776
assert (len(d) - HDR) % REC == 0, 'size not a multiple of 776'
n = (len(d) - HDR) // REC
print('records=%d  record_size=%d' % (n, REC))

# ---- 解析记录字段（按 struct app_profile 布局）----
def parse(rec, base=0):
    version = struct.unpack_from('<I', rec, 0)[0]
    key = rec[4:4+256].split(b'\x00')[0].decode('utf-8', 'replace')
    uid = struct.unpack_from('<i', rec, 260)[0]
    allow_su = rec[264]
    use_default = rec[272]
    rp = 272 + 264               # rp_config.profile 起始
    r_uid = struct.unpack_from('<i', rec, rp+0)[0]
    r_gid = struct.unpack_from('<i', rec, rp+4)[0]
    r_gc = struct.unpack_from('<i', rec, rp+8)[0]
    r_dom = rec[rp+168:rp+168+64].split(b'\x00')[0].decode()
    r_ns = struct.unpack_from('<i', rec, rp+232)[0]
    return dict(version=version, key=key, uid=uid, allow_su=allow_su,
                use_default=use_default, r_uid=r_uid, r_gid=r_gid,
                groups_count=r_gc, domain=r_dom, namespaces=r_ns)

for i in range(n):
    rec = d[HDR+i*REC: HDR+(i+1)*REC]
    print('  [%d] %s' % (i, parse(rec)))

# ---- 取第 0 条记录做模板 ----
tpl = bytearray(d[HDR:HDR+REC])
assert tpl[4:4+256].split(b'\x00')[0] == b'com.android.shell'

# 只改 key 与 current_uid
tpl[4:4+256] = FAKE_PKG + b'\x00' * (256 - len(FAKE_PKG))
struct.pack_into('<i', tpl, 260, FAKE_UID)
# allow_su 保持 1
assert tpl[264] == 1, 'template allow_su != 1'

new = d + bytes(tpl)
open(OUT, 'wb').write(new)
print('\n新条目: key=%s uid=%d allow_su=%d domain=%s' % (
    parse(bytes(tpl))['key'], parse(bytes(tpl))['uid'],
    parse(bytes(tpl))['allow_su'], parse(bytes(tpl))['domain']))
print('输出 %s  size=%d (=%d+%d)' % (OUT, len(new), len(d), REC))
print('sha256(new)=%s' % hashlib.sha256(new).hexdigest())
