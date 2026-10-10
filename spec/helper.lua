-- Shared mock `hs` environment and factories for the TeamsControl specs.

local H = {}

local mock_hs
local TeamsControl

local function makeLogger()
	local l = { _infos = {}, _warnings = {}, _errors = {}, _debugs = {}, _level = 3 }
	l.getLogLevel = function() return l._level end
	l.i = function(msg) table.insert(l._infos, msg) end
	l.f = function(fmt, ...) table.insert(l._infos, string.format(fmt, ...)) end
	l.w = function(msg) table.insert(l._warnings, msg) end
	l.wf = function(fmt, ...) table.insert(l._warnings, string.format(fmt, ...)) end
	l.e = function(msg) table.insert(l._errors, msg) end
	l.d = function() end
	l.df = function(fmt, ...) table.insert(l._debugs, string.format(fmt, ...)) end
	return l
end

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
function H.reset()
	local timers = {}
	local alerts = {}

	mock_hs = {
		logger = { new = function() return makeLogger() end },
		_alerts = alerts,
		_closed = {},
		_launched = {},
		_keyStrokes = {},
		_frontmost = nil,
	}

	mock_hs.alert = {
		show = function(text, ...)
			local handle = { _text = text, _args = { ... } }
			table.insert(alerts, handle)
			return handle
		end,
		closeSpecific = function(handle) table.insert(mock_hs._closed, handle) end,
	}

	mock_hs.timer = { _pending = timers }
	mock_hs.timer.doAfter = function(delay, fn)
		local t = { _delay = delay, _fn = fn, _stopped = false }
		function t:stop() self._stopped = true end
		table.insert(timers, t)
		return t
	end
	-- Fire pending one-shot timers shortest delay first, repeatedly (callbacks
	-- may schedule more), honouring stop() and skipping any longer than
	-- maxDelay. Capped so a scheduling loop can't hang the suite.
	mock_hs._fireTimers = function(maxDelay)
		for _ = 1, 50 do
			local dueIndex
			for i, t in ipairs(timers) do
				if
					not t._stopped
					and not t._fired
					and (not maxDelay or t._delay <= maxDelay)
					and (not dueIndex or t._delay < timers[dueIndex]._delay)
				then
					dueIndex = i
				end
			end
			if not dueIndex then return end
			local due = table.remove(timers, dueIndex)
			due._fired = true
			due._fn()
		end
	end

	mock_hs._windowElementCalls = 0
	mock_hs.axuielement = {
		windowElement = function(win)
			mock_hs._windowElementCalls = mock_hs._windowElementCalls + 1
			return win
		end,
	}

	mock_hs._clicks = {}
	mock_hs.eventtap = {
		keyStroke = function(mods, key, _, app)
			table.insert(mock_hs._keyStrokes, { mods = mods, key = key, app = app })
		end,
		leftClick = function(point) table.insert(mock_hs._clicks, point) end,
	}

	mock_hs._mousePosition = { x = 0, y = 0 }
	mock_hs.mouse = {
		absolutePosition = function(point)
			if point then
				mock_hs._mousePosition = point
			else
				return mock_hs._mousePosition
			end
		end,
	}

	mock_hs.application = {
		frontmostApplication = function() return mock_hs._frontmost end,
		launchOrFocusByBundleID = function(bid) table.insert(mock_hs._launched, bid) end,
	}
	mock_hs.application.watcher = { activated = "activated", launched = "launched", terminated = "terminated" }
	mock_hs.application.watcher.new = function(fn)
		local w = { _fn = fn, _started = false, _stopped = false }
		function w:start() self._started = true end
		function w:stop() self._stopped = true end
		mock_hs._watcher = w
		return w
	end

	mock_hs._now = 0
	mock_hs.timer.secondsSinceEpoch = function() return mock_hs._now end
	mock_hs.timer.doEvery = function(interval, fn)
		local t = { _interval = interval, _fn = fn, _stopped = false }
		function t:stop() self._stopped = true end
		mock_hs._everyTimer = t
		return t
	end

	mock_hs._running = nil
	mock_hs.application.get = function(bid)
		for _, app in ipairs({ mock_hs._running or false, mock_hs._frontmost or false }) do
			if app and app:bundleID() == bid then return app end
		end
	end

	mock_hs._micInUse = false
	mock_hs.audiodevice = {
		allInputDevices = function()
			return {
				{ inUse = function() return false end },
				{ inUse = function() return mock_hs._micInUse end },
			}
		end,
	}

	mock_hs.fnutils = {
		some = function(list, fn)
			for _, v in ipairs(list) do
				if fn(v) then return true end
			end
			return false
		end,
	}

	mock_hs.image = { imageFromName = function(name) return { _name = name } end }

	mock_hs.menubar = {
		new = function(inMenuBar, autosaveName)
			local m = { _inMenuBar = inMenuBar, _autosaveName = autosaveName, _deleted = false }
			function m:setTitle(title) self._title = title end
			function m:setIcon(image, template)
				self._icon = image
				self._template = template
			end
			function m:setClickCallback(fn) self._click = fn end
			function m:delete() self._deleted = true end
			mock_hs._menubar = m
			return m
		end,
	}

	mock_hs.hotkey = {
		bind = function(mods, key, fn)
			local hk = { _mods = mods, _key = key, _fn = fn, _deleted = false }
			function hk:delete() self._deleted = true end
			return hk
		end,
	}

	mock_hs._sockets = {}
	mock_hs.websocket = {
		new = function(url, callback)
			local ws = { _url = url, _cb = callback, _sent = {}, _closed = false }
			function ws:send(msg) table.insert(self._sent, msg) end
			function ws:close() self._closed = true end
			table.insert(mock_hs._sockets, ws)
			return ws
		end,
	}
	mock_hs._settings = {}
	mock_hs.settings = {
		get = function(k) return mock_hs._settings[k] end,
		set = function(k, v) mock_hs._settings[k] = v end,
	}
	-- Incoming messages stay Lua tables; the real decoder isn't under test.
	mock_hs.json = { decode = function(s) return s end }

	mock_hs.spoons = { resourcePath = function(file) return file end }

	package.loaded.hs = nil
	_G.hs = mock_hs

	TeamsControl = dofile("init.lua")
	H.hs, H.spoon = mock_hs, TeamsControl
	return mock_hs, TeamsControl
