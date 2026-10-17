import json
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from starlette.datastructures import UploadFile

from . import discovery
from .store import ASSET_RE, Store, StoreError

MEDIA_TYPES = {"usdz": "model/vnd.usdz+zip", "usda": "text/plain"}


class Hub:
    def __init__(self):
        self.sockets: set[WebSocket] = set()

    async def broadcast(self, message: dict) -> None:
        text = json.dumps(message)
        for ws in list(self.sockets):
            try:
                await ws.send_text(text)
            except Exception:
                self.sockets.discard(ws)


def create_app(data_dir: str = "./data", port: int | None = None, mdns: bool = False) -> FastAPI:
    store = Store(data_dir)
    hub = Hub()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        handle = await run_in_threadpool(discovery.start, port) if mdns and port else None
        yield
        if handle:
            await run_in_threadpool(discovery.stop, handle)

    app = FastAPI(title="RevitSync", lifespan=lifespan)
    app.state.store = store
    app.state.hub = hub
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

    @app.get("/api/health")
    def health():
        return {"ok": True}

    @app.get("/api/projects")
    def projects():
        return {"projects": store.list_projects()}

    @app.get("/api/projects/{project}/manifest")
    def manifest(project: str):
        try:
            m = store.get_manifest(project)
        except StoreError as e:
            raise HTTPException(400, str(e))
        if m is None:
            raise HTTPException(404, "no revision yet")
        return m

    @app.api_route("/api/projects/{project}/assets/{filename}", methods=["GET", "HEAD"])
    def asset(project: str, filename: str):
        match = ASSET_RE.match(filename)
        if not match:
            raise HTTPException(404, "not found")
        try:
            path = store.blob_path(project, filename)
        except StoreError:
            raise HTTPException(404, "not found")
        if not path.is_file():
            raise HTTPException(404, "not found")
        return FileResponse(
            path,
            media_type=MEDIA_TYPES.get(match.group(2), "application/octet-stream"),
            headers={"Cache-Control": "public, max-age=31536000, immutable"},
        )

    @app.post("/api/projects/{project}/revisions")
    async def upload(project: str, request: Request):
        form = await request.form()
        raw = form.get("manifest")
        if raw is None:
            raise HTTPException(400, "missing manifest field")
        if isinstance(raw, UploadFile):
            raw = (await raw.read()).decode("utf-8")
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            raise HTTPException(400, "manifest is not valid JSON")
        if not isinstance(body, dict):
            raise HTTPException(400, "manifest must be an object")
        files = {}
        for key, value in form.multi_items():
            if key != "manifest" and isinstance(value, UploadFile):
                files[key] = await value.read()
        try:
            revision, changed, removed, unchanged = await run_in_threadpool(
                store.commit_revision, project, body.get("name"), body.get("partitions"), files
            )
        except StoreError as e:
            raise HTTPException(400, str(e))
        await hub.broadcast(
            {"event": "scene.updated", "project": project, "revision": revision, "changed": changed, "removed": removed}
        )
        return {"revision": revision, "changed": changed, "removed": removed, "unchanged": unchanged}

    @app.websocket("/api/ws")
    async def ws(websocket: WebSocket):
        await websocket.accept()
        hub.sockets.add(websocket)
        try:
            revisions = {p["id"]: p["revision"] for p in store.list_projects()}
            await websocket.send_text(json.dumps({"event": "hello", "revisions": revisions}))
            while True:
                await websocket.receive_text()
        except WebSocketDisconnect:
            pass
        finally:
            hub.sockets.discard(websocket)

    return app
