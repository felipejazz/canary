-- Cleans the items lying on the map floor exactly 3 times a day (the per-save cleaning in
-- save_interval / global_server_save is disabled in config.lua). One warning minute before.

local CLEAN_TIMES = { "06:00:00", "14:00:00", "22:00:00" } -- warning times; the clean happens 60s later
local WARNING_MS = 60 * 1000

local function nextCleanTime()
	local nextWarning = SaveStatus.nextOccurrence(CLEAN_TIMES)
	return nextWarning and nextWarning + WARNING_MS / 1000
end

local function doClean()
	local removed = cleanMap()
	local message = string.format("Map cleaned: %d item(s) removed from the ground.", removed or 0)
	Game.broadcastMessage(message, MESSAGE_GAME_HIGHLIGHT)
	logger.info("[MapClean] " .. message)
	SaveStatus.set({ lastMapClean = os.time(), nextMapClean = nextCleanTime() })
end

for index, timeOfDay in ipairs(CLEAN_TIMES) do
	local event = GlobalEvent("MapClean" .. index)
	function event.onTime(interval)
		Game.broadcastMessage("The map will be cleaned in 1 minute: items on the ground will be removed. Pick up what you want.", MESSAGE_GAME_HIGHLIGHT)
		addEvent(doClean, WARNING_MS)
		return true
	end
	event:time(timeOfDay)
	event:register()
end

SaveStatus.set({ nextMapClean = nextCleanTime() })
