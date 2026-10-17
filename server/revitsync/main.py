import argparse
import logging
import os

import uvicorn

from .app import create_app
from .discovery import lan_ipv4s


def main() -> None:
    parser = argparse.ArgumentParser(prog="revitsync", description="RevitSync local sync server")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--data", default=os.environ.get("REVITSYNC_DATA", "./data"))
    parser.add_argument("--no-mdns", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO)
    app = create_app(args.data, port=args.port, mdns=not args.no_mdns)

    print(f"RevitSync data: {os.path.abspath(args.data)}")
    ips = lan_ipv4s() if args.host in ("0.0.0.0", "::") else [args.host]
    for ip in ips or ["127.0.0.1"]:
        print(f"RevitSync listening: http://{ip}:{args.port}", flush=True)
    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
