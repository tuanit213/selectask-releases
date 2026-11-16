# SelectAsk for Windows

Select text in a Windows desktop application to show an answer in a compact translucent overlay. This repository distributes Windows x64 and ARM64 builds with the .NET runtime included.

## Install using CMD

Open Command Prompt and paste this single line:

```cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';irm 'https://github.com/tuanit213/selectask-releases/releases/latest/download/install.ps1'|iex"
```

The command downloads the release, verifies its pinned SHA256, installs per-user, creates Desktop/Start Menu shortcuts, opens SelectAsk and removes temporary download files. No manual ZIP download, .NET SDK, Git, Python or administrator privileges are required on the receiving computer.

On a new computer, the app opens in Demo mode if no saved API key exists. Open Settings, choose your provider, enter your own API key and model, turn off Demo and apply. Live AI needs an Internet connection and API access. Keys stay in Windows Credential Manager on that user's computer. No API keys are included in this release.

Reinstalling preserves settings and saved keys. Ctrl + comma (or Ctrl + Shift + comma) toggles selection monitoring. A green/red dot briefly indicates enabled/disabled. The app does not add Windows login autorun.

## Release

Version 1.0.0. The bootstrap pins the ZIP at the corresponding version tag and verifies SHA256 before running its installer. Checksums detect file changes; this is not a publisher digital signature.

The Windows x64 build has been exercised on the publisher's Windows computer. ARM64 has been built and its executable architecture checked, but has not been run on ARM64 hardware. Windows desktop only; no macOS/Linux/32-bit build is included.

If you prefer to inspect the complete command with a pinned ZIP hash before executing, use FULL-CMD.txt in this release. Source code and personal settings are not distributed in this repository.