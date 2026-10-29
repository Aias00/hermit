#!/usr/bin/env python3
"""Create a private xctestrun COPY for attended Access UI verification.

First use --mode smoke and audit its xcresult for retained recordings,
screenshots, and UI hierarchies. A clean smoke result is not a guarantee that
a later live run will retain no diagnostics. Create --mode live using only:
MOSHPIT_CF_LIVE_HOSTNAME, MOSHPIT_CF_LIVE_TEAM_DOMAIN, MOSHPIT_CF_LIVE_AUDIENCE,
MOSHPIT_CF_LIVE_SSH_HOST. TEST_RUNNER_ prefixes are also accepted.

The four inputs are public application metadata. Never supply a password,
private key, OTP, Cookie, or JWT. The test cancels the first system browser; a
human completes the second login. Optional MOSHPIT_CF_EXPORT_LOGIN_LINK_DIR
passes a local directory for the DEBUG simulator's one-time public-key HTML
handoff. It never imports credentials or replaces the App's authentication.
No project/test-plan defaults or production settings are changed by this script.

Usage:
  python3 prepare_live_ui_run.py --input /path/Moshpit.xctestrun --mode smoke
  xcodebuild test-without-building -xctestrun <printed path> -destination ... \
      -collect-test-diagnostics never -parallel-testing-enabled NO

SystemAttachmentLifetime=keepNever and UserAttachmentLifetime=keepNever request
non-retention; they do not prevent every diagnostic capture. XCTest has retained
a Safari UI hierarchy during a failed hit-point retry despite these settings.
The screenshots preference avoids requesting automatic screen recordings; it
does not disable screenshots by itself. The explicit capture-disabled flag also
suppresses the smoke helper's manual screenshots and hierarchy attachments.
Audit every run, including failures, before sharing results. Keep any unexpected
attachments private and do not print their contents, browser URLs, or accounts.
This script cannot guarantee zero captures on failure.
"""

import argparse
import copy
import json
import os
from pathlib import Path
import plistlib
import tempfile


PUBLIC_FIELDS = ("HOSTNAME", "TEAM_DOMAIN", "AUDIENCE", "SSH_HOST")


def expand_paths(value, root, host, bundle):
    if isinstance(value, str):
        return value.replace("__TESTROOT__", str(root)).replace("__TESTHOST__", host).replace("__TESTBUNDLE__", bundle)
    if isinstance(value, list):
        return [expand_paths(item, root, host, bundle) for item in value]
    if isinstance(value, dict):
        return {key: expand_paths(item, root, host, bundle) for key, item in value.items()}
    return value


def configure_target(original, source, mode, metadata):
    target = copy.deepcopy(original)
    host = target.get("TestHostPath", "").replace("__TESTROOT__", str(source.parent))
    bundle = target.get("TestBundlePath", "").replace("__TESTROOT__", str(source.parent)).replace("__TESTHOST__", host)
    target = expand_paths(target, source.parent, host, bundle)
    target.update(SystemAttachmentLifetime="keepNever", UserAttachmentLifetime="keepNever",
                  PreferredScreenCaptureFormat="screenshots", ParallelizationEnabled=False,
                  TestTimeoutsEnabled=True, DefaultTestExecutionTimeAllowance=600,
                  MaximumTestExecutionTimeAllowance=600, CommandLineArguments=[])
    target["OnlyTestIdentifiers"] = [
        "CloudflareLiveUITest/testAccessCancellationLoginAndRelaunch" if mode == "live" else
        "CloudflareConnectionUITest/testCloudflareConfigurationPersistsAndDirectNeedsNoLogin"]
    target.pop("SkipTestIdentifiers", None)
    environment = target.setdefault("EnvironmentVariables", {})
    for name in list(environment):
        if name.startswith(("MOSHPIT_SEED_", "MOSHPIT_CF_LIVE", "MOSHPIT_CF_EXPORT_LOGIN_LINK", "TEST_RUNNER_MOSHPIT_")):
            environment.pop(name)
    # Explicit keepAlways user attachments can survive the xctestrun policy.
    # The synthetic smoke helper must suppress creation as well as retention.
    environment["MOSHPIT_CF_LIVE_CAPTURE_DISABLED"] = "1"
    if mode == "live":
        environment.update(metadata)
        environment["MOSHPIT_CF_LIVE"] = "1"
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", type=Path, help="New file only; defaults to a private temporary directory")
    parser.add_argument("--mode", choices=("smoke", "live"), default="smoke")
    args = parser.parse_args()
    source = args.input.expanduser().resolve()
    metadata = {}
    if args.mode == "live":
        for suffix in PUBLIC_FIELDS:
            name = "MOSHPIT_CF_LIVE_" + suffix
            value = os.environ.get(name) or os.environ.get("TEST_RUNNER_" + name)
            if not value or not value.strip():
                parser.error("Missing public metadata environment variable: " + name)
            metadata[name] = value.strip()
        export_name = "MOSHPIT_CF_EXPORT_LOGIN_LINK_DIR"
        export_directory = os.environ.get(export_name) or os.environ.get("TEST_RUNNER_" + export_name)
        if export_directory is not None:
            if not export_directory.startswith("/") or "\0" in export_directory:
                parser.error("The simulator handoff directory must be an absolute local path")
            metadata[export_name] = export_directory
    data = plistlib.loads(source.read_bytes())
    result = copy.deepcopy(data)
    found = False
    if "TestConfigurations" in result:
        configurations = []
        for configuration in result["TestConfigurations"]:
            targets = []
            for target in configuration.get("TestTargets", []):
                if target.get("ProductModuleName") == "MoshpitUITests":
                    targets.append(configure_target(target, source, args.mode, metadata))
                    found = True
            if targets:
                configuration["TestTargets"] = targets
                configurations.append(configuration)
        result["TestConfigurations"] = configurations
    else:
        result = {key: value for key, value in result.items() if key.startswith("__")}
        for name, target in data.items():
            if isinstance(target, dict) and (name == "MoshpitUITests" or target.get("ProductModuleName") == "MoshpitUITests"):
                result[name] = configure_target(target, source, args.mode, metadata)
                found = True
    if not found:
        parser.error("The input has no MoshpitUITests target")
    output = args.output.expanduser().resolve() if args.output else (
        Path(tempfile.mkdtemp(prefix="moshpit-access-ui-")).resolve() / (args.mode + ".xctestrun"))
    if output == source or output.exists():
        parser.error("Choose a new output path; the original and existing files are never overwritten")
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        plistlib.dump(result, stream)
    print(json.dumps({"xctestrun": str(output), "mode": args.mode,
                      "system_attachments": "keepNever", "user_attachments": "keepNever",
                      "required_cli_option": "-collect-test-diagnostics never"}))


if __name__ == "__main__":
    main()
