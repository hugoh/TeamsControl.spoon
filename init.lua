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
--- Seconds to wait for Teams to come to the front before giving up (default: 5).
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

obj.log = hs.logger.new("TeamsControl", "info")

obj._muteToggleInProgress = false
obj._hotkeys = nil
obj._muteButton = nil

local MUTE_LABEL_PATTERN = "ute mic$"

-- Long enough for the progress alert to paint before the AX lookup blocks
-- Hammerspoon's main thread.
local ALERT_PAINT_DELAY = 0.04

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
-- active, so its presence doubles as the "in a call" check.
local function findMuteButton(teamsApp)
	for _, win in ipairs(teamsApp:allWindows()) do
		local btn = findButton(hs.axuielement.windowElement(win), MUTE_LABEL_PATTERN)
		if btn then return btn end
	end
	return nil
end

-- Walking Teams' AX tree blocks Hammerspoon for ~0.5-1s, so the button found
-- by one toggle is reused by the next. A ref that went stale reads a nil label.
local function findMuteButtonCached(self, teamsApp)
	local remembered = self._muteButton
	local label = remembered and (remembered.AXDescription or remembered.AXTitle)
	if type(label) == "string" and label:match(MUTE_LABEL_PATTERN) then return remembered end
	self._muteButton = findMuteButton(teamsApp)
	return self._muteButton
end

--- TeamsControl:configure(opts)
--- Method
--- Sets one or more of TeamsControl's variables (`teamsBundleID`,
--- `activationTimeout`, `clickSettleDelay`, `clickSettleMaxRetries`) from a table.
---
--- Parameters:
---  * opts - a table with any of the variable names above as keys
---
--- Returns:
---  * The TeamsControl object, for method chaining
function obj:configure(opts)
	for _, key in ipairs({ "teamsBundleID", "activationTimeout", "clickSettleDelay", "clickSettleMaxRetries" }) do
		if opts[key] ~= nil then self[key] = opts[key] end
	end
	return self
end

--- TeamsControl:toggleMute()
--- Method
--- Toggles the Teams meeting microphone. If Teams is not frontmost it is
--- activated first, the toggle is sent, then focus is returned to the app you
--- were in. Re-entrant calls while a toggle is already in flight are ignored.
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

	local currentApp = hs.application.frontmostApplication()
	local isTeams = currentApp and currentApp:bundleID() == self.teamsBundleID

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

	updateProgress(isTeams and "Toggling Teams mute…" or "Activating Teams…")

	-- If any step below throws before finish() runs (AX traversal, keyStroke,
	-- an app that never activates), _muteToggleInProgress would stay true and
	-- every later hotkey press would silently early-return. This clears it.
	local deadmanReset = hs.timer.doAfter(self.activationTimeout + 3, function()
		self._muteToggleInProgress = false
		withdrawProgressIndicator()
		notifyDone()
	end)

	local function finish(previousApp)
		deadmanReset:stop()
		self._muteToggleInProgress = false
		withdrawProgressIndicator()
		if previousApp then previousApp:activate() end
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

	local function sendMuteToggle(teamsApp, previousApp)
		local btn = findMuteButtonCached(self, teamsApp)
		if not btn then
			finish(previousApp)
			showFailure("No active Teams call")
			return
		end

		local beforeLabel = btn.AXDescription or btn.AXTitle
		hs.eventtap.keyStroke({ "cmd", "shift" }, "m", 0, teamsApp)

		-- Re-reading the cached button element avoids re-walking Teams' deep AX
		-- tree on every retry. If the toggle swapped the node out (the stale ref
		-- reads nil), fall back to a fresh lookup.
		local function resolveButton()
			if btn.AXDescription or btn.AXTitle then return btn end
			self._muteButton = findMuteButton(teamsApp)
			return self._muteButton
		end

		local function currentLabel()
			local resolved = resolveButton()
			return resolved and (resolved.AXDescription or resolved.AXTitle)
		end

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
				finish(previousApp)
				showSuccess(afterLabel)
			elseif attempt < self.clickSettleMaxRetries then
				hs.timer.doAfter(self.clickSettleDelay, function() checkResult(phase, attempt + 1) end)
			elseif phase == "keystroke" then
				clickButton()
				updateProgress("Retrying Teams mute toggle…")
				hs.timer.doAfter(self.clickSettleDelay, function() checkResult("click", 1) end)
			else
				finish(previousApp)
				if afterLabel then
					showStillState(afterLabel)
				else
					showFailure("Mute toggle did not register")
				end
			end
		end

		hs.timer.doAfter(self.clickSettleDelay, function() checkResult("keystroke", 1) end)
	end

	if isTeams then
		hs.timer.doAfter(ALERT_PAINT_DELAY, function() sendMuteToggle(currentApp, nil) end)
		return self
	end

	local activated = false
	local timeoutTimer

	local watcher
	watcher = hs.application.watcher.new(function(_, eventType, appObject)
		if eventType ~= hs.application.watcher.activated or appObject:bundleID() ~= self.teamsBundleID then return end
		activated = true
		watcher:stop()
		if timeoutTimer then timeoutTimer:stop() end
		updateProgress("Toggling Teams mute…")
		sendMuteToggle(appObject, currentApp)
	end)
	watcher:start()

	timeoutTimer = hs.timer.doAfter(self.activationTimeout, function()
		watcher:stop()
		if activated then return end
		finish(nil)
		showFailure("Teams did not activate in time")
	end)

	hs.application.launchOrFocusByBundleID(self.teamsBundleID)
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

--- TeamsControl:stop()
--- Method
--- Unbinds any hotkeys bound via `bindHotkeys`.
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
	return self
end

return obj
