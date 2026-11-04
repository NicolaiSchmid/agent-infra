#!/usr/bin/env python3
"""Deliver protected provider credentials to a named MODUS Convex deployment."""

import argparse
import json
import os
from pathlib import Path
import stat
import sys
import urllib.request

DEPLOYMENTS = {
    "dev": "https://gateway-dev.convex.modusservice.com",
    "prod": "https://gateway.convex.modusservice.com",
}
ALLOWED_NAMES = {"TSYSTEMS_API_KEY_SECONDARY", "IONOS_API_KEY"}


def protected_text(filename):
    # Refuse symlinks and files readable by other users, including ACL mode bits.
    fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077:
            raise ValueError("Use a regular owner-only credential file")
        if info.st_uid != os.geteuid():
            raise ValueError("Credential files must belong to the invoking user")
        if info.st_size > 1024 * 1024:
            raise ValueError("Credential file exceeds the size limit")
        with os.fdopen(fd, closefd=False) as source:
            return source.read(1024 * 1024 + 1)
    finally:
        os.close(fd)


def changes_from_text(raw):
    values = json.loads(raw)
    if not isinstance(values, dict) or not values or set(values) - ALLOWED_NAMES:
        raise ValueError("Expected a nonempty JSON object with supported provider variables")
    if any(not isinstance(value, str) or not value.strip() for value in values.values()):
        raise ValueError("Provider values must be nonempty strings")
    return [{"name": name, "value": value} for name, value in sorted(values.items())]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Never forward the deployment admin credential to a redirected host.
        return None


def deliver(deployment, admin_key, changes, opener):
    request = urllib.request.Request(
        DEPLOYMENTS[deployment] + "/api/update_environment_variables",
        data=json.dumps({"changes": changes}).encode(),
        headers={
            "Authorization": "Convex " + admin_key,
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with opener.open(request, timeout=30) as response:
        if response.status != 200:
            raise ValueError("Credential delivery failed")
        # Never print the server response: an error could echo submitted values.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deployment", choices=DEPLOYMENTS, required=True)
    parser.add_argument("--secrets-file", type=Path, required=True)
    parser.add_argument("--admin-key-file", type=Path, required=True)
    parser.add_argument("--check", action="store_true", help="Validate files without network requests")
    args = parser.parse_args()
    try:
        changes = changes_from_text(protected_text(args.secrets_file))
        admin_key = protected_text(args.admin_key_file).strip()
        if not admin_key or any(char.isspace() for char in admin_key):
            raise ValueError("Invalid admin credential")
        if not args.check:
            # Avoid environment-provided proxies receiving the admin credential.
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
            deliver(args.deployment, admin_key, changes, opener)
        print("Credential files validated." if args.check else "Provider credentials delivered.")
        return 0
    except Exception:
        # Parser, HTTP and filesystem exceptions can contain sensitive input.
        print("Credential operation failed; check protected files, target access and network connectivity.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
