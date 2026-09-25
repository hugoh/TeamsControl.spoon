# TeamsControl Spoon

[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Hammerspoon Spoon](https://img.shields.io/badge/Hammerspoon-Spoon-FFA500.svg)](https://www.hammerspoon.org/docs/index.html)

A Hammerspoon Spoon that toggles the Microsoft Teams meeting microphone from any app, tells you whether it worked, and shows your mute state in the menu bar.

**Repository**: [https://github.com/hugoh/TeamsControl.spoon](https://github.com/hugoh/TeamsControl.spoon)

## Features

- **Toggle mute from any app** with one hotkey, without Teams stealing focus
- **Verified toggles**: checks Teams actually changed state, and retries by clicking the mute button if needed
- **On-screen alert** with the result: `🔶 Teams Muted` / `🎤 Teams Unmuted`, or a `🛑` alert explaining what went wrong
- **Menu bar indicator** during calls: a mic when unmuted, a slashed mic when muted, hidden otherwise. It follows mute changes made in Teams, and clicking it toggles mute

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

Bind a hotkey and start the menu bar indicator:

```lua
hs.loadSpoon("TeamsControl")
  :bindHotkeys({ toggleMute = { { "ctrl", "alt", "cmd" }, "m" } })
  :start()
```

`stop()` removes the indicator and unbinds the hotkeys.

Or call `toggleMute()` yourself from your own hotkey wiring:

```lua
local teamsControl = hs.loadSpoon("TeamsControl")
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "m", function() teamsControl:toggleMute() end)
```

`toggleMute()` accepts an optional callback, invoked once the toggle has settled
(or the call was ignored as re-entrant), for driving a busy indicator.

Tune behaviour with `configure()` (all optional):

```lua
hs.loadSpoon("TeamsControl"):configure({
  teamsBundleID = "com.microsoft.teams2",  -- Teams app bundle identifier
  activationTimeout = 5,                    -- seconds to wait for Teams to come forward when retrying
  clickSettleDelay = 0.05,                  -- seconds between checks that the toggle registered
  clickSettleMaxRetries = 10,               -- checks before retrying, then before giving up
  showMenubar = true,                       -- show the menu bar indicator
  menubarPollInterval = 1,                  -- seconds between menu bar indicator refreshes
}):start()
```

## Security & Permissions

TeamsControl reads Teams' accessibility tree and sends synthetic keystrokes and clicks, so Hammerspoon needs **Accessibility** permission (System Settings → Privacy & Security → Accessibility). It never launches anything but Teams and never shells out.

## Credits

The accessibility-tree mute-button lookup (`findButton` in `init.lua`) is adapted from `_teamsFindButtonByLabel` in [RobvH/teams-mac-hotkeys](https://github.com/RobvH/teams-mac-hotkeys).

## API documentation

Full [API reference](https://teamscontrol-spoon.larve.net/) is generated from the docstrings in `init.lua` (`mise run docs`).
