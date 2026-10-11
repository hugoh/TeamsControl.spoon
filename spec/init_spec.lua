-- Busted tests for the spoon lifecycle, configuration, hotkeys and toggle orchestration, using the shared hs_mock from spoon-tools.

local H = require("helper")

local state, ctl
local TeamsControl
local makeWindow, muteButtonOf, makeApp, alertTexts, toggle, inCall, runTeams, connect, update, readyToToggle =
	H.makeWindow,
	H.muteButtonOf,
	H.makeApp,
	H.alertTexts,
	H.toggle,
	H.inCall,
	H.runTeams,
	H.connect,
	H.update,
	H.readyToToggle

before_each(function()
	state, TeamsControl, ctl = H.reset()
end)

describe("init", function()
	it("loads the extensions toggleMute uses so the first toggle doesn't pay for it", function()
		local touched = {}
		local lazy = { alert = hs.alert, axuielement = hs.axuielement, eventtap = hs.eventtap }
		for name in pairs(lazy) do
			hs[name] = nil
		end
		setmetatable(hs, {
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
		assert.are.equal(0.05, TeamsControl.clickSettleDelay)
	end)

	it("returns self for chaining", function() assert.are.equal(TeamsControl, TeamsControl:configure({})) end)
end)

describe("bindHotkeys", function()
	it("binds the toggleMute action and stop() unbinds it", function()
		TeamsControl:bindHotkeys({ toggleMute = { { "cmd", "alt" }, "m" } })
		local hk = TeamsControl._hotkeys.toggleMute
		assert.are.equal("m", hk.key)

		TeamsControl:stop()
		assert.is_true(hk.deleted)
		assert.is_nil(TeamsControl._hotkeys)
	end)

	it("warns on an unknown action", function()
		TeamsControl:bindHotkeys({ bogus = { {}, "x" } })
		assert.is_truthy(#ctl.logged("warning") > 0)
	end)
end)

describe("toggleMute orchestration", function()
	it("ignores a re-entrant call while a toggle is in flight", function()
		local teams = makeApp(TeamsControl.teamsBundleID, { makeWindow("Mute mic") })
		ctl.frontmost = teams

		toggle()
		toggle()

		assert.are.equal(1, #ctl.keyStrokes)
	end)

	it("calls done once the toggle settles", function()
		local win = makeWindow("Mute mic")
		ctl.frontmost = makeApp(TeamsControl.teamsBundleID, { win })
		local calls = 0

		toggle(function() calls = calls + 1 end)
		assert.are.equal(0, calls)
		muteButtonOf(win).AXDescription = "Unmute mic"
		H.fireTimers()

		assert.are.equal(1, calls)
	end)

	it("calls done for a re-entrant call that is ignored", function()
		ctl.frontmost = makeApp(TeamsControl.teamsBundleID, { makeWindow("Mute mic") })
		local calls = 0

		toggle()
		toggle(function() calls = calls + 1 end)

		assert.are.equal(1, calls)
	end)

	it("toggles mute through the API and reports the new state", function()
		local ws = connect()
		update(ws, { canToggleMute = true }, { isMuted = false })

		TeamsControl:toggleMute()
		assert.is_truthy(ws._sent[1]:find('"action":"toggle-mute"', 1, true))
		assert.is_truthy(ws._sent[1]:find('"parameters":{}', 1, true))
		assert.are.equal(0, #ctl.keyStrokes)

		update(ws, { canToggleMute = true }, { isMuted = true })
		local texts = alertTexts()
		assert.are.equal("🔶 Teams Muted", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("falls back to the keystroke when the API does not answer", function()
		local ws = connect()
		update(ws, { canToggleMute = true }, { isMuted = false })
		ctl.frontmost = makeApp(TeamsControl.teamsBundleID, { makeWindow("Mute mic") })
		ctl.apps.teams = ctl.frontmost

		toggle()
		H.fireTimers(TeamsControl.clickSettleDelay * TeamsControl.clickSettleMaxRetries)

		assert.are.equal(1, #ctl.keyStrokes)
	end)

	it("uses the keystroke when the API is not connected", function()
		ctl.frontmost = makeApp(TeamsControl.teamsBundleID, { makeWindow("Mute mic") })
		toggle()
		assert.are.equal(1, #ctl.keyStrokes)
	end)

	it("uses the keystroke after the connection drops", function()
		local ws = connect()
		update(ws, { canToggleMute = true }, { isMuted = false })
		ctl.websocketEvent(ws, "closed")
		ctl.frontmost = makeApp(TeamsControl.teamsBundleID, { makeWindow("Mute mic") })
		ctl.apps.teams = ctl.frontmost
		toggle()
		assert.are.equal(0, #ws._sent)
		assert.are.equal(1, #ctl.keyStrokes)
	end)

	it("uses the keystroke when Teams reports no meeting", function()
		local ws = connect()
		readyToToggle(ws)
		update(ws, { canToggleMute = true }, { isMuted = false, isInMeeting = false })
		toggle()
		assert.are.equal(1, #ctl.keyStrokes)
		assert.are.equal(0, #ws._sent)
	end)

	it("cancels an in-flight toggle on stop", function()
		local ws = connect()
		readyToToggle(ws)
		TeamsControl:toggleMute()
		TeamsControl:stop()
		assert.is_false(TeamsControl._muteToggleInProgress)
		H.fireTimers()
		assert.are.equal(0, #ctl.keyStrokes)
	end)
end)

describe("toggleMute timer lifetime", function()
	-- Hammerspoon garbage-collects a running hs.timer that nothing references,
	-- and it then never fires. These timers are held only weakly, so a timer
	-- survives a collection only if the Spoon keeps a reference to it.
	local function weakTimers()
		local live = setmetatable({}, { __mode = "k" })
		hs.timer.doAfter = function(delay, fn)
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
		ctl.frontmost = makeApp(TeamsControl.teamsBundleID, { win })

		TeamsControl:toggleMute()
		fire(1)
		muteButtonOf(win).AXDescription = "Unmute mic"
		fire()

		local texts = alertTexts()
		assert.are.equal("🔶 Teams Muted", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("stops a stuck toggle's pending steps once the deadman reset fires", function()
		ctl.frontmost = makeApp(TeamsControl.teamsBundleID, { makeWindow("Mute mic") })

		toggle()
		local deadman, step
		for _, t in ipairs(ctl.timers()) do
			if t._interval == TeamsControl.activationTimeout + 3 then
				deadman = t
			else
				step = t
			end
		end
		deadman._fn()

		assert.is_false(step:running())
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)
end)

describe("Teams launch and quit", function()
	local function infos() return ctl.logged("info") end

	local function count(text)
		local n = 0
		for _, m in ipairs(infos()) do
			if m == text then n = n + 1 end
		end
		return n
	end

	it("logs nothing about Teams quitting when it was never running", function()
		TeamsControl:start()
		TeamsControl:stop()
		assert.are.equal(0, count("Teams no longer running"))
	end)

	it("logs Teams detected and quitting once per transition", function()
		local teams = makeApp(TeamsControl.teamsBundleID, {})
		ctl.apps.teams = teams
		TeamsControl:start()
		H.appWatcher()._fn("Microsoft Teams", hs.application.watcher.launched, teams)
		assert.are.equal(1, count("Teams detected running"))
		H.appWatcher()._fn("Microsoft Teams", hs.application.watcher.terminated, teams)
		TeamsControl:stop()
		assert.are.equal(1, count("Teams no longer running"))
	end)

	it("doesn't poll while Teams isn't running", function()
		TeamsControl:start()

		assert.is_nil(H.everyTimer())
		assert.is_truthy(TeamsControl._appWatcher)
		assert.is_true(TeamsControl._appWatcher:isRunning())
	end)

	it("starts polling when Teams launches", function()
		TeamsControl:start()
		local teams = makeApp(TeamsControl.teamsBundleID, {})

		TeamsControl._appWatcher._fn("Microsoft Teams", hs.application.watcher.launched, teams)

		assert.is_not_nil(H.everyTimer())
		assert.is_true(H.everyTimer():running())
	end)

	it("ignores other apps launching", function()
		TeamsControl:start()

		TeamsControl._appWatcher._fn("Notes", hs.application.watcher.launched, makeApp("com.apple.Notes", {}))

		assert.is_nil(H.everyTimer())
	end)

	it("stops polling and hides the item when Teams quits", function()
		inCall("Mute mic")
		TeamsControl:start()
		local bar, timer = H.menubar(), H.everyTimer()

		TeamsControl._appWatcher._fn(
			"Microsoft Teams",
			hs.application.watcher.terminated,
			makeApp(TeamsControl.teamsBundleID, {})
		)

		assert.is_false(timer:running())
		assert.is_true(bar._deleted)
		assert.is_nil(TeamsControl._menubarTimer)
	end)

	it("doesn't start a second timer when Teams launches while already polling", function()
		inCall("Mute mic")
		TeamsControl:start()
		local timer = H.everyTimer()

		TeamsControl._appWatcher._fn(
			"Microsoft Teams",
			hs.application.watcher.launched,
			makeApp(TeamsControl.teamsBundleID, {})
		)

		assert.are.equal(timer, H.everyTimer())
	end)

	it("stop() stops the application watcher", function()
		TeamsControl:start()
		local watcher = TeamsControl._appWatcher

		TeamsControl:stop()

		assert.is_false(watcher:isRunning())
		assert.is_nil(TeamsControl._appWatcher)
	end)

	it("isn't started by init()", function()
		inCall("Mute mic")

		TeamsControl:init()

		assert.is_nil(H.everyTimer())
	end)

	it("start() returns self for chaining", function() assert.are.equal(TeamsControl, TeamsControl:start()) end)

	it("doesn't start when showMenubar is false", function()
		TeamsControl.showMenubar = false
		inCall("Mute mic")

		TeamsControl:start()

		assert.is_nil(H.everyTimer())
		assert.is_nil(H.menubar())
	end)

	it("does not connect when useApi is off", function()
		runTeams()
		TeamsControl:configure({ useApi = false }):start()
		assert.are.equal(0, #ctl.websockets)
	end)

	it("does not connect while Teams is not running", function()
		TeamsControl:start()
		assert.are.equal(0, #ctl.websockets)
	end)

	it("connects when Teams launches", function()
		TeamsControl:start()
		H.appWatcher()._fn("Microsoft Teams", hs.application.watcher.launched, makeApp(TeamsControl.teamsBundleID, {}))
		assert.are.equal(1, #ctl.websockets)
	end)

	it("disconnects and stops retrying when Teams quits", function()
		local ws = connect()
		ctl.websocketEvent(ws, "fail")
		H.appWatcher()
			._fn("Microsoft Teams", hs.application.watcher.terminated, makeApp(TeamsControl.teamsBundleID, {}))
		H.fireTimers()
		assert.are.equal(1, #ctl.websockets)
	end)

	it("logs Teams quitting even when nothing was active", function()
		ctl.apps.teams = makeApp(TeamsControl.teamsBundleID, {})
		TeamsControl:configure({ useApi = false, showMenubar = false }):start()
		H.appWatcher()
			._fn("Microsoft Teams", hs.application.watcher.terminated, makeApp(TeamsControl.teamsBundleID, {}))
		assert.is_truthy(hs.fnutils.some(ctl.logged("info"), function(m) return m == "Teams no longer running" end))
	end)
end)

describe("current mute state", function()
	it("stays hidden when Teams isn't running", function()
		H.mic._inUse = true

		TeamsControl:start()

		assert.is_nil(H.menubar())
	end)

	it("follows the pushed mute state without walking the AX tree", function()
		local ws = connect()
		update(ws, { canToggleMute = true }, { isMuted = true, isInMeeting = true })
		assert.are.equal("NSTouchBarAudioInputMuteTemplate", H.menubar()._icon._name)

		update(ws, { canToggleMute = true }, { isMuted = false, isInMeeting = true })
		assert.are.equal("NSTouchBarAudioInputTemplate", H.menubar()._icon._name)
		assert.are.equal(0, state.windowElementCalls)
	end)

	it("hides when Teams reports no meeting", function()
		local ws = connect()
		update(ws, { canToggleMute = true }, { isMuted = true, isInMeeting = true })
		update(ws, {}, { isMuted = false, isInMeeting = false })
		assert.is_true(H.menubar()._deleted)
	end)

	it("falls back to the AX tree before any state has arrived", function()
		H.mic._inUse = true
		ctl.apps.teams = makeApp(TeamsControl.teamsBundleID, { makeWindow("Unmute mic") })
		TeamsControl:start()
		ctl.websocketEvent(ctl.websockets[#ctl.websockets], "open")
		assert.are.equal("NSTouchBarAudioInputMuteTemplate", H.menubar()._icon._name)
	end)
end)
