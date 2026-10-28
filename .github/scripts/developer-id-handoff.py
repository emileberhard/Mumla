import hashlib
import io
import json
import os
import re
import select
import subprocess
import sys
import time
import urllib.request
import zipfile

DEPLOY = "emileberhard/mumla-deploy"
ORIGIN = "https://ark.esmadil.se/mumla-mbag/"


def api(path, payload=None):
    command = ["gh", "api", "-H", "X-GitHub-Api-Version: 2026-03-10", path]
    if payload is not None:
        command += ["--method", "POST", "--input", "-"]
    with subprocess.Popen(command, stdin=subprocess.PIPE if payload else subprocess.DEVNULL, stdout=subprocess.PIPE) as process:
        try:
            if payload:
                process.stdin.write(json.dumps(payload).encode())
                process.stdin.close()
            deadline = time.monotonic() + 60
            content = bytearray()
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
                    raise TimeoutError("Deployment API request exceeded 60 seconds")
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    break
                content.extend(chunk)
                if len(content) > 1024 * 1024:
                    raise ValueError("GitHub response exceeds 1 MiB")
            if process.wait(timeout=max(0.1, deadline - time.monotonic())):
                raise ValueError("Private deployment API request failed")
            return bytes(content)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()


def document(path, payload=None):
    return json.loads(api(path, payload))


def public_file(name, maximum):
    request = urllib.request.Request(ORIGIN + name, headers={"User-Agent": "Mumla-Release/1.0"})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError("Public release metadata exceeds its size limit")
    return data


def verify_receipt(receipt, expected):
    if any(receipt.get(key) != value for key, value in expected.items()):
        raise ValueError("Developer ID receipt does not match this exact release")
    if receipt.get("origin") != ORIGIN or not re.fullmatch(r"[a-f0-9]{64}", receipt.get("sha256", "")):
        raise ValueError("Invalid Developer ID download identity")
    manifest = json.loads(public_file("latest.json", 65536))
    for key in ("version", "commit", "build", "sha256"):
        if manifest.get(key) != receipt[key]:
            raise ValueError(f"Public manifest does not match receipt: {key}")
    digest = hashlib.sha256()
    total = 0
    deadline = time.monotonic() + 300
    request = urllib.request.Request(ORIGIN + "Mumla.dmg", headers={"User-Agent": "Mumla-Release/1.0"})
    with urllib.request.urlopen(request, timeout=60) as response:
        while chunk := response.read(1024 * 1024):
            total += len(chunk)
            if total > 1024 * 1024 * 1024 or time.monotonic() > deadline:
                raise ValueError("Public DMG exceeds its transfer bound")
            digest.update(chunk)
    if digest.hexdigest() != receipt["sha256"]:
        raise ValueError("Public DMG digest does not match private receipt")


def preflight():
    repository = document(f"repos/{DEPLOY}")
    workflow = document(f"repos/{DEPLOY}/actions/workflows/developer-id.yml")
    if repository["full_name"] != DEPLOY or not repository["private"] or workflow["path"] != ".github/workflows/developer-id.yml" or workflow["state"] != "active":
        raise ValueError("Private Developer ID workflow is not configured and active")
    print("Private Developer ID workflow is reachable")


def main():
    values = {"version": os.environ["VERSION"], "commit": os.environ["SOURCE_COMMIT"],
              "build": os.environ["BUILD_NUMBER"], "source_run": os.environ["GITHUB_RUN_ID"],
              "source_attempt": os.environ["GITHUB_RUN_ATTEMPT"]}
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", values["version"]):
        raise ValueError("Invalid release version")
    if not re.fullmatch(r"[a-f0-9]{40}", values["commit"]) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", values["build"]) or any(not re.fullmatch(r"[1-9][0-9]*", values[key]) for key in ("source_run", "source_attempt")):
        raise ValueError("Invalid immutable release identity")
    dispatched = document(f"repos/{DEPLOY}/actions/workflows/developer-id.yml/dispatches", {"ref": "main", "inputs": values})
    run_id = dispatched["workflow_run_id"]
    if not isinstance(run_id, int) or run_id <= 0:
        raise ValueError("Dispatch did not return an exact private run ID")
    deadline = time.monotonic() + 95 * 60
    while True:
        run = document(f"repos/{DEPLOY}/actions/runs/{run_id}")
        if run["repository"]["full_name"] != DEPLOY or run["path"] != ".github/workflows/developer-id.yml" or run["event"] != "workflow_dispatch" or run["head_branch"] != "main":
            raise ValueError("Unexpected private deployment workflow")
        if run["status"] == "completed":
            if run["conclusion"] != "success":
                raise ValueError(f"Private Developer ID deployment failed: {run['html_url']}")
            break
        if time.monotonic() >= deadline:
            raise ValueError("Private Developer ID deployment exceeded 95 minutes")
        time.sleep(20)
    collection = document(f"repos/{DEPLOY}/actions/runs/{run_id}/artifacts?per_page=100")
    if collection["total_count"] > 100:
        raise ValueError("Private run artifact inventory exceeds its bound")
    artifacts = collection["artifacts"]
    receipts = [a for a in artifacts if a["name"] == "developer-id-receipt" and not a["expired"]]
    if len(receipts) != 1 or receipts[0]["size_in_bytes"] > 1024 * 1024:
        raise ValueError("Private run has no unique bounded Developer ID receipt")
    with zipfile.ZipFile(io.BytesIO(api(f"repos/{DEPLOY}/actions/artifacts/{receipts[0]['id']}/zip"))) as archive:
        files = archive.infolist()
        if len(files) != 1 or files[0].filename != "receipt.json" or files[0].file_size > 65536:
            raise ValueError("Private receipt archive has unexpected contents")
        receipt = json.loads(archive.read(files[0]))
    verify_receipt(receipt, values | {"source_repository": os.environ["GITHUB_REPOSITORY"], "deploy_run": str(run_id)})
    print(f"Verified Developer ID {values['version']} ({values['build']}) at {values['commit']}")


if __name__ == "__main__":
    if sys.argv[1:] == ["preflight"]:
        preflight()
    elif sys.argv[1:]:
        raise ValueError("Usage: developer-id-handoff.py [preflight]")
    else:
        main()
