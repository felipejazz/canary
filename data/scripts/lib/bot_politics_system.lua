-- ============================================================================
-- Bot Politics & Guild System
-- Manages dynamic bot guild formation, territory (cave) dominance, tax collection,
-- hunted lists, and automated guild war escalations in Canary 15.25.
-- ============================================================================

BotPolitics = BotPolitics or {}

BotPolitics.CONFIG = {
	MIN_AFFINITY_FOR_GUILD = 30,
	MIN_MEMBERS_FOR_GUILD = 3,
	MAX_TERRITORIES_PER_GUILD = 3,
	ULTIMATUM_DURATION = 60, -- 60 seconds to pay tax or leave cave
	PASS_DURATION = 3600, -- 1 hour hunting pass
	HUNTED_EXPIRATION_HOURS = 24, -- hunted status expires after 24 in-game hours
	TERRITORY_ABANDON_HOURS = 48, -- territory becomes abandoned if unvisited for 48h
	WAR_FRAG_LIMIT = 20,
	WAR_DURATION_DAYS = 7,
	BASE_PEACE_FEE = 10000,
	CHECK_INTERVAL_MS = 60000 -- 1 minute periodic evaluate tick
}

-- In-memory caches
BotPolitics.guilds = {} -- [guildId] = { id, name, leader_id, leader_name, alignment, home_city_id, tax_rates = {}, treasury, members = {} }
BotPolitics.guildsByName = {} -- [guildName:lower()] = guildId
BotPolitics.playerGuildMap = {} -- [playerGuid] = guildId
BotPolitics.territories = {} -- [caveId] = { id, cave_id, guild_id, status, last_activity, claimed_at }
BotPolitics.hunted = {} -- [guildId:target_name:lower()] = { id, guild_id, target_name, reason, peace_fee, kills_required, kills_suffered, expires_at }
BotPolitics.passes = {} -- [caveId:player_name:lower()] = valid_until timestamp
BotPolitics.activeUltimatums = {} -- [caveId:player_name:lower()] = { startTime, expiresAt, warnedByGuid, guildId, targetGuid, caveName }
BotPolitics.loaded = false

function BotPolitics.isPlayerInGuild(target)
	if not target then return false end
	local guid = nil
	if type(target) == "number" then
		guid = target
	elseif type(target) == "string" then
		local p = Player(target)
		guid = p and p:getGuid()
	elseif target.getGuid then
		guid = target:getGuid()
	end

	if guid and BotPolitics.playerGuildMap[guid] then
		return true, BotPolitics.playerGuildMap[guid]
	end
	if type(target) ~= "number" and type(target) ~= "string" and target.getGuild and target:getGuild() ~= nil then
		return true, target:getGuild():getId()
	end
	return false
end

-- Procedural Guild Name Generator
local GUILD_PREFIXES = {
	"Shadow", "Iron", "Blood", "Golden", "Ancient", "Ruthless", "Venore",
	"Thais", "Darashia", "Edron", "Silver", "Crimson", "Immortal", "Arcane",
	"Dragon", "Silent", "Vanguard", "Dread", "Storm", "Phoenix", "Dark",
	"Abyssal", "Astral", "Northern", "Solar", "Obsidian", "Mythic"
}

local GUILD_SUFFIXES = {
	"Syndicate", "Legion", "Order", "Brotherhood", "Clan", "Guard",
	"Alliance", "Reapers", "Slayers", "Covenant", "Sentinels", "Hunters",
	"Brigade", "Crusaders", "Dominion", "Knights", "Cartel", "Warriors",
	"Protectors", "Guild", "Conclave"
}

