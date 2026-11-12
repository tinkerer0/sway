#!/usr/bin/env python3
"""APK의 dex가 참조하는 Android 프레임워크 API 중 minSdk보다 높은 것을 찾는다."""
import struct, sys, zipfile, xml.etree.ElementTree as ET, collections, json

def uleb(buf, off):
    result = shift = 0
    while True:
        b = buf[off]; off += 1
        result |= (b & 0x7f) << shift
        if b < 0x80: return result, off
        shift += 7

def parse_dex(buf):
    u32 = lambda o: struct.unpack_from('<I', buf, o)[0]
    s_size, s_off = u32(0x38), u32(0x3c)
    t_size, t_off = u32(0x40), u32(0x44)
    p_size, p_off = u32(0x48), u32(0x4c)
    f_size, f_off = u32(0x50), u32(0x54)
    m_size, m_off = u32(0x58), u32(0x5c)
    strings = []
    for i in range(s_size):
        data = u32(s_off + 4 * i)
        _, start = uleb(buf, data)
        end = buf.index(0, start)
        strings.append(buf[start:end].decode('utf-8', 'replace'))
    types = [strings[u32(t_off + 4 * i)] for i in range(t_size)]
    protos = []
    for i in range(p_size):
        base = p_off + 12 * i
        ret = types[u32(base + 4)]
        params_off = u32(base + 8)
        params = []
        if params_off:
            n = u32(params_off)
            params = [types[struct.unpack_from('<H', buf, params_off + 4 + 2 * k)[0]] for k in range(n)]
        protos.append('(' + ''.join(params) + ')' + ret)
    methods = []
    for i in range(m_size):
        cls, proto, name = struct.unpack_from('<HHI', buf, m_off + 8 * i)
        methods.append((types[cls], strings[name] + protos[proto]))
    fields = []
    for i in range(f_size):
        cls, typ, name = struct.unpack_from('<HHI', buf, f_off + 8 * i)
        fields.append((types[cls], strings[name]))
    return methods, fields

def load_api(path):
    classes = {}
    for cls in ET.parse(path).getroot().iter('class'):
        since = int(cls.get('since', '1'))
        methods = {m.get('name'): int(m.get('since', since)) for m in cls.iter('method')}
        fields = {f.get('name'): int(f.get('since', since)) for f in cls.iter('field')}
        supers = [e.get('name') for e in cls.iter('extends')] + [e.get('name') for e in cls.iter('implements')]
        classes[cls.get('name')] = (since, methods, fields, supers)
    return classes

def resolve(api, cls, key, kind, seen=None):
    seen = seen or set()
    if cls in seen or cls not in api: return None
    seen.add(cls)
    since, methods, fields, supers = api[cls]
    table = methods if kind == 'm' else fields
    found = [table[key]] if key in table else []
    for parent in supers:
        r = resolve(api, parent, key, kind, seen)
        if r is not None: found.append(r)
    return min(found) if found else None

def main():
    apk, min_sdk, api_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    api = load_api(api_path)
    hits = collections.defaultdict(set)
    with zipfile.ZipFile(apk) as z:
        for name in sorted(n for n in z.namelist() if n.startswith('classes') and n.endswith('.dex')):
            methods, fields = parse_dex(z.read(name))
            for cls, sig in methods:
                c = cls[1:-1]
                if c not in api: continue
                level = resolve(api, c, sig, 'm')
                if level is None:
                    level = api[c][0]
                if level > min_sdk:
                    hits[(c, sig, level, 'method')].add(name)
            for cls, fname in fields:
                c = cls[1:-1]
                if c not in api: continue
                level = resolve(api, c, fname, 'f')
                if level is None:
                    level = api[c][0]
                if level > min_sdk:
                    hits[(c, fname, level, 'field')].add(name)
    out = [{'class': c, 'member': m, 'since': lv, 'kind': k, 'dex': sorted(d)} for (c, m, lv, k), d in sorted(hits.items(), key=lambda x: (x[0][2], x[0][0]))]
    json.dump(out, sys.stdout, ensure_ascii=False, indent=1)

if __name__ == '__main__':
    main()
