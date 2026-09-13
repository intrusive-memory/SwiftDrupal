---
type: project
---

# Claude Code Instructions

See [AGENTS.md](AGENTS.md) for project context, the config schema, the full
command reference, and build/host/test instructions.

Build and test locally with XcodeBuildMCP's `swift_package_build` and
`swift_package_test` tools. Never run a plain `swift` `build` or `swift`
`test` command, and never run a raw `xcodebuild` build or test yourself —
`xcodebuild` invocations in this repo's docs are for CI or an agent without
XcodeBuildMCP, not for you to execute ad hoc.
