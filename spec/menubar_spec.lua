-- Busted tests for the menu bar indicator, using the mock hs environment.

local H = require("helper")

local mock_hs
local TeamsControl
local muteButtonOf, toggle, tick, inCall = H.muteButtonOf, H.toggle, H.tick, H.inCall

before_each(function()
	mock_hs, TeamsControl = H.reset()
end)

describe("menu bar indicator", function()
	it("creates the item already in the menu bar and named, so macOS restores its position", function()
		inCall("Mute mic")

		TeamsControl:start()

		assert.is_true(mock_hs._menubar._inMenuBar)
		assert.are.equal("TeamsControl", mock_hs._menubar._autosaveName)
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

	it("shows a green dot when unmuted and a yellow dot when muted", function()
		local win = inCall("Mute mic")

		TeamsControl:start()
		assert.are.equal("🟢", mock_hs._menubar._title)
		muteButtonOf(win).AXDescription = "Unmute mic"
		tick()

		assert.are.equal("🟡", mock_hs._menubar._title)
	end)

	it("leaves out the dot when menubarStatusDot is false", function()
		inCall("Mute mic")

		TeamsControl:configure({ menubarStatusDot = false }):start()

		assert.is_nil(mock_hs._menubar._title)
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

	it("refreshes as soon as a hotkey toggle settles, without waiting for a tick", function()
		local win = inCall("Mute mic")
		mock_hs._frontmost = mock_hs._running

		TeamsControl:start()
		toggle()
		muteButtonOf(win).AXDescription = "Unmute mic"
		mock_hs._fireTimers()

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

	it("doesn't bring the item back when a click's toggle settles after stop()", function()
		local win = inCall("Mute mic")
		mock_hs._frontmost = mock_hs._running

		TeamsControl:start()
		mock_hs._menubar._click()
		table.remove(mock_hs.timer._pending)._fn()
		TeamsControl:stop()
		mock_hs._menubar = nil
		muteButtonOf(win).AXDescription = "Unmute mic"
		mock_hs._fireTimers()

		assert.is_nil(mock_hs._menubar)
	end)

	it("start() survives an AX read that throws", function()
		mock_hs.application.get = function() error("AX element went away") end

		assert.has_no.errors(function() TeamsControl:start() end)
		assert.are.equal(1, #TeamsControl.log._errors)
	end)

	it("logs a failing refresh instead of letting it stop the poll timer", function()
		inCall("Mute mic")
		TeamsControl:start()
		mock_hs.application.get = function() error("AX element went away") end

		assert.has_no.errors(tick)
		assert.are.equal(1, #TeamsControl.log._errors)
		assert.is_truthy(TeamsControl.log._errors[1]:match("AX element went away"))
	end)

	it("polls at menubarPollInterval", function()
		inCall("Mute mic")
		TeamsControl:configure({ menubarPollInterval = 0.5 }):start()

		assert.are.equal(0.5, mock_hs._everyTimer._interval)
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
