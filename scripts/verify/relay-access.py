#!/usr/bin/env python3
"""Verify Relay on disposable QA simulators (UI tests reset the app's data)."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--relay-repo', required=True, type=Path)
    parser.add_argument('--device', required=True, action='append', help='Disposable simulator UDID; repeat for phone/Pad')
    parser.add_argument('--derived-data', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path, help='New report directory; keep outside Git')
    parser.add_argument('--skip-build', action='store_true')
    args = parser.parse_args()
    app = Path(__file__).resolve().parents[2]
    relay = args.relay_repo.resolve()
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    if not (relay / 'sdk/swift/Tests/Fixtures/main.go').is_file():
        raise RuntimeError('Relay fixture source is missing')
    base = ['xcodebuild', '-project', 'Hermit.xcodeproj', '-scheme', 'Hermit',
            '-derivedDataPath', str(args.derived_data.resolve()), '-parallel-testing-enabled', 'NO']
    if not (app / 'Hermit.xcodeproj').is_dir():
        subprocess.run(['xcodegen', 'generate'], cwd=app, check=True)
    if not args.skip_build:
        with tempfile.TemporaryDirectory(prefix='build-tmp-', dir=output) as build_tmp, (output / 'build.log').open('w') as log:
            build_env = os.environ.copy()
            build_env['TMPDIR'] = build_tmp
            subprocess.run(base + ['build-for-testing', '-destination', 'platform=iOS Simulator,id=' + args.device[0],
                           'CODE_SIGN_IDENTITY=-', 'CODE_SIGNING_ALLOWED=YES'], cwd=app,
                           env=build_env, stdout=log, stderr=subprocess.STDOUT, check=True)
    with tempfile.TemporaryDirectory(prefix='private-fixture-', dir=output) as private:
        private = Path(private)
        binary = private / 'fixture'
        env = os.environ.copy()
        env['TMPDIR'] = str(private)
        subprocess.run(['go', 'build', '-trimpath', '-o', str(binary), './sdk/swift/Tests/Fixtures'], cwd=relay, env=env, check=True)
        for index, device in enumerate(args.device):
            record = private / 'fixture.json'
            record.unlink(missing_ok=True)
            env['RF_SWIFT_FIXTURE_OUTPUT'] = str(record)
            child = subprocess.Popen([str(binary)], env=env, stdin=subprocess.DEVNULL,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                import time
                for _ in range(200):
                    try:
                        json.loads(record.read_bytes())
                        break
                    except (OSError, ValueError):
                        if child.poll() is not None:
                            raise RuntimeError('Isolated fixture exited')
                        time.sleep(0.025)
                else:
                    raise RuntimeError('Isolated fixture startup timed out')
                env['TEST_RUNNER_MOSHPIT_RELAY_FIXTURE'] = str(record)
                env['TEST_RUNNER_MOSHPIT_RELAY_LOOPBACK_TESTS'] = '1'
                run = output / ('device-' + str(index + 1))
                command = base + ['test-without-building', '-destination', 'platform=iOS Simulator,id=' + device,
                                  '-resultBundlePath', str(run.with_suffix('.xcresult'))]
                for suite in ['RelayAccessTests', 'RelayCredentialOwnershipTests', 'RelaySSHServiceLiveTests',
                              'ConnectionTransportTests', 'ConnectionTransportFormTests', 'CloudSyncTests',
                              'SSHSessionShutdownTests', 'HostListPresentationTests']:
                    command.append('-only-testing:HermitTests/' + suite)
                command.append('-only-testing:HermitUITests/RelayConnectionUITest')
                with run.with_suffix('.log').open('w') as log:
                    subprocess.run(command, cwd=app, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
                print('Relay simulator verification passed: ' + device)
            finally:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
    print('Reports: ' + str(output))


if __name__ == '__main__':
    main()
