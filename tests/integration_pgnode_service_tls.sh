#!/usr/bin/env bash
# Real HTTP/TLS sockets and authentication; no host services or ACME accounts.
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT_DIR/pg-node-service.sh" <<'PY'
import hashlib, http.client, os, pathlib, re, shutil, signal, socket, ssl, subprocess, sys, tempfile, time
with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    script = root / 'service.sh'
    shutil.copyfile(sys.argv[1], script)
    script.chmod(0o700)
    def openssl(*args):
        subprocess.run(['openssl', *map(str, args)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # Use a CA-signed leaf to ensure issuer classification never requires mTLS.
    openssl('req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes', '-days', '1', '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign', '-subj', '/CN=test-ca', '-keyout', root/'ca.key', '-out', root/'ca.pem')
    openssl('req', '-new', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes', '-subj', '/CN=test-leaf', '-keyout', root/'leaf.key', '-out', root/'leaf.csr')
    (root/'ext').write_text('subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n')
    openssl('x509', '-req', '-in', root/'leaf.csr', '-CA', root/'ca.pem', '-CAkey', root/'ca.key', '-CAcreateserial', '-days', '1', '-extfile', root/'ext', '-out', root/'leaf.pem')
    def environment(enabled, host, port):
        envfile = root/'service.env'
        envfile.write_text(f'API_KEY=test-key\nTLS_ENABLED={enabled}\nNODE_HOST={host}\nAPI_PORT={port}\nSSL_CERT_FILE={root / "leaf.pem" if enabled == "true" else root / "absent.pem"}\nSSL_KEY_FILE={root / "leaf.key" if enabled == "true" else root / "absent.key"}\n')
        return dict(os.environ, ENV_FILE=str(envfile))
    for enabled in ('true', 'false'):
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        with (root/'service.log').open('wb') as log:
            process = subprocess.Popen(['bash', str(script)], env=environment(enabled, '127.0.0.1', port), stdout=log, stderr=log, start_new_session=True)
            try:
                def request(key=None):
                    if enabled == 'true':
                        client = http.client.HTTPSConnection('127.0.0.1', port, timeout=1, context=ssl.create_default_context(cafile=str(root/'ca.pem')))
                    else:
                        client = http.client.HTTPConnection('127.0.0.1', port, timeout=1)
                    try:
                        client.request('GET', '/', headers={'Connection': 'close', **({'x-api-key': key} if key else {})})
                        response = client.getresponse()
                        response.read()
                        return response.status
                    finally:
                        client.close()
                deadline = time.monotonic() + 5
                while True:
                    try:
                        assert request() == 401
                        break
                    except (OSError, http.client.HTTPException):
                        if process.poll() is not None or time.monotonic() >= deadline:
                            raise AssertionError((root/'service.log').read_text())
                        time.sleep(.03)
                assert request('wrong') == 401
                assert request('test-key') == 200
                if enabled == 'true':
                    # Exercise the manager's real fresh-handshake verifier, with
                    # both the matching leaf pin and an unexpected replacement.
                    manager = pathlib.Path(sys.argv[1]).with_name('pg-node.sh').read_text()
                    verifier = re.search(r'^verify_node_cert_endpoint\(\) \(.*?^\)', manager, re.M | re.S).group()
                    pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert((root/'leaf.pem').read_text())).hexdigest()
                    for expected, code in ((pin, 0), ('0'*64, 1)):
                        result = subprocess.run(['bash', '-c', verifier + '\nverify_node_cert_endpoint "$@"', '_',
                            '127.0.0.1', str(port), expected, 'localhost'], capture_output=True, timeout=15)
                        assert result.returncode == code, result.stderr.decode()
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=5)
    for enabled, host in [('invalid', '127.0.0.1'), ('false', '0.0.0.0'), ('false', '::'), ('false', '8.8.8.8'), ('false', 'fe80::1'), ('false', '::ffff:8.8.8.8')]:
        result = subprocess.run(['bash', str(script)], env=environment(enabled, host, 62050), capture_output=True, timeout=3)
        assert result.returncode != 0, (enabled, host)
    for host in ('::1', '10.1.1.1', '172.16.0.1', '192.168.0.1', 'fd00::1', '::ffff:192.168.1.1'):
        result = subprocess.run(['bash', '-c', 'PG_NODE_SERVICE_SOURCE_ONLY=true source "$1"; private_backend_host "$2"', '_', str(script), host], capture_output=True, timeout=3)
        assert result.returncode == 0, (host, result.stderr)
print('Maintenance transport tests passed')
PY
