"""Start the local G2 map workbench: python serve_g2.py --open."""
import argparse
import threading
from pathlib import Path
import webbrowser

from rtsmap.workbench.server import make_server


def _warm_candidate_pool():
    """后台预热候选进程池：worker 的 numpy/scipy/native 导入提前做完。

    实测首次生成的 G2 要 8.5s（含 3 个 worker 首次 spawn + warmup 的开销），
    预热后这段不在关键路径上。预热失败不影响生成（只是慢一点）。
    """
    try:
        from rtsmap.gates.g2_candidates import ensure_pool
        ensure_pool()
    except Exception as error:
        print(f'[warmup] candidate pool skipped: {error}', flush=True)


def main():
    from rtsmap.pathing_native import warmup
    warmup()
    from rtsmap.workbench.catalog import prepare_g1_library
    prepare_g1_library(Path(__file__).resolve().parent)
    threading.Thread(target=_warm_candidate_pool, daemon=True).start()
    parser = argparse.ArgumentParser(description='G2 地图调参工作台')
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--open', action='store_true', help='启动后打开浏览器')
    args = parser.parse_args()
    server = make_server(Path(__file__).resolve().parent, args.port)
    url = f'http://127.0.0.1:{server.server_port}'
    print(f'G2 workbench: {url}\nPress Ctrl+C to stop.', flush=True)
    if args.open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
