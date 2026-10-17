import hashlib
import json

import pytest
from fastapi.testclient import TestClient

from revitsync.app import create_app


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def upload(client, parts, files, project="demo"):
    manifest = {
        "name": "Demo",
        "partitions": [{"id": pid, "name": pid, "sha256": sha(data), "ext": "usda"} for pid, data in parts.items()],
    }
    return client.post(
        f"/api/projects/{project}/revisions",
        data={"manifest": json.dumps(manifest)},
        files={pid: (f"{pid}.usda", parts[pid]) for pid in files},
    )


@pytest.fixture
def client(tmp_path):
    with TestClient(create_app(str(tmp_path))) as c:
        yield c


def test_revisions_diff(client):
    parts = {"level-1": b"#usda 1.0 a", "level-2": b"#usda 1.0 b", "level-3": b"#usda 1.0 c"}
    r = upload(client, parts, parts)
    assert r.status_code == 200
    assert r.json() == {"revision": 1, "changed": ["level-1", "level-2", "level-3"], "removed": [], "unchanged": []}

    parts["level-2"] = b"#usda 1.0 b2"
    r = upload(client, parts, ["level-2"])
    assert r.json() == {"revision": 2, "changed": ["level-2"], "removed": [], "unchanged": ["level-1", "level-3"]}

    del parts["level-3"]
    r = upload(client, parts, [])
    assert r.json() == {"revision": 3, "changed": [], "removed": ["level-3"], "unchanged": ["level-1", "level-2"]}

    m = client.get("/api/projects/demo/manifest").json()
    assert m["revision"] == 3 and m["upAxis"] == "Y" and m["metersPerUnit"] == 1
    assert m["partitions"][1]["file"] == f"assets/{sha(b'#usda 1.0 b2')}.usda"
    assert client.get("/api/projects").json()["projects"][0]["revision"] == 3


def test_missing_blob_rejected(client):
    assert upload(client, {"level-1": b"x"}, []).status_code == 400
    assert client.get("/api/projects/demo/manifest").status_code == 404


def test_sha_mismatch_rejected(client):
    manifest = {"name": "Demo", "partitions": [{"id": "a", "name": "A", "sha256": sha(b"x"), "ext": "usda"}]}
    r = client.post(
        "/api/projects/demo/revisions", data={"manifest": json.dumps(manifest)}, files={"a": ("a.usda", b"y")}
    )
    assert r.status_code == 400


def test_invalid_project_rejected(client):
    assert upload(client, {"a": b"x"}, ["a"], project="Bad_Name").status_code == 400


def test_assets(client):
    data = b"#usda 1.0 hello"
    upload(client, {"a": data}, ["a"])
    url = f"/api/projects/demo/assets/{sha(data)}.usda"
    assert client.head(url).status_code == 200
    r = client.get(url)
    assert r.content == data
    assert r.headers["content-type"].startswith("text/plain")
    assert "immutable" in r.headers["cache-control"]
    assert client.head(f"/api/projects/demo/assets/{'0' * 64}.usda").status_code == 404
    assert client.get("/api/projects/demo/assets/..%2Fmanifest.json").status_code in (400, 404)
    assert client.get("/api/projects/demo/assets/manifest.json").status_code in (400, 404)


def test_websocket(client):
    with client.websocket_connect("/api/ws") as ws:
        assert ws.receive_json() == {"event": "hello", "revisions": {}}
        ws.send_text('{"event":"ping"}')
        upload(client, {"a": b"x"}, ["a"])
        assert ws.receive_json() == {
            "event": "scene.updated",
            "project": "demo",
            "revision": 1,
            "changed": ["a"],
            "removed": [],
        }
