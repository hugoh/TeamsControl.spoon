-- Shared hs_mock setup, Teams-specific fakes and factories for the TeamsControl specs.

local hs_mock = require("hs_mock")

local H = {}

local ctl
local state
local TeamsControl

local nextWindowID = 0

-- Build an accessibility subtree: a window element whose descendants include
-- (optionally) a mute button with the given label. `standard = false` makes it
-- a non-standard window like Teams' floating compact view.
local function makeWindow(muteLabel, standard)
	local children = {}
	if muteLabel then
		table.insert(children, {
			AXRole = "AXButton",
			AXDescription = muteLabel,
			AXChildren = {},
			AXPosition = { x = 100, y = 200 },
			AXSize = { w = 46, h = 46 },
		})
	end
	nextWindowID = nextWindowID + 1
	local win = {
		AXRole = "AXWindow",
		AXChildren = { { AXRole = "AXGroup", AXChildren = children } },
		_id = nextWindowID,
		_standard = standard ~= false,
	}
	function win:id() return self._id end
	function win:isStandard() return self._standard end
	return win
end

local function muteButtonOf(win) return win.AXChildren[1].AXChildren[1] end

local function makeApp(bundleID, windows)
	local app = { _bid = bundleID, _activated = 0, _windows = windows or {} }
	function app:bundleID() return self._bid end
	function app:allWindows() return self._windows end
	function app:activate() self._activated = self._activated + 1 end
	return app
end

-- Builds a fresh mock `hs` and loads a fresh spoon; call from before_each.
-- Returns the local test state, the spoon, and hs_mock's ctl.
function H.reset()
	local hs
	hs, ctl = hs_mock.new()
	state = { windowElementCalls = 0 }

	-- Local, not in hs_mock: an honest hs.axuielement needs whole accessibility
	-- trees; these fixtures make each window its own element (see makeWindow).
	hs.axuielement = {
		windowElement = function(win)
			state.windowElementCalls = state.windowElementCalls + 1
			return win
		end,
	}

	-- Local, not in hs_mock: incoming messages stay Lua tables on purpose; the real
	-- decoder isn't under test.
	hs.json.decode = function(str) return str end

	for _, name in ipairs({ "NSTouchBarAudioInputTemplate", "NSTouchBarAudioInputMuteTemplate" }) do
		ctl.images[name] = { _name = name }
	end
	ctl.addAudioDevice({ name = "Built-in Microphone", input = true })
	H.mic = ctl.addAudioDevice({ name = "Headset", input = true })

	_G.hs = hs

	TeamsControl = dofile("init.lua")
	H.spoon, H.ctl, H.state = TeamsControl, ctl, state
	return state, TeamsControl, ctl
end

local function newest(predicate)
	local timers = ctl.timers()
	for i = #timers, 1, -1 do
		if not predicate or predicate(timers[i]) then return timers[i] end
	end
end

-- Fires the most recently scheduled pending timer once and retires it.
function H.fireNewest()
	local t = newest()
	t:stop()
	t:fire()
end

function H.newestTimer() return newest() end

function H.everyTimer()
	return newest(function(t) return t._repeats end)
end

function H.menubar() return ctl.menubars[#ctl.menubars] end

function H.appWatcher() return ctl.appWatchers[#ctl.appWatchers] end

-- Fires pending one-shot timers in due order, moving the clock to each and
-- including ones their callbacks schedule; with maxDelay, only timers whose own
-- delay is at most that, so a chain of short retries runs but not a longer
-- timeout. The repeating tick is left alone (H.tick fires it). Capped so a
-- scheduling loop can't hang the suite.
function H.fireTimers(maxDelay)
	for _ = 1, 50 do
		local due, dueAt
		for _, t in ipairs(ctl.timers()) do
			local at = ctl.now + t:nextTrigger()
			if not t._repeats and (not maxDelay or t._interval <= maxDelay) and (not due or at < dueAt) then
				due, dueAt = t, at
			end
		end
		if not due then return end
		ctl.now = math.max(ctl.now, dueAt)
		due:stop()
		due:fire()
	end
end

local function alertTexts()
	local out = {}
	for _, a in ipairs(ctl.alerts) do
		table.insert(out, a.text)
	end
	return out
end

function H.closedAlerts()
	local out = {}
	for _, a in ipairs(ctl.alerts) do
		if a.closed then table.insert(out, a) end
	end
	return out
end

-- Calls toggleMute and runs only the timer it schedules last: the deferral
-- that lets the progress alert paint before the blocking AX lookup.
local function toggle(done)
	local before = {}
	for _, t in ipairs(ctl.timers()) do
		before[t] = true
	end
	TeamsControl:toggleMute(done)
	local deferred = newest(function(t) return not before[t] end)
	if deferred then
		deferred:stop()
		deferred:fire()
	end
end

H.makeWindow, H.muteButtonOf, H.makeApp = makeWindow, muteButtonOf, makeApp
H.alertTexts, H.toggle = alertTexts, toggle

function H.tick() H.everyTimer():fire() end

function H.inCall(label)
	local win = makeWindow(label)
	ctl.apps.teams = makeApp(TeamsControl.teamsBundleID, { win })
	H.mic._inUse = true
	return win
end

function H.runTeams() ctl.apps.teams = makeApp(TeamsControl.teamsBundleID, {}) end

-- Starts the spoon with Teams running and opens its API socket.
function H.connect()
	H.runTeams()
	TeamsControl:start()
	local ws = ctl.websockets[#ctl.websockets]
	ctl.websocketEvent(ws, "open")
	return ws
end

function H.update(ws, permissions, meetingState)
	ctl.websocketEvent(
		ws,
		"received",
		{ meetingUpdate = { meetingPermissions = permissions, meetingState = meetingState } }
	)
end

-- An open API socket with mute control ready, and Teams with a mute button in the AX tree.
function H.readyToToggle(ws)
	H.update(ws, { canToggleMute = true }, { isMuted = false, isInMeeting = true })
	ctl.frontmost = makeApp(TeamsControl.teamsBundleID, { makeWindow("Mute mic") })
	ctl.apps.teams = ctl.frontmost
end

return H
