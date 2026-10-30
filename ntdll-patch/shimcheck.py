#!/usr/bin/env python3
# Checks that every shipped x86 detour payload hands the detour the register its ntdll keeps
# the MODREF (wm) in. The payload pins only prove the bytes match a build; a payload that was
# never rebuilt after a shim change still matches its own pin (WineCX 11.15 i386 did).
#
# Each payload's opening runs symbolically up to its call into the detour, and the
# arguments are compared with resolve.py's PINNED entry for the ntdll. The ntdll is found by
# the payload's sha256, and the NtdllPatch that ships the file must agree with that entry on
# the hook and the cave. No capstone needed: anything the small decoder below does not know
# fails the check.
#
#   shimcheck.py                          every detour32*.bin and detour2*.bin in Resources
#   shimcheck.py [--root DIR] [file...]   another checkout, or only these payloads
import argparse, ast, hashlib, pathlib, re, struct, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from wmguard import GPR  # noqa: E402

RESOURCES = 'app/Sources/BridgeplayApp/Resources'
REGS = {32: GPR['i386'], 64: GPR['x86_64']}


class Unsupported(Exception):
    pass


class Machine:
    """Just enough x86 to follow a shim to its call, on symbolic values."""

    def __init__(self, bits):
        self.bits, self.w = bits, bits // 8
        self.regs = {r: r for r in REGS[bits]}
        self.sp = ('entry', 0)          # the stack pointer as (base, offset)
        self.mem = {}                   # stack slots written so far
        self.aligned = 0

    def sp_name(self):
        return REGS[self.bits][4]

    def read(self, r):
        if r == self.sp_name():
            return f"sp:{self.sp[0]}{self.sp[1]:+#x}"
        return self.regs[r]

    def write(self, r, v):
        if r == self.sp_name():
            raise Unsupported(f"moves a value into {r}")
        self.regs[r] = v

    def slot(self, base, disp):
        if base == self.sp_name():
            return (self.sp[0], self.sp[1] + disp)
        v = self.regs.get(base, '')
        m = re.fullmatch(r'sp:(\w+)([+-]0x[0-9a-f]+)', v)
        if m:
            return (m.group(1), int(m.group(2), 16) + disp)
        return None

    def load(self, base, disp):
        if base == 'rip':
            return f"[rip{disp:+#x}]"
        s = self.slot(base, disp)
        if s is None:
            raise Unsupported(f"reads memory through {base}")
        return self.mem.get(s, f"[{s[0]}{s[1]:+#x}]")

    def store(self, base, disp, v):
        s = self.slot(base, disp) if base not in (None, 'rip') else None
        if s is None:
            raise Unsupported("writes memory outside the stack")
        self.mem[s] = v

    def push(self, v):
        self.sp = (self.sp[0], self.sp[1] - self.w)
        self.mem[self.sp] = v

    def pop(self):
        v = self.mem.get(self.sp, f"[{self.sp[0]}{self.sp[1]:+#x}]")
        self.sp = (self.sp[0], self.sp[1] + self.w)
        return v


def modrm(code, o, bits, rex):
    """(reg field, operand, next offset); operand is ('reg', name) or ('mem', base, disp)."""
    names = REGS[bits]
    m = code[o]
    o += 1
    mod, reg, rm = m >> 6, ((m >> 3) & 7) | ((rex & 4) << 1), m & 7
    if mod == 3:
        return names[reg], ('reg', names[rm | ((rex & 1) << 3)]), o
    disp32 = False
    if rm == 4:
        sib = code[o]
        o += 1
        if (((sib >> 3) & 7) | ((rex & 2) << 2)) != 4:
            raise Unsupported("uses an indexed address")
        base = names[(sib & 7) | ((rex & 1) << 3)]
        if sib & 7 == 5 and mod == 0:
            base, disp32 = None, True
    elif rm == 5 and mod == 0:
        base, disp32 = ('rip' if bits == 64 else None), True
    else:
        base = names[rm | ((rex & 1) << 3)]
    if mod == 1:
        disp = struct.unpack_from('<b', code, o)[0]
        o += 1
    elif mod == 2 or disp32:
        disp = struct.unpack_from('<i', code, o)[0]
        o += 4
    else:
        disp = 0
    return names[reg], ('mem', base, disp), o


