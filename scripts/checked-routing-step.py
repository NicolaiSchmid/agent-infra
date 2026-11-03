#!/usr/bin/env python3
"""Run every readiness check successfully before a routing mutation command."""
import argparse
import json
import subprocess


def command(value):
    result = json.loads(value)
    if not isinstance(result, list) or not result or not all(isinstance(x, str) and x for x in result):
        raise argparse.ArgumentTypeError('Expected a nonempty JSON argument array')
    return result


def checked_step(checks, action):
    for check in checks:
        subprocess.run(check, check=True)
    subprocess.run(action, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', required=True, action='append', type=command)
    parser.add_argument('--action', required=True, type=command)
    args = parser.parse_args()
    checked_step(args.check, args.action)


if __name__ == '__main__':
    main()
