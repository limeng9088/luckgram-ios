#!/usr/bin/env python3
"""Re-issue the fake-codesigning provisioning profiles for a new bundle id.

The upstream fake profiles are self-signed and only consumed for unsigned CI builds;
Make.py matches them by `Entitlements.application-identifier` prefix, so a bundle id
change requires rewriting every identifier inside them and re-signing with the same
self-signed certificate (build-system/fake-codesigning/certs/SelfSigned.p12).

Usage: python3 ci/rebrand_profiles.py <old_bundle_id> <new_bundle_id>
"""
import datetime
import glob
import os
import plistlib
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAKE = os.path.join(ROOT, 'build-system', 'fake-codesigning')


def replace_ids(value, old, new):
    """Recursively replace the bundle id in every string of a plist object."""
    if isinstance(value, str):
        return value.replace(old, new)
    if isinstance(value, list):
        return [replace_ids(v, old, new) for v in value]
    if isinstance(value, dict):
        return {k: replace_ids(v, old, new) for k, v in value.items()}
    return value


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    old, new = sys.argv[1], sys.argv[2]

    with tempfile.TemporaryDirectory() as tmp:
        pem = os.path.join(tmp, 'fake.pem')
        # Empty password is the upstream convention for the fake p12.
        subprocess.run(['openssl', 'pkcs12', '-in', os.path.join(FAKE, 'certs', 'SelfSigned.p12'),
                        '-passin', 'pass:', '-nodes', '-legacy', '-out', pem], check=True)

        for path in sorted(glob.glob(os.path.join(FAKE, 'profiles', '*.mobileprovision'))):
            raw = subprocess.run(['openssl', 'smime', '-inform', 'der', '-verify', '-noverify', '-in', path],
                                 check=True, capture_output=True).stdout
            profile = replace_ids(plistlib.loads(raw), old, new)
            profile.pop('DER-Encoded-Profile', None)
            # Upstream fake profiles expire; keep CI builds working.
            profile['ExpirationDate'] = datetime.datetime(2035, 1, 1)

            plist = os.path.join(tmp, 'profile.plist')
            with open(plist, 'wb') as f:
                plistlib.dump(profile, f)
            subprocess.run(['openssl', 'smime', '-sign', '-binary', '-nodetach', '-outform', 'der',
                            '-signer', pem, '-in', plist, '-out', path], check=True)
            print('{}: {}'.format(os.path.basename(path), profile['Entitlements']['application-identifier']))


if __name__ == '__main__':
    main()
