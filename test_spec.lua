-- Busted tests for the TeamsControl Spoon using a mock hs environment.

local mock_hs
local TeamsControl

local function makeLogger()
	local l = { _infos = {}, _warnings = {}, _errors = {} }
	l.i = function(msg) table.insert(l._infos, msg) end
	l.f = function(fmt, ...) table.insert(l._infos, string.format(fmt, ...)) end
	l.w = function(msg) table.insert(l._warnings, msg) end
	l.wf = function(fmt, ...) table.insert(l._warnings, string.format(fmt, ...)) end
	l.e = function(msg) table.insert(l._errors, msg) end
	l.d = function() end
	l.df = function() end
	return l
end

-- Build an accessibility subtree: a window element whose descendants include
-- (optionally) a mute button with the given label.
local function makeWindow(muteLabel)
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
	return { AXRole = "AXWindow", AXChildren = { { AXRole = "AXGroup", AXChildren = children } } }
end

local function muteButtonOf(win) return win.AXChildren[1].AXChildren[1] end

local function makeApp(bundleID, windows)
	local app = { _bid = bundleID, _activated = 0 }
	function app:bundleID() return self._bid end
	app.allWindows = function() return windows or {} end
	function app:activate() self._activated = self._activated + 1 end
	return app
end

before_each(function()
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
	-- may schedule more), honouring stop(). Capped so a scheduling loop can't
	-- hang the suite.
	mock_hs._fireTimers = function()
		for _ = 1, 50 do
			local dueIndex
			for i, t in ipairs(timers) do
				if not t._stopped and not t._fired and (not dueIndex or t._delay < timers[dueIndex]._delay) then
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
		keyStroke = function(mods, key) table.insert(mock_hs._keyStrokes, { mods = mods, key = key }) end,
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
	mock_hs.application.watcher = { activated = "activated" }
	mock_hs.application.watcher.new = function(fn)
		local w = { _fn = fn, _started = false, _stopped = false }
		function w:start() self._started = true end
		function w:stop() self._stopped = true end
		mock_hs._watcher = w
		return w
	end

	mock_hs.hotkey = {
		bind = function(mods, key, fn)
			local hk = { _mods = mods, _key = key, _fn = fn, _deleted = false }
			function hk:delete() self._deleted = true end
			return hk
		end,
	}

	package.loaded.hs = nil
	_G.hs = mock_hs

	TeamsControl = dofile("init.lua")
end)

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
		deferred._fn()
	end
end

describe("init", function()
	it("loads the extensions toggleMute uses so the first toggle doesn't pay for it", function()
		local touched = {}
		local lazy = { alert = mock_hs.alert, axuielement = mock_hs.axuielement, eventtap = mock_hs.eventtap }
		for name in pairs(lazy) do
			mock_hs[name] = nil
		end
		setmetatable(mock_hs, {
			__index = function(_, name)
				touched[name] = true
				return lazy[name]
			end,
		})

		TeamsControl:init()

		assert.is_true(touched.alert)
		assert.is_true(touched.axuielement)
		assert.is_true(touched.eventtap)
	end)
end)

describe("configure", function()
	it("overrides only the provided keys", function()
		TeamsControl:configure({ activationTimeout = 9, teamsBundleID = "com.example.teams" })
		assert.are.equal(9, TeamsControl.activationTimeout)
		assert.are.equal("com.example.teams", TeamsControl.teamsBundleID)
		assert.are.equal(0.15, TeamsControl.clickSettleDelay)
	end)

	it("returns self for chaining", function() assert.are.equal(TeamsControl, TeamsControl:configure({})) end)
end)

