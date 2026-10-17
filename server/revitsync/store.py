import hashlib
import json
import os
import re
import tempfile
import threading
from datetime import datetime, timezone
from pathlib import Path

PROJECT_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
EXT_RE = re.compile(r"^[a-z0-9]{1,8}$")
ASSET_RE = re.compile(r"^([0-9a-f]{64})\.([a-z0-9]{1,8})$")


class StoreError(ValueError):
    pass


def _write_json_atomic(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-", suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


class Store:
    def __init__(self, root: str | os.PathLike):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()

    def _project_dir(self, project: str) -> Path:
        if not PROJECT_RE.match(project):
            raise StoreError(f"invalid project id: {project!r}")
        return self.root / project

    def list_projects(self) -> list[dict]:
        projects = []
        for d in sorted(self.root.iterdir()):
            if not d.is_dir() or not PROJECT_RE.match(d.name):
                continue
            m = self.get_manifest(d.name)
            if m:
                projects.append(
                    {"id": m["project"], "name": m["name"], "revision": m["revision"], "updatedAt": m["createdAt"]}
                )
        return projects

    def get_manifest(self, project: str) -> dict | None:
        path = self._project_dir(project) / "manifest.json"
        if not path.exists():
            return None
        return json.loads(path.read_text(encoding="utf-8"))

    def blob_path(self, project: str, filename: str) -> Path:
        if not ASSET_RE.match(filename):
            raise StoreError(f"invalid asset filename: {filename!r}")
        return self._project_dir(project) / "assets" / filename

    def has_blob(self, project: str, filename: str) -> bool:
        return self.blob_path(project, filename).is_file()

    def commit_revision(
        self, project: str, name: str, partitions: list[dict], uploaded_files: dict[str, bytes]
    ) -> tuple[int, list[str], list[str], list[str]]:
        pdir = self._project_dir(project)
        if not isinstance(name, str) or not name:
            raise StoreError("manifest name is required")
        if not isinstance(partitions, list):
            raise StoreError("manifest partitions must be a list")

        ids = set()
        for p in partitions:
            if not isinstance(p, dict):
                raise StoreError("partition must be an object")
            pid, sha, ext = p.get("id"), p.get("sha256"), p.get("ext")
            if not isinstance(pid, str) or not pid:
                raise StoreError("partition id is required")
            if pid in ids:
                raise StoreError(f"duplicate partition id: {pid}")
            ids.add(pid)
            if not isinstance(sha, str) or not SHA_RE.match(sha):
                raise StoreError(f"partition {pid}: invalid sha256")
            if not isinstance(ext, str) or not EXT_RE.match(ext):
                raise StoreError(f"partition {pid}: invalid ext")
        unknown = set(uploaded_files) - ids
        if unknown:
            raise StoreError(f"file parts for unlisted partitions: {sorted(unknown)}")

        with self._lock:
            for p in partitions:
                data = uploaded_files.get(p["id"])
                filename = f"{p['sha256']}.{p['ext']}"
                if data is not None:
                    if hashlib.sha256(data).hexdigest() != p["sha256"]:
                        raise StoreError(f"partition {p['id']}: sha256 mismatch")
                elif not self.has_blob(project, filename):
                    raise StoreError(f"partition {p['id']}: no file part and no stored blob")

            assets = pdir / "assets"
            assets.mkdir(parents=True, exist_ok=True)
            entries = []
            for p in partitions:
                filename = f"{p['sha256']}.{p['ext']}"
                path = assets / filename
                data = uploaded_files.get(p["id"])
                if data is not None and not path.exists():
                    fd, tmp = tempfile.mkstemp(dir=assets, prefix=".tmp-")
                    with os.fdopen(fd, "wb") as f:
                        f.write(data)
                    os.replace(tmp, path)
                entries.append(
                    {
                        "id": p["id"],
                        "name": p.get("name") or p["id"],
                        "file": f"assets/{filename}",
                        "sha256": p["sha256"],
                        "bytes": path.stat().st_size,
                    }
                )

            previous = self.get_manifest(project)
            old = {e["id"]: e["sha256"] for e in previous["partitions"]} if previous else {}
            revision = (previous["revision"] if previous else 0) + 1
            changed = [e["id"] for e in entries if old.get(e["id"]) != e["sha256"]]
            unchanged = [e["id"] for e in entries if old.get(e["id"]) == e["sha256"]]
            removed = [pid for pid in old if pid not in ids]

            manifest = {
                "project": project,
                "name": name,
                "revision": revision,
                "createdAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "upAxis": "Y",
                "metersPerUnit": 1,
                "partitions": entries,
            }
            _write_json_atomic(pdir / "revisions" / f"{revision}.json", manifest)
            _write_json_atomic(pdir / "manifest.json", manifest)
            return revision, changed, removed, unchanged
