local function ServerSave()
	-- Open the next daily reward claim window before players are kicked and saved
	UpdateDailyRewardServerSave()

	if configManager.getBoolean(configKeys.GLOBAL_SERVER_SAVE_CLEAN_MAP) then
		cleanMap()
	end

	if configManager.getBoolean(configKeys.GLOBAL_SERVER_SAVE_CLOSE) then
		Game.setGameState(GAME_STATE_CLOSED)
	end
	if configManager.getBoolean(configKeys.GLOBAL_SERVER_SAVE_SHUTDOWN) then
		Game.setGameState(GAME_STATE_SHUTDOWN)
	else
		-- No shutdown: save everything in place and keep the server (and players) online.
		saveServer()
		SaveStatus.set({ nextDailySave = SaveStatus.nextOccurrence({ configManager.getString(configKeys.GLOBAL_SERVER_SAVE_TIME) }) })
	end

	-- Reset raid daily counters
	for name, raid in pairs(Raid.registry) do
		raid.kv:set("checks-today", 0)
		raid.kv:set("last-check-date", os.date("%Y%m%d"))
	end
end

local function savingMessage(remainingTime)
	local minutes = remainingTime / 60000
	if configManager.getBoolean(configKeys.GLOBAL_SERVER_SAVE_SHUTDOWN) then
		return "Server is saving the game in " .. minutes .. " minute(s). Please logout."
	end
	return "Server is saving the game in " .. minutes .. " minute(s). You may lag for a few seconds; no restart."
end

local function ServerSaveWarning(time)
	-- Calculate remaining time, minus one minute
	local remainingTime = tonumber(time) - 60000
	if configManager.getBoolean(configKeys.GLOBAL_SERVER_SAVE_NOTIFY_MESSAGE) then
		local message = savingMessage(remainingTime)
		Webhook.sendMessage("Server save", message, WEBHOOK_COLOR_WARNING)
		Game.broadcastMessage(message, MESSAGE_GAME_HIGHLIGHT)
	end

	if remainingTime > 60000 then
		addEvent(ServerSaveWarning, 60000, remainingTime)
	else
		addEvent(ServerSave, 60000)
	end
end

local globalServerSave = GlobalEvent("GlobalServerSave")

-- Function that is called by the global events when it reaches the time configured
-- Interval is the time between the event start and the effective save, it will send a notify message every minute
function globalServerSave.onTime(interval)
	local remainingTime = configManager.getNumber(configKeys.GLOBAL_SERVER_SAVE_NOTIFY_DURATION) * 60000
	if configManager.getBoolean(configKeys.GLOBAL_SERVER_SAVE_NOTIFY_MESSAGE) then
		local message = savingMessage(remainingTime)
		Webhook.sendMessage("Server save", message, WEBHOOK_COLOR_WARNING)
		Game.broadcastMessage(message, MESSAGE_GAME_HIGHLIGHT)
	end

	-- Schedule the next warning event in 1 minute (60000 milliseconds)
	addEvent(ServerSaveWarning, 60000, remainingTime)
	return not configManager.getBoolean(configKeys.GLOBAL_SERVER_SAVE_SHUTDOWN)
end

SaveStatus.set({ nextDailySave = SaveStatus.nextOccurrence({ configManager.getString(configKeys.GLOBAL_SERVER_SAVE_TIME) }) })
globalServerSave:time(configManager.getString(configKeys.GLOBAL_SERVER_SAVE_TIME))
globalServerSave:register()