def run(code, bits, limit=64):
    """Follow the shim to its first real call. Returns the machine at that call."""
    vm, o = Machine(bits), 0
    for _ in range(limit):
        at, rex = o, 0
        if bits == 64 and 0x40 <= code[o] <= 0x4f:
            rex = code[o]
            o += 1
        op = code[o]
        o += 1
        try:
            if 0x50 <= op <= 0x57:
                vm.push(vm.read(REGS[bits][(op - 0x50) | ((rex & 1) << 3)]))
            elif 0x58 <= op <= 0x5f:
                vm.write(REGS[bits][(op - 0x58) | ((rex & 1) << 3)], vm.pop())
            elif op == 0x60 and bits == 32:
                before = vm.read('esp')
                for r in REGS[32]:
                    vm.push(before if r == 'esp' else vm.read(r))
            elif op == 0xe8:
                rel = struct.unpack_from('<i', code, o)[0]
                o += 4
                if rel:
                    return vm, at
                vm.push('eip')          # call $+5, for the load delta
            elif op in (0x89, 0x8b, 0x8d, 0x81, 0x83):
                if bits == 64 and not rex & 8:
                    raise Unsupported("is not a 64-bit operation")
                reg, rm, o = modrm(code, o, bits, rex)
                if op == 0x89:
                    if rm[0] == 'reg':
                        vm.write(rm[1], vm.read(reg))
                    else:
                        vm.store(rm[1], rm[2], vm.read(reg))
                elif op == 0x8b:
                    vm.write(reg, vm.read(rm[1]) if rm[0] == 'reg' else vm.load(rm[1], rm[2]))
                elif op == 0x8d:
                    if rm[0] != 'mem':
                        raise Unsupported("is a lea without an address")
                    s = vm.slot(rm[1], rm[2]) if rm[1] not in (None, 'rip') else None
                    vm.write(reg, f"sp:{s[0]}{s[1]:+#x}" if s else f"&[{rm[1]}{rm[2]:+#x}]")
                else:
                    if op == 0x81:
                        imm = struct.unpack_from('<i', code, o)[0]
                        o += 4
                    else:
                        imm = struct.unpack_from('<b', code, o)[0]
                        o += 1
                    kind = {0: '+', 4: '&', 5: '-'}.get(REGS[bits].index(reg) & 7)
                    if rm[0] != 'reg' or kind is None:
                        raise Unsupported("is an arithmetic form the check does not model")
                    if rm[1] == vm.sp_name():
                        if kind == '&':
                            vm.aligned += 1
                            vm.sp = (f"aligned{vm.aligned}", 0)
                        else:
                            vm.sp = (vm.sp[0], vm.sp[1] + (imm if kind == '+' else -imm))
                    else:
                        vm.write(rm[1], f"({vm.read(rm[1])}{kind}{imm:#x})")
            else:
                raise Unsupported(f"is opcode {op:#04x}")
        except Unsupported as e:
            raise Unsupported(f"the instruction at +{at:#x} ({code[at:o + 4].hex()}) {e}")
    raise Unsupported(f"no call into the detour in the first {limit} instructions")


def check(data, pin):
    """None if the payload hands the detour pin['wm'], else what it hands it instead."""
    wm = pin['wm']
    bits = 32 if wm in REGS[32] else 64
    try:
        vm, at = run(data, bits)
    except Unsupported as e:
        return f"cannot follow the shim: {e}"
    if bits == 32:
        # detour_build_module32(ctx, wm, fp), cdecl
        got_wm, got_fp = vm.load('esp', 4), vm.load('esp', 8)
        if got_wm != wm or got_fp != 'ebp':
            return (f"the detour call at +{at:#x} gets wm={got_wm} fp={got_fp}, "
                    f"the pin says wm={wm} fp=ebp")
        return None
    # detour_build_module(ctx, wm, load_path), Win64: rcx rdx r8
    got_wm, got_lp = vm.read('rdx'), vm.read('r8')
    want_lp = f"[entry{pin['load_path']:+#x}]"
    if got_wm != wm or got_lp != want_lp:
        return (f"the detour call at +{at:#x} gets wm={got_wm} load_path={got_lp}, "
                f"the pin says wm={wm} load_path={want_lp}")
    return None


