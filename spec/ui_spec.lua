-- Busted tests for driving the Teams UI: the keystroke, the click fallback and the AX tree, using the shared hs_mock from spoon-tools.

local H = require("helper")

local state, ctl
local TeamsControl
local makeWindow, muteButtonOf, makeApp, alertTexts, toggle, tick, inCall =
	H.makeWindow, H.muteButtonOf, H.makeApp, H.alertTexts, H.toggle, H.tick, H.inCall

before_each(function()
	state, TeamsControl, ctl = H.reset()
end)

describe("toggleMute when Teams is frontmost", function()
	it("shows the progress alert before walking the AX tree", function()
		ctl.frontmost = makeApp(TeamsControl.teamsBundleID, { makeWindow("Mute mic") })

		TeamsControl:toggleMute()

		assert.are.same({ "Toggling Teams mute…" }, alertTexts())
		assert.are.equal(0, state.windowElementCalls)
		assert.are.equal(0, #ctl.keyStrokes)
	end)

	it("sends Cmd+Shift+M and reports the new state once the label flips", function()
		local win = makeWindow("Mute mic")
		local teams = makeApp(TeamsControl.teamsBundleID, { win })
		ctl.frontmost = teams

		toggle()
		muteButtonOf(win).AXDescription = "Unmute mic"
		H.fireTimers()

		assert.are.equal(1, #ctl.keyStrokes)
		assert.are.equal("m", ctl.keyStrokes[1].key)
		assert.is_truthy(H.closedAlerts()[1]) -- progress indicator withdrawn
		local texts = alertTexts()
		assert.are.equal("🔶 Teams Muted", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("re-reads the cached button element instead of re-walking the AX tree", function()
		local win = makeWindow("Mute mic")
		ctl.frontmost = makeApp(TeamsControl.teamsBundleID, { win })

		toggle()
		muteButtonOf(win).AXDescription = "Unmute mic"
		H.fireTimers()

		-- One walk for beforeLabel; every retry reads the cached element.
		assert.are.equal(1, state.windowElementCalls)
	end)

	it("reuses the button found by a previous toggle instead of re-walking the AX tree", function()
		local win = makeWindow("Mute mic")
		ctl.frontmost = makeApp(TeamsControl.teamsBundleID, { win })

		toggle()
		muteButtonOf(win).AXDescription = "Unmute mic"
		H.fireTimers()
		toggle()
		muteButtonOf(win).AXDescription = "Mute mic"
		H.fireTimers()

		assert.are.equal(1, state.windowElementCalls)
		assert.are.equal(2, #ctl.keyStrokes)
		local texts = alertTexts()
		assert.are.equal("🎤 Teams Unmuted", texts[#texts])
	end)

	it("sends the keystroke right away when the cached button is still valid", function()
		local win = makeWindow("Mute mic")
		ctl.frontmost = makeApp(TeamsControl.teamsBundleID, { win })

		toggle()
		muteButtonOf(win).AXDescription = "Unmute mic"
		H.fireTimers()
		TeamsControl:toggleMute()

		assert.are.equal(2, #ctl.keyStrokes)
	end)

	it("re-walks the AX tree on the next toggle when the remembered button went stale", function()
		local win = makeWindow("Mute mic")
		ctl.frontmost = makeApp(TeamsControl.teamsBundleID, { win })

		toggle()
		muteButtonOf(win).AXDescription = "Unmute mic"
		H.fireTimers()
		muteButtonOf(win).AXDescription = nil
		table.insert(
			win.AXChildren[1].AXChildren,
			{ AXRole = "AXButton", AXDescription = "Unmute mic", AXChildren = {} }
		)
		toggle()

		assert.are.equal(2, state.windowElementCalls)
	end)

	it("falls back to a fresh lookup when the cached button ref goes stale", function()
		local win = makeWindow("Mute mic")
		ctl.frontmost = makeApp(TeamsControl.teamsBundleID, { win })

		toggle()
		-- Simulate Teams swapping the node out: old ref reads nil, a new
		-- button node carries the flipped label.
		muteButtonOf(win).AXDescription = nil
		table.insert(
			win.AXChildren[1].AXChildren,
			{ AXRole = "AXButton", AXDescription = "Unmute mic", AXChildren = {} }
		)
		H.fireTimers()

		local texts = alertTexts()
		assert.are.equal("🔶 Teams Muted", texts[#texts])
		assert.is_true(state.windowElementCalls > 1)
	end)

	it("treats a swapped-out button as stale even though Teams reports an empty AXTitle", function()
		local win = makeWindow("Mute mic")
		muteButtonOf(win).AXTitle = ""
		ctl.frontmost = makeApp(TeamsControl.teamsBundleID, { win })

		toggle()
		muteButtonOf(win).AXDescription = nil
		table.insert(
			win.AXChildren[1].AXChildren,
			{ AXRole = "AXButton", AXDescription = "Unmute mic", AXTitle = "", AXChildren = {} }
		)
		H.fireTimers()

		local texts = alertTexts()
		assert.are.equal("🔶 Teams Muted", texts[#texts])
	end)

	it("reports 'No active Teams call' when the mute button is absent", function()
		local teams = makeApp(TeamsControl.teamsBundleID, { makeWindow(nil) })
		ctl.frontmost = teams

		toggle()

		assert.are.equal(0, #ctl.keyStrokes)
		local texts = alertTexts()
		assert.are.equal("🛑 No active Teams call", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("falls back to clicking the button's on-screen position when the keystroke doesn't register", function()
		local win = makeWindow("Mute mic")
		local btn = muteButtonOf(win)
		ctl.frontmost = makeApp(TeamsControl.teamsBundleID, { win })

		local origLeftClick = hs.eventtap.leftClick
		hs.eventtap.leftClick = function(point)
			origLeftClick(point)
			btn.AXDescription = "Unmute mic"
		end

		toggle()
		H.fireTimers()

		assert.are.same({ { x = 100 + 23, y = 200 + 23 } }, ctl.clicks)
		local texts = alertTexts()
		assert.are.equal("🔶 Teams Muted", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("reports failure when the label never changes even after the click fallback", function()
		local teams = makeApp(TeamsControl.teamsBundleID, { makeWindow("Mute mic") })
		ctl.frontmost = teams

		toggle()
		H.fireTimers()

		local texts = alertTexts()
		assert.are.equal("🛑 STILL UNMUTED", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)
end)

describe("toggleMute when Teams is not frontmost", function()
	local other, win, teams

	before_each(function()
		other = makeApp("com.other.app")
		ctl.frontmost = other
		win = makeWindow("Mute mic")
		teams = makeApp(TeamsControl.teamsBundleID, { win })
		ctl.apps.teams = teams
	end)

	-- Runs the keystroke phase to exhaustion without the label flipping, so the
	-- click fallback starts and waits for Teams to activate.
	local function exhaustKeystroke()
		toggle()
		H.fireTimers(TeamsControl.clickSettleDelay)
	end

	it("sends the keystroke to Teams in the background without activating it", function()
		toggle()
		muteButtonOf(win).AXDescription = "Unmute mic"
		H.fireTimers()

		assert.are.equal(teams, ctl.keyStrokes[1].app)
		assert.are.same({}, ctl.launched)
		assert.are.equal(0, other._activated)
		local texts = alertTexts()
		assert.are.equal("🔶 Teams Muted", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("reports 'No active Teams call' without launching Teams when it isn't running", function()
		ctl.apps.teams = nil

		toggle()

		assert.are.same({}, ctl.launched)
		local texts = alertTexts()
		assert.are.equal("🛑 No active Teams call", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("activates Teams only for the click fallback, then restores focus", function()
		local origLeftClick = hs.eventtap.leftClick
		hs.eventtap.leftClick = function(point)
			origLeftClick(point)
			muteButtonOf(win).AXDescription = "Unmute mic"
		end

		exhaustKeystroke()
		assert.are.equal(TeamsControl.teamsBundleID, ctl.launched[1])
		assert.are.equal(0, #ctl.clicks)

		ctl.frontmost = teams
		H.appWatcher()._fn(nil, hs.application.watcher.activated, teams)
		H.fireTimers()

		assert.are.equal(1, #ctl.clicks)
		assert.is_false(H.appWatcher():isRunning())
		assert.are.equal(1, other._activated)
		local texts = alertTexts()
		assert.are.equal("🔶 Teams Muted", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("skips the click when the label catches up once Teams is in front", function()
		exhaustKeystroke()
		muteButtonOf(win).AXDescription = "Unmute mic"
		ctl.frontmost = teams
		H.appWatcher()._fn(nil, hs.application.watcher.activated, teams)
		H.fireTimers()

		assert.are.equal(0, #ctl.clicks)
		local texts = alertTexts()
		assert.are.equal("🔶 Teams Muted", texts[#texts])
	end)

	it("restores focus and reports a timeout when the deadman fires mid-fallback", function()
		exhaustKeystroke()
		ctl.frontmost = teams
		H.appWatcher()._fn(nil, hs.application.watcher.activated, teams)
		for _, t in ipairs(ctl.timers()) do
			if t._interval == TeamsControl.activationTimeout + 3 then t._fn() end
		end

		assert.are.equal(1, other._activated)
		local texts = alertTexts()
		assert.are.equal("🛑 Mute toggle timed out", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("keeps the activation watcher referenced so it can't be garbage-collected", function()
		exhaustKeystroke()

		assert.are.equal(H.appWatcher(), TeamsControl._activationWatcher)
	end)

	it("reports a timeout when Teams never activates for the click fallback", function()
		exhaustKeystroke()
		H.fireTimers()

		assert.are.equal(0, #ctl.clicks)
		local texts = alertTexts()
		assert.are.equal("🛑 Teams did not activate in time", texts[#texts])
		assert.is_false(TeamsControl._muteToggleInProgress)
	end)

	it("calls done exactly once when activation times out", function()
		local calls = 0

		toggle(function() calls = calls + 1 end)
		H.fireTimers()
		H.fireTimers()

		assert.are.equal(1, calls)
	end)
end)

describe("mute button lookup", function()
	-- Teams' main meeting window stops updating while Teams is in the
	-- background; the floating compact view (a non-standard window) stays live.
	it("prefers the compact view's button over the main meeting window's", function()
		local main = makeWindow("Mute mic")
		local compact = makeWindow("Unmute mic", false)
		ctl.apps.teams = makeApp(TeamsControl.teamsBundleID, { main, compact })
		H.mic._inUse = true

		TeamsControl:start()

		assert.are.equal("NSTouchBarAudioInputMuteTemplate", H.menubar()._icon._name)
	end)

	it("re-walks when Teams' windows change, even if the cached button still reads fine", function()
		local main = makeWindow("Mute mic")
		local teams = makeApp(TeamsControl.teamsBundleID, { main })
		ctl.apps.teams = teams
		H.mic._inUse = true

		TeamsControl:start()
		table.insert(teams._windows, makeWindow("Unmute mic", false))
		H.everyTimer():fire()

		assert.are.equal("NSTouchBarAudioInputMuteTemplate", H.menubar()._icon._name)
	end)

	it("toggleMute re-walks when Teams' windows change", function()
		local main = makeWindow("Mute mic")
		local teams = makeApp(TeamsControl.teamsBundleID, { main })
		ctl.frontmost = teams

		toggle()
		muteButtonOf(main).AXDescription = "Unmute mic"
		H.fireTimers()
		table.insert(teams._windows, makeWindow("Unmute mic", false))
		toggle()

		assert.are.equal(2, state.windowElementCalls)
	end)
end)

describe("AX mute state", function()
	it("stays hidden without walking the AX tree when no mic is in use", function()
		inCall("Mute mic")
		H.mic._inUse = false

		TeamsControl:start()

		assert.is_nil(H.menubar())
		assert.are.equal(0, state.windowElementCalls)
	end)

	it("follows a mute toggled in Teams by re-reading the cached button", function()
		local win = inCall("Mute mic")

		TeamsControl:start()
		muteButtonOf(win).AXDescription = "Unmute mic"
		tick()

		assert.are.equal("NSTouchBarAudioInputMuteTemplate", H.menubar()._icon._name)
		assert.are.equal(1, state.windowElementCalls)
	end)

	it("rate-limits AX walks while the mic is in use but no mute button exists", function()
		local win = inCall(nil)

		TeamsControl:start()
		tick()
		assert.are.equal(1, state.windowElementCalls)

		table.insert(win.AXChildren[1].AXChildren, { AXRole = "AXButton", AXDescription = "Mute mic", AXChildren = {} })
		ctl.now = 5
		tick()

		assert.are.equal(2, state.windowElementCalls)
		assert.are.equal("NSTouchBarAudioInputTemplate", H.menubar()._icon._name)
	end)

	it("backs off further after each consecutive walk that finds no mute button", function()
		inCall(nil)

		TeamsControl:start()
		ctl.now = 5
		tick()
		assert.are.equal(2, state.windowElementCalls)

		ctl.now = 10
		tick()
		assert.are.equal(2, state.windowElementCalls)

		ctl.now = 15
		tick()
		assert.are.equal(3, state.windowElementCalls)
	end)

	it("restarts the backoff when Teams' windows change", function()
		local win = inCall(nil)

		TeamsControl:start()
		ctl.now = 5
		tick()
		table.insert(ctl.apps.teams._windows, makeWindow(nil, false))
		ctl.now = 6
		tick()
		assert.are.equal(4, state.windowElementCalls) -- both windows walked

		table.insert(win.AXChildren[1].AXChildren, { AXRole = "AXButton", AXDescription = "Mute mic", AXChildren = {} })
		ctl.now = 11
		tick()

		assert.are.equal("NSTouchBarAudioInputTemplate", H.menubar()._icon._name)
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

		assert.are.equal(2, state.windowElementCalls)
		assert.are.equal("NSTouchBarAudioInputMuteTemplate", H.menubar()._icon._name)
	end)
end)
