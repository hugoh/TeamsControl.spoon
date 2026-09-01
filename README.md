# TeamsControl Spoon

[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Hammerspoon Spoon](https://img.shields.io/badge/Hammerspoon-Spoon-FFA500.svg)](https://www.hammerspoon.org/docs/index.html)

A Hammerspoon Spoon that toggles the Microsoft Teams meeting microphone from a single hotkey, from any app, and tells you whether it worked.

**Repository**: [https://github.com/hugoh/TeamsControl.spoon](https://github.com/hugoh/TeamsControl.spoon)

## Features

- One hotkey toggles mute from anywhere: if Teams isn't frontmost it's activated, the toggle is sent, then focus returns to the app you were in
- Sends `Cmd+Shift+M`, then confirms the toggle.
- On-screen alert for the result: `🔶 Teams Muted` / `🎤 Teams Unmuted` on success, or a `🛑` alert (`No active Teams call`, `Teams did not activate in time`, `Mute toggle did not register`, `STILL MUTED`/`STILL UNMUTED`) on failure

## Installation

Ensure you have [Hammerspoon](https://www.hammerspoon.org) installed, then choose a method:

### Release zip (recommended)

1. Download `TeamsControl.spoon.zip` from the [latest release](https://github.com/hugoh/TeamsControl.spoon/releases/latest)
2. Unzip — this produces a `TeamsControl.spoon` folder
3. Move it to `~/.hammerspoon/Spoons/`
4. Reload Hammerspoon (menu bar icon → Reload Config, or run `hs.reload()` in the console)

### SpoonInstall (if you already use it)

```lua
spoon.SpoonInstall:installSpoonFromZip(
  "https://github.com/hugoh/TeamsControl.spoon/releases/latest/download/TeamsControl.spoon.zip"
)
```

### Clone from git (for development or latest changes)

```bash
cd ~/.hammerspoon/Spoons
git clone https://github.com/hugoh/TeamsControl.spoon.git
```

## Configuration

Bind a hotkey:

```lua
hs.loadSpoon("TeamsControl"):bindHotkeys({
  toggleMute = { { "ctrl", "alt", "cmd" }, "m" },
})
```

Or call `toggleMute()` yourself from your own hotkey wiring:

```lua
local teamsControl = hs.loadSpoon("TeamsControl")
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "m", function() teamsControl:toggleMute() end)
```

Tune behaviour with `configure()` before binding (all optional):

```lua
hs.loadSpoon("TeamsControl"):configure({
  teamsBundleID = "com.microsoft.teams2",  -- Teams app bundle identifier
  activationTimeout = 5,                    -- seconds to wait for Teams to come to the front
  clickSettleDelay = 0.15,                  -- seconds between accessibility re-checks after the keystroke
  clickSettleMaxRetries = 5,               -- re-checks before declaring the toggle failed
}):bindHotkeys({ toggleMute = { { "ctrl", "alt", "cmd" }, "m" } })
```

## Security & Permissions

TeamsControl reads Teams' accessibility tree and sends a synthetic keystroke, so Hammerspoon needs **Accessibility** permission (System Settings → Privacy & Security → Accessibility). It never launches anything but Teams and never shells out.

## Credits

The accessibility-tree mute-button lookup (`findButton` in `init.lua`) is adapted from `_teamsFindButtonByLabel` in [RobvH/teams-mac-hotkeys](https://github.com/RobvH/teams-mac-hotkeys).

## API documentation

Full [API reference](https://teamscontrol-spoon.larve.net/) is generated from the docstrings in `init.lua` (`mise run docs`).
