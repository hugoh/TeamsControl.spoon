-- Busted tests for the Teams local API client, using the shared hs_mock from spoon-tools.

local H = require("helper")

local ctl
local TeamsControl
local makeApp, alertTexts, toggle, runTeams, connect, update, readyToToggle =
	H.makeApp, H.alertTexts, H.toggle, H.runTeams, H.connect, H.update, H.readyToToggle

before_each(function()
	_, TeamsControl, ctl = H.reset()
end)

describe("Teams API", function()
	it("redacts the token in the debug log", function()
		local ws = connect()
		TeamsControl.log.setLogLevel(4)
		ctl.websocketEvent(ws, "received", '{"tokenRefresh":"s3cret"}')
		local logged = table.concat(ctl.logged("debug"), "\n")
		assert.is_falsy(logged:find("s3cret", 1, true))
		assert.is_truthy(logged:find("<redacted>", 1, true))
	end)

	it("does not format incoming messages unless debug logging is on", function()
		local ws = connect()
		local formatted = 0
		TeamsControl.log.df = function() formatted = formatted + 1 end
		ctl.websocketEvent(ws, "received", '{"response":"Success","requestId":1}')
		assert.are.equal(0, formatted)
	end)

	it("logs other messages unchanged", function()
		local ws = connect()
		TeamsControl.log.setLogLevel(4)
		ctl.websocketEvent(ws, "received", '{"response":"Success","requestId":1}')
		local logged = table.concat(ctl.logged("debug"), "\n")
		assert.is_truthy(logged:find('{"response":"Success","requestId":1}', 1, true))
	end)

	it("logs an error instead of throwing out of the socket callback", function()
		local ws = connect()
		hs.settings.set = function() error("boom") end
		assert.has_no.errors(function() ctl.websocketEvent(ws, "received", { tokenRefresh = "x" }) end)
		assert.are.equal(1, #ctl.logged("error"))
	end)

	it("connects on start with the saved token", function()
		ctl.settings["TeamsControl.apiToken"] = "abc"
		runTeams()
		TeamsControl:start()
		assert.is_truthy(ctl.websockets[1]._url:find("token=abc", 1, true))
	end)

	it("gives up after apiMaxRetries failed retries and warns once", function()
		runTeams()
		TeamsControl:configure({ apiMaxRetries = 2 }):start()
		for _ = 1, 3 do
			local ws = ctl.websockets[#ctl.websockets]
			ctl.websocketEvent(ws, "fail")
			H.fireTimers()
		end
		assert.are.equal(3, #ctl.websockets)
		assert.are.equal(1, #ctl.logged("warning"))
	end)

	it("starts counting again when Teams relaunches", function()
		runTeams()
		TeamsControl:configure({ apiMaxRetries = 0 }):start()
		ctl.websocketEvent(ctl.websockets[1], "fail")
		H.fireTimers()
		H.appWatcher()._fn("Microsoft Teams", hs.application.watcher.launched, makeApp(TeamsControl.teamsBundleID, {}))
		assert.are.equal(2, #ctl.websockets)
	end)

	it("forgives earlier failures once connected", function()
		runTeams()
		TeamsControl:configure({ apiMaxRetries = 1 }):start()
		ctl.websocketEvent(ctl.websockets[1], "fail")
		H.fireTimers()
		ctl.websocketEvent(ctl.websockets[2], "open")
		ctl.websocketEvent(ctl.websockets[2], "closed")
		H.fireTimers()
		assert.are.equal(3, #ctl.websockets)
	end)

	it("retries after the connection fails", function()
		runTeams()
		TeamsControl:start()
		ctl.websocketEvent(ctl.websockets[1], "fail")
		H.fireTimers()
		assert.are.equal(2, #ctl.websockets)
	end)

	it("saves refreshed tokens", function()
		local ws = connect()
		ctl.websocketEvent(ws, "received", { tokenRefresh = "new" })
		assert.are.equal("new", ctl.settings["TeamsControl.apiToken"])
	end)

	it("pairs once when Teams allows it", function()
		local ws = connect()
		update(ws, { canPair = true }, {})
		update(ws, { canPair = true }, {})
		assert.are.equal(1, #ws._sent)
		assert.is_truthy(ws._sent[1]:find('"action":"pair"', 1, true))
	end)

	it("asks for the meeting state after pairing", function()
		local ws = connect()
		ctl.websocketEvent(ws, "received", { tokenRefresh = "new" })
		assert.is_truthy(ws._sent[#ws._sent]:find('"action":"query-state"', 1, true))
	end)

	it("asks for the meeting state once when an update arrives without it", function()
		local ws = connect()
		update(ws, { canToggleMute = true })
		update(ws, { canToggleMute = true })
		assert.are.equal(1, #ws._sent)
		assert.is_truthy(ws._sent[1]:find('"action":"query-state"', 1, true))
	end)

	it("does not ask for the state while pairing is still pending", function()
		local ws = connect()
		update(ws, { canPair = true })
		assert.are.equal(1, #ws._sent)
		assert.is_truthy(ws._sent[1]:find('"action":"pair"', 1, true))
	end)

	it("opens only one new connection when a dead socket reports both fail and closed", function()
		runTeams()
		TeamsControl:start()
		ctl.websocketEvent(ctl.websockets[1], "fail")
		ctl.websocketEvent(ctl.websockets[1], "closed")
		H.fireTimers()
		assert.are.equal(2, #ctl.websockets)
	end)

	it("closes the socket on stop", function()
		local ws = connect()
		TeamsControl:stop()
		assert.is_true(ws._closed)
	end)

	it("treats a Success response as confirmation without waiting for the state push", function()
		local ws = connect()
		readyToToggle(ws)
		TeamsControl:toggleMute()
		ctl.websocketEvent(ws, "received", { response = "Success", requestId = 1 })
		local texts = alertTexts()
		assert.are.equal("🔶 Teams Muted", texts[#texts])
		assert.are.equal(0, #ctl.keyStrokes)
	end)

	it("falls back at once when Teams rejects the toggle", function()
		local ws = connect()
		readyToToggle(ws)
		toggle()
		ctl.websocketEvent(ws, "received", { response = "Not allowed", requestId = 1 })
		H.fireTimers(0.05)
		assert.are.equal(1, #ctl.keyStrokes)
	end)

	it("falls back at once when the connection drops mid-toggle", function()
		local ws = connect()
		readyToToggle(ws)
		toggle()
		ctl.websocketEvent(ws, "closed")
		H.fireTimers(0.05)
		assert.are.equal(1, #ctl.keyStrokes)
	end)

	it("waits apiConfirmTimeout regardless of the keystroke retry settings", function()
		local ws = connect()
		readyToToggle(ws)
		TeamsControl:configure({ clickSettleDelay = 0 })
		TeamsControl:toggleMute()
		assert.are.equal(TeamsControl.apiConfirmTimeout, H.newestTimer()._interval)
	end)

	it("pairs again when canPair returns after having gone away", function()
		local ws = connect()
		update(ws, { canPair = true }, {})
		update(ws, { canPair = false }, {})
		update(ws, { canPair = true }, {})
		assert.are.equal(2, #ws._sent)
	end)

	it("url-encodes the token", function()
		ctl.settings["TeamsControl.apiToken"] = "a&b+c"
		runTeams()
		TeamsControl:start()
		assert.is_truthy(ctl.websockets[1]._url:find("token=a%26b%2Bc&", 1, true))
	end)
end)
