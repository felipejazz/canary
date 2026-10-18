-- ============================================================================
-- Bot Manager -- Load bots on startup
-- Bots load at their last saved position (players.posx/y/z from normal server save).
-- Inactive bots are truly offline — removed from the world when deactivated.
-- Use /cavebot <name> active|inactive to control bots.
-- ============================================================================

-- Staging position — kept as fallback for brand-new bots with no prior loginPosition.
-- INACTIVE_STAGING_POS is no longer used as the "home" for inactive bots.
-- local INACTIVE_STAGING_POS = Position(31970, 32283, 7)

-- Startup: load all bot players from database
local botStartup = GlobalEvent("BotStartup")

function botStartup.onStartup()
	if BOT_CONFIG.MASTER_DISABLE then
		logger.warn("[BotManager] MASTER_DISABLE=true — bot startup skipped (lag-investigation Test 1)")
		return true
	end
	logger.info("[BotManager] Starting bot system...")
	if BotHuntData and BotHuntData.ensureLoaded then
		BotHuntData.ensureLoaded()
	end

	-- Clear stale cast_broadcasters from previous run/crash
	db.query("DELETE FROM `cast_broadcasters`")

	-- BOT_LIVENESS_PACK Phase C.1: visual-identity reroll. Every server restart
	-- shuffles each bot's looktype + addons + colors + mount + mount colors.
	-- Bots ALREADY own the full catalog (mounts + outfits via player_storage seeded
	-- by tools/bot_population_generator/generate.py) — these UPDATEs just pick a
	-- different row from the owned set. Runs BEFORE Game.loadBotPlayer below so
	-- the in-memory Player object reads the fresh values on load. ~3 sync queries,
	-- ~150ms total blocking time (negligible vs the rest of startup).
	-- Only triggers at GLOBALEVENT_STARTUP — /cavebot reload does NOT hit this
	-- path (it goes through createBotEngine + bot re-registration without touching
	-- this onStartup), which matches the user's "reroll every daily restart" intent.
	local rerollOnRestart = false
	if configKeys and configKeys.BOT_PERSONALITY_REROLL_ON_RESTART then
		pcall(function() rerollOnRestart = configManager.getBoolean(configKeys.BOT_PERSONALITY_REROLL_ON_RESTART) end)
	end
	if rerollOnRestart then
		logger.info("[BotManager] Rerolling visual identity (looktype + addons + colors + mount) for all bots...")
		-- 1. Pick a random OWNED outfit (lookType<<16|addons) per bot from player_storage.
		--    MySQL 8.0 window function — runs in <100ms for ~123k storage rows.
		db.query([[
			UPDATE players p
			INNER JOIN (
				SELECT player_id, value,
				       ROW_NUMBER() OVER (PARTITION BY player_id ORDER BY RAND()) AS rn
				  FROM player_storage
				 WHERE `key` BETWEEN 10001001 AND 10001500
			) s ON p.id = s.player_id AND s.rn = 1
			   SET p.looktype = FLOOR(s.value / 65536),
			       p.lookaddons = FLOOR(RAND() * 4)
			 WHERE p.account_id = ]] .. BOT_CONFIG.BOT_ACCOUNT_ID)
		-- 2. Randomize the four outfit-color bytes + four mount-color bytes (palette 0..132).
		db.query([[
			UPDATE players SET
			  lookbody      = FLOOR(RAND() * 133),
			  lookfeet      = FLOOR(RAND() * 133),
			  lookhead      = FLOOR(RAND() * 133),
			  looklegs      = FLOOR(RAND() * 133),
			  lookmountbody = FLOOR(RAND() * 133),
			  lookmountfeet = FLOOR(RAND() * 133),
			  lookmounthead = FLOOR(RAND() * 133),
			  lookmountlegs = FLOOR(RAND() * 133)
			WHERE account_id = ]] .. BOT_CONFIG.BOT_ACCOUNT_ID)
		-- 3. Pick a random mount id 1..235 as the current mount. mountChancePct (in
		--    bot_engine.cpp activateBot) decides whether the bot is actually mounted.
		db.query([[
			UPDATE player_storage ps
			INNER JOIN players p ON p.id = ps.player_id
			   SET ps.value = FLOOR(1 + RAND() * 235)
			 WHERE p.account_id = ]] .. BOT_CONFIG.BOT_ACCOUNT_ID .. [[
			   AND ps.`key` = 10002011]])
		logger.info("[BotManager] Visual identity reroll complete.")
	end

	-- Ensure staging tile exists for brand-new bots that have no prior loginPosition
	Game.createTile(Position(31970, 32283, 7), true)

	-- Query all bot characters ordered by id ASC (= level ASC, since bots are seeded sorted by level).
	-- We fetch all then stratify in Lua so any TARGET_ONLINE < total still covers the full
	-- level/vocation range (otherwise LIMIT N would clip to the lowest-level slice).
	local query = "SELECT `id`, `name` FROM `players` WHERE (`account_id` = " .. BOT_CONFIG.BOT_ACCOUNT_ID
		.. " OR `name` LIKE 'Bot %') AND `deletion` = 0 ORDER BY `id` ASC"

	local resultId = db.storeQuery(query)

	if not resultId then
		logger.warn("[BotManager] No bot players found in database (account_id=" ..
			BOT_CONFIG.BOT_ACCOUNT_ID .. ")")
		return true
	end

	local allBotNames = {}
	repeat
		table.insert(allBotNames, Result.getString(resultId, "name"))
	until not Result.next(resultId)
	Result.free(resultId)

	-- Stratified selection: evenly-spaced indices across [1, total] so we get diverse levels
	-- + vocations regardless of TARGET_ONLINE. Deterministic across restarts so
	-- bot_state_persistence rows stay coherent.
	local total = #allBotNames
	local target = BOT_CONFIG.TARGET_ONLINE
	if configKeys and configKeys.BOT_PLAYERS_ONLINE then
		pcall(function()
			local cfgVal = configManager.getNumber(configKeys.BOT_PLAYERS_ONLINE)
			if cfgVal and cfgVal > 0 then target = cfgVal end
		end)
	end
	local botNames = {}

	if target <= 5 then
		local preferredTestBots = { "Bot Titus", "Bot Kallum", "Bot Eamon", "Bot Valdemar", "Bot Sylas" }
		local inDb = {}
		for _, n in ipairs(allBotNames) do inDb[n] = true end
		for _, pref in ipairs(preferredTestBots) do
			if #botNames < target and inDb[pref] then
				table.insert(botNames, pref)
			end
		end
	end

	-- 2026-05-28 test override: when target == 1 AND BOT_CONFIG.SINGLE_BOT_NAME is set,
	-- load that specific bot (useful for isolated cast-watch perf testing on a chosen
	-- high-level character rather than the lowest-id bot stratification picker would return).
	if #botNames == 0 and target == 1 and BOT_CONFIG.SINGLE_BOT_NAME and BOT_CONFIG.SINGLE_BOT_NAME ~= "" then
		local found = false
		for _, n in ipairs(allBotNames) do
			if n == BOT_CONFIG.SINGLE_BOT_NAME then
				table.insert(botNames, n)
				found = true
				break
			end
		end
		if not found then
			logger.warn("[BotManager] SINGLE_BOT_NAME '" .. BOT_CONFIG.SINGLE_BOT_NAME ..
				"' not in DB; falling back to stratified pick")
		end
	end

	if #botNames == 0 then
		if target >= total then
			botNames = allBotNames
		else
			for i = 0, target - 1 do
				local idx = math.floor(i * total / target) + 1
				table.insert(botNames, allBotNames[idx])
			end
		end

		-- 2026-05-28 extension: when target > 1 AND SINGLE_BOT_NAME is set, ensure the
		-- named bot is in the picked set. If missing, replace the last entry with it.
		-- Keeps the stratified diversity while guaranteeing the cast-watched bot is loaded.
		if target > 1 and BOT_CONFIG.SINGLE_BOT_NAME and BOT_CONFIG.SINGLE_BOT_NAME ~= "" then
			local already = false
			for _, n in ipairs(botNames) do
				if n == BOT_CONFIG.SINGLE_BOT_NAME then already = true; break end
			end
			if not already then
				-- Verify the named bot exists in DB
				local existsInDB = false
				for _, n in ipairs(allBotNames) do
					if n == BOT_CONFIG.SINGLE_BOT_NAME then existsInDB = true; break end
				end
				if existsInDB then
					botNames[#botNames] = BOT_CONFIG.SINGLE_BOT_NAME
					logger.info("[BotManager] Forced inclusion of '" .. BOT_CONFIG.SINGLE_BOT_NAME ..
						"' replacing last stratified pick")
				else
					logger.warn("[BotManager] SINGLE_BOT_NAME '" .. BOT_CONFIG.SINGLE_BOT_NAME ..
						"' not in DB; using stratified pick as-is")
				end
			end
		end
	end

	logger.info("[BotManager] Found " .. total .. " bots in database, loading "
		.. #botNames .. " (stratified across level/vocation) as INACTIVE...")

	-- Load bots with staggered timing to avoid startup spike (100ms per bot)
	for i, name in ipairs(botNames) do
		addEvent(function()
			local player = Game.loadBotPlayer(name)
			if player then
				local guid = player:getGuid()
				BotPlayers[guid] = player

				-- Register death handler
				player:registerEvent("BotDeath")

				-- Log every 10th bot
				if i % 10 == 0 or i == #botNames then
					logger.info("[BotManager] Loaded bot " .. i .. "/" .. #botNames .. ": " .. name)
				end
			else
				logger.warn("[BotManager] Failed to load bot: " .. name)
			end

			-- After all bots loaded, set required quest/access storages
			if i == #botNames then
				-- PERF_INVESTIGATION_2026-05-28: sync bot rows into players_online
				-- exactly once after loading completes. Previously Game::updatePlayersOnline
				-- enumerated every active bot guid into a sync INSERT/DELETE pair on the
				-- dispatcher every 10 minutes; at bots=500 that was ~500ms of dispatcher
				-- blockage. The C++ sweep no longer touches bot rows (account_id=65000
				-- filter in DELETE); we replace the whole bot row set here via async
				-- queries so the dispatcher is never blocked, and re-sync on /cavebot
				-- reload too (this same loading path runs on reload).
				local showAsOnline = true
				if configKeys and configKeys.BOT_PLAYERS_SHOW_AS_ONLINE then
					pcall(function() showAsOnline = configManager.getBoolean(configKeys.BOT_PLAYERS_SHOW_AS_ONLINE) end)
				end
				if showAsOnline then
					local botGuids = {}
					for guid, _ in pairs(BotPlayers) do
						table.insert(botGuids, tostring(guid))
					end
					if #botGuids > 0 then
						local guidList = table.concat(botGuids, ",")
						db.botAsyncQuery(string.format(
							"DELETE FROM `players_online` WHERE `player_id` IN (SELECT `id` FROM `players` WHERE `account_id` = 65000 OR `account_id` BETWEEN 77 AND 151 OR `name` LIKE 'Bot %%') AND `player_id` NOT IN (%s)",
							guidList))
						local valueRows = {}
						for _, g in ipairs(botGuids) do
							table.insert(valueRows, "(" .. g .. ")")
						end
						db.botAsyncQuery("INSERT IGNORE INTO `players_online` (`player_id`) VALUES " .. table.concat(valueRows, ","))
						logger.info("[BotManager] Synced " .. #botGuids .. " bot rows to players_online (async)")
					end
				end

				addEvent(function()
					-- Set quest storages so bots can use wagons, shrines, levers, teleports
					local storageCount = 0
					for guid, player in pairs(BotPlayers) do
						BotSystem.applyQuestStorages(player)
						storageCount = storageCount + 1
					end
					logger.info("[BotManager] Set " .. storageCount .. " bot quest/access storages (wagons, shrines, quests)")
					-- Ativa todos os bots carregados no ecossistema
					for guid, botPlayer in pairs(BotPlayers) do
						local ok, err = pcall(BotSystem.activateBot, botPlayer)
						if not ok then
							logger.error("[BotManager] Erro ao ativar bot " .. (botPlayer and botPlayer:getName() or tostring(guid)) .. ": " .. tostring(err))
						elseif #botNames <= 10 and BotState and BotState[guid] then
							BotState[guid].verboseLog = true
							BotState[guid].verboseLogAutoEnabled = true
						end
					end
					logger.info("[BotManager] Todos os " .. #botNames .. " bots foram carregados e ATIVADOS no mundo!")

					-- Check for persisted state restore (500ms after last bot is registered)
					addEvent(function()
						local cfgResult = db.storeQuery(
							"SELECT `config_value` FROM `bot_startup_config` WHERE `config_key` = 'should_restore_states'"
						)
						if cfgResult then
							local val = Result.getString(cfgResult, "config_value")
							Result.free(cfgResult)
							if val == "1" then
								if Game.botRestoreStates then
									Game.botRestoreStates()
								end
								-- restoreAllStates() already deletes bot_state_persistence rows internally.
								-- Clear the flag so a crash before next graceful shutdown doesn't re-restore stale data.
								db.botAsyncQuery("UPDATE `bot_startup_config` SET `config_value`='0' WHERE `config_key`='should_restore_states'")
								logger.info("[BotManager] Bot state restore complete. Restore flag cleared.")
							else
								logger.info("[BotManager] No restore flag — bots activating fresh.")
							end
						else
							logger.warn("[BotManager] bot_startup_config not found — bots activate fresh.")
						end
					end, 500)
				end, 2000)
			end
		end, i * 100)
	end

	return true
end

botStartup:register()

-- Population manager: DISABLED — only polls bot_commands table for admin control
-- Max bytes of a command result persisted to bot_commands.result.
-- The column is TEXT (65535 BYTES), and db.escapeString can at worst double the length, so
-- 32000 is the largest provably safe cap. The previous value was 4096, which silently truncated
-- longer replies with no error -- the perf harness reads structured output back through this
-- channel, and a half-JSON reply parses as garbage rather than failing loudly.
local BOT_CMD_RESULT_MAX = 32000

local botManager = GlobalEvent("BotManager")

function botManager.onThink(interval)
	-- Global command queue poll (so MySQL-based commands still work).
	-- JITTER FIX 2026-06-10: async — the sync db.storeQuery blocked the dispatcher
	-- for the full round-trip incl. databaseLock convoy behind worker-thread DB
	-- bursts (measured 376ms and 643ms tonight via DB_SYNC_SLOW). Command
	-- processing becomes eventually-consistent within the same 10s window.
	db.botAsyncStoreQuery(
		"SELECT `id`, `bot_name`, `command` FROM `bot_commands` WHERE `processed` = 0 ORDER BY `id` ASC LIMIT 10",
		function(cmdResult)
	if cmdResult then
		repeat
			local cmdId = Result.getNumber(cmdResult, "id")
			local botName = Result.getString(cmdResult, "bot_name")
			local cmd = Result.getString(cmdResult, "command")

			local resultText
			-- Global reload: parse `reload [debug,N | debug off]`
			-- _global / reload              → plain hot-reload, preserve current active set
			-- _global / reload debug,1      → hot-reload + activate 1 bot with debug stream
			-- _global / reload debug off    → hot-reload + activate all bots, clear debug
			local low = cmd:lower()
			if botName == "_global" and (low == "reload" or low:match("^reload%s")) then
				local opts = { source = "queue" }
				-- Parse from `cmd` (original case), NOT `low` — bot names must survive.
				local dbgSpec, dbgNames = BotSystem.parseDebugSpec(cmd)
				if dbgSpec then
					opts.debugCount = dbgSpec
					opts.debugBotNames = dbgNames
				end
				local rv = BotSystem.executeReload(opts)
				resultText = (rv and rv.message) or "reload returned nil"
			elseif botName == "_global" and (low:match("^set_population%s+") or low:match("^population%s+") or low:match("^scale%s+")) then
				local targetCount = tonumber(cmd:match("%d+")) or 0
				local rv = BotSystem.setPopulation(targetCount, { source = "queue" })
				resultText = (rv and rv.message) or ("População ajustada para " .. targetCount)
			elseif botName == "_global" and (low == "hard_reset" or low == "hardreset" or low == "reset hard") then
				local count = BotSystem.hardResetAllBots()
				resultText = "Hard reset executed: " .. count .. " online bots reset to fresh level 8"
			elseif low:match("^apply_edit") then
				local targetPlayer = Player(botName)
				if targetPlayer then
					local bState = (BotState and BotState[targetPlayer:getGuid()]) or nil
					resultText = BotSystem.executeCavebotCommand(targetPlayer, bState, cmd) or "OK"
				else
					resultText = "Player '" .. botName .. "' offline"
				end
			elseif low:match("^bot_toggle%s+") then
				local targetName, action = cmd:match("^%S+%s+[\"']?(.-)[\"']?%s+(%S+)$")
				if not targetName or not action then
					resultText = "Usage: bot_toggle <bot_name> <connect|disconnect>"
				else
					action = action:lower()
					if action == "connect" or action == "on" then
						local p = Player(targetName)
						if p then
							resultText = targetName .. " is already online"
						else
							local newP = Game.loadBotPlayer(targetName)
							if newP then
								local guid = newP:getGuid()
								BotPlayers[guid] = newP
								newP:registerEvent("BotDeath")
								pcall(BotSystem.activateBot, newP)
								db.botAsyncQuery("INSERT IGNORE INTO `players_online` (`player_id`) VALUES (" .. guid .. ")")
								resultText = "Loaded and activated " .. targetName
							else
								resultText = "Failed to load " .. targetName
							end
						end
					elseif action == "disconnect" or action == "off" then
						local p = Player(targetName)
						if p then
							local guid = p:getGuid()
							if Game.botHibernate then
								pcall(Game.botHibernate, guid)
							end
							pcall(function() p:remove() end)
							if BotActive then BotActive[guid] = false end
							if BotPlayers then BotPlayers[guid] = nil end
							if BotState then BotState[guid] = nil end
							db.botAsyncQuery("DELETE FROM `players_online` WHERE `player_id` = " .. guid)
							resultText = "Despawned " .. targetName
						else
							resultText = targetName .. " is not online"
						end
					else
						resultText = "Unknown action: " .. action
					end
				end
			elseif Game.botCommand then
				resultText = Game.botCommand(botName, cmd) or ""
				logger.info("[BotManager] Command '" .. cmd .. "' for '" .. botName .. "': " .. resultText)
			else
				local targetPlayer = Player(botName)
				if targetPlayer and BotState and BotState[targetPlayer:getGuid()] then
					resultText = BotSystem.executeCavebotCommand(targetPlayer, BotState[targetPlayer:getGuid()], cmd) or "OK"
				else
					resultText = "Command executed"
				end
			end

			-- Persist result + timestamp (mark processed in same statement)
			db.botAsyncQuery(string.format(
				"UPDATE `bot_commands` SET `processed` = 1, `result` = %s, `executed_at` = %d WHERE `id` = %d",
				db.escapeString(resultText:sub(1, BOT_CMD_RESULT_MAX)), os.time(), cmdId))
		until not Result.next(cmdResult)
		Result.free(cmdResult)
	end
	end)

	return true
end

botManager:interval(BOT_CONFIG.MANAGER_INTERVAL)
botManager:register()

-- Shutdown handler: save all active bot states to DB before server stops.
-- Sets should_restore_states=1 so next boot restores where bots left off.
local botShutdown = GlobalEvent("BotShutdown")

function botShutdown.onShutdown()
	logger.info("[BotManager] Server shutting down — saving bot states...")
	if Game.botSaveStates then
		Game.botSaveStates()
	end
	db.query(
		"INSERT INTO `bot_startup_config` (`config_key`, `config_value`) "
		.. "VALUES ('should_restore_states', '1') "
		.. "ON DUPLICATE KEY UPDATE `config_value` = '1'"
	)
	logger.info("[BotManager] Bot states saved. Restore flag set for next boot.")
	return true
end

botShutdown:register()
