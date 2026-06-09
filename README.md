![Sidekick — hotkey-summoned, edge-anchored notes panel for macOS](docs/banner.png)

# Sidekick

A hotkey-summoned, edge-anchored notes panel for macOS. Tap a global shortcut, a translucent panel slides in from the side of the screen, you write, you dismiss it. Notes persist as plain `.md` files in a folder you control. Built as a replacement for SideNotes when I wanted the speed of a hotkey-summoned scratch surface without giving up file ownership.

![Sidekick edge panel summoned with the formatting toolbar and a sample note](docs/sidekick.png)

## Features

- Global hotkey to summon and dismiss
- Edge-anchored translucent panel that stays out of the way
- Hybrid markdown editor: live formatting (bold, italic, inline code, links, lists) over plain `.md` text
- Notes saved as individual `.md` files in a folder you choose
- Lightweight sidebar for note switching
- Native macOS, no Electron, no web view

## Built with

- Swift, SwiftUI + AppKit hybrid (`NSTextView`-backed editor for live formatting, SwiftUI for everything else)
- Tested on macOS 14+

## Build and run

Requires Xcode 15+ / Swift 5.9+.

```
./build-and-run.sh
```

Builds a release `.app` to `/Applications/Sidekick.app` and launches it.

## License

MIT. See [LICENSE](LICENSE).
