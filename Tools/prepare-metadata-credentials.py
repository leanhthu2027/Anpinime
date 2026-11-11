#!/usr/bin/env python3
"""Prepare the ignored app resource from build secrets without logging values."""

import argparse
import os
from pathlib import Path
import plistlib
import re
import sys
import tempfile


def credential(settings):
    for name in ("TMDB_READ_TOKEN", "TMDB_API_KEY"):
        raw = settings.get(name, "")
        if not isinstance(raw, str):
            raise ValueError("Metadata credential must be text.")
        value = raw.strip()
        if not value:
            continue
        if len(value.encode()) > 8192 or any(c.isspace() for c in value):
            raise ValueError("Metadata credential format is invalid.")
        if name == "TMDB_API_KEY" and not re.fullmatch(r"[a-fA-F0-9]{32}", value):
            raise ValueError("TMDB_API_KEY must be a 32-character hexadecimal API key.")
        return {name: value}
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-file", type=Path,
                        help="Optional private plist; never pass the credential as a command argument.")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1]
                        / "AnyAnime/Private/MetadataCredentials.plist")
    args = parser.parse_args()
    try:
        value = credential(os.environ)
        if value is None:
            source = args.source_file or args.output
            if source.is_file():
                data = source.read_bytes()
                if len(data) > 32 * 1024:
                    raise ValueError("Metadata credential resource is too large.")
                settings = plistlib.loads(data)
                if not isinstance(settings, dict):
                    raise ValueError("Metadata credential resource is invalid.")
                value = credential(settings)
        if value is None:
            raise ValueError("Missing metadata credential. Set the TMDB_API_KEY or TMDB_READ_TOKEN build secret.")
        args.output.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
        fd, name = tempfile.mkstemp(prefix=".metadata-", dir=args.output.parent)
        temporary = Path(name)
        try:
            with os.fdopen(fd, "wb") as output:
                plistlib.dump(value, output, fmt=plistlib.FMT_BINARY, sort_keys=True)
            os.chmod(temporary, 0o600)
            os.replace(temporary, args.output)
        finally:
            temporary.unlink(missing_ok=True)
        print("Metadata credential resource prepared.")
        return 0
    except ValueError as error:
        print(str(error), file=sys.stderr)
    except (OSError, plistlib.InvalidFileException):
        print("Could not read or prepare the private metadata credential resource.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
