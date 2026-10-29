# Hermit

**English** · [中文](README-zh.md)

**Hermit is an SSH / Mosh terminal for iPhone and iPad, built for working with
coding agents on remote machines.** It supports tmux and herdr sessions, direct
SSH, Cloudflare Access, and embedded Tailscale, with local voice input and native
connection status on the Lock Screen and Dynamic Island.

Hermit is maintained in this repository and is based on
[Moshpit by Cluas](https://github.com/Cluas/moshpit). The upstream project and its
original copyright and license notices remain acknowledged here.

[Repository](https://github.com/Aias00/hermit) ·
[Architecture](docs/ARCHITECTURE.md) ·
[Build guide](CONTRIBUTING.md) ·
[Issues](https://github.com/Aias00/hermit/issues)

## Screenshots

These screenshots are inherited from upstream Moshpit and show the terminal,
agent status and icon features. Hermit's current host list and voice review flow
have since changed.

| Agents at a glance | An agent's pane | tmux windows | Needs-you alert | Nine icons |
|---|---|---|---|---|
| ![Upstream home screen with agent status](docs/assets/agents.png) | ![A Claude Code pane in the terminal](docs/assets/agent-terminal.png) | ![tmux window picker with agent status](docs/assets/tmux-windows.png) | ![Lock Screen with an encrypted push from a host](docs/assets/lock-screen.png) | ![Icon gallery with nine Liquid Glass icons](docs/assets/icons.png) |

## What it does

**Terminal and connections**

- SSH and Mosh, with connection recovery and diagnostics for network changes.
- Configurable [Cloudflare Access](docs/design/cloudflare-herdr-access.md) and
  [embedded Tailscale](docs/design/tailcat-ssh.md) connections. Tailcat is also
  available as an experimental transport.
- tmux control mode with native rendering, window and pane navigation, and
  session management.
- [herdr](https://github.com/herdrdev/herdr) support for coding agents, rendered
  one full-width pane at a time.
- An iPad host sidebar, native pickers, hardware keyboard shortcuts, themes,
  terminal fonts, a shortcut bar, IME composition and tappable links.

**Input and session status**

- On-device Apple speech recognition and optional local Whisper models. Stop to
  review text, change language and recognize the recording again, restore the
  original result, or edit before adding it to the draft.
- Local technical vocabulary for supported Apple recognizers and Whisper.
  Compare local engines using the same recording in Settings, with preparation,
  first-text and finalization timings. Vocabulary stays outside cloud requests
  and iCloud synchronization.
- Optional Doubao cloud transcription with your own API key, plus a recording
  test page in Settings that works without an SSH connection. The selected
  cloud provider receives audio only when you stop for transcription or retry.
- One draft and paper-plane action for sending text to the remote terminal;
  review and cancellation keep text local.
- Connection and reported task status in Live Activities. Updates pause when
  iOS suspends the app and resume when the app becomes active.
- Agent notifications, image sharing and remote worktree workflows inherited
  from Moshpit. Remote push delivery requires working relay/APNs configuration
  and signing capabilities; see [the push guide](docs/PUSH.md).
- Optional iCloud synchronization of host configuration and app settings, with
  credential synchronization controls.

**Data and host control**

- Passwords and private keys use the iOS Keychain. The iCloud settings control
  whether eligible credentials also synchronize between devices.
- Apple and Whisper recognition stay on the device. Selecting Doubao sends
  recordings to Volcengine for recognition; its account terms and charges apply.
  Its API key stays in the device Keychain and is excluded from SSH credential
  sync. Temporary retry audio is released when review is accepted or cancelled.
- Host installation and session creation use explicit app actions. SSH host-key
  verification applies across the supported connection transports.

Works with any SSH server. Mosh, tmux and herdr are optional; install guides are
built in.

## Build from source

You need macOS, Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen),
Go 1.27.3 for the embedded network library, and an iOS 18 or later simulator or
device.

```sh
git clone https://github.com/Aias00/hermit.git
cd hermit
brew install xcodegen
scripts/build-tailcat.sh # builds the pinned native library; Go must already be installed
xcodegen generate        # project.yml is the source of truth
open Hermit.xcodeproj
```

Pick the **Hermit** scheme and a simulator, then press ⌘R. Swift packages resolve
on the first build. Device builds need your signing configuration in
`Signing.xcconfig`; see [CONTRIBUTING.md](CONTRIBUTING.md) and the
[personal-device guide](docs/install-free-account.md).

Run the tests with ad hoc simulator signing so SystemKeychain tests retain the
app's entitlements:

```sh
xcodebuild test -project Hermit.xcodeproj -scheme Hermit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= CODE_SIGNING_REQUIRED=YES
```

Choose an installed simulator in `-destination`. External integration tests
require their documented fixtures; the test output reports skipped cases.

## Repository layout

| Path | What lives there |
|---|---|
| `Hermit/` | App screens, SSH / Mosh / tmux / herdr services, network access, synchronization and voice input |
| `Extensions/` | `HermitIsland/` for widgets and Live Activities, `HermitPush/` for encrypted notifications, and `HermitShare/` for sharing images |
| `Packages/HermitKit/` | Shared app/extension library; its Swift module remains `MoshpitKit` for compatibility |
| `Tests/` | `HermitTests/` unit tests and `HermitUITests/` UI tests |
| `push-relay/` | Go relay between your host and APNs, with deployment files under `deploy/` |
| `docs/` | [Architecture](docs/ARCHITECTURE.md), [push protocol](docs/PUSH.md), [SwiftTerm changes](docs/PATCHES.md), and design/verification notes |
| `scripts/` | Host helpers, generators, verification fixtures, capture tools and release tooling |

The inherited default push relay belongs to upstream Moshpit. The
[push guide](docs/PUSH.md) explains the protocol and how to run your own relay.

## Upgrade compatibility

The Hermit name does not require a new installed-app identity. Existing bundle,
Keychain, App Group, cloud-record and host-protocol identifiers are retained to
keep upgrades compatible with saved hosts, keys, live activities and remote
helpers. The main app's Swift module remains `Moshpit`, and the shared module
remains `MoshpitKit`. Historical validation notes and artifacts retain the names
used when they were produced.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the XcodeGen workflow and conventions,
and [SECURITY.md](SECURITY.md) before reporting sensitive issues. Participants
follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## License and upstream

Hermit is derived from [Moshpit](https://github.com/Cluas/moshpit) and is released
under the [GNU General Public License v3.0](LICENSE) (GPL-3.0-only). Original
copyright and license notices are retained. Third-party components keep their
own licenses, listed in [NOTICES.md](NOTICES.md).
