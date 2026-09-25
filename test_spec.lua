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
	mock_hs.application.watcher = { activated = "activated" }
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

	mock_hs.image = { imageFromName = function(name) return { _name = name } end }

	mock_hs.menubar = {
		new = function(inMenuBar, autosaveName)
			local m = { _inMenuBar = inMenuBar, _autosaveName = autosaveName, _deleted = false }
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

	it("treats a swapped-out button as stale even though Teams reports an empty AXTitle", function()
		local win = makeWindow("Mute mic")
		muteButtonOf(win).AXTitle = ""
		mock_hs._frontmost = makeApp(TeamsControl.teamsBundleID, { win })

		toggle()
		muteButtonOf(win).AXDescription = nil
		table.insert(
			win.AXChildren[1].AXChildren,
			{ AXRole = "AXButton", AXDescription = "Unmute mic", AXTitle = "", AXChildren = {} }
		)
		mock_hs._fireTimers()

		local texts = alertTexts()
		assert.are.equal("🔶 Teams Muted", texts[#texts])
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
	local other, win, teams

	before_each(function()
		other = makeApp("com.other.app")
		mock_hs._frontmost = other
		win = makeWindow("Mute mic")
		teams = makeApp(TeamsControl.teamsBundleID, { win })
		mock_hs._running = teams
	end)

	-- Runs the keystroke phase to exhaustion without the label flipping, so the
	-- click fallback starts and waits for Teams to activate.
	local function exhaustKeystroke()
		toggle()
		mock_hs._fireTimers(TeamsControl.clickSettleDelay)
	end

	it("sends the keystroke to Teams in the background without activating it", function()
		toggle()
		muteButtonOf(win).AXDescription = "Unmute mic"
		mock_hs._fireTimers()

		assert.are.equal(teams, mock_hs._keyStrokes[1].app)
		assert.are.same({}, mock_hs._launched)
		assert.are.equal(0, other._activated)
		local texts = alertTexts()
		assert.are.equal("🔶 Teams Muted", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("reports 'No active Teams call' without launching Teams when it isn't running", function()
		mock_hs._running = nil

		toggle()

		assert.are.same({}, mock_hs._launched)
		local texts = alertTexts()
		assert.are.equal("🛑 No active Teams call", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("activates Teams only for the click fallback, then restores focus", function()
		local origLeftClick = mock_hs.eventtap.leftClick
		mock_hs.eventtap.leftClick = function(point)
			origLeftClick(point)
			muteButtonOf(win).AXDescription = "Unmute mic"
		end

		exhaustKeystroke()
		assert.are.equal(TeamsControl.teamsBundleID, mock_hs._launched[1])
		assert.are.equal(0, #mock_hs._clicks)

		mock_hs._frontmost = teams
		mock_hs._watcher._fn(nil, "activated", teams)
		mock_hs._fireTimers()

		assert.are.equal(1, #mock_hs._clicks)
		assert.is_true(mock_hs._watcher._stopped)
		assert.are.equal(1, other._activated)
		local texts = alertTexts()
		assert.are.equal("🔶 Teams Muted", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("keeps the activation watcher referenced so it can't be garbage-collected", function()
		exhaustKeystroke()

		assert.are.equal(mock_hs._watcher, TeamsControl._activationWatcher)
	end)

	it("reports a timeout when Teams never activates for the click fallback", function()
		exhaustKeystroke()
		mock_hs._fireTimers()

		assert.are.equal(0, #mock_hs._clicks)
		local texts = alertTexts()
		assert.are.equal("🛑 Teams did not activate in time", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("calls done exactly once when activation times out", function()
		local calls = 0

		toggle(function() calls = calls + 1 end)
		mock_hs._fireTimers()
		mock_hs._fireTimers()

		assert.are.equal(1, calls)
	end)
end)

describe("mute button lookup", function()
	-- Teams' main meeting window stops updating while Teams is in the
	-- background; the floating compact view (a non-standard window) stays live.
	it("prefers the compact view's button over the main meeting window's", function()
		local main = makeWindow("Mute mic")
		local compact = makeWindow("Unmute mic", false)
		mock_hs._running = makeApp(TeamsControl.teamsBundleID, { main, compact })
		mock_hs._micInUse = true

		TeamsControl:start()

		assert.are.equal("NSTouchBarAudioInputMuteTemplate", mock_hs._menubar._icon._name)
	end)

	it("re-walks when Teams' windows change, even if the cached button still reads fine", function()
		local main = makeWindow("Mute mic")
		local teams = makeApp(TeamsControl.teamsBundleID, { main })
		mock_hs._running = teams
		mock_hs._micInUse = true

		TeamsControl:start()
		table.insert(teams._windows, makeWindow("Unmute mic", false))
		mock_hs._everyTimer._fn()

		assert.are.equal("NSTouchBarAudioInputMuteTemplate", mock_hs._menubar._icon._name)
	end)

	it("toggleMute re-walks when Teams' windows change", function()
		local main = makeWindow("Mute mic")
		local teams = makeApp(TeamsControl.teamsBundleID, { main })
		mock_hs._frontmost = teams

		toggle()
		muteButtonOf(main).AXDescription = "Unmute mic"
		mock_hs._fireTimers()
		table.insert(teams._windows, makeWindow("Unmute mic", false))
		toggle()

		assert.are.equal(2, mock_hs._windowElementCalls)
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

describe("menu bar indicator", function()
	local function tick() mock_hs._everyTimer._fn() end

	local function inCall(label)
		local win = makeWindow(label)
		mock_hs._running = makeApp(TeamsControl.teamsBundleID, { win })
		mock_hs._micInUse = true
		return win
	end

	it("creates the item already in the menu bar and named, so macOS restores its position", function()
		inCall("Mute mic")

		TeamsControl:start()

		assert.is_true(mock_hs._menubar._inMenuBar)
		assert.are.equal("TeamsControl", mock_hs._menubar._autosaveName)
	end)

	it("stays hidden when Teams isn't running", function()
		mock_hs._micInUse = true

		TeamsControl:start()

		assert.is_nil(mock_hs._menubar)
	end)

	it("stays hidden without walking the AX tree when no mic is in use", function()
		inCall("Mute mic")
		mock_hs._micInUse = false

		TeamsControl:start()

		assert.is_nil(mock_hs._menubar)
		assert.are.equal(0, mock_hs._windowElementCalls)
	end)

	it("shows the mic icon when in a call and unmuted", function()
		inCall("Mute mic")

		TeamsControl:start()

		assert.is_true(mock_hs._menubar._template)
		assert.are.equal("NSTouchBarAudioInputTemplate", mock_hs._menubar._icon._name)
	end)

	it("shows the muted icon when in a call and muted", function()
		inCall("Unmute mic")

		TeamsControl:start()

		assert.are.equal("NSTouchBarAudioInputMuteTemplate", mock_hs._menubar._icon._name)
	end)

	it("follows a mute toggled in Teams by re-reading the cached button", function()
		local win = inCall("Mute mic")

		TeamsControl:start()
		muteButtonOf(win).AXDescription = "Unmute mic"
		tick()

		assert.are.equal("NSTouchBarAudioInputMuteTemplate", mock_hs._menubar._icon._name)
		assert.are.equal(1, mock_hs._windowElementCalls)
	end)

	it("removes the item once the mic is released", function()
		inCall("Mute mic")

		TeamsControl:start()
		local bar = mock_hs._menubar
		mock_hs._micInUse = false
		tick()

		assert.is_true(bar._deleted)
		assert.is_nil(TeamsControl._menubar)
	end)

	it("reuses the item across refreshes while the call lasts", function()
		inCall("Mute mic")

		TeamsControl:start()
		local bar = mock_hs._menubar
		tick()

		assert.are.equal(bar, mock_hs._menubar)
		assert.is_false(bar._deleted)
	end)

	it("rate-limits AX walks while the mic is in use but no mute button exists", function()
		local win = inCall(nil)

		TeamsControl:start()
		tick()
		assert.are.equal(1, mock_hs._windowElementCalls)

		table.insert(win.AXChildren[1].AXChildren, { AXRole = "AXButton", AXDescription = "Mute mic", AXChildren = {} })
		mock_hs._now = 5
		tick()

		assert.are.equal(2, mock_hs._windowElementCalls)
		assert.are.equal("NSTouchBarAudioInputTemplate", mock_hs._menubar._icon._name)
	end)

	it("re-walks right away when the cached button went stale", function()
		local win = inCall("Mute mic")

		TeamsControl:start()
		muteButtonOf(win).AXDescription = nil
		table.insert(
			win.AXChildren[1].AXChildren,
			{ AXRole = "AXButton", AXDescription = "Unmute mic", AXChildren = {} }
		)
		tick()

		assert.are.equal(2, mock_hs._windowElementCalls)
		assert.are.equal("NSTouchBarAudioInputMuteTemplate", mock_hs._menubar._icon._name)
	end)

	it("toggles mute on click and refreshes once the toggle settles", function()
		local win = inCall("Mute mic")
		mock_hs._frontmost = mock_hs._running

		TeamsControl:start()
		mock_hs._menubar._click()
		table.remove(mock_hs.timer._pending)._fn()
		muteButtonOf(win).AXDescription = "Unmute mic"
		mock_hs._fireTimers()

		assert.are.equal(1, #mock_hs._keyStrokes)
		assert.are.equal("NSTouchBarAudioInputMuteTemplate", mock_hs._menubar._icon._name)
	end)

	it("logs each state change once, with the reason when hidden", function()
		inCall("Mute mic")
		mock_hs._micInUse = false

		TeamsControl:start()
		tick()
		mock_hs._micInUse = true
		tick()

		local transitions = {}
		for _, line in ipairs(TeamsControl.log._infos) do
			if line:match("^Menu bar") then table.insert(transitions, line) end
		end
		assert.are.same({
			"Menu bar indicator: hidden: no mic in use",
			"Menu bar indicator: unmuted",
		}, transitions)
	end)

	it("logs a failing refresh instead of letting it stop the poll timer", function()
		TeamsControl:start()
		mock_hs.application.get = function() error("AX element went away") end

		assert.has_no.errors(tick)
		assert.are.equal(1, #TeamsControl.log._errors)
		assert.is_truthy(TeamsControl.log._errors[1]:match("AX element went away"))
	end)

	it("restarts at a new menubarPollInterval", function()
		TeamsControl:start()
		TeamsControl:configure({ menubarPollInterval = 0.5 })

		assert.are.equal(0.5, mock_hs._everyTimer._interval)
	end)

	it("isn't started by init()", function()
		inCall("Mute mic")

		TeamsControl:init()

		assert.is_nil(mock_hs._everyTimer)
	end)

	it("configure() before start() doesn't start it", function()
		inCall("Mute mic")

		TeamsControl:configure({ showMenubar = true })

		assert.is_nil(mock_hs._everyTimer)
	end)

	it("start() returns self for chaining", function() assert.are.equal(TeamsControl, TeamsControl:start()) end)

	it("doesn't start when showMenubar is false", function()
		TeamsControl.showMenubar = false
		inCall("Mute mic")

		TeamsControl:start()

		assert.is_nil(mock_hs._everyTimer)
		assert.is_nil(mock_hs._menubar)
	end)

	it("configure({ showMenubar = false }) tears down a running indicator", function()
		inCall("Mute mic")
		TeamsControl:start()
		local bar, timer = mock_hs._menubar, mock_hs._everyTimer

		TeamsControl:configure({ showMenubar = false })

		assert.is_true(bar._deleted)
		assert.is_true(timer._stopped)
	end)

	it("configure({ showMenubar = true }) starts it", function()
		TeamsControl.showMenubar = false
		TeamsControl:start()
		inCall("Mute mic")

		TeamsControl:configure({ showMenubar = true })

		assert.is_truthy(mock_hs._menubar)
	end)

	it("stop() tears it down", function()
		inCall("Mute mic")
		TeamsControl:start()
		local bar, timer = mock_hs._menubar, mock_hs._everyTimer

		TeamsControl:stop()

		assert.is_true(bar._deleted)
		assert.is_true(timer._stopped)
		assert.is_nil(TeamsControl._menubar)
	end)
end)
