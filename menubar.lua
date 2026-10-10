-- vim: set ft=lua:

-- The menu bar indicator, loaded by init.lua, which documents the settings it reads. It adds
-- `_refreshMenubar`, `_startPoll` and `_stopPoll` to the TeamsControl object; the mute state it
-- shows comes from `_currentMuted`.

return function(obj)
	local function refreshMenubar(self)
		local muted, reason = self:_currentMuted()
		local state = muted == nil and ("hidden: " .. reason) or muted and "muted" or "unmuted"
		if state ~= self._menubarState then
			self.log.f("Menu bar indicator: %s", state)
			self._menubarState = state
		end
		if muted == nil then
			if self._menubar then self._menubar:delete() end
			self._menubar = nil
			return
		end
		-- Created visible and named rather than hidden and re-shown: returnToMenuBar()
		-- drops the autosave name, so macOS would forget the item's position.
		if not self._menubar then
			self._menubar = hs.menubar.new(true, self.name)
			self._menubar:setClickCallback(function() self:toggleMute() end)
		end
		self._menubar:setIcon(
			hs.image.imageFromName(muted and "NSTouchBarAudioInputMuteTemplate" or "NSTouchBarAudioInputTemplate"),
			true
		)
		if self.menubarStatusDot then self._menubar:setTitle(muted and "🟡" or "🟢") end
	end

	-- A no-op once stopped, so a click's toggle settling late can't resurrect the
	-- item. AX reads can throw while Teams re-renders, and hs.timer stops a
	-- repeating timer whose callback throws.
	function obj:_refreshMenubar()
		if not self._menubarTimer then return end
		local ok, err = xpcall(refreshMenubar, debug.traceback, self)
		if not ok then self.log.e("Menu bar refresh failed: " .. tostring(err)) end
	end

	function obj:_startPoll()
		if self._menubarTimer then return end
		self._menubarTimer = hs.timer.doEvery(self.menubarPollInterval, function() self:_refreshMenubar() end)
		self:_refreshMenubar()
	end

	function obj:_stopPoll()
		if self._menubarTimer then self._menubarTimer:stop() end
		if self._menubar then self._menubar:delete() end
		self._menubarTimer = nil
		self._menubar = nil
		self._menubarState = nil
	end
end
