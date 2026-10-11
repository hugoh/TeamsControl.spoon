-- Busted tests for the menu bar indicator, using the shared hs_mock from spoon-tools.

local H = require("helper")

local ctl
local TeamsControl
local muteButtonOf, toggle, tick, inCall = H.muteButtonOf, H.toggle, H.tick, H.inCall

before_each(function()
	_, TeamsControl, ctl = H.reset()
end)

describe("menu bar indicator", function()
	it("creates the item already in the menu bar and named, so macOS restores its position", function()
		inCall("Mute mic")

		TeamsControl:start()

		assert.is_true(H.menubar()._inMenuBar)
		assert.are.equal("TeamsControl", H.menubar()._autosaveName)
	end)

	it("shows the mic icon when in a call and unmuted", function()
		inCall("Mute mic")

		TeamsControl:start()

		assert.is_true(H.menubar()._iconTemplate)
		assert.are.equal("NSTouchBarAudioInputTemplate", H.menubar()._icon._name)
	end)

	it("shows the muted icon when in a call and muted", function()
		inCall("Unmute mic")

		TeamsControl:start()

		assert.are.equal("NSTouchBarAudioInputMuteTemplate", H.menubar()._icon._name)
	end)

	it("shows a green dot when unmuted and a yellow dot when muted", function()
		local win = inCall("Mute mic")

		TeamsControl:start()
		assert.are.equal("🟢", H.menubar()._title)
		muteButtonOf(win).AXDescription = "Unmute mic"
		tick()

		assert.are.equal("🟡", H.menubar()._title)
	end)

	it("leaves out the dot when menubarStatusDot is false", function()
		inCall("Mute mic")

		TeamsControl:configure({ menubarStatusDot = false }):start()

		assert.is_nil(H.menubar()._title)
	end)

	it("removes the item once the mic is released", function()
		inCall("Mute mic")

		TeamsControl:start()
		local bar = H.menubar()
		H.mic._inUse = false
		tick()

		assert.is_true(bar._deleted)
		assert.is_nil(TeamsControl._menubar)
	end)

	it("reuses the item across refreshes while the call lasts", function()
		inCall("Mute mic")

		TeamsControl:start()
		local bar = H.menubar()
		tick()

		assert.are.equal(bar, H.menubar())
		assert.is_false(bar._deleted)
	end)

	it("refreshes as soon as a hotkey toggle settles, without waiting for a tick", function()
		local win = inCall("Mute mic")
		ctl.frontmost = ctl.apps.teams

		TeamsControl:start()
		toggle()
		muteButtonOf(win).AXDescription = "Unmute mic"
		H.fireTimers()

		assert.are.equal("NSTouchBarAudioInputMuteTemplate", H.menubar()._icon._name)
	end)

	it("toggles mute on click and refreshes once the toggle settles", function()
		local win = inCall("Mute mic")
		ctl.frontmost = ctl.apps.teams

		TeamsControl:start()
		H.menubar():_click()
		H.fireNewest()
		muteButtonOf(win).AXDescription = "Unmute mic"
		H.fireTimers()

		assert.are.equal(1, #ctl.keyStrokes)
		assert.are.equal("NSTouchBarAudioInputMuteTemplate", H.menubar()._icon._name)
	end)

	it("logs each state change once, with the reason when hidden", function()
		inCall("Mute mic")
		H.mic._inUse = false

		TeamsControl:start()
		tick()
		H.mic._inUse = true
		tick()

		local transitions = {}
		for _, line in ipairs(ctl.logged("info")) do
			if line:match("^Menu bar") then table.insert(transitions, line) end
		end
		assert.are.same({
			"Menu bar indicator: hidden: no mic in use",
			"Menu bar indicator: unmuted",
		}, transitions)
	end)

	it("doesn't bring the item back when a click's toggle settles after stop()", function()
		local win = inCall("Mute mic")
		ctl.frontmost = ctl.apps.teams

		TeamsControl:start()
		H.menubar():_click()
		H.fireNewest()
		TeamsControl:stop()
		local bars = #ctl.menubars
		muteButtonOf(win).AXDescription = "Unmute mic"
		H.fireTimers()

		assert.are.equal(bars, #ctl.menubars)
	end)

	it("start() survives an AX read that throws", function()
		hs.application.get = function() error("AX element went away") end

		assert.has_no.errors(function() TeamsControl:start() end)
		assert.are.equal(1, #ctl.logged("error"))
	end)

	it("logs a failing refresh instead of letting it stop the poll timer", function()
		inCall("Mute mic")
		TeamsControl:start()
		hs.application.get = function() error("AX element went away") end

		assert.has_no.errors(tick)
		assert.are.equal(1, #ctl.logged("error"))
		assert.is_truthy(ctl.logged("error")[1]:match("AX element went away"))
	end)

	it("polls at menubarPollInterval", function()
		inCall("Mute mic")
		TeamsControl:configure({ menubarPollInterval = 0.5 }):start()

		assert.are.equal(0.5, H.everyTimer()._interval)
	end)

	it("stop() tears it down", function()
		inCall("Mute mic")
		TeamsControl:start()
		local bar, timer = H.menubar(), H.everyTimer()

		TeamsControl:stop()

		assert.is_true(bar._deleted)
		assert.is_false(timer:running())
		assert.is_nil(TeamsControl._menubar)
	end)
end)
