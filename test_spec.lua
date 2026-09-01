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
	if muteLabel then table.insert(children, { AXRole = "AXButton", AXDescription = muteLabel, AXChildren = {} }) end
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
	-- Fire pending one-shot timers repeatedly (callbacks may schedule more),
	-- honouring stop(). Capped so a scheduling loop can't hang the suite.
	mock_hs._fireTimers = function()
		for _ = 1, 50 do
			local due
			for i, t in ipairs(timers) do
				if not t._stopped and not t._fired then
					due = t
					table.remove(timers, i)
					break
				end
			end
			if not due then return end
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

	mock_hs.eventtap = {
		keyStroke = function(mods, key) table.insert(mock_hs._keyStrokes, { mods = mods, key = key }) end,
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
	it("sends Cmd+Shift+M and reports the new state once the label flips", function()
		local win = makeWindow("Mute mic")
		local teams = makeApp(TeamsControl.teamsBundleID, { win })
		mock_hs._frontmost = teams

		TeamsControl:toggleMute()
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

		TeamsControl:toggleMute()
		muteButtonOf(win).AXDescription = "Unmute mic"
		mock_hs._fireTimers()

		-- One walk for beforeLabel; every retry reads the cached element.
		assert.are.equal(1, mock_hs._windowElementCalls)
	end)

	it("falls back to a fresh lookup when the cached button ref goes stale", function()
		local win = makeWindow("Mute mic")
		mock_hs._frontmost = makeApp(TeamsControl.teamsBundleID, { win })

		TeamsControl:toggleMute()
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

		TeamsControl:toggleMute()

		assert.are.equal(0, #mock_hs._keyStrokes)
		local texts = alertTexts()
		assert.are.equal("🛑 No active Teams call", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("reports failure when the label never changes", function()
		local teams = makeApp(TeamsControl.teamsBundleID, { makeWindow("Mute mic") })
		mock_hs._frontmost = teams

		TeamsControl:toggleMute()
		mock_hs._fireTimers()

		local texts = alertTexts()
		assert.are.equal("🛑 STILL UNMUTED", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("ignores a re-entrant call while a toggle is in flight", function()
		local teams = makeApp(TeamsControl.teamsBundleID, { makeWindow("Mute mic") })
		mock_hs._frontmost = teams

		TeamsControl:toggleMute()
		TeamsControl:toggleMute()

		assert.are.equal(1, #mock_hs._keyStrokes)
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