def pinned(resolve_py):
    """resolve.py's PINNED table, read without importing it (that needs capstone)."""
    tree = ast.parse(pathlib.Path(resolve_py).read_text())
    for n in tree.body:
        if isinstance(n, ast.Assign) and getattr(n.targets[0], 'id', '') == 'PINNED':
            return ast.literal_eval(n.value)
    raise SystemExit(f"{resolve_py}: no PINNED table")


def swift_pins(sources):
    """payloadResource -> (sha256, first hook RVA, caveRVA) for every NtdllPatch."""
    out = {}
    for f in sorted(pathlib.Path(sources).rglob('*.swift')):
        text = f.read_text()
        starts = [m.start() for m in re.finditer(r'\bpayloadResource:', text)]
        for a, b in zip(starts, starts[1:] + [len(text)]):
            block = text[a:b]
            res = re.search(r'payloadResource:\s*"([^"]+)"', block)
            sha = re.search(r'payloadSHA256:\s*"([0-9a-f]{64})"', block)
            cave = re.search(r'\bcaveRVA:\s*(0x[0-9a-fA-F_]+)', block)
            hook = re.search(r'NtdllHook\(rva:\s*(0x[0-9a-fA-F_]+)', block)
            if res and sha and cave and hook:
                out[res.group(1)] = (sha.group(1), int(hook.group(1).replace('_', ''), 16),
                                     int(cave.group(1).replace('_', ''), 16), f.name)
    return out


def main(argv):
    ap = argparse.ArgumentParser(description='Check that shipped x86 detours read the pinned wm.')
    ap.add_argument('--root', default=str(pathlib.Path(__file__).resolve().parent.parent),
                    help='the checkout whose resolve.py, Swift pins and payloads to use')
    ap.add_argument('payloads', nargs='*')
    a = ap.parse_args(argv)
    root = pathlib.Path(a.root)
    pins = pinned(root / 'ntdll-patch/resolve.py')
    by_payload = {v['payload']: (k, v) for k, v in pins.items() if 'payload' in v}
    swift = swift_pins(root / 'app/Sources')
    files = [pathlib.Path(p) for p in a.payloads] or sorted(
        p for g in ('detour32*.bin', 'detour2*.bin') for p in (root / RESOURCES).glob(g))
    if not files:
        raise SystemExit(f"no detour payloads under {root / RESOURCES}")

    bad = 0
    for f in files:
        data = f.read_bytes()
        sha = hashlib.sha256(data).hexdigest()
        problem = None
        if sha not in by_payload:
            problem = f"no PINNED ntdll in resolve.py carries payload {sha[:12]}"
        else:
            ntdll, pin = by_payload[sha]
            ship = swift.get(f.stem)
            if 'wm' not in pin:
                problem = f"PINNED {ntdll[:12]} is not an x86 build"
            elif ship is None:
                problem = f"no NtdllPatch in {root / 'app/Sources'} ships {f.stem}"
            elif ship[0] != sha:
                problem = f"{ship[3]} pins {f.stem} as {ship[0][:12]}, the file is {sha[:12]}"
            elif (ship[1], ship[2]) != (pin['hookRVA'], pin['caveRVA']):
                problem = (f"{ship[3]} hooks {ship[1]:#x} with the cave at {ship[2]:#x}, but the "
                           f"ntdll this payload was built for ({ntdll[:12]}) hooks "
                           f"{pin['hookRVA']:#x} with the cave at {pin['caveRVA']:#x}")
            else:
                problem = check(data, pin)
        if problem:
            bad += 1
            print(f"FAIL {f.name}: {problem}")
        else:
            print(f"ok   {f.name}: ntdll {ntdll[:12]} keeps wm in {pin['wm']}, and the shim hands "
                  f"the detour {pin['wm']}")
    print(f"==> detourcheck: {len(files) - bad} of {len(files)} payloads read the pinned wm"
          + ("" if not bad else f", {bad} FAILED"))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
