-- Busted tests for driving the Teams UI: the keystroke, the click fallback and the AX tree, using the mock hs environment.

local H = require("helper")

local mock_hs
local TeamsControl
local makeWindow, muteButtonOf, makeApp, alertTexts, toggle, tick, inCall =
	H.makeWindow, H.muteButtonOf, H.makeApp, H.alertTexts, H.toggle, H.tick, H.inCall

before_each(function()
	mock_hs, TeamsControl = H.reset()
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

	it("sends the keystroke right away when the cached button is still valid", function()
		local win = makeWindow("Mute mic")
		mock_hs._frontmost = makeApp(TeamsControl.teamsBundleID, { win })

		toggle()
		muteButtonOf(win).AXDescription = "Unmute mic"
		mock_hs._fireTimers()
		TeamsControl:toggleMute()

		assert.are.equal(2, #mock_hs._keyStrokes)
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

	it("skips the click when the label catches up once Teams is in front", function()
		exhaustKeystroke()
		muteButtonOf(win).AXDescription = "Unmute mic"
		mock_hs._frontmost = teams
		mock_hs._watcher._fn(nil, "activated", teams)
		mock_hs._fireTimers()

		assert.are.equal(0, #mock_hs._clicks)
		local texts = alertTexts()
		assert.are.equal("🔶 Teams Muted", texts[#texts])
	end)

	it("restores focus and reports a timeout when the deadman fires mid-fallback", function()
		exhaustKeystroke()
		mock_hs._frontmost = teams
		mock_hs._watcher._fn(nil, "activated", teams)
		for _, t in ipairs(mock_hs.timer._pending) do
			if t._delay == TeamsControl.activationTimeout + 3 then t._fn() end
		end

		assert.are.equal(1, other._activated)
		local texts = alertTexts()
		assert.are.equal("🛑 Mute toggle timed out", texts[#texts])
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

describe("AX mute state", function()
	it("stays hidden without walking the AX tree when no mic is in use", function()
		inCall("Mute mic")
		mock_hs._micInUse = false

		TeamsControl:start()

		assert.is_nil(mock_hs._menubar)
		assert.are.equal(0, mock_hs._windowElementCalls)
	end)

	it("follows a mute toggled in Teams by re-reading the cached button", function()
		local win = inCall("Mute mic")

		TeamsControl:start()
		muteButtonOf(win).AXDescription = "Unmute mic"
		tick()

		assert.are.equal("NSTouchBarAudioInputMuteTemplate", mock_hs._menubar._icon._name)
		assert.are.equal(1, mock_hs._windowElementCalls)
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

	it("backs off further after each consecutive walk that finds no mute button", function()
		inCall(nil)

		TeamsControl:start()
		mock_hs._now = 5
		tick()
		assert.are.equal(2, mock_hs._windowElementCalls)

		mock_hs._now = 10
		tick()
		assert.are.equal(2, mock_hs._windowElementCalls)

		mock_hs._now = 15
		tick()
		assert.are.equal(3, mock_hs._windowElementCalls)
	end)

	it("restarts the backoff when Teams' windows change", function()
		local win = inCall(nil)

		TeamsControl:start()
		mock_hs._now = 5
		tick()
		table.insert(mock_hs._running._windows, makeWindow(nil, false))
		mock_hs._now = 6
		tick()
		assert.are.equal(4, mock_hs._windowElementCalls) -- both windows walked

		table.insert(win.AXChildren[1].AXChildren, { AXRole = "AXButton", AXDescription = "Mute mic", AXChildren = {} })
		mock_hs._now = 11
		tick()

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
end)
