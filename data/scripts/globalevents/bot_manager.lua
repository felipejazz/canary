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

	-- Restore saved XP Multiplier (SCHEDULE_EXP_RATE)
	local expRes = db.storeQuery("SELECT `config_value` FROM `bot_startup_config` WHERE `config_key` = 'exp_multiplier'")
	if expRes then
		local val = tonumber(Result.getString(expRes, "config_value"))
		Result.free(expRes)
		if val and val > 0 then
			SCHEDULE_EXP_RATE = math.floor(val * 100)
			logger.info(string.format("[BotManager] Restored XP Multiplier to %.2fx (SCHEDULE_EXP_RATE=%d)", val, SCHEDULE_EXP_RATE))
		end
	end

	-- Ensure staging tile exists for brand-new bots that have no prior loginPosition
	Game.createTile(Position(31970, 32283, 7), true)

	-- Query all bot characters ordered by level DESC, experience DESC (top level bots first).
	local query = "SELECT `id`, `name`, `level`, `experience` FROM `players` WHERE (`account_id` = " .. BOT_CONFIG.BOT_ACCOUNT_ID
		.. " OR `name` LIKE 'Bot %') AND `deletion` = 0 ORDER BY `level` DESC, `experience` DESC"

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

	local total = #allBotNames
	local target = BOT_CONFIG.TARGET_ONLINE
	if configKeys and configKeys.BOT_PLAYERS_ONLINE then
		pcall(function()
			local cfgVal = configManager.getNumber(configKeys.BOT_PLAYERS_ONLINE)
			if cfgVal and cfgVal > 0 then target = cfgVal end
		end)
	end

	-- Restore persisted debug_active_count if set
	local cfgRes = db.storeQuery("SELECT `config_value` FROM `bot_startup_config` WHERE `config_key` = 'debug_active_count'")
	if cfgRes then
		local dVal = tonumber(Result.getString(cfgRes, "config_value"))
		Result.free(cfgRes)
		if dVal and dVal > 0 then
			target = dVal
		end
	end

	local botNames = {}
	local maxPick = math.min(target, total)
	for i = 1, maxPick do
		table.insert(botNames, allBotNames[i])
	end

	-- Override for single bot test if explicitly configured
	if target == 1 and BOT_CONFIG.SINGLE_BOT_NAME and BOT_CONFIG.SINGLE_BOT_NAME ~= "" then
		botNames = { BOT_CONFIG.SINGLE_BOT_NAME }
	end

	logger.info("[BotManager] Found " .. total .. " bots in database, loading top "
		.. #botNames .. " by level (descending) as INACTIVE...")

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
local lastBotWatchdogCheck = 0

function botManager.onThink(interval)
	-- Liveness Watchdog: periodically inspect loaded bots and revive inactive ones (every 10s)
	local now = os.time()
	if not lastBotWatchdogCheck or (now - lastBotWatchdogCheck) >= 10 then
		lastBotWatchdogCheck = now

		-- 1. Inspect all instantiated bot players in the engine
		local onlineCount = 0
		for _, player in ipairs(Game.getPlayers()) do
			if player:isBotPlayer() and not player:isRemoved()
				and not (BotSystem.isHuntTesterWorker and BotSystem.isHuntTesterWorker(player:getGuid())) then
				onlineCount = onlineCount + 1
				local guid = player:getGuid()
				BotPlayers[guid] = player
				local isInactive = (not BotActive or not BotActive[guid])
				local missingThink = (not botThinkEvents or not botThinkEvents[guid])
				if isInactive or missingThink then
					logger.warn(string.format("[BotWatchdog] Bot %s (GUID %d) found inactive (BotActive=%s, ThinkEvent=%s). Reactivating...",
						player:getName(), guid, tostring(BotActive and BotActive[guid]), tostring(botThinkEvents and botThinkEvents[guid] ~= nil)))
					pcall(BotSystem.activateBot, player)
				end
			end
		end

		-- 2. Population Auto-Heal: Ensure target online count is maintained
		local target = BOT_CONFIG.TARGET_ONLINE
		local cfgRes = db.storeQuery("SELECT `config_value` FROM `bot_startup_config` WHERE `config_key` = 'debug_active_count'")
		if cfgRes then
			local dVal = tonumber(Result.getString(cfgRes, "config_value"))
			Result.free(cfgRes)
			if dVal and dVal > 0 then target = dVal end
		end

		if onlineCount < target then
			local q = string.format("SELECT `id`, `name` FROM `players` WHERE (`account_id` = %d OR `name` LIKE 'Bot %s') AND `deletion` = 0 ORDER BY `level` DESC, `experience` DESC LIMIT %d",
				BOT_CONFIG.BOT_ACCOUNT_ID, "%", target)
			local qRes = db.storeQuery(q)
			if qRes then
				repeat
					local qGuid = Result.getNumber(qRes, "id")
					local bName = Result.getString(qRes, "name")
					if not (BotOfflineTraining and BotOfflineTraining[qGuid]) then
						local p = Player(bName)
						if not p or p:isRemoved() then
							local newP = Game.loadBotPlayer(bName)
							if newP then
								local guid = newP:getGuid()
								BotPlayers[guid] = newP
								newP:registerEvent("BotDeath")
								pcall(BotSystem.activateBot, newP)
								db.botAsyncQuery("INSERT IGNORE INTO `players_online` (`player_id`) VALUES (" .. guid .. ")")
								logger.info("[BotWatchdog] Auto-healed population deficit: loaded and activated " .. bName)
								onlineCount = onlineCount + 1
								if onlineCount >= target then
									break
								end
							end
						end
					end
				until not Result.next(qRes)
				Result.free(qRes)
			end
		end
	end

	-- Global command queue poll (so MySQL-based commands still work).
	-- JITTER FIX 2026-06-10: async — the sync db.storeQuery blocked the dispatcher
	-- for the full round-trip incl. databaseLock convoy behind worker-thread DB
	-- bursts (measured 376ms and 643ms tonight via DB_SYNC_SLOW). Command
	-- processing becomes eventually-consistent within the same 10s window.
	db.botAsyncStoreQuery(
		"SELECT `id`, `bot_name`, `command` FROM `bot_commands` WHERE `processed` = 0 ORDER BY `id` ASC LIMIT 10",
		function(cmdResult)
	if cmdResult then
		local rows = {}
		repeat
			table.insert(rows, {
				id = Result.getNumber(cmdResult, "id"),
				bot_name = Result.getString(cmdResult, "bot_name"),
				command = Result.getString(cmdResult, "command")
			})
		until not Result.next(cmdResult)
		Result.free(cmdResult)

		-- Detect multiple set_population commands in the same batch and only execute the last one
		local lastPopIdx = nil
		for idx, r in ipairs(rows) do
			local low = r.command:lower()
			if r.bot_name == "_global" and (low:match("^set_population%s+") or low:match("^population%s+") or low:match("^scale%s+")) then
				lastPopIdx = idx
			end
		end

		for idx, row in ipairs(rows) do
			local cmdId = row.id
			local botName = row.bot_name
			local cmd = row.command
			local low = cmd:lower()
			local resultText

			-- If there is a newer scale command in this same batch, skip and mark superseded
			if row.bot_name == "_global" and (low:match("^set_population%s+") or low:match("^population%s+") or low:match("^scale%s+")) and lastPopIdx and idx < lastPopIdx then
				resultText = "Comando de escala ignorado (substituido por comando mais recente na fila)"
			elseif botName == "_global" and (low == "reload" or low:match("^reload%s")) then
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
			elseif botName == "_global" and (low == "clean" or low == "cleanmap" or low == "clean_map") then
				local count = cleanMap() or 0
				resultText = "Cleaned " .. count .. " items from the map"
			elseif botName == "_global" and (low == "save" or low == "saveserver") then
				local ok, err = pcall(function() saveServer() end)
				resultText = ok and "Server and players saved to DB successfully" or ("Save failed: " .. tostring(err))
				logger.info("[BotManager] " .. resultText)
			elseif botName == "_global" and (low == "reload_scripts" or low == "scripts") then
				local ok, err = pcall(function() Game.reload(RELOAD_TYPE_SCRIPTS) end)
				resultText = ok and "Scripts reloaded successfully" or ("Reload failed: " .. tostring(err))
			elseif botName == "_global" and (low == "replenish_market" or low == "market_replenish") then
				local ok, err = pcall(function()
					-- Top-up depleted GOD offers
					db.asyncQuery("UPDATE `market_offers` SET `amount` = 65535, `created` = UNIX_TIMESTAMP() WHERE `player_id` = 7 AND `amount` < 1000")
					-- Clean GOD inbox/depot
					db.asyncQuery("DELETE FROM `player_inboxitems` WHERE `player_id` = 7")
					db.asyncQuery("DELETE FROM `player_depotitems` WHERE `player_id` = 7")
				end)
				resultText = ok and "Market replenished successfully" or ("Replenish failed: " .. tostring(err))
			elseif botName == "_global" and (low == "wake_all" or low == "wake" or low == "wakeall") then
				local awakened = 0
				for _, p in ipairs(Game.getPlayers()) do
					if p:isBotPlayer() and not p:isRemoved() then
						local guid = p:getGuid()
						BotPlayers[guid] = p
						pcall(BotSystem.activateBot, p)
						awakened = awakened + 1
					end
				end
				resultText = string.format("Woke up %d online bots", awakened)
			elseif botName == "_global" and low:match("^inspect%s+") then
				local targetName = cmd:match("^%S+%s+(.+)")
				if targetName and targetName:lower() == "summary" then
					local totalOnline = 0
					local totalActive = 0
					local totalThink = 0
					for _, botP in ipairs(Game.getPlayers()) do
						if botP:isBotPlayer() and not botP:isRemoved() then
							local guid = botP:getGuid()
							BotPlayers[guid] = botP
							totalOnline = totalOnline + 1
							if BotActive and BotActive[guid] then
								totalActive = totalActive + 1
							end
							if botThinkEvents and botThinkEvents[guid] then
								totalThink = totalThink + 1
							end
						end
					end
					resultText = string.format("Bot Summary: %d online | %d active | %d think loops running", totalOnline, totalActive, totalThink)
				else
					local p = Player(targetName)
					if not p and BotPlayers then
						for guid, botP in pairs(BotPlayers) do
							if botP and not botP:isRemoved() and botP:getName():lower() == targetName:lower() then
								p = botP
								break
							end
						end
					end
					if p then
						local guid = p:getGuid()
						BotPlayers[guid] = p
						local s = BotState and BotState[p:getGuid()]
						local pos = p:getPosition()
						if s then
							resultText = string.format("Bot: %s (GUID:%d) | State: %s | Phase: %s | Cmd: %s | FC: %s | Pos: %d,%d,%d | StuckStart: %s | WalkHistLen: %d | IdleStart: %s | Active: %s",
								p:getName(), p:getGuid(), tostring(s.state), tostring(s.huntPhase), tostring(s.cavebotCommand), tostring(s.floorChangeState),
								pos.x, pos.y, pos.z, tostring(s.stuckStartTime), s.walkHistory and #s.walkHistory or 0, tostring(s.idleStartTime), tostring(BotActive and BotActive[p:getGuid()]))
						else
							resultText = string.format("Bot: %s (GUID:%d) online at %d,%d,%d but has NO BotState table!", p:getName(), p:getGuid(), pos.x, pos.y, pos.z)
						end
					else
						local allOnline = {}
						for guid, botP in pairs(BotPlayers or {}) do
							if botP and not botP:isRemoved() then
								table.insert(allOnline, botP:getName())
							end
						end
						resultText = string.format("Bot '%s' not found. Total BotPlayers in memory: %d", targetName, #allOnline)
					end
				end
			elseif botName == "_global" and (low:match("^set_exp_multiplier%s+") or low:match("^exp_multiplier%s+")) then
				local mult = tonumber(cmd:match("[%d%.]+")) or 1.0
				local ratePct = math.floor(mult * 100)
				SCHEDULE_EXP_RATE = ratePct
				db.botAsyncQuery(string.format(
					"INSERT INTO `bot_startup_config` (`config_key`, `config_value`) VALUES ('exp_multiplier', '%s') ON DUPLICATE KEY UPDATE `config_value` = '%s'",
					tostring(mult), tostring(mult)))
				resultText = string.format("XP Multiplier ajustado para %.2fx (SCHEDULE_EXP_RATE=%d)", mult, ratePct)
				logger.info("[BotManager] " .. resultText)
				pcall(function()
					Game.broadcastMessage(string.format("[Servidor] Multiplicador de Experiencia alterado para %.2fx!", mult), MESSAGE_EVENT_ADVANCE)
					-- Atualiza o mostrador visual de XP imediatamente no cliente (OTClient) de todos os jogadores online
					for _, onlineP in ipairs(Game.getPlayers()) do
						if onlineP and not onlineP:isRemoved() then
							local newBaseRate = onlineP:getFinalBaseRateExperience() * 100
							onlineP:setBaseXpGain(newBaseRate)
						end
					end
				end)
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
						if not p and BotPlayers then
							for guid, botP in pairs(BotPlayers) do
								if botP and not botP:isRemoved() and botP:getName():lower() == targetName:lower() then
									p = botP
									break
								end
							end
						end
						if p and not p:isRemoved() then
							BotPlayers[p:getGuid()] = p
							local ok, err = pcall(BotSystem.activateBot, p)
							resultText = string.format("%s online: activateBot ok=%s err=%s", targetName, tostring(ok), tostring(err))
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
		end
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
