#!/usr/bin/env python3
"""Update an AltStore/SideStore source JSON from this repo's GitHub Release.

Runs in GitHub Actions on `release: published`. It finds the `.ipa` asset in the
release and prepends a new version entry to the app's `versions` array, taking
the download URL and exact byte size straight from the release asset. Fields that
a release can't provide (minOSVersion, buildVersion) are carried over from the
previous top version. Any legacy top-level version fields already present on the
app are refreshed too.

The script is identical across every app repo — only the SOURCE_FILE env differs.

Env:
  REPO         owner/repo (Actions provides this as github.repository)
  SOURCE_FILE  path to the source JSON to update (e.g. source.json)
  RELEASE_TAG  tag to read; empty -> latest published release
  BUNDLE_ID    optional; which app in `apps` to update (default: first)
  GITHUB_TOKEN token for the GitHub API
"""
import json
import os
import re
import sys
import urllib.request

API = "https://api.github.com"


def gh(path):
    req = urllib.request.Request(
        API + path,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {os.environ['GITHUB_TOKEN']}",
            "User-Agent": "altstore-source-updater",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))


def main():
    repo = os.environ["REPO"]
    source_file = os.environ.get("SOURCE_FILE", "source.json")
    tag = os.environ.get("RELEASE_TAG", "").strip()
    bundle_id = os.environ.get("BUNDLE_ID", "").strip()

    release = gh(f"/repos/{repo}/releases/tags/{tag}") if tag \
        else gh(f"/repos/{repo}/releases/latest")

    ipa = next(
        (a for a in release.get("assets", []) if a["name"].lower().endswith(".ipa")),
        None,
    )
    if not ipa:
        sys.exit(f"No .ipa asset in release {release.get('tag_name')!r}; nothing to do.")

    version = release["tag_name"].lstrip("vV")
    date = (release.get("published_at") or "")[:10]
    notes = (release.get("body") or "").strip()
    download_url = ipa["browser_download_url"]
    size = ipa["size"]

    with open(source_file, encoding="utf-8") as f:
        raw = f.read()
    data = json.loads(raw)

    apps = data.get("apps")
    if not apps:
        sys.exit(f"{source_file} has no 'apps' array.")
    app = (
        next((a for a in apps if a.get("bundleIdentifier") == bundle_id), apps[0])
        if bundle_id else apps[0]
    )

    versions = app.setdefault("versions", [])
    prev = versions[0] if versions else {}

    entry = {"version": version}
    if "buildVersion" in prev:
        entry["buildVersion"] = prev["buildVersion"]
    entry["date"] = date
    entry["localizedDescription"] = notes or f"{app.get('name', 'App')} {version}"
    entry["downloadURL"] = download_url
    entry["size"] = size
    if "minOSVersion" in prev:
        entry["minOSVersion"] = prev["minOSVersion"]

    if versions and versions[0].get("version") == version:
        versions[0] = entry  # re-publish of same version -> replace in place
    else:
        versions.insert(0, entry)

    # Refresh legacy top-level fields only if the app already uses them.
    legacy = {
        "version": version,
        "versionDate": date,
        "versionDescription": entry["localizedDescription"],
        "downloadURL": download_url,
        "size": size,
        "minOSVersion": entry.get("minOSVersion"),
    }
    for key, value in legacy.items():
        if key in app and value is not None:
            app[key] = value

    # Preserve the file's existing indentation (2 or 4 spaces, or tabs).
    match = re.search(r"\n([ \t]+)\"", raw)
    detected = match.group(1) if match else "  "
    indent = len(detected) if set(detected) == {" "} else detected

    with open(source_file, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=indent, ensure_ascii=False)
        f.write("\n")

    print(f"Updated {source_file}: {app.get('name')} -> {version} ({size} bytes)")


if __name__ == "__main__":
    main()
