-- Real-time quest log for kill/task counters.
--
-- The base Player.updateStorage only refreshes the quest log/tracker when the changed storage is a
-- mission storage (storageId). Kill counters ("You killed %d/50 dragons") live in separate storages
-- that are only *read* by the mission `description` function, so the log stayed stale until relog.
--
-- Here we discover those counter storages automatically: every mission description function is run
-- once against a recording proxy of the player and the storage keys it reads are indexed. When one
-- of them changes, the tracker is refreshed and the quest line is resent to the client.

if not Player.__questCounterBaseUpdateStorage then
	Player.__questCounterBaseUpdateStorage = Player.updateStorage
end

local counterIndex -- [storageKey] = { [questId] = true }

local function buildCounterIndex(realPlayer)
	local index = {}
	for questId in pairs(Quests) do
		local quest = Game.getQuest(questId)
		for missionIndex = 1, quest and quest.missions and #quest.missions or 0 do
			local mission = Game.getMission(questId, missionIndex)
			if mission and type(mission.description) == "function" then
				local keys = {}
				local proxy = setmetatable({}, {
					__index = function(_, name)
						local member = realPlayer[name]
						if type(member) ~= "function" then
							return member
						end
						return function(_, ...)
							if name == "getStorageValue" then
								keys[#keys + 1] = (...)
							end
							return member(realPlayer, ...)
						end
					end,
				})
				pcall(mission.description, proxy)
				for _, key in ipairs(keys) do
					-- mission storages already trigger the base refresh
					if type(key) == "number" and not Game.isQuestStorageKey(key) then
						index[key] = index[key] or {}
						index[key][questId] = true
					end
				end
			end
		end
	end
	return index
end

function Player:updateStorage(key, value, oldValue, currentFrameTime)
	Player.__questCounterBaseUpdateStorage(self, key, value, oldValue, currentFrameTime)

	if value == oldValue or (self.isBotPlayer and self:isBotPlayer()) then
		return
	end

	counterIndex = counterIndex or buildCounterIndex(self)
	local questIds = counterIndex[key]
	if not questIds then
		return
	end

	self:refreshTrackedMissions()
	for questId in pairs(questIds) do
		if self:questIsStarted(questId) then
			self:sendQuestLine(questId)
		end
	end
end
