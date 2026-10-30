#!/usr/bin/env python3
"""TOTP/Passkey 核心回归：fake 认证、RFC 假种子、OpenSSL 独立验签，无真实网站登录。"""
import base64
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('kagi_cli_fixture', Path(__file__).with_name('check-cli.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)

SEED = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'  # RFC 6238 published test seed
URI = 'otpauth://totp/FAKE:alice?secret=' + SEED + '&issuer=FAKE&digits=6'


def b64(data):
    return base64.urlsafe_b64encode(data).decode().rstrip('=')


def unb64(text):
    return base64.urlsafe_b64decode(text + '=' * (-len(text) % 4))


# 独立的小型 CBOR 解码器，只供测试解析注册输出，不与 Swift 编码器共用实现。
class CBORReader:
    def __init__(self, data):
        self.data, self.offset = data, 0

    def take(self, size):
        value = self.data[self.offset:self.offset + size]
        assert len(value) == size
        self.offset += size
        return value

    def read(self):
        first = self.take(1)[0]
        major, argument = first >> 5, first & 31
        if argument >= 24:
            assert argument in [24, 25, 26, 27]
            argument = int.from_bytes(self.take(1 << (argument - 24)), 'big')
        if major == 0:
            return argument
        if major == 1:
            return -1 - argument
        if major == 2:
            return self.take(argument)
        if major == 3:
            return self.take(argument).decode()
        if major == 5:
            result = {}
            for _ in range(argument):
                key = self.read()
                assert key not in result
                result[key] = self.read()
            return result
        raise AssertionError('unsupported CBOR output')

    def all(self):
        result = self.read()
        assert self.offset == len(self.data)
        return result


class AuthenticatorCLITests(fixture.CLIFixture):
    def import_otp(self):
        result = self.call('totp', 'import', 'demo/otp', '--stdin', '--tag', 'auth', data=URI.encode())
        self.assertEqual(result.returncode, 0, result.stderr)

    def request(self, registration=True, **changes):
        value = {'rpID': 'example.test', 'origin': 'https://example.test', 'challenge': b64(os.urandom(32))}
        if registration:
            value.update(userHandle=b64(b'FAKE-alice-id'), userName='alice')
        value.update(changes)
        return value

    def register(self):
        request = self.request()
        result = self.call('passkey', 'register', 'demo/passkey', '--stdin', data=json.dumps(request).encode())
        self.assertEqual(result.returncode, 0, result.stderr)
        return request, json.loads(result.stdout)

    def test_totp_current_code_matches_independent_hmac_and_has_expiry(self):
        self.import_otp()
        result = self.call('totp', 'code', 'demo/otp', '--json')
        self.assertEqual(result.returncode, 0, result.stderr)
        code = json.loads(result.stdout)
        self.assertEqual(code['validUntil'] - code['validFrom'], 30)
        digest = hmac.new(b'12345678901234567890', struct.pack('>Q', code['validFrom'] // 30), hashlib.sha1).digest()
        offset = digest[-1] & 15
        expected = str((int.from_bytes(digest[offset:offset + 4], 'big') & 0x7fffffff) % 1000000).zfill(6)
        self.assertEqual(code['code'], expected)
        row = json.loads(self.call('where', 'demo/otp', '--json').stdout)
        self.assertEqual(row['record']['kind'], 'totp')
        self.assertEqual(row['record']['metadata']['tags'], ['auth'])
        self.assertNotIn(SEED.encode(), self.call('ls', '--json').stdout)

    def test_otp_injection_masks_code_and_cannot_export_seed(self):
        self.import_otp()
        for option in ['--env', '--stdin']:
            injection = ['--env', 'SEED=demo/otp'] if option == '--env' else ['--stdin', 'demo/otp']
            result = self.call('run', *injection, '--', '/usr/bin/true')
            self.assertEqual(result.returncode, 64, result.stderr)
        for injection, script in [(['--otp', 'OTP=demo/otp'], 'printf %s "$OTP"'),
                                  (['--otp-stdin', 'demo/otp'], 'cat')]:
            result = self.call('run', *injection, '--', '/bin/sh', '-c', script)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, '‹kagi:demo/otp›'.encode())
            self.assertNotIn(SEED.encode(), result.stdout + result.stderr)
        self.assertEqual(self.call('set', 'demo/otp', '--stdin', data=b'FAKE-OVERWRITE').returncode, 64)

    def test_fake_denial_and_lock_block_authenticator_outputs_and_mutation(self):
        self.import_otp()
        self.register()
        before = self.vault_snapshot()
        request = json.dumps(self.request(False)).encode()
        for decision, expected in [('deny', 77), ('locked', 75)]:
            self.env['KAGI_DEBUG_AUTH_DECISION'] = decision
            for args, data in [
                (('totp', 'code', 'demo/otp'), None),
                (('totp', 'import', 'demo/new', '--stdin'), URI.encode()),
                (('passkey', 'assert', 'demo/passkey', '--stdin'), request),
                (('passkey', 'register', 'demo/new-passkey', '--stdin'), json.dumps(self.request()).encode()),
                (('run', '--otp', 'OTP=demo/otp', '--', '/usr/bin/true'), None),
            ]:
                result = self.call(*args, data=data)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(result.stdout, b'')
                self.assertEqual(self.vault_snapshot(), before)

    def test_passkey_cbor_registration_and_openssl_assertion_verification(self):
        request, registration = self.register()
        self.assertEqual(registration['type'], 'public-key')
        self.assertEqual(registration['id'], registration['rawId'])
        client = json.loads(unb64(registration['response']['clientDataJSON']))
        self.assertEqual(client, {'type': 'webauthn.create', 'challenge': request['challenge'],
                                  'origin': request['origin'], 'crossOrigin': False})
        attestation = CBORReader(unb64(registration['response']['attestationObject'])).all()
        self.assertEqual(attestation['fmt'], 'none')
        self.assertEqual(attestation['attStmt'], {})
        auth = attestation['authData']
        self.assertEqual(auth[:32], hashlib.sha256(b'example.test').digest())
        self.assertEqual(auth[32], 0x4D)  # simulated UP/UV + BE + AT; BS remains clear
        self.assertEqual(auth[33:53], bytes(20))  # zero counter and zero AAGUID
        size = int.from_bytes(auth[53:55], 'big')
        self.assertEqual(auth[55:55 + size], unb64(registration['id']))
        cose = CBORReader(auth[55 + size:]).all()
        self.assertEqual({key: cose[key] for key in [1, 3, -1]}, {1: 2, 3: -7, -1: 1})
        self.assertEqual(len(cose[-2]), 32)
        self.assertEqual(len(cose[-3]), 32)
        public_der = bytes.fromhex('3059301306072a8648ce3d020106082a8648ce3d030107034200') + b'\x04' + cose[-2] + cose[-3]
        (self.root / 'public.der').write_bytes(public_der)
        openssl = shutil.which('openssl')
        self.assertIsNotNone(openssl, '独立验签需要已安装的 OpenSSL')
        conversion = subprocess.run([openssl, 'pkey', '-pubin', '-inform', 'DER', '-in', str(self.root / 'public.der'),
                                     '-out', str(self.root / 'public.pem')], capture_output=True)
        self.assertEqual(conversion.returncode, 0, conversion.stderr)
        assertion_request = self.request(False)
        result = self.call('passkey', 'assert', 'demo/passkey', '--stdin', data=json.dumps(assertion_request).encode())
        self.assertEqual(result.returncode, 0, result.stderr)
        assertion = json.loads(result.stdout)
        self.assertEqual(assertion['id'], registration['id'])
        response = assertion['response']
        client_data = unb64(response['clientDataJSON'])
        self.assertEqual(json.loads(client_data), {'type': 'webauthn.get', 'challenge': assertion_request['challenge'],
                                                  'origin': assertion_request['origin'], 'crossOrigin': False})
        auth_data = unb64(response['authenticatorData'])
        self.assertEqual(len(auth_data), 37)
        self.assertEqual(auth_data[:32], hashlib.sha256(b'example.test').digest())
        self.assertEqual(auth_data[32], 0x0D)
        self.assertEqual(auth_data[33:], bytes(4))
        self.assertEqual(unb64(response['userHandle']), b'FAKE-alice-id')
        (self.root / 'signature.der').write_bytes(unb64(response['signature']))
        signed = auth_data + hashlib.sha256(client_data).digest()
        for data, valid in [(signed, True), (signed[:-1] + bytes([signed[-1] ^ 1]), False)]:
            (self.root / 'signed.bin').write_bytes(data)
            verification = subprocess.run([openssl, 'dgst', '-sha256', '-verify', str(self.root / 'public.pem'),
                                            '-signature', str(self.root / 'signature.der'), str(self.root / 'signed.bin')],
                                           capture_output=True)
            self.assertEqual(verification.returncode == 0, valid)
        self.assertNotIn('privateKey', result.stdout.decode())

    def test_passkey_scope_duplicate_registration_and_unsupported_options(self):
        self.register()
        before = self.vault_snapshot()
        requests = [self.request(False, origin='https://evil.test'),
                    self.request(False, rpID='evil.test', origin='https://evil.test'),
                    self.request(False, origin='http://example.test'),
                    self.request(False, challenge=b64(b'too-short')),
                    self.request(False, excludeCredentials=[])]
        for request in requests:
            result = self.call('passkey', 'assert', 'demo/passkey', '--stdin', data=json.dumps(request).encode())
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b'')
        result = self.call('passkey', 'register', 'demo/passkey', '--stdin', data=json.dumps(self.request()).encode())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.vault_snapshot(), before)
        self.assertEqual(self.call('run', '--env', 'PRIVATE=demo/passkey', '--', '/usr/bin/true').returncode, 64)
        self.assertEqual(self.call('run', '--otp', 'OTP=demo/passkey', '--', '/usr/bin/true').returncode, 64)

    def test_typed_credentials_archive_repair_and_independent_recovery(self):
        self.import_otp()
        _, registration = self.register()
        self.assertEqual(self.call('archive', 'demo/otp').returncode, 0)
        self.assertEqual(self.call('totp', 'code', 'demo/otp').returncode, 66)
        self.assertEqual(self.call('restore', 'demo/otp').returncode, 0)
        self.assertEqual(self.call('repair-index').returncode, 0)
        row = json.loads(self.call('where', 'demo/passkey', '--json').stdout)
        self.assertEqual(row['record']['kind'], 'passkey')
        result = subprocess.run(['swift', str(fixture.ROOT / 'recover/recover.swift'), '--vault', str(self.root / 'vault'),
                                 '--out', str(self.root / 'out')], input=(self.recovery + '\n').encode(),
                                capture_output=True, timeout=30, start_new_session=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.root / 'out/manifest.json').read_text())
        self.assertEqual({row['kind'] for row in manifest}, {'totp', 'passkey'})
        for row in manifest:
            payload = json.loads((self.root / 'out' / row['file']).read_bytes())
            if row['kind'] == 'totp':
                self.assertEqual(base64.b64decode(payload['secret']), b'12345678901234567890')
            else:
                self.assertEqual(b64(base64.b64decode(payload['credentialID'])), registration['id'])
                self.assertEqual(len(base64.b64decode(payload['privateKey'])), 32)
        log = (self.root / 'local/log.jsonl').read_text()
        self.assertNotIn(SEED, log)
        self.assertNotIn('privateKey', log)


if __name__ == '__main__':
    unittest.main()
