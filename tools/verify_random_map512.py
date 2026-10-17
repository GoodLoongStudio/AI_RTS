"""Exercise the real local map HTTP pipeline without opening UI or old services."""
import json
from pathlib import Path
import sys
import threading
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools/mapgen'))
from rtsmap.workbench.server import make_server

def main():
    output = ROOT / 'agent/runs/map512/random-http'
    output.mkdir(parents=True, exist_ok=False)
    server = make_server(ROOT / 'tools/mapgen', port=0, output=output / 'jobs')
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    url = f'http://127.0.0.1:{server.server_address[1]}'
    def request(path, data=None):
        body = json.dumps(data).encode() if data is not None else None
        req = urllib.request.Request(url + path, body, {'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=15) as result:
            return json.load(result)
    try:
        boot = request('/api/bootstrap')
        assert boot['fixed']['world_size_m'] == [512, 512]
        assert boot['fixed']['export_contract_version'] == 'world-meters-v2'
        config = json.loads((ROOT / 'tools/mapgen/workbench_output/af0ac5ce8d3d4289bd3474bf7748704a/job.json').read_text(encoding='utf-8'))['config']
        payload = dict(config, target='full', skip_engine_check=True, required_world_size_m=[512, 512])
        job = request('/api/generate', payload)
        deadline = time.time() + 240
        while job['status'] == 'running' and time.time() < deadline:
            time.sleep(1)
            job = request('/api/jobs/' + job['id'])
        (output / 'bootstrap.json').write_text(json.dumps(boot, indent=2), encoding='utf-8')
        (output / 'result.json').write_text(json.dumps(job, indent=2), encoding='utf-8')
        assert job['status'] == 'done', job.get('error')
        index = json.loads((ROOT / 'source/match/maps/generated' / job['map_id'] / 'map_index.json').read_text(encoding='utf-8'))
        assert index['size'] == [512, 512] and index['root_scale'] == [1, 1, 1]
        print(json.dumps(dict(scene=job['scene_res'], index=index, stages={name: stage['status'] for name, stage in job['stages'].items()})))
        return 0
    finally:
        server.shutdown()
        server.server_close()

if __name__ == '__main__':
    raise SystemExit(main())
