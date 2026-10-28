import json
import os
import plistlib
import subprocess
import time

version, commit = os.environ["VERSION"], os.environ["SOURCE_COMMIT"]
with open("Apple/Config/MumlaiOS-Info.plist", "rb") as plist:
    origin = plistlib.load(plist)["MumlaAccessOrigin"]
command = [
    "curl", "--disable", "--silent", "--fail", "--proto", "=https",
    "--max-time", "10", "--max-filesize", "4096",
    "--header", "Cache-Control: no-cache", "--user-agent", "Mumla-Release/1.0",
    "--write-out", "\n%{http_code}",
    "--url", origin.rstrip("/") + "/healthz",
]
deadline = time.monotonic() + 1800
print(f"Waiting for ready access service {version} at {commit} on {origin}", flush=True)
while time.monotonic() < deadline:
    try:
        result = subprocess.run(command, capture_output=True, timeout=12, check=False)
        body, _, status = result.stdout.rpartition(b"\n")
        if not result.returncode and status == b"200":
            health = json.loads(body)
            if isinstance(health, dict) and health.get("version") == version and health.get("commit") == commit:
                print(f"Verified ready access service {version} at {commit}")
                break
    except (subprocess.TimeoutExpired, ValueError):
        pass
    time.sleep(min(10, max(0, deadline - time.monotonic())))
else:
    raise TimeoutError("Access service did not report the ready release within 30 minutes; inspect deployment before retrying")
