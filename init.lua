-- vim: set ft=lua:

--- === TeamsControl ===
---
--- A Hammerspoon Spoon that toggles the Microsoft Teams meeting microphone
--- from a single hotkey, from any app.
---
--- It sends Cmd+Shift+M, then confirms the toggle actually registered by
--- reading Teams' "Mute mic"/"Unmute mic" accessibility button label before
--- and after -- a real success/failure signal instead of a timeout guess --
--- and shows the resulting state (or the failure) in an on-screen alert.
---
--- The accessibility-tree button lookup (`findButton` in `ui.lua`) is adapted from
--- `_teamsFindButtonByLabel` in
--- [RobvH/teams-mac-hotkeys](https://github.com/RobvH/teams-mac-hotkeys).
---
--- The Teams local API client (`api.lua`) follows the protocol handling of
--- [asp55/MSTeams.spoon2](https://github.com/asp55/MSTeams.spoon2) (MIT, (c) 2026 asp55).
---
--- Download: https://github.com/hugoh/TeamsControl.spoon/releases/latest

local obj = {}
obj.__index = obj

obj.name = "TeamsControl"
obj.version = "dev"
obj.author = "Hugo Haas"
obj.license = "MIT"
obj.homepage = "https://github.com/hugoh/TeamsControl.spoon"

--- TeamsControl.teamsBundleID
--- Variable
--- Bundle identifier of the Microsoft Teams app (default: "com.microsoft.teams2").
obj.teamsBundleID = "com.microsoft.teams2"

--- TeamsControl.activationTimeout
--- Variable
--- Seconds to wait for Teams to come to the front for the click fallback
--- before giving up (default: 5).
obj.activationTimeout = 5

--- TeamsControl.clickSettleDelay
--- Variable
--- Seconds between accessibility re-checks after sending the mute keystroke (default: 0.05).
obj.clickSettleDelay = 0.05

--- TeamsControl.clickSettleMaxRetries
--- Variable
--- How many times to re-check the button label -- after the keystroke, and again after the
--- click fallback -- before declaring the toggle failed (default: 10).
obj.clickSettleMaxRetries = 10

--- TeamsControl.showMenubar
--- Variable
--- Show a menu bar indicator during Teams calls: the macOS mic glyph when
--- unmuted, the slashed mic when muted, nothing otherwise. Clicking it toggles
--- mute (default: true).
obj.showMenubar = true

--- TeamsControl.menubarStatusDot
--- Variable
--- Show a 🟢 (unmuted) or 🟡 (muted) dot next to the menu bar icon (default: true).
obj.menubarStatusDot = true

--- TeamsControl.menubarPollInterval
--- Variable
--- Seconds between menu bar indicator refreshes (default: 1).
obj.menubarPollInterval = 1

--- TeamsControl.useApi
--- Variable
--- Use Teams' local third-party API (a websocket on localhost) when it is available: mute
--- toggles then need no keystroke or focus change. Falls back to the keystroke/click path
--- whenever the API is off, not paired, or doesn't answer (default: true).
obj.useApi = true

--- TeamsControl.apiPort
--- Variable
--- Port of Teams' local API (default: 8124).
obj.apiPort = 8124

--- TeamsControl.apiRetryInterval
--- Variable
--- Seconds between attempts to reach Teams' local API while it is unavailable (default: 30).
obj.apiRetryInterval = 30

--- TeamsControl.apiConfirmTimeout
--- Variable
--- Seconds to wait for Teams to confirm a mute toggle sent through its API before falling back to
--- the keystroke (default: 0.5).
obj.apiConfirmTimeout = 0.5

--- TeamsControl.apiMaxRetries
--- Variable
--- How many times to retry reaching Teams' local API for one running instance of Teams before
--- giving up until Teams restarts. A successful connection resets the count (default: 3).
obj.apiMaxRetries = 3

obj.log = hs.logger.new("TeamsControl", "info")

obj._muteToggleInProgress = false

dofile(hs.spoons.resourcePath("ui.lua"))(obj)

--- TeamsControl:configure(opts)
--- Method
--- Sets one or more of TeamsControl's variables from a table. Call it before `start()`.
---
--- Parameters:
---  * opts - a table with any of the variable names documented on this page as keys
---
--- Returns:
---  * The TeamsControl object, for method chaining
function obj:configure(opts)
	for _, key in ipairs({
		"teamsBundleID",
		"activationTimeout",
		"clickSettleDelay",
		"clickSettleMaxRetries",
		"showMenubar",
		"menubarStatusDot",
		"menubarPollInterval",
		"useApi",
		"apiPort",
		"apiRetryInterval",
		"apiMaxRetries",
		"apiConfirmTimeout",
	}) do
		if opts[key] ~= nil then self[key] = opts[key] end
	end
	return self
end

--- TeamsControl:toggleMute()
--- Method
--- Toggles the Teams meeting microphone by sending Cmd+Shift+M to Teams
--- without bringing it forward. If that doesn't register, Teams is activated,
--- its mute button clicked, and focus returned to the app you were in.
--- Re-entrant calls while a toggle is already in flight are ignored.
---
--- Parameters:
---  * done - an optional function called once when the toggle has settled (or
---    the call was ignored), so callers can drive a busy indicator
---
--- Returns:
---  * The TeamsControl object, for method chaining
function obj:toggleMute(done)
	local function notifyDone()
		local callback = done
		done = nil
		if callback then callback() end
	end

	if self._muteToggleInProgress then
		self.log.d("Mute toggle already in progress; ignoring")
		notifyDone()
		return self
	end
	self._muteToggleInProgress = true

	local teamsApp = hs.application.get(self.teamsBundleID)
	local previousApp = hs.application.frontmostApplication()
	local activatedTeams = false

	local progressIndicator

	local function withdrawProgressIndicator()
		if progressIndicator then
			hs.alert.closeSpecific(progressIndicator)
			progressIndicator = nil
		end
	end

	-- Long fixed duration so the alert reads as "still working" rather than
	-- ticking down; withdrawProgressIndicator() closes it as soon as we're done.
	local function updateProgress(text)
		withdrawProgressIndicator()
		progressIndicator = hs.alert.show(text, self.activationTimeout + 3)
	end

	updateProgress("Toggling Teams mute…")

	local function finish()
		self._abortToggle = nil
		self._deadman:stop()
		self:_apiCancelToggle()
		self:_uiCancel()
		self._muteToggleInProgress = false
		withdrawProgressIndicator()
		if activatedTeams and previousApp then previousApp:activate() end
		self:_refreshMenubar()
		notifyDone()
	end

	local function showFailure(message)
		hs.alert.show(
			"🛑 " .. message,
			{ fillColor = { hue = 0, saturation = 1, brightness = 0.6, alpha = 0.9 } },
			nil,
			2
		)
	end

	local function showSuccess(muted)
		local state = muted and "Muted" or "Unmuted"
		local color = state == "Muted" and { hue = 0.15, saturation = 1, brightness = 0.8, alpha = 0.9 }
			or { hue = 0.33, saturation = 1, brightness = 0.6, alpha = 0.9 }
		local icon = state == "Muted" and "🔶" or "🎤"
		hs.alert.show(icon .. " Teams " .. state, { fillColor = color }, nil, 1)
	end

	-- If any step below throws before finish() runs (AX traversal, keyStroke,
	-- an app that never activates), _muteToggleInProgress would stay true and
	-- every later hotkey press would silently early-return. This clears it.
	self._deadman = hs.timer.doAfter(self.activationTimeout + 3, function()
		finish()
		showFailure("Mute toggle timed out")
	end)

	self._abortToggle = finish

	local function viaUi()
		self:_uiToggle(teamsApp, {
			progress = updateProgress,
			activated = function() activatedTeams = true end,
			done = function(muted)
				finish()
				showSuccess(muted)
			end,
			still = function(muted)
				finish()
				showFailure("STILL " .. (muted and "MUTED" or "UNMUTED"))
			end,
			fail = function(message)
				finish()
				showFailure(message)
			end,
		})
	end

	local useApi = self:_apiCanToggleMute()
	self.log.f("Toggling mute via %s", useApi and "Teams API" or "keystroke")
	if useApi then
		self:_apiToggleMute(function(muted)
			finish()
			showSuccess(muted)
		end, viaUi)
	else
		viaUi()
	end
	return self
end

--- TeamsControl:bindHotkeys(mapping)
--- Method
--- Binds hotkeys for TeamsControl.
---
--- Parameters:
---  * mapping - a table with a `toggleMute` key mapped to a `{ {modifiers}, key }` spec
---
--- Returns:
---  * The TeamsControl object, for method chaining
function obj:bindHotkeys(mapping)
	local actions = { toggleMute = function() self:toggleMute() end }
	self._hotkeys = self._hotkeys or {}
	for name, spec in pairs(mapping) do
		if actions[name] then
			if self._hotkeys[name] then self._hotkeys[name]:delete() end
			self._hotkeys[name] = hs.hotkey.bind(spec[1], spec[2], actions[name])
		else
			self.log.wf("Unknown hotkey action %q", tostring(name))
		end
	end
	return self
end

-- The API's pushed state wins; otherwise the accessibility tree is read.
-- Returns whether the mic is muted, or nil plus why that isn't known.
function obj:_currentMuted()
	local teams = hs.application.get(self.teamsBundleID)
	if not teams then return nil, "Teams not running" end
	local apiMuted, apiReason = self:_apiMuted()
	if apiMuted ~= nil or apiReason then return apiMuted, apiReason end
	return self:_uiMuted(teams)
end

-- Polling and API connections only make sense while Teams runs, so launch and quit events
-- drive them. A lookup that throws counts as running, leaving the refresh to log the failure.
function obj:_startWatching()
	self:_stopWatching()
	self._appWatcher = hs.application.watcher.new(function(_, event, app)
		if not app or app:bundleID() ~= self.teamsBundleID then return end
		if event == hs.application.watcher.launched then
			self:_teamsStarted()
		elseif event == hs.application.watcher.terminated then
			self:_teamsStopped()
		end
	end)
	self._appWatcher:start()
	local ok, teams = pcall(hs.application.get, self.teamsBundleID)
	if not ok or teams then self:_teamsStarted() end
	return self
end

function obj:_stopWatching()
	self:_teamsStopped()
	if self._appWatcher then self._appWatcher:stop() end
	self._appWatcher = nil
	return self
end

function obj:_teamsStarted()
	if not self._teamsRunning then self.log.i("Teams detected running") end
	self._teamsRunning = true
	if self.showMenubar then self:_startPoll() end
	if self.useApi then self:_startApi() end
end

function obj:_teamsStopped()
	if self._teamsRunning then self.log.i("Teams no longer running") end
	self._teamsRunning = false
	self:_stopPoll()
	self:_stopApi()
end

dofile(hs.spoons.resourcePath("api.lua"))(obj)
dofile(hs.spoons.resourcePath("menubar.lua"))(obj)

--- TeamsControl:init()
--- Method
--- Called automatically by `hs.loadSpoon()`. Logs the loaded version.
---
--- Returns:
---  * The TeamsControl object, for method chaining
function obj:init()
	-- Hammerspoon loads extensions on first access, which would otherwise add to
	-- the first toggle's latency.
	local _ = hs.alert and hs.axuielement and hs.eventtap
	self.log.f("Loaded %s v%s", self.name, self.version)
	return self
end

--- TeamsControl:start()
--- Method
--- Watches for Teams running. While it does, starts the menu bar indicator, if `showMenubar` is
--- set, and connects to Teams' local API, if `useApi` is set.
---
--- Returns:
---  * The TeamsControl object, for method chaining
function obj:start() return self:_startWatching() end

--- TeamsControl:stop()
--- Method
--- Unbinds any hotkeys bound via `bindHotkeys`, stops the menu bar indicator and disconnects from the Teams API.
---
--- Returns:
---  * The TeamsControl object, for method chaining
function obj:stop()
	if self._abortToggle then self._abortToggle() end
	if self._hotkeys then
		for _, hk in pairs(self._hotkeys) do
			hk:delete()
		end
		self._hotkeys = nil
	end
	return self:_stopWatching()
end

return obj
