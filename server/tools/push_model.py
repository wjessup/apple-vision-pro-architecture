import argparse
import hashlib
import json
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path


def asset_exists(base: str, project: str, filename: str) -> bool:
    req = urllib.request.Request(f"{base}/api/projects/{project}/assets/{filename}", method="HEAD")
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status == 200
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return False
        raise


def multipart(fields: dict[str, str], files: dict[str, tuple[str, bytes]]) -> tuple[bytes, str]:
    boundary = uuid.uuid4().hex
    out = bytearray()
    for name, value in fields.items():
        out += f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'.encode()
        out += value.encode() + b"\r\n"
    for name, (filename, data) in files.items():
        out += (
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
            "Content-Type: application/octet-stream\r\n\r\n"
        ).encode()
        out += data + b"\r\n"
    out += f"--{boundary}--\r\n".encode()
    return bytes(out), f"multipart/form-data; boundary={boundary}"


def main() -> None:
    parser = argparse.ArgumentParser(description="Upload a .usdz/.usda file as a single-partition revision")
    parser.add_argument("file")
    parser.add_argument("--server", default="http://127.0.0.1:8787")
    parser.add_argument("--project", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--partition", default="whole")
    parser.add_argument("--partition-name", default="Whole model")
    args = parser.parse_args()

    path = Path(args.file)
    ext = path.suffix.lstrip(".").lower()
    if ext not in ("usdz", "usda"):
        sys.exit("file must be .usdz or .usda")
    data = path.read_bytes()
    sha = hashlib.sha256(data).hexdigest()
    base = args.server.rstrip("/")

    manifest = {
        "name": args.name,
        "partitions": [{"id": args.partition, "name": args.partition_name, "sha256": sha, "ext": ext}],
    }
    files = {}
    if asset_exists(base, args.project, f"{sha}.{ext}"):
        print(f"blob {sha}.{ext} already on server, skipping file part")
    else:
        files[args.partition] = (path.name, data)

    body, content_type = multipart({"manifest": json.dumps(manifest)}, files)
    req = urllib.request.Request(
        f"{base}/api/projects/{args.project}/revisions",
        data=body,
        method="POST",
        headers={"Content-Type": content_type},
    )
    try:
        with urllib.request.urlopen(req) as resp:
            print(resp.read().decode())
    except urllib.error.HTTPError as e:
        sys.exit(f"{e.code}: {e.read().decode()}")


if __name__ == "__main__":
    main()