end

local function alertTexts()
	local out = {}
	for _, a in ipairs(mock_hs._alerts) do
		table.insert(out, a._text)
	end
	return out
end

-- Calls toggleMute and runs only the timer it schedules last: the deferral
-- that lets the progress alert paint before the blocking AX lookup.
local function toggle(done)
	local pending = mock_hs.timer._pending
	local before = #pending
	TeamsControl:toggleMute(done)
	if #pending > before then
		local deferred = table.remove(pending)
		deferred._fired = true
		if not deferred._stopped then deferred._fn() end
	end
end

H.makeWindow, H.muteButtonOf, H.makeApp = makeWindow, muteButtonOf, makeApp
H.alertTexts, H.toggle = alertTexts, toggle

function H.tick() mock_hs._everyTimer._fn() end

function H.inCall(label)
	local win = makeWindow(label)
	mock_hs._running = makeApp(TeamsControl.teamsBundleID, { win })
	mock_hs._micInUse = true
	return win
end

function H.runTeams() mock_hs._running = makeApp(TeamsControl.teamsBundleID, {}) end

-- Starts the spoon with Teams running and opens its API socket.
function H.connect()
	H.runTeams()
	TeamsControl:start()
	local ws = mock_hs._sockets[#mock_hs._sockets]
	ws._cb("open")
	return ws
end

function H.update(ws, permissions, state)
	ws._cb("received", { meetingUpdate = { meetingPermissions = permissions, meetingState = state } })
end

-- An open API socket with mute control ready, and Teams with a mute button in the AX tree.
function H.readyToToggle(ws)
	H.update(ws, { canToggleMute = true }, { isMuted = false, isInMeeting = true })
	mock_hs._frontmost = makeApp(TeamsControl.teamsBundleID, { makeWindow("Mute mic") })
	mock_hs._running = mock_hs._frontmost
end

return H