describe("toggleMute when Teams is frontmost", function()
	it("shows the progress alert before walking the AX tree", function()
		mock_hs._frontmost = makeApp(TeamsControl.teamsBundleID, { makeWindow("Mute mic") })

		TeamsControl:toggleMute()

		assert.are.same({ "Toggling Teams mute…" }, alertTexts())
		assert.are.equal(0, mock_hs._windowElementCalls)
		assert.are.equal(0, #mock_hs._keyStrokes)
	end)

	it("sends Cmd+Shift+M and reports the new state once the label flips", function()
		local win = makeWindow("Mute mic")
		local teams = makeApp(TeamsControl.teamsBundleID, { win })
		mock_hs._frontmost = teams

		toggle()
		muteButtonOf(win).AXDescription = "Unmute mic"
		mock_hs._fireTimers()

		assert.are.equal(1, #mock_hs._keyStrokes)
		assert.are.equal("m", mock_hs._keyStrokes[1].key)
		assert.is_truthy(mock_hs._closed[1]) -- progress indicator withdrawn
		local texts = alertTexts()
		assert.are.equal("🔶 Teams Muted", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("re-reads the cached button element instead of re-walking the AX tree", function()
		local win = makeWindow("Mute mic")
		mock_hs._frontmost = makeApp(TeamsControl.teamsBundleID, { win })

		toggle()
		muteButtonOf(win).AXDescription = "Unmute mic"
		mock_hs._fireTimers()

		-- One walk for beforeLabel; every retry reads the cached element.
		assert.are.equal(1, mock_hs._windowElementCalls)
	end)

	it("reuses the button found by a previous toggle instead of re-walking the AX tree", function()
		local win = makeWindow("Mute mic")
		mock_hs._frontmost = makeApp(TeamsControl.teamsBundleID, { win })

		toggle()
		muteButtonOf(win).AXDescription = "Unmute mic"
		mock_hs._fireTimers()
		toggle()
		muteButtonOf(win).AXDescription = "Mute mic"
		mock_hs._fireTimers()

		assert.are.equal(1, mock_hs._windowElementCalls)
		assert.are.equal(2, #mock_hs._keyStrokes)
		local texts = alertTexts()
		assert.are.equal("🎤 Teams Unmuted", texts[#texts])
	end)

	it("re-walks the AX tree on the next toggle when the remembered button went stale", function()
		local win = makeWindow("Mute mic")
		mock_hs._frontmost = makeApp(TeamsControl.teamsBundleID, { win })

		toggle()
		muteButtonOf(win).AXDescription = "Unmute mic"
		mock_hs._fireTimers()
		muteButtonOf(win).AXDescription = nil
		table.insert(
			win.AXChildren[1].AXChildren,
			{ AXRole = "AXButton", AXDescription = "Unmute mic", AXChildren = {} }
		)
		toggle()

		assert.are.equal(2, mock_hs._windowElementCalls)
	end)

	it("falls back to a fresh lookup when the cached button ref goes stale", function()
		local win = makeWindow("Mute mic")
		mock_hs._frontmost = makeApp(TeamsControl.teamsBundleID, { win })

		toggle()
		-- Simulate Teams swapping the node out: old ref reads nil, a new
		-- button node carries the flipped label.
		muteButtonOf(win).AXDescription = nil
		table.insert(
			win.AXChildren[1].AXChildren,
			{ AXRole = "AXButton", AXDescription = "Unmute mic", AXChildren = {} }
		)
		mock_hs._fireTimers()

		local texts = alertTexts()
		assert.are.equal("🔶 Teams Muted", texts[#texts])
		assert.is_true(mock_hs._windowElementCalls > 1)
	end)

	it("reports 'No active Teams call' when the mute button is absent", function()
		local teams = makeApp(TeamsControl.teamsBundleID, { makeWindow(nil) })
		mock_hs._frontmost = teams

		toggle()

		assert.are.equal(0, #mock_hs._keyStrokes)
		local texts = alertTexts()
		assert.are.equal("🛑 No active Teams call", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("falls back to clicking the button's on-screen position when the keystroke doesn't register", function()
		local win = makeWindow("Mute mic")
		local btn = muteButtonOf(win)
		mock_hs._frontmost = makeApp(TeamsControl.teamsBundleID, { win })

		local origLeftClick = mock_hs.eventtap.leftClick
		mock_hs.eventtap.leftClick = function(point)
			origLeftClick(point)
			btn.AXDescription = "Unmute mic"
		end

		toggle()
		mock_hs._fireTimers()

		assert.are.same({ { x = 100 + 23, y = 200 + 23 } }, mock_hs._clicks)
		local texts = alertTexts()
		assert.are.equal("🔶 Teams Muted", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("reports failure when the label never changes even after the click fallback", function()
		local teams = makeApp(TeamsControl.teamsBundleID, { makeWindow("Mute mic") })
		mock_hs._frontmost = teams

		toggle()
		mock_hs._fireTimers()

		local texts = alertTexts()
		assert.are.equal("🛑 STILL UNMUTED", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("ignores a re-entrant call while a toggle is in flight", function()
		local teams = makeApp(TeamsControl.teamsBundleID, { makeWindow("Mute mic") })
		mock_hs._frontmost = teams

		toggle()
		toggle()

		assert.are.equal(1, #mock_hs._keyStrokes)
	end)

	it("calls done once the toggle settles", function()
		local win = makeWindow("Mute mic")
		mock_hs._frontmost = makeApp(TeamsControl.teamsBundleID, { win })
		local calls = 0

		toggle(function() calls = calls + 1 end)
		assert.are.equal(0, calls)
		muteButtonOf(win).AXDescription = "Unmute mic"
		mock_hs._fireTimers()

		assert.are.equal(1, calls)
	end)

	it("calls done for a re-entrant call that is ignored", function()
		mock_hs._frontmost = makeApp(TeamsControl.teamsBundleID, { makeWindow("Mute mic") })
		local calls = 0

		toggle()
		toggle(function() calls = calls + 1 end)

		assert.are.equal(1, calls)
	end)
end)

describe("toggleMute timer lifetime", function()
	-- Hammerspoon garbage-collects a running hs.timer that nothing references,
	-- and it then never fires. These timers are held only weakly, so a timer
	-- survives a collection only if the Spoon keeps a reference to it.
	local function weakTimers()
		local live = setmetatable({}, { __mode = "k" })
		mock_hs.timer.doAfter = function(delay, fn)
			local t = { _delay = delay, _fn = fn }
			function t:stop() self._stopped = true end
			live[t] = true
			return t
		end
		return function(limit)
			for _ = 1, limit or 50 do
				collectgarbage("collect")
				local due
				for t in pairs(live) do
					if not t._stopped and (not due or t._delay < due._delay) then due = t end
				end
				if not due then return end
				live[due] = nil
				due._fn()
			end
		end
	end

	it("completes a toggle when garbage is collected between steps", function()
		local fire = weakTimers()
		local win = makeWindow("Mute mic")
		mock_hs._frontmost = makeApp(TeamsControl.teamsBundleID, { win })

		TeamsControl:toggleMute()
		fire(1)
		muteButtonOf(win).AXDescription = "Unmute mic"
		fire()

		local texts = alertTexts()
		assert.are.equal("🔶 Teams Muted", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("stops a stuck toggle's pending steps once the deadman reset fires", function()
		mock_hs._frontmost = makeApp(TeamsControl.teamsBundleID, { makeWindow("Mute mic") })

		toggle()
		local deadman, step
		for _, t in ipairs(mock_hs.timer._pending) do
			if t._delay == TeamsControl.activationTimeout + 3 then
				deadman = t
			else
				step = t
			end
		end
		deadman._fn()

		assert.is_true(step._stopped)
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)
end)

describe("toggleMute when Teams is not frontmost", function()
	it("activates Teams, toggles on the activation event, and restores focus", function()
		local other = makeApp("com.other.app")
		mock_hs._frontmost = other
		local win = makeWindow("Mute mic")
		local teams = makeApp(TeamsControl.teamsBundleID, { win })

		TeamsControl:toggleMute()
		assert.are.equal(TeamsControl.teamsBundleID, mock_hs._launched[1])
		assert.is_true(mock_hs._watcher._started)

		mock_hs._watcher._fn(nil, "activated", teams)

		-- The activation-timeout timer is stopped once Teams activates.
		local timeoutTimer
		for _, t in ipairs(mock_hs.timer._pending) do
			if t._delay == TeamsControl.activationTimeout then timeoutTimer = t end
		end
		assert.is_true(timeoutTimer._stopped)

		muteButtonOf(win).AXDescription = "Unmute mic"
		mock_hs._fireTimers()

		assert.is_true(mock_hs._watcher._stopped)
		assert.are.equal(1, other._activated) -- focus restored
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("reports a timeout when Teams never activates", function()
		mock_hs._frontmost = makeApp("com.other.app")

		TeamsControl:toggleMute()
		mock_hs._fireTimers()

		local texts = alertTexts()
		assert.are.equal("🛑 Teams did not activate in time", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("calls done exactly once when activation times out", function()
		mock_hs._frontmost = makeApp("com.other.app")
		local calls = 0

		TeamsControl:toggleMute(function() calls = calls + 1 end)
		mock_hs._fireTimers()

		assert.are.equal(1, calls)
	end)
end)

describe("bindHotkeys", function()
	it("binds the toggleMute action and stop() unbinds it", function()
		TeamsControl:bindHotkeys({ toggleMute = { { "cmd", "alt" }, "m" } })
		local hk = TeamsControl._hotkeys.toggleMute
		assert.are.equal("m", hk._key)

		TeamsControl:stop()
		assert.is_true(hk._deleted)
		assert.is_nil(TeamsControl._hotkeys)
	end)

	it("warns on an unknown action", function()
		TeamsControl:bindHotkeys({ bogus = { {}, "x" } })
		assert.is_truthy(#TeamsControl.log._warnings > 0)
	end)
end)
