-- vim: set ft=lua:

-- Drives Teams' UI -- its accessibility tree, the mute keystroke and the click fallback -- loaded by
-- init.lua. It adds the plain helpers `_muteLabelOf`, `_labelMuted`, `_validCachedMuteButton` and
-- `_findMuteButtonCached`, and the methods `_uiMuted`, `_uiToggle` and `_uiCancel`, to the
-- TeamsControl object. The tree lookup (`findButton`) is adapted from `_teamsFindButtonByLabel` in
-- https://github.com/RobvH/teams-mac-hotkeys

return function(obj)
	obj._nextMenubarWalk = 0
	obj._missedWalks = 0

	local MUTE_LABEL_PATTERN = "ute mic$"

	-- Long enough for the progress alert to paint before the AX lookup blocks
	-- Hammerspoon's main thread.
	local ALERT_PAINT_DELAY = 0.04

	-- The mic can be open with no mute button to find (Teams' pre-join screen,
	-- another app's call), so a walk that found nothing isn't retried every tick,
	-- and each further miss doubles the wait. Joining a call opens a window, which
	-- walks right away regardless.
	local MENUBAR_MISSED_WALK_BACKOFF = 5
	local MENUBAR_MISSED_WALK_BACKOFF_MAX = 60

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
	function obj._muteLabelOf(button)
		local label = button and (button.AXDescription or button.AXTitle)
		if type(label) == "string" and label:match(MUTE_LABEL_PATTERN) then return label end
		return nil
	end

	-- The button label names the action it performs, not the current state:
	-- "Unmute mic" means the mic is muted right now (and vice versa).
	function obj._labelMuted(label) return label:match("^Unmute") ~= nil end

	function obj._validCachedMuteButton(self, teamsApp)
		local windows = windowSetKey(teamsApp)
		if windows == self._muteButtonWindows and obj._muteLabelOf(self._muteButton) then return self._muteButton end
		return nil, windows
	end

	-- Walking Teams' AX tree blocks Hammerspoon for ~0.5-1s, so the button found
	-- by one lookup is reused by the next.
	function obj._findMuteButtonCached(self, teamsApp)
		local cached, windows = obj._validCachedMuteButton(self, teamsApp)
		if cached then return cached end
		self._muteButton = findMuteButton(teamsApp)
		self._muteButtonWindows = windows
		self.log.df("Walked Teams AX tree for mute button: %s", self._muteButton and "found" or "not found")
		return self._muteButton
	end

	-- Teams keeps the mic open while muted, so an open mic is a cheap "maybe in a
	-- call" gate in front of the AX lookup. Any input counts: Teams may not use
	-- the system default.
	local function anyMicInUse()
		return hs.fnutils.some(hs.audiodevice.allInputDevices(), function(device) return device:inUse() end)
	end

	-- Only walks the AX tree when the cached button went stale mid-call, or at
	-- most every MENUBAR_MISSED_WALK_BACKOFF seconds while no button is found.
	-- Returns whether the mic is muted, or nil plus why that isn't known.
	function obj:_uiMuted(teams)
		if not anyMicInUse() then return nil, "no mic in use" end

		local now = hs.timer.secondsSinceEpoch()
		if windowSetKey(teams) ~= self._muteButtonWindows then
			self._missedWalks = 0
		elseif not self._muteButton and now < self._nextMenubarWalk then
			return nil, "no mute button found"
		end
		local label = obj._muteLabelOf(obj._findMuteButtonCached(self, teams))
		if self._muteButton then
			self._missedWalks = 0
		else
			self._missedWalks = self._missedWalks + 1
			local backoff = MENUBAR_MISSED_WALK_BACKOFF * 2 ^ (self._missedWalks - 1)
			self._nextMenubarWalk = now + math.min(backoff, MENUBAR_MISSED_WALK_BACKOFF_MAX)
		end
		if not label then return nil, "no mute button found" end
		return obj._labelMuted(label)
	end

	-- Hammerspoon garbage-collects a running hs.timer that nothing references, so
	-- an in-flight toggle's timers and watcher are kept on self.
	local function stopWaitingForActivation(self)
		if self._activationWatcher then self._activationWatcher:stop() end
		if self._activationTimer then self._activationTimer:stop() end
		self._activationWatcher = nil
		self._activationTimer = nil
	end

	function obj:_uiCancel()
		if self._stepTimer then self._stepTimer:stop() end
		stopWaitingForActivation(self)
	end

	-- Toggles the mic with Cmd+Shift+M and, if that doesn't register, a click on the button, and
	-- reports through hooks: progress(text), activated() once it had to bring Teams forward,
	-- done(muted), still(muted) when the state didn't change, and fail(message).
	function obj:_uiToggle(teamsApp, hooks)
		local muteLabelOf, labelMuted = obj._muteLabelOf, obj._labelMuted
		local function after(delay, fn) self._stepTimer = hs.timer.doAfter(delay, fn) end

		-- A synthetic click lands on whatever is on screen, so unlike the
		-- keystroke it needs Teams in front.
		local function withTeamsFrontmost(fn)
			local front = hs.application.frontmostApplication()
			if front and front:bundleID() == self.teamsBundleID then return fn() end

			self._activationWatcher = hs.application.watcher.new(function(_, eventType, appObject)
				if eventType ~= hs.application.watcher.activated or appObject:bundleID() ~= self.teamsBundleID then
					return
				end
				stopWaitingForActivation(self)
				hooks.activated()
				fn()
			end)
			self._activationWatcher:start()
			self._activationTimer = hs.timer.doAfter(
				self.activationTimeout,
				function() hooks.fail("Teams did not activate in time") end
			)
			hs.application.launchOrFocusByBundleID(self.teamsBundleID)
		end

		local function sendMuteToggle()
			local btn = obj._findMuteButtonCached(self, teamsApp)
			if not btn then
				hooks.fail("No active Teams call")
				return
			end

			local beforeLabel = muteLabelOf(btn)
			hs.eventtap.keyStroke({ "cmd", "shift" }, "m", 0, teamsApp)

			-- Re-reading the cached button element avoids re-walking Teams' deep AX
			-- tree on every retry. If the toggle swapped the node out (the stale ref
			-- reads nil), fall back to a fresh lookup.
			local function resolveButton()
				if muteLabelOf(btn) then return btn end
				btn = obj._findMuteButtonCached(self, teamsApp)
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
			local function settled(label)
				if not (label and label ~= beforeLabel) then return false end
				hooks.done(labelMuted(label))
				return true
			end

			local function checkResult(phase, attempt)
				local afterLabel = currentLabel()

				if settled(afterLabel) then
					return
				elseif attempt < self.clickSettleMaxRetries then
					after(self.clickSettleDelay, function() checkResult(phase, attempt + 1) end)
				elseif phase == "keystroke" then
					hooks.progress("Retrying Teams mute toggle…")
					-- A frozen main-window label can hide a keystroke that worked, and
					-- it catches up once Teams is in front: clicking then would undo it.
					withTeamsFrontmost(function()
						after(self.clickSettleDelay, function()
							if settled(currentLabel()) then return end
							clickButton()
							after(self.clickSettleDelay, function() checkResult("click", 1) end)
						end)
					end)
				elseif afterLabel then
					hooks.still(labelMuted(afterLabel))
				else
					hooks.fail("Mute toggle did not register")
				end
			end

			after(self.clickSettleDelay, function() checkResult("keystroke", 1) end)
		end

		if not teamsApp then
			hooks.fail("No active Teams call")
			return
		end
		-- Only a cache miss walks the AX tree, the one step that blocks long enough
		-- to need the progress alert painted first.
		if obj._validCachedMuteButton(self, teamsApp) then
			sendMuteToggle()
		else
			after(ALERT_PAINT_DELAY, sendMuteToggle)
		end
	end
end
