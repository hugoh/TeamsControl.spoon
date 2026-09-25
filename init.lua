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
--- The accessibility-tree button lookup (`findButton` below) is adapted from
--- `_teamsFindButtonByLabel` in
--- [RobvH/teams-mac-hotkeys](https://github.com/RobvH/teams-mac-hotkeys).
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
--- Seconds between accessibility re-checks after sending the mute keystroke (default: 0.15).
obj.clickSettleDelay = 0.15

--- TeamsControl.clickSettleMaxRetries
--- Variable
--- How many times to re-check the button label -- after the keystroke, and again after the
--- click fallback -- before declaring the toggle failed (default: 3).
obj.clickSettleMaxRetries = 3

--- TeamsControl.showMenubar
--- Variable
--- Show a menu bar indicator during Teams calls: the macOS mic glyph when
--- unmuted, the slashed mic when muted, nothing otherwise. Clicking it toggles
--- mute (default: true).
obj.showMenubar = true

--- TeamsControl.menubarPollInterval
--- Variable
--- Seconds between menu bar indicator refreshes (default: 1).
obj.menubarPollInterval = 1

obj.log = hs.logger.new("TeamsControl", "info")

obj._muteToggleInProgress = false
obj._hotkeys = nil
obj._muteButton = nil
obj._muteButtonWindows = nil
-- Hammerspoon garbage-collects a running hs.timer that nothing references, so
-- an in-flight toggle's timers are kept here.
obj._deadman = nil
obj._stepTimer = nil
obj._activationWatcher = nil
obj._activationTimer = nil
obj._started = false
obj._menubar = nil
obj._menubarTimer = nil
obj._nextMenubarWalk = 0

local MUTE_LABEL_PATTERN = "ute mic$"

-- Long enough for the progress alert to paint before the AX lookup blocks
-- Hammerspoon's main thread.
local ALERT_PAINT_DELAY = 0.04

-- The mic can be open with no mute button to find (Teams' pre-join screen,
-- another app's call), so a walk that found nothing isn't retried every tick.
local MENUBAR_MISSED_WALK_BACKOFF = 5

-- Depth-first search of an accessibility subtree for the first AXButton whose
-- description/title matches `pattern`. Teams' meeting-control buttons sit
-- roughly 20 levels deep in its WebView2 accessibility tree.
-- Adapted from `_teamsFindButtonByLabel` in
-- https://github.com/RobvH/teams-mac-hotkeys
local function findButton(element, pattern, depth)
	depth = depth or 0
	if depth > 25 then return nil end

	local role = element.AXRole
	local label = element.AXDescription or element.AXTitle or ""
	if role == "AXButton" and type(label) == "string" and label:match(pattern) then return element end

	local children = element.AXChildren
	if children then
		for _, child in ipairs(children) do
			local found = findButton(child, pattern, depth + 1)
			if found then return found end
		end
	end
	return nil
end

-- The mute button ("Mute mic" / "Unmute mic") exists only while a call is
-- active, so its presence doubles as the "in a call" check. Teams' main
-- meeting window stops updating while Teams is in the background, but the
-- floating compact view (a non-standard window) stays live, so it's searched
-- first.
local function findMuteButton(teamsApp)
	local windows = teamsApp:allWindows()
	for _, standard in ipairs({ false, true }) do
		for _, win in ipairs(windows) do
			if win:isStandard() == standard then
				local btn = findButton(hs.axuielement.windowElement(win), MUTE_LABEL_PATTERN)
				if btn then return btn end
			end
		end
	end
	return nil
end

-- Changes when the compact view opens or closes, which can make a cached
-- button that still reads a valid label the frozen one.
local function windowSetKey(teamsApp)
	local ids = {}
	for _, win in ipairs(teamsApp:allWindows()) do
		table.insert(ids, tostring(win:id()))
	end
	table.sort(ids)
	return table.concat(ids, ",")
end

-- A ref that went stale reads a nil label.
local function muteLabelOf(button)
	local label = button and (button.AXDescription or button.AXTitle)
	if type(label) == "string" and label:match(MUTE_LABEL_PATTERN) then return label end
	return nil
end

local function walkForMuteButton(self, teamsApp, windows)
	self._muteButton = findMuteButton(teamsApp)
	self._muteButtonWindows = windows
	return self._muteButton
end

-- Walking Teams' AX tree blocks Hammerspoon for ~0.5-1s, so the button found
-- by one toggle is reused by the next.
local function findMuteButtonCached(self, teamsApp)
	local windows = windowSetKey(teamsApp)
	if windows == self._muteButtonWindows and muteLabelOf(self._muteButton) then return self._muteButton end
	return walkForMuteButton(self, teamsApp, windows)
end

-- Teams keeps the mic open while muted, so an open mic is a cheap "maybe in a
-- call" gate in front of the AX lookup. Any input counts: Teams may not use
-- the system default.
local function anyMicInUse()
	for _, device in ipairs(hs.audiodevice.allInputDevices()) do
		if device:inUse() then return true end
	end
	return false
end

--- TeamsControl:configure(opts)
--- Method
--- Sets one or more of TeamsControl's variables (`teamsBundleID`,
--- `activationTimeout`, `clickSettleDelay`, `clickSettleMaxRetries`,
--- `showMenubar`, `menubarPollInterval`) from a table. After `start()`, the
--- menu bar indicator is started or stopped to match.
---
--- Parameters:
---  * opts - a table with any of the variable names above as keys
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
		"menubarPollInterval",
	}) do
		if opts[key] ~= nil then self[key] = opts[key] end
	end
	if self._started and (opts.showMenubar ~= nil or opts.menubarPollInterval ~= nil) then
		if self.showMenubar then
			self:_startMenubar()
		else
			self:_stopMenubar()
		end
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

	local function after(delay, fn) self._stepTimer = hs.timer.doAfter(delay, fn) end

	local function stopWaitingForActivation()
		if self._activationWatcher then self._activationWatcher:stop() end
		if self._activationTimer then self._activationTimer:stop() end
		self._activationWatcher = nil
		self._activationTimer = nil
	end

	-- If any step below throws before finish() runs (AX traversal, keyStroke,
	-- an app that never activates), _muteToggleInProgress would stay true and
	-- every later hotkey press would silently early-return. This clears it.
	self._deadman = hs.timer.doAfter(self.activationTimeout + 3, function()
		if self._stepTimer then self._stepTimer:stop() end
		stopWaitingForActivation()
		self._muteToggleInProgress = false
		withdrawProgressIndicator()
		notifyDone()
	end)

	local function finish()
		self._deadman:stop()
		stopWaitingForActivation()
		self._muteToggleInProgress = false
		withdrawProgressIndicator()
		if activatedTeams and previousApp then previousApp:activate() end
		notifyDone()
	end

	-- Button label names the action it performs, not the current state:
	-- "Unmute mic" means the mic is muted right now (and vice versa).
	local function micState(buttonLabel) return buttonLabel:match("^Unmute") and "Muted" or "Unmuted" end

	local function showFailure(message)
		hs.alert.show(
			"🛑 " .. message,
			{ fillColor = { hue = 0, saturation = 1, brightness = 0.6, alpha = 0.9 } },
			nil,
			2
		)
	end

	local function showSuccess(buttonLabel)
		local state = micState(buttonLabel)
		local color = state == "Muted" and { hue = 0.15, saturation = 1, brightness = 0.8, alpha = 0.9 }
			or { hue = 0.33, saturation = 1, brightness = 0.6, alpha = 0.9 }
		local icon = state == "Muted" and "🔶" or "🎤"
		hs.alert.show(icon .. " Teams " .. state, { fillColor = color }, nil, 1)
	end

	local function showStillState(buttonLabel) showFailure("STILL " .. micState(buttonLabel):upper()) end

	if not teamsApp then
		finish()
		showFailure("No active Teams call")
		return self
	end

	-- A synthetic click lands on whatever is on screen, so unlike the
	-- keystroke it needs Teams in front.
	local function withTeamsFrontmost(fn)
		local front = hs.application.frontmostApplication()
		if front and front:bundleID() == self.teamsBundleID then return fn() end

		self._activationWatcher = hs.application.watcher.new(function(_, eventType, appObject)
			if eventType ~= hs.application.watcher.activated or appObject:bundleID() ~= self.teamsBundleID then
				return
			end
			stopWaitingForActivation()
			activatedTeams = true
			fn()
		end)
		self._activationWatcher:start()
		self._activationTimer = hs.timer.doAfter(self.activationTimeout, function()
			finish()
			showFailure("Teams did not activate in time")
		end)
		hs.application.launchOrFocusByBundleID(self.teamsBundleID)
	end

	local function sendMuteToggle()
		local btn = findMuteButtonCached(self, teamsApp)
		if not btn then
			finish()
			showFailure("No active Teams call")
			return
		end

		local beforeLabel = muteLabelOf(btn)
		hs.eventtap.keyStroke({ "cmd", "shift" }, "m", 0, teamsApp)

		-- Re-reading the cached button element avoids re-walking Teams' deep AX
		-- tree on every retry. If the toggle swapped the node out (the stale ref
		-- reads nil), fall back to a fresh lookup.
		local function resolveButton()
			if muteLabelOf(btn) then return btn end
			btn = findMuteButtonCached(self, teamsApp)
			return btn
		end

		local function currentLabel() return muteLabelOf(resolveButton()) end

		-- The keystroke can land on a focused text field (e.g. the Notes panel)
		-- instead of Teams' mute shortcut handler. AXPress on the button is a
		-- no-op on Teams' WebView2-rendered controls, so the fallback is a real
		-- synthetic mouse click at the button's on-screen position -- that's
		-- what actually reaches its click handler.
		local function clickButton()
			local resolved = resolveButton()
			local pos = resolved and resolved.AXPosition
			local size = resolved and resolved.AXSize
			if not (pos and size) then return end
			local savedMouse = hs.mouse.absolutePosition()
			hs.eventtap.leftClick({ x = pos.x + size.w / 2, y = pos.y + size.h / 2 })
			hs.mouse.absolutePosition(savedMouse)
		end

		-- Two phases, each with its own clickSettleMaxRetries budget: poll after the
		-- keystroke, and if that never registers, click the button and poll again.
		local function checkResult(phase, attempt)
			local afterLabel = currentLabel()

			if afterLabel and afterLabel ~= beforeLabel then
				finish()
				showSuccess(afterLabel)
			elseif attempt < self.clickSettleMaxRetries then
				after(self.clickSettleDelay, function() checkResult(phase, attempt + 1) end)
			elseif phase == "keystroke" then
				updateProgress("Retrying Teams mute toggle…")
				withTeamsFrontmost(function()
					clickButton()
					after(self.clickSettleDelay, function() checkResult("click", 1) end)
				end)
			else
				finish()
				if afterLabel then
					showStillState(afterLabel)
				else
					showFailure("Mute toggle did not register")
				end
			end
		end

		after(self.clickSettleDelay, function() checkResult("keystroke", 1) end)
	end

	after(ALERT_PAINT_DELAY, sendMuteToggle)
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

