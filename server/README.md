# RevitSync server

Local broker between the Revit add-in and the Vision Pro app. Implements `../PROTOCOL.md`.

## Install

```sh
cd server
pip install -e .[dev]
```

## Run

```sh
revitsync                      # or: python -m revitsync.main
revitsync --port 8787 --data ./data --no-mdns
```

It prints `http://<lan-ip>:8787` at startup — type that on the headset if Bonjour discovery
doesn't find the server. Data lives in `./data` (override with `--data` or `REVITSYNC_DATA`).

**Windows Firewall:** allow inbound TCP 8787 (and UDP 5353 for Bonjour), e.g. from an admin shell:

```powershell
New-NetFirewallRule -DisplayName "RevitSync" -Direction Inbound -Protocol TCP -LocalPort 8787 -Action Allow
```

## Push a hand-exported model

```sh
python tools/push_model.py --server http://127.0.0.1:8787 --project demo --name "Demo" path/to/model.usdz
```

Optional: `--partition whole --partition-name "Whole model"`.

## Tests

```sh
pytest -q
```
