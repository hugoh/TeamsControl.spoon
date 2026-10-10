-- vim: set ft=lua:

-- Client for Teams' local third-party API (a websocket on localhost), loaded by init.lua, which
-- documents the settings it reads. It adds the `_api*` methods to the TeamsControl object:
-- connect/retry, pairing and token storage, the pushed meeting state, and the mute toggle.
-- The connection URL, pairing flow and request format follow
-- https://github.com/asp55/MSTeams.spoon2 (MIT, (c) 2026 asp55).

return function(obj)
	local API_TOKEN_KEY = "TeamsControl.apiToken"

	-- hs.logger levels: 4 is debug. Incoming messages are only formatted, and the token redacted,
	-- when it is on.
	local DEBUG_LOG_LEVEL = 4

	local function urlEncode(text)
		return (text:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
	end

	-- `id` numbers the current socket, so late events from a replaced one are ignored.
	local function apiOf(self)
		self._api = self._api or { id = 0, requestId = 0, failures = 0 }
		return self._api
	end

	local function dropConnection(self, closeSocket)
		local api = apiOf(self)
		api.id = api.id + 1
		if api.retryTimer then api.retryTimer:stop() end
		if closeSocket and api.ws then api.ws:close() end
		local pending = api.pending
		api.ws, api.retryTimer, api.permissions, api.state = nil, nil, nil, nil
		api.pairing, api.queried = false, false
		if pending then pending.fail("connection lost") end
	end

	function obj:_apiSend(action)
		local api = self._api
		api.requestId = api.requestId + 1
		api.ws:send(string.format('{"requestId":%d,"action":"%s","parameters":{}}', api.requestId, action))
		return api.requestId
	end

	function obj:_apiCanToggleMute()
		local api = self._api
		return api ~= nil
			and api.ws ~= nil
			and api.permissions ~= nil
			and api.permissions.canToggleMute == true
			and api.state ~= nil
			and api.state.isMuted ~= nil
			and api.state.isInMeeting ~= false
	end

	-- Teams confirms with a Success response, or with a pushed state whose isMuted flipped.
	-- A rejection, a lost connection or silence for apiConfirmTimeout calls onFail instead.
	function obj:_apiToggleMute(onDone, onFail)
		local api = self._api
		local pending = { before = api.state.isMuted }
		local function settle(fn)
			if api.pending ~= pending then return end
			api.pending = nil
			pending.timer:stop()
			fn()
		end
		function pending.confirm(muted)
			settle(function() onDone(muted) end)
		end
		function pending.fail(reason)
			settle(function()
				self.log.wf("Teams API toggle failed (%s); falling back to the keystroke", reason)
				onFail()
			end)
		end
		pending.timer = hs.timer.doAfter(self.apiConfirmTimeout, function() pending.fail("no confirmation") end)
		api.pending = pending
		pending.requestId = self:_apiSend("toggle-mute")
	end

	function obj:_apiCancelToggle()
		local pending = self._api and self._api.pending
		if not pending then return end
		self._api.pending = nil
		pending.timer:stop()
	end

	function obj:_apiReceive(message)
		local api = self._api
		if self.log.getLogLevel() >= DEBUG_LOG_LEVEL then
			local text = tostring(message)
			if text:find('"tokenRefresh"', 1, true) then
				text = text:gsub('("tokenRefresh"%s*:%s*)"[^"]*"', '%1"<redacted>"')
			end
			self.log.df("Teams API message: %s", text)
		end
		local ok, msg = pcall(hs.json.decode, message)
		if not ok or type(msg) ~= "table" then
			self.log.wf("Unparsable Teams API message: %s", tostring(message))
			return
		end
		if msg.tokenRefresh then
			hs.settings.set(API_TOKEN_KEY, msg.tokenRefresh)
			self.log.i("Teams API token received and saved")
			self:_apiSend("query-state")
		end
		if msg.response == "Pairing response resulted in no action" then
			self.log.i("Teams API pairing not completed; will retry on the next meeting update")
			api.pairing = false
		end
		local pending = api.pending
		if pending and msg.response and msg.requestId == pending.requestId then
			if msg.response == "Success" then
				pending.confirm(not pending.before)
			else
				pending.fail(tostring(msg.response))
			end
		end

		local update = msg.meetingUpdate
		if not update then return end
		local wasReady = self:_apiCanToggleMute()
		local hadState = api.state ~= nil
		api.permissions = update.meetingPermissions or api.permissions
		api.state = update.meetingState or api.state
		if self:_apiCanToggleMute() ~= wasReady then
			self.log.f("Teams API mute control: %s", wasReady and "unavailable" or "ready")
		end
		local canPair = api.permissions and api.permissions.canPair
		if not canPair then
			api.pairing = false
		elseif not api.pairing then
			api.pairing = true
			self.log.i("Teams API pairing requested; approve it in Teams")
			self:_apiSend("pair")
		end
		if not (hadState or update.meetingState or canPair or api.queried) then
			api.queried = true
			self:_apiSend("query-state")
		end
		self:_refreshMenubar()
		local current = api.pending
		if current and api.state and api.state.isMuted ~= nil and api.state.isMuted ~= current.before then
			current.confirm(api.state.isMuted)
		end
	end

	-- Teams pushes its state, so while it's known the AX tree isn't walked. Returns nothing when the
	-- API has no state to offer, leaving the caller to fall back to the tree.
	function obj:_apiMuted()
		local api = self._api
		local state = api and api.ws and api.state
		if not (state and state.isMuted ~= nil) then return nil end
		if state.isInMeeting == false then return nil, "not in a meeting" end
		return state.isMuted
	end

	function obj:_apiLost()
		local api = self._api
		dropConnection(self, false)
		if not api.running then return end
		api.failures = api.failures + 1
		if api.failures > self.apiMaxRetries then
			self.log.wf("Teams API unreachable after %d retries; giving up until Teams restarts", self.apiMaxRetries)
			return
		end
		api.retryTimer = hs.timer.doAfter(self.apiRetryInterval, function() self:_apiConnect() end)
	end

	-- A refused connection is how we learn the API is off. Retries stop after apiMaxRetries, so
	-- enabling the API later takes a Teams restart.
	function obj:_apiConnect()
		local api = apiOf(self)
		dropConnection(self, true)
		local id = api.id
		local url = string.format(
			"ws://localhost:%d?token=%s&protocol-version=2.0.0&manufacturer=Hammerspoon&device=%s&app=%s&app-version=%s",
			self.apiPort,
			urlEncode(hs.settings.get(API_TOKEN_KEY) or ""),
			urlEncode(self.name),
			urlEncode(self.name),
			urlEncode(self.version)
		)
		local function onEvent(kind, message)
			if id ~= api.id then return end
			if kind == "received" then
				self:_apiReceive(message)
			elseif kind == "open" then
				api.failures = 0
				self.log.f("Teams API connected on port %d", self.apiPort)
			elseif kind == "closed" or kind == "fail" then
				self.log.df("Teams API unavailable (%s); retrying in %ds", kind, self.apiRetryInterval)
				self:_apiLost()
			end
		end
		-- An error escaping a websocket callback would only be logged by Hammerspoon, with the
		-- connection state half updated.
		local ws = hs.websocket.new(url, function(...)
			local ok, err = xpcall(onEvent, debug.traceback, ...)
			if not ok then self.log.e("Teams API event failed: " .. tostring(err)) end
		end)
		-- A callback that fired before new() returned has already retired this socket.
		if id == api.id then api.ws = ws end
	end

	function obj:_startApi()
		self:_stopApi()
		local api = apiOf(self)
		api.running = true
		api.failures = 0
		self:_apiConnect()
	end

	function obj:_stopApi()
		local api = apiOf(self)
		api.running = false
		dropConnection(self, true)
	end
end