-- Only walks the AX tree when the cached button went stale mid-call, or at
-- most every MENUBAR_MISSED_WALK_BACKOFF seconds while no button is found.
-- Returns the mute button label, or nil plus why there isn't one.
function obj:_currentMuteLabel()
	local teams = hs.application.get(self.teamsBundleID)
	if not teams then return nil, "Teams not running" end
	if not anyMicInUse() then return nil, "no mic in use" end

	local windows = windowSetKey(teams)
	local unchanged = windows == self._muteButtonWindows
	local label = unchanged and muteLabelOf(self._muteButton)
	if label then return label end

	local now = hs.timer.secondsSinceEpoch()
	if unchanged and not self._muteButton and now < self._nextMenubarWalk then return nil, "no mute button found" end
	walkForMuteButton(self, teams, windows)
	self.log.df("Walked Teams AX tree for mute button: %s", self._muteButton and "found" or "not found")
	if not self._muteButton then self._nextMenubarWalk = now + MENUBAR_MISSED_WALK_BACKOFF end
	label = muteLabelOf(self._muteButton)
	return label, not label and "no mute button found" or nil
end

function obj:_refreshMenubar()
	local label, reason = self:_currentMuteLabel()
	local muted = label and label:match("^Unmute")
	local state = not label and ("hidden: " .. reason) or muted and "muted" or "unmuted"
	if state ~= self._menubarState then
		self.log.f("Menu bar indicator: %s", state)
		self._menubarState = state
	end
	if not label then
		if self._menubar then self._menubar:delete() end
		self._menubar = nil
		return
	end
	-- Created visible and named rather than hidden and re-shown: returnToMenuBar()
	-- drops the autosave name, so macOS would forget the item's position.
	if not self._menubar then
		self._menubar = hs.menubar.new(true, self.name)
		self._menubar:setClickCallback(function()
			self:toggleMute(function() self:_refreshMenubar() end)
		end)
	end
	self._menubar:setIcon(
		hs.image.imageFromName(muted and "NSTouchBarAudioInputMuteTemplate" or "NSTouchBarAudioInputTemplate"),
		true
	)
