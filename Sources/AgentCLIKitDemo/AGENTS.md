## Demo App

- Keep the demo as an AppKit/SwiftUI executable target that depends on AgentCLIKit.
- Mirror BlockInputKit's app shell conventions for menus, titlebar behavior, and launch script behavior.
- Keep chat transcript state in memory; persisted session records should come from AgentCLIKit stores.
- Keep live Claude-specific behavior behind AgentCLIKit APIs instead of adding host-only hook transport code here.
