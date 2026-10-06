# AudioBunny

A macOS app for managing Audio Units and VST plugins.

## Features

- **Discover** all Audio Units (via `AVAudioUnitComponentManager`), VST2, and VST3 plugins installed on the system
- **Filter** by plugin type and status; search by name/manufacturer
- **Test** plugins one-by-one or all at once:
  - Audio Units: instantiated via `AVAudioUnit.instantiate`
  - VST2/VST3: bundle loaded and entry-point symbol verified (`VSTPluginMain` / `GetPluginFactory`)
- **Disable** plugins by moving them to `~/Library/Audio/Plug-Ins/Disabled/`
- **Re-enable** disabled plugins, restoring them to their original folder
- **Sync app settings** across Macs: moves an app's settings folder (Ableton User Library, Logic's Audio Music Apps, Bitwig, REAPER, or any folder/file you add) into iCloud Drive or Dropbox under `AudioBunny/App Settings/`, and leaves a symlink at the original location. Preference plists and sandboxed app containers are refused, since macOS replaces symlinks there.

## Plugin scan locations

| Type   | Paths scanned |
|--------|---------------|
| AU     | `/Library/Audio/Plug-Ins/Components`, `~/Library/Audio/Plug-Ins/Components` |
| VST2   | `/Library/Audio/Plug-Ins/VST`, `~/Library/Audio/Plug-Ins/VST` |
| VST3   | `/Library/Audio/Plug-Ins/VST3`, `~/Library/Audio/Plug-Ins/VST3` |

Disabled plugins live in `~/Library/Audio/Plug-Ins/Disabled/`.

## Building

### Open in Xcode (recommended)

```
open Package.swift
```

Then build with ⌘B and run with ⌘R.

### Command line

```bash
swift build -c release
.build/release/AudioBunny
```

## Requirements

- macOS 13+
- Xcode 15+ / Swift 5.9+

## Notes

- Moving plugins requires file-system permissions. If sandboxed, grant access when prompted.
- Disabling a plugin moves the `.component`/`.vst`/`.vst3` bundle; the system plugin cache may need a restart to fully reflect the change.
- The app does **not** sandbox itself by default so it can freely access plugin folders.