end

function obj:_startMenubar()
	self:_stopMenubar()
	-- hs.timer stops a repeating timer whose callback throws, and a Teams
	-- re-render mid-walk can make an AX read throw.
	self._menubarTimer = hs.timer.doEvery(self.menubarPollInterval, function()
		local ok, err = xpcall(function() self:_refreshMenubar() end, debug.traceback)
		if not ok then self.log.e("Menu bar refresh failed: " .. tostring(err)) end
	end)
	self:_refreshMenubar()
	return self
end

function obj:_stopMenubar()
	if self._menubarTimer then self._menubarTimer:stop() end
	if self._menubar then self._menubar:delete() end
	self._menubarTimer = nil
	self._menubar = nil
	self._menubarState = nil
	return self
end

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
--- Starts the menu bar indicator, if `showMenubar` is set.
---
--- Returns:
---  * The TeamsControl object, for method chaining
function obj:start()
	self._started = true
	if self.showMenubar then self:_startMenubar() end
	return self
end

--- TeamsControl:stop()
--- Method
--- Unbinds any hotkeys bound via `bindHotkeys` and stops the menu bar indicator.
---
--- Returns:
---  * The TeamsControl object, for method chaining
function obj:stop()
	if self._hotkeys then
		for _, hk in pairs(self._hotkeys) do
			hk:delete()
		end
		self._hotkeys = nil
	end
	self._started = false
	return self:_stopMenubar()
end

return obj
