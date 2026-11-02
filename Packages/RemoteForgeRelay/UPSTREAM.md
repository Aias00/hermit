# RemoteForge Relay SDK snapshot

Source: https://github.com/Aias00/remoteforge-relay
Commit: 51601b45ebd608d531a759f2fb8096fd606335a3
Directory: sdk/swift/Sources
License: MIT (included).

Production sources are copied without modifications. The local package omits
upstream test targets and fixtures. SDK and real SSH protocol tests live in the
upstream repository; Hermit tests cover app integration. This snapshot keeps
Hermit builds self-contained without requiring checkout of a private sibling
repository. Update all production sources and this commit together.
