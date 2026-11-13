# Better Passwords (extension for Apple Passwords)

[![CI](https://github.com/fanckush/better-passwords-extension/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/fanckush/better-passwords-extension/actions/workflows/ci.yml)
[![Coverage](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Ffanckush%2Fbetter-passwords-extension%2Fbadges%2Fcoverage.json)](https://github.com/fanckush/better-passwords-extension/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/fanckush/better-passwords-extension?filter=extension-v*&label=release)](https://github.com/fanckush/better-passwords-extension/releases/latest)
[![License: MIT](https://img.shields.io/github/license/fanckush/better-passwords-extension)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-informational)](#setup)
[![Windows 10+](https://img.shields.io/badge/Windows-10%2B-informational)](#on-windows)

**An alternative to Apple's iCloud Passwords extension for Chromium and firefox based browsers**

## Why

I am honestly sick of seeing this all the time

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/apple-autofill-prompt-dark.png">
  <img src="docs/images/apple-autofill-prompt-light.png" width="340" alt="Apple's extension asking again: Enable Password AutoFill. Click here to allow iCloud Passwords to AutoFill your passwords.">
</picture>

also, Apple's extension **doesn't** suggest passwords when signing up!

## Demo

Visit [betterpasswords.app](https://betterpasswords.app) for an interactive dummy form

[Chrome Web Store][chrome-web-store] · [Firefox Add-ons][firefox-addons] · [Website](https://betterpasswords.app) · [Setup](#setup)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/screenshot-dark.png">
  <img src="docs/images/screenshot-light.png" width="856" alt="Better Passwords suggesting saved Apple Passwords logins under a sign-in field, with its toolbar popup open">
</picture>

## Features

- ✏️ login suggestions
- 🔐 password generatino on sign-ups
- ⏱️ fill OTP codes
- ✨ NO MORE 6 DIGIT CODES!! *
- 💾 asks to save/update new logins you type (obviously)
- ☁️ generate Hide My Email in email fields (needs iCloud+)
- 👤 suggest your email addresses from your contact card *

\* Needs [companion Mac app](docs/companion.md)

## Installation

- **Chrome, Arc, Brave, Edge, Vivaldi and other Chromium browsers:** [Chrome Web Store][chrome-web-store]
- **Firefox and Zen:** [Firefox Add-ons][firefox-addons]

Or manually download `better-passwords-<version>-chrome.zip` from the [latest release](https://github.com/fanckush/better-passwords-extension/releases/latest), unzip it, open `chrome://extensions`, turn on **Developer mode** and choose **Load unpacked**. Manual installs don't support auto updates (similar steps for FF)

### Connect to apple passwords

[Download the optional companion Mac app](https://betterpasswords.app/companion) ([how it works](docs/companion.md)), move it to Applications, open **Better Passwords.app**, and choose **Connect**. It also enables Touch ID and contact email suggestions after you allow the required permissions.

Or run the setup script without the companion app:

```sh
curl -fsSL https://github.com/fanckush/better-passwords-extension/raw/main/scripts/setup-mac.sh | sh
```

The script lets the extension reach Apple's built-in password helper. You can find it [here](scripts/setup-mac.sh). To undo use it with `--uninstall`.

The setup connects Chrome, Brave, Edge, Vivaldi, Arc, Dia, Helium, Crest, Ardia, Yab, Search, Chromium, Firefox and Zen. Ardia and Yab can't use Apple Passwords yet: macOS stops them from starting Apple's helper. They'll work as soon as that changes. Using another browser? [Ask for it](https://github.com/fanckush/better-passwords-extension/issues/new?template=browser.yml).

### On Windows

#### Chrome with automatic pairing

The Windows pairing build reads the six-digit code from Apple's dialog and submits it through Chrome's native messaging when the extension needs to verify. Pairing happens in the background without a Windows Hello prompt. You can also enter the code manually if automatic pairing fails.

1. Install iCloud for Windows, sign in and turn on Passwords.
2. Build this fork from its root with [Bun](https://bun.sh/).

   ```powershell
   bun install --frozen-lockfile --ignore-scripts
   $env:WXT_WINDOWS_PAIRING_FORK = '1'
   bun run --filter @app/extension build:chrome
   Remove-Item Env:WXT_WINDOWS_PAIRING_FORK
   ```

3. Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup-windows-pairing.ps1` once from the fork folder to register the companion. Keep `scripts` and `apps/companion-windows` together so Chrome can find the companion.
4. Open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked**, and select `apps/extension/.output/chrome-mv3-windows-pairing`.
5. **Better Passwords - Windows pairing** verifies automatically after you load it. If the companion cannot read the dialog, open the extension popup to enter the code manually. Automatic reading currently expects Apple's English dialog.

Open Chrome from your usual shortcut. Chrome starts the companion when needed, and the companion exits after returning the pairing result. To remove the fork, remove it from Chrome and run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup-windows-pairing.ps1 -Uninstall`. The fork has its own Chrome extension ID and native host registrations, so it can coexist with the store version.

#### Manual pairing with the standard build

Install [iCloud for Windows](https://apps.microsoft.com/detail/9PKTQ5699M62) from the Microsoft Store, sign in and turn on Passwords. Then run this in PowerShell:

```powershell
irm https://github.com/fanckush/better-passwords-extension/raw/main/scripts/setup-windows.ps1 | iex
```

The script lets the extension reach the password helper that comes with iCloud for Windows. You can find it [here](scripts/setup-windows.ps1). To undo, download it and run `powershell -ExecutionPolicy Bypass -File setup-windows.ps1 -Uninstall`. It connects Chrome, Edge, Brave, Chromium and Firefox; other Chromium browsers usually read Chrome's setup. The companion app is Mac only, so on Windows you type the 6-digit code once per browser session. Apple's Windows helper doesn't ask for anything before filling, so Better Passwords locks when your PC locks (you can turn that off in the popup). Firefox doesn't tell extensions when the PC locks, so there it stays unlocked until you click Lock or quit Firefox.

## Contributing

Contributions are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers setup (Bun), tests, and how to try changes against the real helper. Please report security issues privately, as described in [SECURITY.md](SECURITY.md).

## Credits

Thanks to the authors of the following projects for inspiring me to build this:

- [Open Passwords](https://github.com/ManiForoughi2/open-passwords) fills from Apple Passwords in Chrome and Edge. It showed that keeping the connection to Apple's helper open means far fewer six-digit codes.
- [iCloud Hide My Email](https://github.com/dedoussis/icloud-hide-my-email-browser-extension) by Dimitrios Dedoussis showed how to use Hide My Email from a browser.

## License

[MIT](LICENSE). The protocol knowledge builds on earlier Apache-2.0 projects, credited in [NOTICE](NOTICE).

<!-- Store listings: apps/site/assets/browser.js links the same pages. -->

[chrome-web-store]: https://chromewebstore.google.com/detail/better-passwords/ocongmkplhijgajnipnhhggfcjfdilgj
[firefox-addons]: https://addons.mozilla.org/firefox/addon/better-passwords/

> Not affiliated with or endorsed by Apple Inc. "Apple" and "iCloud" are trademarks of Apple Inc.
