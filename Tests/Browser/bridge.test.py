"""Real loopback bridge + stdio framing test, no GUI, no user archive or AI access."""
import json, os, pathlib, socket, struct, subprocess, tempfile, time
root = pathlib.Path(__file__).resolve().parents[2]
host = root/'build/native-host-test'
assert host.is_file(), 'Build the isolated DEBUG test host first (see docs/RELEASE-v0.5.0.zh-CN.md)'
with tempfile.TemporaryDirectory(prefix='snapsend-bridge-') as folder:
    endpoint = pathlib.Path(folder)/'bridge.json'
    harness = subprocess.Popen([str(root/'build/bridge-test'), str(endpoint)], stdout=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if endpoint.exists():
                try:
                    probe = socket.create_connection(('127.0.0.1',27185), .1); probe.close(); break
                except OSError: pass
            time.sleep(.03)
        assert endpoint.exists()
        assert endpoint.stat().st_mode & 0o777 == 0o600
        # Unauthenticated web-origin style request cannot obtain a job.
        s = socket.create_connection(('127.0.0.1',27185), 1)
        s.sendall(b'POST /command HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}')
        assert s.recv(1024) == b''; s.close()
        payload = json.dumps({'kind':'poll'}).encode()
        wire = struct.pack('<I',len(payload)) + payload
        env = dict(os.environ, SNAPSEND_TEST_ENDPOINT=str(endpoint))
        result = subprocess.run([str(host)],input=wire*2,stdout=subprocess.PIPE,env=env,timeout=10,check=True).stdout
        for _ in range(2):
            size = struct.unpack('<I',result[:4])[0]
            assert size < 1_000_000
            response = json.loads(result[4:4+size]); result = result[4+size:]
            assert response['ok'] and response['echo'] == 'poll'
            assert len(response['jpeg']) == 906668
        assert result == b''
        print('PASS: localhost token gate, 0600 endpoint, ordered native framing, maximum photo response')
    finally:
        harness.terminate(); harness.wait(timeout=5)