function BotPolitics.generateGuildName()
	local maxAttempts = 50
	for _ = 1, maxAttempts do
		local p = GUILD_PREFIXES[math.random(#GUILD_PREFIXES)]
		local s = GUILD_SUFFIXES[math.random(#GUILD_SUFFIXES)]
		local candidate = p .. " " .. s
		if not BotPolitics.guildsByName[candidate:lower()] then
			-- Verify against MariaDB
			local res = db.storeQuery(string.format("SELECT `id` FROM `guilds` WHERE `name` = %s LIMIT 1", db.escapeString(candidate)))
			if not res then
				return candidate
			end
			Result.free(res)
		end
	end
	return "Guild of " .. os.date("%H%M%S")
end

-- ============================================================================
-- Data Synchronization & Cache Loader
-- ============================================================================

function BotPolitics.loadAll()
	BotPolitics.guilds = {}
	BotPolitics.guildsByName = {}
	BotPolitics.playerGuildMap = {}
	BotPolitics.territories = {}
	BotPolitics.hunted = {}
	BotPolitics.passes = {}

	-- 1. Load Guilds & Metadata
	local gRes = db.storeQuery([[
		SELECT g.`id`, g.`name`, g.`ownerid`, g.`residence`, g.`balance`,
		       bg.`alignment`, bg.`home_city_id`, bg.`tax_rate_tier1`, bg.`tax_rate_tier2`, bg.`tax_rate_tier3`, bg.`treasury`
		FROM `guilds` g
		LEFT JOIN `bot_guild_data` bg ON g.`id` = bg.`guild_id`
	]])

	if gRes then
		repeat
			local gId = Result.getNumber(gRes, "id")
			local gName = Result.getString(gRes, "name")
			local ownerId = Result.getNumber(gRes, "ownerid")
			local residence = Result.getNumber(gRes, "residence")
			local balance = Result.getNumber(gRes, "balance")
			local align = Result.getString(gRes, "alignment") or "NEUTRAL"
			local homeCity = Result.getNumber(gRes, "home_city_id") or residence or 2
			local t1 = Result.getNumber(gRes, "tax_rate_tier1") or 500
			local t2 = Result.getNumber(gRes, "tax_rate_tier2") or 2000
			local t3 = Result.getNumber(gRes, "tax_rate_tier3") or 5000
			local treasury = Result.getNumber(gRes, "treasury") or balance or 0

			BotPolitics.guilds[gId] = {
				id = gId,
				name = gName,
				ownerid = ownerId,
				alignment = align,
				home_city_id = homeCity,
				tax_rates = { [1] = t1, [2] = t2, [3] = t3 },
				treasury = treasury,
				members = {}
			}
			BotPolitics.guildsByName[gName:lower()] = gId
			BotPolitics.playerGuildMap[ownerId] = gId
		until not Result.next(gRes)
		Result.free(gRes)
	end

	-- 2. Load Guild Members
	local mRes = db.storeQuery("SELECT `player_id`, `guild_id`, `rank_id`, `nick` FROM `guild_membership`")
	if mRes then
		repeat
			local pId = Result.getNumber(mRes, "player_id")
			local gId = Result.getNumber(mRes, "guild_id")
			if BotPolitics.guilds[gId] then
				table.insert(BotPolitics.guilds[gId].members, pId)
			end
			BotPolitics.playerGuildMap[pId] = gId
		until not Result.next(mRes)
		Result.free(mRes)
	end

	-- 3. Load Active Territories
	local tRes = db.storeQuery("SELECT `id`, `cave_id`, `guild_id`, `claimed_at`, `last_activity`, `status` FROM `bot_territories` WHERE `status` = 'ACTIVE'")
	if tRes then
		repeat
			local caveId = Result.getString(tRes, "cave_id")
			BotPolitics.territories[caveId] = {
				id = Result.getNumber(tRes, "id"),
				cave_id = caveId,
				guild_id = Result.getNumber(tRes, "guild_id"),
				status = Result.getString(tRes, "status"),
				claimed_at = Result.getString(tRes, "claimed_at")
			}
		until not Result.next(tRes)
		Result.free(tRes)
	end

	-- 4. Load Active Hunted
	local hRes = db.storeQuery("SELECT `id`, `guild_id`, `target_name`, `reason`, `peace_fee`, `kills_required`, `kills_suffered`, `expires_at` FROM `bot_guild_hunted` WHERE `status` = 'ACTIVE' AND `expires_at` > NOW()")
	if hRes then
		repeat
			local gId = Result.getNumber(hRes, "guild_id")
			local tName = Result.getString(hRes, "target_name")
			local key = string.format("%d:%s", gId, tName:lower())
			BotPolitics.hunted[key] = {
				id = Result.getNumber(hRes, "id"),
				guild_id = gId,
				target_name = tName,
				reason = Result.getString(hRes, "reason"),
				peace_fee = Result.getNumber(hRes, "peace_fee"),
				kills_required = Result.getNumber(hRes, "kills_required"),
				kills_suffered = Result.getNumber(hRes, "kills_suffered"),
				expires_at = Result.getString(hRes, "expires_at")
			}
		until not Result.next(hRes)
		Result.free(hRes)
	end

	-- 5. Load Active Passes
	local pRes = db.storeQuery("SELECT `cave_id`, `player_name`, UNIX_TIMESTAMP(`valid_until`) as `exp_ts` FROM `bot_territory_passes` WHERE `valid_until` > NOW()")
	if pRes then
		repeat
			local cId = Result.getString(pRes, "cave_id")
			local pName = Result.getString(pRes, "player_name")
			local key = string.format("%s:%s", cId, pName:lower())
			BotPolitics.passes[key] = Result.getNumber(pRes, "exp_ts")
		until not Result.next(pRes)
		Result.free(pRes)
	end

	BotPolitics.loaded = true
	local gCount = 0
	for _ in pairs(BotPolitics.guilds) do gCount = gCount + 1 end
	local tCount = 0
	for _ in pairs(BotPolitics.territories) do tCount = tCount + 1 end
	local hCount = 0
	for _ in pairs(BotPolitics.hunted) do hCount = hCount + 1 end

	logger.info(string.format("[BotPolitics] Loaded %d guilds, %d active territories, %d hunted records.", gCount, tCount, hCount))
end

-- ============================================================================
-- Guild Creation & Dynamic Founding
-- ============================================================================

function BotPolitics.createGuild(guildName, leaderPlayer, initialMembers, alignment, homeCityId)
	if not leaderPlayer or leaderPlayer:isRemoved() then return false end
	local leaderGuid = leaderPlayer:getGuid()
	local leaderName = leaderPlayer:getName()

	homeCityId = homeCityId or (leaderPlayer:getTown() and leaderPlayer:getTown():getId()) or 2
	alignment = alignment or "NEUTRAL"

	-- Tax rates by alignment
	local taxT1 = 500
	local taxT2 = 2000
	local taxT3 = 5000
	if alignment == "DOMINANDO" then
		taxT1 = 1500
		taxT2 = 5000
		taxT3 = 15000
	elseif alignment == "COMMERCIAL" then
		taxT1 = 800
		taxT2 = 2500
		taxT3 = 6000
	else
		taxT1 = 0
		taxT2 = 0
		taxT3 = 0
	end

	-- 1. Insert into guilds
	local now = os.time()
	local motd = string.format("Bem-vindos a %s! Honra e uniao.", guildName)
	local insertGuildQuery = string.format(
		"INSERT INTO `guilds` (`name`, `ownerid`, `creationdata`, `motd`, `residence`, `balance`, `points`) " ..
		"VALUES (%s, %d, %d, %s, %d, 0, 0)",
		db.escapeString(guildName), leaderGuid, now, db.escapeString(motd), homeCityId
	)

	if not db.query(insertGuildQuery) then
		logger.error(string.format("[BotPolitics] Failed to create guild in guilds table: %s", guildName))
		return false
	end

	local gRes = db.storeQuery(string.format("SELECT `id` FROM `guilds` WHERE `name` = %s LIMIT 1", db.escapeString(guildName)))
	if not gRes then return false end
	local guildId = Result.getNumber(gRes, "id")
	Result.free(gRes)

	-- 2. Insert standard Canary ranks
	db.query(string.format("INSERT INTO `guild_ranks` (`guild_id`, `name`, `level`) VALUES (%d, 'The Leader', 3)", guildId))
	db.query(string.format("INSERT INTO `guild_ranks` (`guild_id`, `name`, `level`) VALUES (%d, 'Vice-Leader', 2)", guildId))
	db.query(string.format("INSERT INTO `guild_ranks` (`guild_id`, `name`, `level`) VALUES (%d, 'Member', 1)", guildId))

	-- Retrieve rank IDs
	local rRes = db.storeQuery(string.format("SELECT `id`, `level` FROM `guild_ranks` WHERE `guild_id` = %d", guildId))
	local rankMap = {}
	if rRes then
		repeat
			rankMap[Result.getNumber(rRes, "level")] = Result.getNumber(rRes, "id")
		until not Result.next(rRes)
		Result.free(rRes)
	end

	local leaderRankId = rankMap[3] or 1
	local viceRankId = rankMap[2] or 1
	local memberRankId = rankMap[1] or 1

	-- 3. Insert metadata in bot_guild_data
	db.query(string.format(
		"INSERT INTO `bot_guild_data` (`guild_id`, `alignment`, `home_city_id`, `tax_rate_tier1`, `tax_rate_tier2`, `tax_rate_tier3`, `treasury`) " ..
		"VALUES (%d, %s, %d, %d, %d, %d, 0) ON DUPLICATE KEY UPDATE `alignment` = %s",
		guildId, db.escapeString(alignment), homeCityId, taxT1, taxT2, taxT3, db.escapeString(alignment)
	))

	-- 4. Insert Leader into membership
	db.query(string.format(
		"INSERT INTO `guild_membership` (`player_id`, `guild_id`, `rank_id`, `nick`) VALUES (%d, %d, %d, 'Leader') " ..
		"ON DUPLICATE KEY UPDATE `guild_id` = %d, `rank_id` = %d",
		leaderGuid, guildId, leaderRankId, guildId, leaderRankId
	))

	-- In-memory update for Leader
	local canaryGuild = Guild(guildId)
	if canaryGuild then
		pcall(function()
			leaderPlayer:setGuild(canaryGuild)
			leaderPlayer:setGuildLevel(3)
			leaderPlayer:setGuildNick("Leader")
		end)
	end

	-- 5. Insert Members into membership
	local memberGuids = { leaderGuid }
	for i, mPlayer in ipairs(initialMembers or {}) do
		if mPlayer and not mPlayer:isRemoved() and mPlayer:getGuid() ~= leaderGuid then
			local mGuid = mPlayer:getGuid()
			local rId = (i == 1) and viceRankId or memberRankId
			local rLvl = (i == 1) and 2 or 1
			local rNick = (i == 1) and "Vice" or "Member"

			db.query(string.format(
				"INSERT INTO `guild_membership` (`player_id`, `guild_id`, `rank_id`, `nick`) VALUES (%d, %d, %d, %s) " ..
				"ON DUPLICATE KEY UPDATE `guild_id` = %d, `rank_id` = %d",
				mGuid, guildId, rId, db.escapeString(rNick), guildId, rId
			))

			if canaryGuild then
				pcall(function()
					mPlayer:setGuild(canaryGuild)
					mPlayer:setGuildLevel(rLvl)
					mPlayer:setGuildNick(rNick)
				end)
			end
			table.insert(memberGuids, mGuid)
		end
	end

	-- Update in-memory cache
	BotPolitics.guilds[guildId] = {
		id = guildId,
		name = guildName,
		ownerid = leaderGuid,
		alignment = alignment,
		home_city_id = homeCityId,
		tax_rates = { [1] = taxT1, [2] = taxT2, [3] = taxT3 },
		treasury = 0,
		members = memberGuids
	}
	BotPolitics.guildsByName[guildName:lower()] = guildId
	BotPolitics.playerGuildMap[leaderGuid] = guildId
	for _, mGuid in ipairs(memberGuids) do
		BotPolitics.playerGuildMap[mGuid] = guildId
	end

	logger.info(string.format(
		"[BotPolitics] New Guild Formed: '%s' (ID: %d, Alignment: %s, Leader: %s, Members: %d, City: %d)",
		guildName, guildId, alignment, leaderName, #memberGuids, homeCityId
	))

	-- Announce in World Broadcast
	Game.broadcastMessage(string.format("[Server Chronicle] A guilda '%s' (%s) foi fundada em nosso mundo sob lideranca de %s!",
		guildName, alignment, leaderName), MESSAGE_GAME_HIGHLIGHT)

	return guildId
end

function BotPolitics.evaluateGuildFounding()
	if not db or not db.storeQuery then return end

	-- Query all pairs with affinity >= MIN_AFFINITY_FOR_GUILD
	local query = string.format([[
		SELECT br.`bot_name`, br.`target_name`, br.`affinity`
		FROM `bot_relationships` br
		WHERE br.`affinity` >= %d AND br.`status` = 'FRIEND'
		ORDER BY br.`affinity` DESC
	]], BotPolitics.CONFIG.MIN_AFFINITY_FOR_GUILD)

	local res = db.storeQuery(query)
	if not res then return end

	-- Build friend graph
	local adj = {}
	repeat
		local b1 = Result.getString(res, "bot_name")
		local b2 = Result.getString(res, "target_name")
		adj[b1] = adj[b1] or {}
		adj[b2] = adj[b2] or {}
		adj[b1][b2] = true
		adj[b2][b1] = true
	until not Result.next(res)
	Result.free(res)

	-- Find connected clusters of bots not yet in any guild
	local visited = {}
	for botName, friends in pairs(adj) do
		if not visited[botName] then
			local cluster = {}
			local queue = { botName }
			visited[botName] = true

			while #queue > 0 do
				local curr = table.remove(queue, 1)
				local p = Player(curr)
				-- Ensure bot is not already in a guild
				local inGuild = BotPolitics.isPlayerInGuild(p or curr)
				if not inGuild then
					table.insert(cluster, curr)
					for neighbor, _ in pairs(adj[curr] or {}) do
						if not visited[neighbor] then
							visited[neighbor] = true
							table.insert(queue, neighbor)
						end
					end
				end
			end

			-- If cluster has sufficient members, found a new guild!
			if #cluster >= BotPolitics.CONFIG.MIN_MEMBERS_FOR_GUILD then
				local playersInCluster = {}
				local totalPersonality = 0
				local leaderCandidate = nil
				local maxLevel = -1

				for _, name in ipairs(cluster) do
					local p = Player(name)
					if p and not p:isRemoved() and not BotPolitics.isPlayerInGuild(p) then
						table.insert(playersInCluster, p)
						local lvl = p:getLevel()
						if lvl > maxLevel then
							maxLevel = lvl
							leaderCandidate = p
						end
						local pState = BotState and BotState[p:getGuid()]
						local pers = pState and pState.personality or 2
						totalPersonality = totalPersonality + pers
					end
				end

				if leaderCandidate and #playersInCluster >= BotPolitics.CONFIG.MIN_MEMBERS_FOR_GUILD then
					local avgPers = totalPersonality / #playersInCluster
					local alignment = "NEUTRAL"
					if avgPers >= 3.8 then
						alignment = "DOMINANDO"
					elseif avgPers >= 2.5 then
						alignment = "COMMERCIAL"
					else
						alignment = "NEUTRAL"
					end

					local gName = BotPolitics.generateGuildName()
					BotPolitics.createGuild(gName, leaderCandidate, playersInCluster, alignment)
					return true -- found one per cycle to avoid spamming
				end
			end
		end
	end
	return false
end

-- ============================================================================
-- Territory & Cave Dominance Management
-- ============================================================================

function BotPolitics.getTerritoryOwner(caveId)
	if not caveId then return nil end
	local t = BotPolitics.territories[caveId]
	if t and t.status == "ACTIVE" then
		return BotPolitics.guilds[t.guild_id]
	end
	return nil
end

function BotPolitics.recordCaveActivity(scriptId, player)
	if not scriptId or not player or player:isRemoved() then return end
	local guild = player:getGuild()
	if not guild then return end
	local guildId = guild:getId()

	local script = BotHuntData and BotHuntData.scripts and BotHuntData.scripts[scriptId]
	local caveName = script and script.name or tostring(scriptId)

	-- Update last activity in MariaDB
	db.asyncQuery(string.format([[
		UPDATE `bot_territories`
		SET `last_activity` = NOW(), `status` = 'ACTIVE'
		WHERE `cave_id` = %s AND `guild_id` = %d
	]], db.escapeString(caveName), guildId))
end

function BotPolitics.evaluateTerritoryClaims()
	if not db or not db.storeQuery then return end

	-- Expire abandoned territories (no activity for > 48h)
	db.query(string.format([[
		UPDATE `bot_territories`
		SET `status` = 'ABANDONED'
		WHERE `status` = 'ACTIVE' AND `last_activity` < NOW() - INTERVAL %d HOUR
	]], BotPolitics.CONFIG.TERRITORY_ABANDON_HOURS))

	-- Clean in-memory cache of abandoned
	for caveId, terr in pairs(BotPolitics.territories) do
		if terr.status == "ABANDONED" then
			BotPolitics.territories[caveId] = nil
		end
	end

	-- Check which guilds are hunting where
	for gId, gData in pairs(BotPolitics.guilds) do
		if gData.alignment == "DOMINANDO" or gData.alignment == "COMMERCIAL" then
			-- Count how many active territories this guild currently has
			local currentClaims = 0
			for _, terr in pairs(BotPolitics.territories) do
				if terr.guild_id == gId and terr.status == "ACTIVE" then
					currentClaims = currentClaims + 1
				end
			end

			if currentClaims < BotPolitics.CONFIG.MAX_TERRITORIES_PER_GUILD then
				-- Inspect caves where members are hunting right now
				for _, mGuid in ipairs(gData.members or {}) do
					local mPlayer = Player(mGuid)
					local mState = mPlayer and BotState and BotState[mGuid]
					if mState and mState.huntScriptId then
						local script = BotHuntData and BotHuntData.scripts and BotHuntData.scripts[mState.huntScriptId]
						local caveName = script and script.name
						if caveName and not BotPolitics.territories[caveName] then
							-- Claim this cave for this guild!
							db.query(string.format([[
								INSERT INTO `bot_territories` (`cave_id`, `guild_id`, `claimed_at`, `last_activity`, `status`)
								VALUES (%s, %d, NOW(), NOW(), 'ACTIVE')
								ON DUPLICATE KEY UPDATE `guild_id` = %d, `status` = 'ACTIVE', `last_activity` = NOW()
							]], db.escapeString(caveName), gId, gId))

							BotPolitics.territories[caveName] = {
								cave_id = caveName,
								guild_id = gId,
								status = "ACTIVE",
								claimed_at = os.date("%Y-%m-%d %H:%M:%S")
							}

							logger.info(string.format("[BotTerritory] Guild '%s' (%s) claimed DOMINION over cave '%s'!",
								gData.name, gData.alignment, caveName))
							currentClaims = currentClaims + 1
							if currentClaims >= BotPolitics.CONFIG.MAX_TERRITORIES_PER_GUILD then
								break
							end
						end
					end
				end
			end
		end
	end
end

-- ============================================================================
-- Passes & Tax Payment System
-- ============================================================================

function BotPolitics.hasValidPass(caveId, playerName)
	if not caveId or not playerName then return false end
	local key = string.format("%s:%s", caveId, playerName:lower())
	local exp = BotPolitics.passes[key]
	if exp and exp > os.time() then
		return true
	end
	return false
end

function BotPolitics.getCaveTaxFee(caveId, guildData)
	local tier = 1
	if BotHuntData and BotHuntData.scripts then
		for _, s in pairs(BotHuntData.scripts) do
			if s.name == caveId then
				local minLvl = s.min_level or 1
				if minLvl >= 100 then
					tier = 3
				elseif minLvl >= 40 then
					tier = 2
				else
					tier = 1
				end
				break
			end
		end
	end
	return guildData.tax_rates[tier] or 2000
end

function BotPolitics.payCaveTax(player, caveId)
	if not player or player:isRemoved() or not caveId then return false, "Jogador ou cave invalida." end
	local terr = BotPolitics.territories[caveId]
	if not terr or terr.status ~= "ACTIVE" then
		return false, "Esta cave nao esta dominada por nenhuma guilda no momento."
	end

	local guildData = BotPolitics.guilds[terr.guild_id]
	if not guildData then
		return false, "Guilda dona do territorio nao encontrada."
	end

	if guildData.alignment == "NEUTRAL" then
		return false, "Esta guilda e neutra e nao cobra taxa de caça!"
	end

	local fee = BotPolitics.getCaveTaxFee(caveId, guildData)
	if fee <= 0 then
		return false, "Esta cave esta liberada gratuitamente."
	end

	-- Check and deduct money (from inventory and/or bank)
	local removed = false
	pcall(function()
		removed = player:removeMoney(fee, 0, true)
	end)

	if not removed then
		return false, string.format("Voce nao tem dinheiro suficiente (%d gps) na mochila ou no banco.", fee)
	end

	-- Credit guild treasury
	guildData.treasury = guildData.treasury + fee
	db.asyncQuery(string.format([[
		UPDATE `bot_guild_data` SET `treasury` = `treasury` + %d WHERE `guild_id` = %d
	]], fee, guildData.id))

	local cGuild = Guild(guildData.id)
	if cGuild then
		pcall(function() cGuild:setBankBalance(cGuild:getBankBalance() + fee) end)
	end

	-- Grant Pass
	local pName = player:getName()
	local validUntil = os.time() + BotPolitics.CONFIG.PASS_DURATION
	local passKey = string.format("%s:%s", caveId, pName:lower())
	BotPolitics.passes[passKey] = validUntil

	db.asyncQuery(string.format([[
		INSERT INTO `bot_territory_passes` (`cave_id`, `player_name`, `paid_amount`, `valid_until`)
		VALUES (%s, %s, %d, FROM_UNIXTIME(%d))
	]], db.escapeString(caveId), db.escapeString(pName), fee, validUntil))

	-- Clear active ultimatum if any
	BotPolitics.activeUltimatums[passKey] = nil

	logger.info(string.format("[BotTax] %s paid %d gps tax to Guild '%s' for cave '%s' (Pass until %s)",
		pName, fee, guildData.name, caveId, os.date("%H:%M:%S", validUntil)))

	return true, fee, guildData.name, validUntil
end

-- ============================================================================
-- HUNTED & Conflict System
-- ============================================================================

function BotPolitics.isPlayerHunted(guildId, playerName)
	if not playerName then return false end
	if guildId then
		local key = string.format("%d:%s", guildId, playerName:lower())
		local h = BotPolitics.hunted[key]
		return h ~= nil
	else
		-- Check against all guilds
		for _, h in pairs(BotPolitics.hunted) do
			if h.target_name:lower() == playerName:lower() then
				return true, h.guild_id
			end
		end
		return false
	end
end

function BotPolitics.declareHunted(guildId, targetName, reason, peaceFee)
	local guildData = BotPolitics.guilds[guildId]
	if not guildData or not targetName then return false end

	peaceFee = peaceFee or BotPolitics.CONFIG.BASE_PEACE_FEE
	local expiresAt = os.time() + (BotPolitics.CONFIG.HUNTED_EXPIRATION_HOURS * 3600)
	local key = string.format("%d:%s", guildId, targetName:lower())

	db.query(string.format([[
		INSERT INTO `bot_guild_hunted` (`guild_id`, `target_name`, `reason`, `peace_fee`, `kills_required`, `kills_suffered`, `expires_at`, `status`)
		VALUES (%d, %s, %s, %d, 1, 0, FROM_UNIXTIME(%d), 'ACTIVE')
		ON DUPLICATE KEY UPDATE `reason` = %s, `peace_fee` = %d, `expires_at` = FROM_UNIXTIME(%d), `status` = 'ACTIVE'
	]], guildId, db.escapeString(targetName), db.escapeString(reason), peaceFee, expiresAt,
	    db.escapeString(reason), peaceFee, expiresAt))

	BotPolitics.hunted[key] = {
		guild_id = guildId,
		target_name = targetName,
		reason = reason,
		peace_fee = peaceFee,
		kills_required = 1,
		kills_suffered = 0,
		expires_at = os.date("%Y-%m-%d %H:%M:%S", expiresAt)
	}

	-- Update bot relationships for all members of this guild
	for _, mGuid in ipairs(guildData.members or {}) do
		local mPlayer = Player(mGuid)
		if mPlayer and not mPlayer:isRemoved() then
			BotSystem.setRelationship(mPlayer:getName(), targetName, "PK_TARGET", -30, "HUNTED_DECLARED", "Guild hunted: " .. reason)
		end
	end

	logger.info(string.format("[BotHunted] GUILD '%s' DECLARED HUNTED ON '%s'! Reason: %s (Peace Fee: %d gps)",
		guildData.name, targetName, reason, peaceFee))

	-- Send guild notification
	for _, mGuid in ipairs(guildData.members or {}) do
		local mp = Player(mGuid)
		if mp and not mp:isRemoved() then
			mp:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("[Guild Intel] HUNTED DECLARADO: %s! Motivo: %s. Recompensa ativa!", targetName, reason))
		end
	end

	-- If target is online, inform them
	local targetPlayer = Player(targetName)
	if targetPlayer and not targetPlayer:isRemoved() then
		targetPlayer:sendTextMessage(MESSAGE_GAME_HIGHLIGHT, string.format("Voce foi marcado como HUNTED pela guilda '%s'! Motivo: %s. Quitação: !peace %s",
			guildData.name, reason, guildData.name))
	end

	return true
end

function BotPolitics.clearHunted(guildId, targetName, resolution)
	resolution = resolution or "PAID"
	local key = string.format("%d:%s", guildId, targetName:lower())
	BotPolitics.hunted[key] = nil

	db.query(string.format([[
		UPDATE `bot_guild_hunted` SET `status` = %s
		WHERE `guild_id` = %d AND LOWER(`target_name`) = %s AND `status` = 'ACTIVE'
	]], db.escapeString(resolution), guildId, db.escapeString(targetName:lower())))

	local guildData = BotPolitics.guilds[guildId]
	if guildData then
		for _, mGuid in ipairs(guildData.members or {}) do
			local mp = Player(mGuid)
			if mp and not mp:isRemoved() then
				BotSystem.setRelationship(mp:getName(), targetName, "NEUTRAL", 10, "HUNTED_RESOLVED", "Hunted cleared: " .. resolution)
			end
		end
	end

	logger.info(string.format("[BotHunted] Hunted status on '%s' resolved by Guild %d (%s).", targetName, guildId, resolution))
end

function BotPolitics.payPeaceFee(player, guildNameOrId)
	if not player or player:isRemoved() then return false, "Jogador invalido." end
	local pName = player:getName()

	local targetGuildId = nil
	if type(guildNameOrId) == "number" then
		targetGuildId = guildNameOrId
	elseif type(guildNameOrId) == "string" then
		targetGuildId = BotPolitics.guildsByName[guildNameOrId:lower()]
	end

	-- If no guild specified, find first active hunted record
	local huntedRecord = nil
	if targetGuildId then
		local key = string.format("%d:%s", targetGuildId, pName:lower())
		huntedRecord = BotPolitics.hunted[key]
	else
		for _, h in pairs(BotPolitics.hunted) do
			if h.target_name:lower() == pName:lower() then
				huntedRecord = h
				targetGuildId = h.guild_id
				break
			end
		end
	end

	if not huntedRecord or not targetGuildId then
		return false, "Voce nao esta marcado como hunted por essa guilda."
	end

	local gData = BotPolitics.guilds[targetGuildId]
	local fee = huntedRecord.peace_fee or BotPolitics.CONFIG.BASE_PEACE_FEE

	local removed = false
	pcall(function()
		removed = player:removeMoney(fee, 0, true)
	end)

	if not removed then
		return false, string.format("Voce precisa de %d gps no banco ou na mochila para pagar a taxa de paz da guilda %s.", fee, gData and gData.name or "")
	end

	-- Credit guild treasury
	if gData then
		gData.treasury = gData.treasury + fee
		db.asyncQuery(string.format("UPDATE `bot_guild_data` SET `treasury` = `treasury` + %d WHERE `guild_id` = %d", fee, targetGuildId))
	end

	BotPolitics.clearHunted(targetGuildId, pName, "PAID")

	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("Voce pagou %d gps e sua divida de HUNTED com a guilda '%s' foi totalmente perdoada!",
		fee, gData and gData.name or ""))
	return true, fee, gData and gData.name or ""
end

-- ============================================================================
-- Cave Intrusion & Ultimatum Management
-- ============================================================================

function BotPolitics.checkIntruderUltimatum(intruder, scriptId, occupant)
	if not intruder or intruder:isRemoved() or not occupant or occupant:isRemoved() then return end
	local script = BotHuntData and BotHuntData.scripts and BotHuntData.scripts[scriptId]
	local caveName = script and script.name or tostring(scriptId)

	local terr = BotPolitics.territories[caveName]
	if not terr or terr.status ~= "ACTIVE" then return end

	local guildData = BotPolitics.guilds[terr.guild_id]
	if not guildData then return end

	local intruderName = intruder:getName()
	local intruderGuid = intruder:getGuid()
	local occGuid = occupant:getGuid()

	-- Check if intruder is in same guild or in party with occupant
	local intGuild = intruder:getGuild()
	if intGuild and intGuild:getId() == terr.guild_id then return end
	local occParty = occupant:getParty()
	if occParty and intruder:getParty() == occParty then return end

	-- Check if intruder has a valid pass
	if BotPolitics.hasValidPass(caveName, intruderName) then return end

	-- If Neutral Guild: offer friendly party share instead of tax/ultimatum!
	if guildData.alignment == "NEUTRAL" then
		-- Handled by normal cavebot friendly negotiation
		return
	end

	-- Commercial or Dominando Guild: Ultimatum!
	local ultKey = string.format("%s:%s", caveName, intruderName:lower())
	local ult = BotPolitics.activeUltimatums[ultKey]
	local now = os.time()

	if not ult then
		-- Start 60-second countdown
		local fee = BotPolitics.getCaveTaxFee(caveName, guildData)
		BotPolitics.activeUltimatums[ultKey] = {
			startTime = now,
			expiresAt = now + BotPolitics.CONFIG.ULTIMATUM_DURATION,
			warnedByGuid = occGuid,
			guildId = terr.guild_id,
			targetGuid = intruderGuid,
			caveName = caveName
		}

		local warningMsg = string.format(
			"Atencao %s! Esta cave e dominio da guilda '%s'. Taxa: %d gps/hora. Pague com '!pagar' ou saia em 60s sob pena de virar HUNTED!",
			intruderName, guildData.name, fee
		)
		occupant:say(warningMsg, TALKTYPE_SAY)
		BotSystem.sendBotPrivateMessage(occupant, intruder, warningMsg)
		logger.info(string.format("[BotUltimatum] %s issued 60s ultimatum to %s in cave '%s' (Guild: %s)",
			occupant:getName(), intruderName, caveName, guildData.name))

	elseif now >= ult.expiresAt then
		-- Ultimatum Expired and Intruder still here!
		BotPolitics.activeUltimatums[ultKey] = nil
		local shout = string.format("Voce foi avisado %s! Nao pagou e nao saiu! Agora voce e HUNTED pela '%s'!", intruderName, guildData.name)
		occupant:say(shout, TALKTYPE_SAY)

		BotPolitics.declareHunted(terr.guild_id, intruderName, "Invasao de cave dominada: " .. caveName, 10000)

		-- Trigger immediate PK Attack
		local oState = BotState and BotState[occGuid]
		if oState then
			BotSystem.clearAllTasks(occupant, oState)
			oState.state = BOT_STATE.PK_ATTACK
			oState.pkTarget = intruder:getId()
			occupant:setTarget(intruder)
		end
	end
end

-- ============================================================================
-- Canary Guild Wars Dynamic Escalation
-- ============================================================================

function BotPolitics.declareWar(guildId1, guildId2, reason)
	local g1 = BotPolitics.guilds[guildId1]
	local g2 = BotPolitics.guilds[guildId2]
	if not g1 or not g2 or guildId1 == guildId2 then return false end

	-- Check if war already exists between them
	local res = db.storeQuery(string.format([[
		SELECT `id` FROM `guild_wars`
		WHERE ((`guild1` = %d AND `guild2` = %d) OR (`guild1` = %d AND `guild2` = %d)) AND `status` = 1 LIMIT 1
	]], guildId1, guildId2, guildId2, guildId1))

	if res then
		Result.free(res)
		return false -- War already active
	end

	local now = os.time()
	local ended = now + (BotPolitics.CONFIG.WAR_DURATION_DAYS * 86400)

	db.query(string.format([[
		INSERT INTO `guild_wars` (`guild1`, `guild2`, `name1`, `name2`, `status`, `started`, `ended`, `frags_limit`, `payment`, `duration_days`)
		VALUES (%d, %d, %s, %s, 1, %d, %d, %d, 0, %d)
	]], guildId1, guildId2, db.escapeString(g1.name), db.escapeString(g2.name), now, ended, BotPolitics.CONFIG.WAR_FRAG_LIMIT, BotPolitics.CONFIG.WAR_DURATION_DAYS))

	logger.info(string.format("[BotWar] OFFICIAL GUILD WAR DECLARED: '%s' VS '%s' (Frag Limit: %d)!",
		g1.name, g2.name, BotPolitics.CONFIG.WAR_FRAG_LIMIT))

	Game.broadcastMessage(string.format("[Guild War] GUERRA DECLARADA! A guilda '%s' entrou em guerra oficial contra a guilda '%s'!",
		g1.name, g2.name), MESSAGE_GAME_HIGHLIGHT)

	return true
end

-- Periodic background check for politics engine
function BotPolitics.onThinkPeriodic()
	if not BotPolitics.loaded then
		BotPolitics.loadAll()
	end

	-- 1. Check for new guilds to be formed from friendships
	pcall(BotPolitics.evaluateGuildFounding)

	-- 2. Check and evaluate cave territories
	pcall(BotPolitics.evaluateTerritoryClaims)
end

-- Auto-load caches on file load
pcall(BotPolitics.loadAll)
