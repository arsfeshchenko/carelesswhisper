# Parrrot

macOS menu bar push-to-talk transcription app.

## Project

- **Repo**: `~/Documents/GitHub/papuga`
- **App**: `/Applications/parrrot.app`
- **Bundle ID**: `com.arsfeshchenko.parrrot`
- **Xcode project**: `Parrrot.xcodeproj`

## Build & Run

```bash
cd ~/Documents/GitHub/papuga
xcodebuild -project Parrrot.xcodeproj -scheme parrrot -configuration Debug build
rm -rf /Applications/parrrot.app
cp -R ~/Library/Developer/Xcode/DerivedData/Parrrot-*/Build/Products/Debug/parrrot.app /Applications/parrrot.app
pkill -9 -f parrrot; open /Applications/parrrot.app
```

## Code Signing

Signed with local self-signed cert **"Papuga Dev"** (in Keychain Access).
This keeps Accessibility permissions stable across rebuilds.
The post-build script runs `codesign --force --deep --sign "Papuga Dev"` automatically.

## Permissions Required

- **Accessibility** — required for CGEventTap (hotkey detection) and posting key events
- **Microphone** — required for audio recording
- Input Monitoring is NOT required (Swift uses CGEventTap, not pynput)

## Auto-Submit (Enter after paste)

- Toggled in menu: **Auto-submit (Enter)**
- Sends Enter 0.4s after paste via `CGEvent` with `nil` source and zero flags
- The nil source is critical — prevents Option key residue from being inherited
- If Enter adds a newline instead of submitting, increase the delay in `Paster.swift`

## Behavior

- After **every** code change, always rebuild and restart the app automatically using `build.sh` — do not wait to be asked

## Known Behaviors

- Every rebuild with a new signing identity requires re-adding to Accessibility
- With "Papuga Dev" cert, the identity is stable — no re-grant needed per rebuild
- API key is stored in Keychain under service `com.arsfeshchenko.parrrot`, account `apiKey`
