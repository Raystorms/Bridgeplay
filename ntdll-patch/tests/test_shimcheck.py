# shimcheck.py on the shipped payloads, on the 11.15 and 11.17 payloads from before their
# fixes, and on payloads for a wm the shim cannot read.
import hashlib, io, pathlib, shutil, sys, tempfile, unittest
from contextlib import redirect_stdout

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE.parent))
import shimcheck  # noqa: E402

RES = ROOT / shimcheck.RESOURCES
PINS = shimcheck.pinned(ROOT / 'ntdll-patch/resolve.py')
BY_PAYLOAD = {v['payload']: v for v in PINS.values() if 'payload' in v}


def payload(name):
    data = (RES / name).read_bytes()
    return bytearray(data), BY_PAYLOAD[hashlib.sha256(data).hexdigest()]


def quiet(argv):
    out = io.StringIO()
    with redirect_stdout(out):
        rc = shimcheck.main(argv)
    return rc, out.getvalue()


class Shipped(unittest.TestCase):
    def test_every_shipped_payload_reads_its_pinned_wm(self):
        rc, out = quiet([])
        self.assertEqual(rc, 0, out)
        self.assertEqual(out.count('\nok   ') + out.startswith('ok   '), 20, out)


class BeforeTheFix(unittest.TestCase):
    # The pre-fix payloads differ from the shipped ones only in the order of the two moves
    # after `sub ecx, imm32`: mov ebx, ebp ran before mov esi, ebx.
    OLD = {'detour32-winecx-11.15.bin':
           '37daf5f795535df91bc8fcbd356f22f4fd1ab379ec4acc97ddff44037d265556',  # before 7af57dc
           'detour32-winecx-11.17.bin':
           '0676104e0bd56c4a1e8c473d9cbcd21fb2ba105fc7dc6cf5a70d37692c129e28'}  # before aa17158

    def test_old_payloads_fail(self):
        for name, old_sha in self.OLD.items():
            with self.subTest(name):
                data, pin = payload(name)
                self.assertEqual(data[13:17], bytes.fromhex('89de89eb'))
                data[13:17] = bytes.fromhex('89eb89de')
                self.assertEqual(hashlib.sha256(data).hexdigest(), old_sha,
                                 'not the byte stream that shipped before the fix')
                self.assertIsNone(shimcheck.check(bytes(payload(name)[0]), pin))
                problem = shimcheck.check(bytes(data), pin)
                self.assertIsNotNone(problem)
                self.assertIn('wm=ebp', problem)

    def test_old_payload_fails_the_whole_run(self):
        # A checkout where the old 11.17 payload ships with its old pins
        with tempfile.TemporaryDirectory() as d:
            d = pathlib.Path(d)
            shutil.copytree(ROOT / 'app/Sources', d / 'app/Sources')
            (d / 'ntdll-patch').mkdir()
            data, _ = payload('detour32-winecx-11.17.bin')
            new_sha = hashlib.sha256(data).hexdigest()
            data[13:17] = bytes.fromhex('89eb89de')
            old_sha = self.OLD['detour32-winecx-11.17.bin']
            (d / shimcheck.RESOURCES / 'detour32-winecx-11.17.bin').write_bytes(data)
            for rel in ('ntdll-patch/resolve.py', 'app/Sources/BridgeplayApp/Model/FreeEngineWinecx.swift'):
                src = (ROOT / rel).read_text()
                self.assertIn(new_sha, src)
                (d / rel).write_text(src.replace(new_sha, old_sha))
            rc, out = quiet(['--root', str(d)])
            self.assertEqual(rc, 1, out)
            self.assertIn('FAIL detour32-winecx-11.17.bin: the detour call at +0x68 gets wm=ebp', out)
            self.assertIn('19 of 20', out)


class Unreadable(unittest.TestCase):
    def test_i386_wm_in_ecx_fails_in_either_order(self):
        data, pin = payload('detour32-cx26.bin')
        self.assertEqual(data[13:17], bytes.fromhex('89eb89f6'))   # mov ebx, ebp ; mov esi, esi
        pin = dict(pin, wm='ecx')
        for order in ('89eb89ce', '89ce89eb'):                    # mov esi, ecx before or after
            with self.subTest(order):
                data[13:17] = bytes.fromhex(order)
                problem = shimcheck.check(bytes(data), pin)
                self.assertIsNotNone(problem)
                self.assertNotIn('gets wm=ecx', problem)

    def test_x86_64_wm_the_shim_overwrites_fails(self):
        data, pin = payload('detour2.bin')
        at = 0x4f
        self.assertEqual(data[at:at + 3], bytes.fromhex('4889f2'))  # mov rdx, rsi
        for reg, insn in (('rax', '4889c2'), ('rcx', '4889ca'), ('r10', '4c89d2')):
            with self.subTest(reg):
                data[at:at + 3] = bytes.fromhex(insn)
                problem = shimcheck.check(bytes(data), dict(pin, wm=reg))
                self.assertIsNotNone(problem)
                self.assertNotIn(f'gets wm={reg} ', problem)
        # rbx is this payload's scratch register, so it carries load_path by then
        data[at:at + 3] = bytes.fromhex('4889da')                  # mov rdx, rbx
        self.assertIn('gets wm=[entry+0xd0]', shimcheck.check(bytes(data), dict(pin, wm='rbx')))
        data[at:at + 3] = bytes.fromhex('4889fa')                  # mov rdx, rdi
        self.assertIsNone(shimcheck.check(bytes(data), dict(pin, wm='rdi')))

    def test_wrong_pin_fails(self):
        data, pin = payload('detour32-41069.bin')
        self.assertIsNone(shimcheck.check(bytes(data), pin))
        self.assertIn('wm=edi', shimcheck.check(bytes(data), dict(pin, wm='esi')))
        data, pin = payload('detour2-winehq-11.15.bin')
        self.assertIsNone(shimcheck.check(bytes(data), pin))
        self.assertIn('load_path', shimcheck.check(bytes(data), dict(pin, load_path=0x58)))

    def test_unknown_instruction_fails(self):
        data, pin = payload('detour32.bin')
        data[13] = 0x0f
        self.assertIn('cannot follow the shim', shimcheck.check(bytes(data), pin))


class Pins(unittest.TestCase):
    def test_swift_pin_for_another_ntdll_fails(self):
        with tempfile.TemporaryDirectory() as d:
            d = pathlib.Path(d)
            shutil.copytree(ROOT / 'app/Sources', d / 'app/Sources')
            (d / 'ntdll-patch').mkdir()
            shutil.copy(ROOT / 'ntdll-patch/resolve.py', d / 'ntdll-patch/resolve.py')
            swift = d / 'app/Sources/BridgeplayApp/Model/FreeEngineWinecx.swift'
            text = swift.read_text()
            self.assertIn('NtdllHook(rva: 0x4f880,', text)
            swift.write_text(text.replace('NtdllHook(rva: 0x4f880,', 'NtdllHook(rva: 0x4f7c0,'))
            rc, out = quiet(['--root', str(d)])
            self.assertEqual(rc, 1, out)
            self.assertIn('FAIL detour32-winecx-11.17.bin: FreeEngineWinecx.swift hooks 0x4f7c0', out)

    def test_unpinned_payload_fails(self):
        with tempfile.TemporaryDirectory() as d:
            f = pathlib.Path(d) / 'detour32-x.bin'
            f.write_bytes(b'\x90' * 16)
            rc, out = quiet([str(f)])
            self.assertEqual(rc, 1, out)
            self.assertIn('no PINNED ntdll', out)


if __name__ == '__main__':
    unittest.main()
