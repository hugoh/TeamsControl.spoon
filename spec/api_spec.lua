-- Busted tests for the Teams local API client, using the mock hs environment.

local H = require("helper")

local mock_hs
local TeamsControl
local makeApp, alertTexts, toggle, runTeams, connect, update, readyToToggle =
	H.makeApp, H.alertTexts, H.toggle, H.runTeams, H.connect, H.update, H.readyToToggle

before_each(function()
	mock_hs, TeamsControl = H.reset()
end)

describe("Teams API", function()
	it("redacts the token in the debug log", function()
		local ws = connect()
		TeamsControl.log._level = 4
		ws._cb("received", '{"tokenRefresh":"s3cret"}')
		local logged = table.concat(TeamsControl.log._debugs, "\n")
		assert.is_falsy(logged:find("s3cret", 1, true))
		assert.is_truthy(logged:find("<redacted>", 1, true))
	end)

	it("does not format incoming messages unless debug logging is on", function()
		local ws = connect()
		local formatted = 0
		TeamsControl.log.df = function() formatted = formatted + 1 end
		ws._cb("received", '{"response":"Success","requestId":1}')
		assert.are.equal(0, formatted)
	end)

	it("logs other messages unchanged", function()
		local ws = connect()
		TeamsControl.log._level = 4
		ws._cb("received", '{"response":"Success","requestId":1}')
		local logged = table.concat(TeamsControl.log._debugs, "\n")
		assert.is_truthy(logged:find('{"response":"Success","requestId":1}', 1, true))
	end)

	it("logs an error instead of throwing out of the socket callback", function()
		local ws = connect()
		mock_hs.settings.set = function() error("boom") end
		assert.has_no.errors(function() ws._cb("received", { tokenRefresh = "x" }) end)
		assert.are.equal(1, #TeamsControl.log._errors)
	end)

	it("connects on start with the saved token", function()
		mock_hs._settings["TeamsControl.apiToken"] = "abc"
		runTeams()
		TeamsControl:start()
		assert.is_truthy(mock_hs._sockets[1]._url:find("token=abc", 1, true))
	end)

	it("gives up after apiMaxRetries failed retries and warns once", function()
		runTeams()
		TeamsControl:configure({ apiMaxRetries = 2 }):start()
		for _ = 1, 3 do
			local ws = mock_hs._sockets[#mock_hs._sockets]
			ws._cb("fail")
			mock_hs._fireTimers()
		end
		assert.are.equal(3, #mock_hs._sockets)
		assert.are.equal(1, #TeamsControl.log._warnings)
	end)

	it("starts counting again when Teams relaunches", function()
		runTeams()
		TeamsControl:configure({ apiMaxRetries = 0 }):start()
		mock_hs._sockets[1]._cb("fail")
		mock_hs._fireTimers()
		mock_hs._watcher._fn("Microsoft Teams", "launched", makeApp(TeamsControl.teamsBundleID, {}))
		assert.are.equal(2, #mock_hs._sockets)
	end)

	it("forgives earlier failures once connected", function()
		runTeams()
		TeamsControl:configure({ apiMaxRetries = 1 }):start()
		mock_hs._sockets[1]._cb("fail")
		mock_hs._fireTimers()
		mock_hs._sockets[2]._cb("open")
		mock_hs._sockets[2]._cb("closed")
		mock_hs._fireTimers()
		assert.are.equal(3, #mock_hs._sockets)
	end)

	it("retries after the connection fails", function()
		runTeams()
		TeamsControl:start()
		mock_hs._sockets[1]._cb("fail")
		mock_hs._fireTimers()
		assert.are.equal(2, #mock_hs._sockets)
	end)

	it("saves refreshed tokens", function()
		local ws = connect()
		ws._cb("received", { tokenRefresh = "new" })
		assert.are.equal("new", mock_hs._settings["TeamsControl.apiToken"])
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
		ws._cb("received", { tokenRefresh = "new" })
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
		mock_hs._sockets[1]._cb("fail")
		mock_hs._sockets[1]._cb("closed")
		mock_hs._fireTimers()
		assert.are.equal(2, #mock_hs._sockets)
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
		ws._cb("received", { response = "Success", requestId = 1 })
		local texts = alertTexts()
		assert.are.equal("🔶 Teams Muted", texts[#texts])
		assert.are.equal(0, #mock_hs._keyStrokes)
	end)

	it("falls back at once when Teams rejects the toggle", function()
		local ws = connect()
		readyToToggle(ws)
		toggle()
		ws._cb("received", { response = "Not allowed", requestId = 1 })
		mock_hs._fireTimers(0.05)
		assert.are.equal(1, #mock_hs._keyStrokes)
	end)

	it("falls back at once when the connection drops mid-toggle", function()
		local ws = connect()
		readyToToggle(ws)
		toggle()
		ws._cb("closed")
		mock_hs._fireTimers(0.05)
		assert.are.equal(1, #mock_hs._keyStrokes)
	end)

	it("waits apiConfirmTimeout regardless of the keystroke retry settings", function()
		local ws = connect()
		readyToToggle(ws)
		TeamsControl:configure({ clickSettleDelay = 0 })
		TeamsControl:toggleMute()
		assert.are.equal(TeamsControl.apiConfirmTimeout, mock_hs.timer._pending[#mock_hs.timer._pending]._delay)
	end)

	it("pairs again when canPair returns after having gone away", function()
		local ws = connect()
		update(ws, { canPair = true }, {})
		update(ws, { canPair = false }, {})
		update(ws, { canPair = true }, {})
		assert.are.equal(2, #ws._sent)
	end)

	it("url-encodes the token", function()
		mock_hs._settings["TeamsControl.apiToken"] = "a&b+c"
		runTeams()
		TeamsControl:start()
		assert.is_truthy(mock_hs._sockets[1]._url:find("token=a%26b%2Bc&", 1, true))
	end)
end)
