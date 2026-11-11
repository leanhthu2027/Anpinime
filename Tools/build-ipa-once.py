#!/usr/bin/env python3
"""Dispatch one explicitly authorized light IPA build and deliver its metadata.

Never retries a dispatch, including when GitHub's response is ambiguous.
Run only after authorization for this specific new macOS run.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time


def gh(*args):
    result = subprocess.run(['gh', *args], text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError('GitHub command failed. No automatic retry was attempted.')
    return json.loads(result.stdout) if result.stdout.strip() else None


def runs(repository, branch):
    return gh('run', 'list', '--repo', repository, '--workflow', 'build-ipa-light.yml',
              '--branch', branch, '--limit', '20', '--json', 'databaseId,status,headSha')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--branch', required=True)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--credential-file', required=True, type=Path)
    parser.add_argument('--dispatch-authorized', action='store_true', required=True)
    args = parser.parse_args()
    if not args.credential_file.is_file():
        raise RuntimeError('Private metadata file is missing; nothing dispatched.')
    branch = gh('api', 'repos/' + args.repository + '/git/ref/heads/' + args.branch)
    if branch['object']['sha'] != args.source_sha:
        raise RuntimeError('Remote branch differs from reviewed source; nothing dispatched.')
    previous = runs(args.repository, args.branch)
    if any(run['status'] != 'completed' for run in previous):
        raise RuntimeError('A build is already queued or running; nothing dispatched.')
    known = {run['databaseId'] for run in previous}
    # Exactly one mutation. Failure below must not re-enter this dispatch.
    gh('workflow', 'run', 'build-ipa-light.yml', '--repo', args.repository, '--ref', args.branch)
    print('One build requested; locating the run. This command will not redispatch.', flush=True)
    deadline = time.monotonic() + 90
    run_id = None
    while time.monotonic() < deadline:
        matches = [run for run in runs(args.repository, args.branch)
                   if run['databaseId'] not in known and run['headSha'] == args.source_sha]
        if len(matches) > 1:
            raise RuntimeError('Multiple new runs found; inspect Actions before proceeding.')
        if matches:
            run_id = str(matches[0]['databaseId'])
            break
        time.sleep(2)
    if run_id is None:
        raise RuntimeError('Requested run not visible yet. Inspect Actions; do not redispatch.')
    print('Run: https://github.com/' + args.repository + '/actions/runs/' + run_id, flush=True)
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        run = gh('api', 'repos/' + args.repository + '/actions/runs/' + run_id)
        if run['status'] == 'completed':
            raise RuntimeError('Run ended before metadata delivery; inspect its log.')
        if run['status'] == 'in_progress':
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('deliver-metadata-handoff.py')),
                '--repository', args.repository, '--run-id', run_id, '--source-sha', args.source_sha,
                '--credential-file', str(args.credential_file)])
            if result.returncode:
                raise RuntimeError('Metadata delivery failed. No automatic build retry was attempted.')
            print('Metadata delivered; follow this exact run to download the IPA.', flush=True)
            return
        time.sleep(3)
    raise RuntimeError('Run remains queued; inspect it before any further action.')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(str(error) if isinstance(error, RuntimeError) else 'Build coordination failed; no retry attempted.', file=sys.stderr)
        sys.exit(1)
