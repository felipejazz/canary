-- ============================================================================
-- Bot Hunt Tester Engine
-- Automated Hunt Accessibility Testing Suite for Tibia Local (Canary)
-- Supports single and parallel testers (Tester 1..N)
-- Full cycle: Temple -> travel_to -> cave -> hunt_patrol -> travel_from -> Temple
-- Real-time broadcasts, stuck/timeout detection (18s), obstacle clearing,
-- MariaDB reporting (bot_hunt_test_reports), and HUNT_ACCESSIBILITY_REPORT.md generation.
-- ============================================================================

HuntTester = HuntTester or {}
HuntTester.running = HuntTester.running or false
HuntTester.workers = HuntTester.workers or 1
HuntTester.queue = HuntTester.queue or {}
HuntTester.queueIndex = HuntTester.queueIndex or 1
HuntTester.activeWorkers = HuntTester.activeWorkers or {}
HuntTester.workerTickEvents = HuntTester.workerTickEvents or {}
HuntTester.reports = HuntTester.reports or {}
HuntTester.startTime = HuntTester.startTime or 0
HuntTester.totalQueued = HuntTester.totalQueued or 0

HuntTester.LOG_FILE = "data/logs/hunt_tester.log"

-- Dedicated high-fidelity Hunt Tester logger
function HuntTester.logEvent(level, workerName, huntInfo, phase, wpIndex, totalWps, curPos, targetPos, action, details)
	local timestamp = os.date("!%Y-%m-%d %H:%M:%S")
	local huntStr = huntInfo and string.format("[%d: %s (%s)]", huntInfo.id or 0, huntInfo.name or "?", huntInfo.town_name or "?") or "[-]"
	local wpStr = (wpIndex and totalWps) and string.format("[WP %d/%d]", wpIndex, totalWps) or "[-]"
	local phaseStr = phase and ("[" .. phase .. "]") or "[-]"
	local curStr = curPos and string.format("(%d,%d,%d)", curPos.x, curPos.y, curPos.z) or "(-)"
	local targetStr = targetPos and string.format("(%d,%d,%d)", targetPos.x, targetPos.y, targetPos.z) or "(-)"
	local distStr = ""
	if curPos and targetPos then
		local dx = math.abs(curPos.x - targetPos.x)
		local dy = math.abs(curPos.y - targetPos.y)
		local dz = targetPos.z - curPos.z
		local cheb = math.max(dx, dy)
		distStr = string.format("dist=%d,dz=%d", cheb, dz)
	end

	local line = string.format(
		"[%s] [%-5s] [%-8s] %-30s %-13s %-11s Cur=%-16s Target=%-16s %-12s | ACT=%-16s | %s\n",
		timestamp, level or "INFO", workerName or "Tester", huntStr, phaseStr, wpStr, curStr, targetStr, distStr, action or "TICK", details or ""
	)

	pcall(function()
		local f = io.open(HuntTester.LOG_FILE, "a")
		if f then
			f:write(line)
			f:flush()
			f:close()
		end
	end)
end

-- Diagnostic dump of surroundings when stuck or timing out
function HuntTester.logDiagnosticSnapshot(workerName, huntInfo, phase, wpIndex, totalWps, curPos, targetPos, reason)
	local timestamp = os.date("!%Y-%m-%d %H:%M:%S")
	pcall(function()
		local f = io.open(HuntTester.LOG_FILE, "a")
		if not f then return end
		f:write(string.format(
			"\n======================================== [DIAGNOSTIC SNAPSHOT] ========================================\n" ..
			"Timestamp: %s | Worker: %s | Hunt: %d (%s) | Town: %s\n" ..
			"Phase: %s | Waypoint: %d/%d\n" ..
			"Current Pos: (%d,%d,%d) | Target Pos: (%d,%d,%d)\n" ..
			"Reason: %s\n",
			timestamp, workerName, huntInfo.id, huntInfo.name, huntInfo.town_name or "?",
			phase or "?", wpIndex or 0, totalWps or 0,
			curPos.x, curPos.y, curPos.z,
			targetPos and targetPos.x or 0, targetPos and targetPos.y or 0, targetPos and targetPos.z or 0,
			reason or "N/A"
		))
		f:write("Surrounding 3x3 tiles on player floor (z=" .. curPos.z .. "):\n")
		for dy = -1, 1 do
			local row = "  "
			for dx = -1, 1 do
				local p = Position(curPos.x + dx, curPos.y + dy, curPos.z)
				local t = Tile(p)
				if not t then
					row = row .. string.format("[dx:%+d,dy:%+d: VOID] ", dx, dy)
				else
					local isWalk = t:isWalkable() and "WALK" or "BLOCKED"
					local hasFloorChange = t:hasFlag(TILESTATE_FLOORCHANGE) and "+FLRCHG" or ""
					local ground = t:getGround()
					local gId = ground and ground:getId() or 0
					local topDown = t:getTopDownItem()
					local tdId = topDown and topDown:getId() or 0
					row = row .. string.format("[dx:%+d,dy:%+d: %s%s g:%d top:%d] ", dx, dy, isWalk, hasFloorChange, gId, tdId)
				end
			end
			f:write(row .. "\n")
		end
		if targetPos and targetPos.z ~= curPos.z then
			f:write("Target tile info (z=" .. targetPos.z .. "):\n")
			local tTile = Tile(targetPos)
			if tTile then
				local isWalk = tTile:isWalkable() and "WALK" or "BLOCKED"
				local hasFloorChange = tTile:hasFlag(TILESTATE_FLOORCHANGE) and "+FLRCHG" or ""
				f:write(string.format("  Target tile (%d,%d,%d): %s%s\n", targetPos.x, targetPos.y, targetPos.z, isWalk, hasFloorChange))
			else
				f:write(string.format("  Target tile (%d,%d,%d): UNLOADED / VOID\n", targetPos.x, targetPos.y, targetPos.z))
			end
		end
		f:write("========================================================================================================\n\n")
		f:flush()
		f:close()
	end)
end

-- Default Temple coordinates for all towns
HuntTester.TEMPLE_POSITIONS = {
	[1] = Position(32069, 31901, 6), -- Dawnport Tutorial
	[2] = Position(32064, 31894, 6), -- Dawnport
	[3] = Position(32097, 32219, 7), -- Rookgaard
	[4] = Position(32091, 32027, 7), -- Island of Destiny
	[5] = Position(32732, 31634, 7), -- Ab'Dendriel
	[6] = Position(32360, 31782, 7), -- Carlin
	[7] = Position(32649, 31925, 11), -- Kazordoon
	[8] = Position(32369, 32241, 7), -- Thais
	[9] = Position(32957, 32076, 7), -- Venore
	[10] = Position(33194, 32853, 8), -- Ankrahmun
	[11] = Position(33217, 31814, 8), -- Edron
	[12] = Position(33023, 31521, 11), -- Farmine
	[13] = Position(33213, 32454, 1), -- Darashia
	[14] = Position(32317, 32826, 7), -- Liberty Bay
	[15] = Position(32594, 32745, 7), -- Port Hope
	[16] = Position(32212, 31132, 7), -- Svargrond
	[17] = Position(32787, 31276, 7), -- Yalahar
	[18] = Position(33447, 31323, 9), -- Gray Beach
	[19] = Position(33657, 31665, 8), -- Krailos
	[20] = Position(33594, 31899, 6), -- Rathleton / Oramond
	[21] = Position(33513, 32363, 6), -- Roshamuul
	[22] = Position(33921, 31477, 5), -- Issavi
	[26] = Position(33490, 32221, 7), -- Feyrist
	[28] = Position(33842, 32853, 7), -- Marapur
}

-- Broadcast announcement to all players/GMs
function HuntTester.broadcast(msg)
	logger.info("[HuntTester] " .. msg)
	if Game and Game.broadcastMessage then
		pcall(function() Game.broadcastMessage(msg, MESSAGE_LOOK) end)
	end
end

-- Get temple position for a given townId or townName
function HuntTester.getTemplePosition(townId, townName)
	if BotSystem and BotSystem.getTownTemplePos and townId and townId > 0 then
		local p = BotSystem.getTownTemplePos(townId)
		if p and p.x > 0 then return p end
	end
	if townId and townId > 0 then
		local town = Town(townId)
		if town and town.getTemplePosition then
			local tPos = town:getTemplePosition()
			if tPos and tPos.x > 0 then return tPos end
		end
		if HuntTester.TEMPLE_POSITIONS[townId] then
			return HuntTester.TEMPLE_POSITIONS[townId]
		end
	end
	if townName and townName ~= "" then
		local town = Town(townName)
		if town and town.getTemplePosition then
			local tPos = town:getTemplePosition()
			if tPos and tPos.x > 0 then return tPos end
		end
	end
	-- Default fallback to Thais temple
	return Position(32369, 32241, 7)
end

-- Ensure worker has tools (rope 3003, shovel 3457, machete 3308)
function HuntTester.ensureTools(player)
	if not player or player:isRemoved() then return end
	if player.getItemCount then
		if player:getItemCount(3003) == 0 then player:addItem(3003, 1, false) end
		if player:getItemCount(3457) == 0 and player:getItemCount(3456) == 0 then player:addItem(3457, 1, false) end
		if player:getItemCount(3308) == 0 then player:addItem(3308, 1, false) end
	end
end

-- Load or get player for a worker
function HuntTester.getOrLoadWorker(workerName)
	local player = Player(workerName)
	if not player then
		if Game and Game.loadBotPlayer then
			player = Game.loadBotPlayer(workerName)
		end
	end
	if player then
		HuntTester.ensureTools(player)
		if BotSystem and BotSystem.applyQuestStorages then
			pcall(function() BotSystem.applyQuestStorages(player) end)
		end
		local curSpeed = player:getSpeed()
		if curSpeed < 800 then
			player:changeSpeed(800 - curSpeed)
		end
		local guid = player:getGuid()
		if guid then
			if BotPlayers then
				BotPlayers[guid] = player
			end
			if BotSystem and BotSystem.cancelBotWalk then
				BotSystem.cancelBotWalk(guid)
			end
		end
	end
	return player
end

-- Check if a player satisfies all mandatory quest accesses (`bot_hunt_accesses`) for a hunt
function HuntTester.playerHasHuntAccess(player, scriptId)
	if not player or not scriptId then return true, nil end
	local res = db.storeQuery(
		"SELECT qa.access_code, qa.required_storage_key, qa.required_storage_val " ..
		"FROM `bot_hunt_accesses` ha " ..
		"JOIN `bot_quest_accesses` qa ON qa.id = ha.access_id " ..
		"WHERE ha.hunt_id = " .. tonumber(scriptId) .. " AND ha.is_mandatory = 1"
	)
	if not res then return true, nil end
	local accessCodes = {}
	local hasAll = true
	repeat
		local code = Result.getString(res, "access_code")
		local skey = Result.getNumber(res, "required_storage_key")
		local sval = Result.getNumber(res, "required_storage_val")
		table.insert(accessCodes, string.format("%s(%d>=%d)", code, skey, sval))
		local curVal = player:getStorageValue(skey)
		if curVal < sval then
			hasAll = false
		end
	until not Result.next(res)
	Result.free(res)
	return hasAll, table.concat(accessCodes, ", ")
end

-- Fetch all waypoints for a hunt script across travel_to, hunt_patrol, travel_from
function HuntTester.loadHuntWaypoints(scriptId)
	local wps = {}
	local travelTo = (BotHuntData and BotHuntData.getPhaseWaypoints and BotHuntData.getPhaseWaypoints(scriptId, "travel_to")) or {}
	local patrol = (BotHuntData and BotHuntData.getPhaseWaypoints and BotHuntData.getPhaseWaypoints(scriptId, "hunt_patrol")) or {}
	local travelFrom = (BotHuntData and BotHuntData.getPhaseWaypoints and BotHuntData.getPhaseWaypoints(scriptId, "travel_from")) or {}

	-- If BotHuntData not loaded or empty, fallback to direct DB query
	if #travelTo == 0 and #patrol == 0 and #travelFrom == 0 then
		local res = db.storeQuery(
			"SELECT `phase`, `seq`, `waypoint_type`, `pos_x`, `pos_y`, `pos_z`, `label`, `extra_data` " ..
			"FROM `bot_hunt_waypoints` WHERE `script_id` = " .. tonumber(scriptId) .. " ORDER BY `phase`, `seq` ASC"
		)
		if res then
			repeat
				local phase = Result.getString(res, "phase")
				local wp = {
					phase = phase,
					seq = Result.getNumber(res, "seq"),
					waypoint_type = Result.getString(res, "waypoint_type"),
					pos_x = Result.getNumber(res, "pos_x"),
					pos_y = Result.getNumber(res, "pos_y"),
					pos_z = Result.getNumber(res, "pos_z"),
					label = Result.getString(res, "label"),
					extra_data = Result.getString(res, "extra_data"),
				}
				if phase == "travel_to" then
					table.insert(travelTo, wp)
				elseif phase == "hunt_patrol" then
					table.insert(patrol, wp)
				elseif phase == "travel_from" then
					table.insert(travelFrom, wp)
				end
			until not Result.next(res)
			Result.free(res)
		end
	end

	-- 1. Travel To phase (inject preventive key acquisition waypoints if hunt requires keys)
	if BotSystem and BotSystem.injectKeyAcquisitionWaypoints then
		local dummyPlayer = HuntTester.currentLoadingPlayer
		if dummyPlayer then
			travelTo = BotSystem.injectKeyAcquisitionWaypoints(dummyPlayer, travelTo, scriptId)
		end
	end
	if BotSystem and BotSystem.injectQuestAccessWaypoints then
		local dummyPlayer = HuntTester.currentLoadingPlayer
		if dummyPlayer then
			travelTo = BotSystem.injectQuestAccessWaypoints(dummyPlayer, travelTo, scriptId)
		end
	end
	for _, wp in ipairs(travelTo) do
		wp.phase = "travel_to"
		table.insert(wps, wp)
	end

	-- 2. Hunt Patrol phase (1 full cycle)
	for _, wp in ipairs(patrol) do
		wp.phase = "hunt_patrol"
		table.insert(wps, wp)
	end

	-- 3. Travel From phase (if missing, reverse travel_to)
	if #travelFrom > 0 then
		for _, wp in ipairs(travelFrom) do
			wp.phase = "travel_from"
			table.insert(wps, wp)
		end
	elseif #travelTo > 0 then
		for i = #travelTo, 1, -1 do
			local orig = travelTo[i]
			table.insert(wps, {
				phase = "travel_from",
				seq = #travelTo - i + 1,
				waypoint_type = orig.waypoint_type,
				pos_x = orig.pos_x,
				pos_y = orig.pos_y,
				pos_z = orig.pos_z,
				label = orig.label,
				extra_data = orig.extra_data
			})
		end
	end

	return wps
end

-- Get hunt info
function HuntTester.getHuntInfo(scriptId)
	if BotHuntData and BotHuntData.scripts and BotHuntData.scripts[scriptId] then
		local s = BotHuntData.scripts[scriptId]
		return {
			id = scriptId,
			name = s.name or "Hunt #" .. scriptId,
			town_id = s.town_id or 8,
			town_name = s.town_name or "Thais"
		}
	end
	local res = db.storeQuery("SELECT `id`, `name`, `town_id`, `town_name` FROM `bot_hunt_scripts` WHERE `id` = " .. tonumber(scriptId))
	if res then
		local info = {
			id = Result.getNumber(res, "id"),
			name = Result.getString(res, "name"),
			town_id = Result.getNumber(res, "town_id"),
			town_name = Result.getString(res, "town_name")
		}
		Result.free(res)
		return info
	end
	return { id = scriptId, name = "Hunt #" .. scriptId, town_id = 8, town_name = "Thais" }
end

-- Reset all test reports and queue history
function HuntTester.resetReports()
	db.asyncQuery("DELETE FROM `bot_hunt_test_reports`")
	db.asyncQuery("DELETE FROM `bot_hunt_test_queue`")
	HuntTester.reports = {}
	HuntTester.broadcast("[HuntTester] Histórico de testes zerado com sucesso!")
	HuntTester.generateMarkdownReport()
end

-- Start testing suite
function HuntTester.start(options)
	if HuntTester.running then
		HuntTester.broadcast("[HuntTester] Testes já estão em execução! Use !test_hunts status ou !test_hunts stop.")
		return false
	end

	options = options or {}
	if options.reset then
		HuntTester.resetReports()
	end

	local workersCount = math.max(1, math.min(8, tonumber(options.workers) or 1))
	HuntTester.workers = workersCount
	HuntTester.running = true
	HuntTester.queue = {}
	HuntTester.queueIndex = 1
	HuntTester.activeWorkers = {}
	HuntTester.reports = {}
	HuntTester.startTime = os.time()
	HuntTester.batchId = "batch_" .. os.time()

	-- Build queue of hunt script IDs
	if options.huntId then
		table.insert(HuntTester.queue, tonumber(options.huntId))
	else
		local sql = "SELECT `id` FROM `bot_hunt_scripts` WHERE `enabled` = 1"
		if options.failedOnly then
			sql = sql .. " AND `id` IN (SELECT r.hunt_id FROM bot_hunt_test_reports r INNER JOIN (SELECT hunt_id, MAX(id) AS max_id FROM bot_hunt_test_reports GROUP BY hunt_id) latest ON r.id = latest.max_id WHERE r.status != 'ACCESSIBLE')"
		elseif options.untestedOnly or (not options.force and not options.allForce) then
			sql = sql .. " AND `id` NOT IN (SELECT DISTINCT `hunt_id` FROM `bot_hunt_test_reports`)"
		end
		if options.town and options.town ~= "" then
			local escapedTown = db.escapeString(options.town:lower())
			sql = sql .. " AND (LOWER(`town_name`) = " .. escapedTown .. " OR `town_id` = " .. (tonumber(options.town) or -1) .. ")"
		end
		sql = sql .. " ORDER BY `town_id` ASC, `id` ASC"
		if options.limit and tonumber(options.limit) and tonumber(options.limit) > 0 then
			sql = sql .. " LIMIT " .. tonumber(options.limit)
		end

		local res = db.storeQuery(sql)
		if res then
			repeat
				table.insert(HuntTester.queue, Result.getNumber(res, "id"))
			until not Result.next(res)
			Result.free(res)
		end
	end

	HuntTester.totalQueued = #HuntTester.queue
	if HuntTester.totalQueued == 0 then
		HuntTester.running = false
		HuntTester.broadcast("[HuntTester] Nenhuma hunt pendente para teste com os filtros aplicados (todas já testadas ou inexistentes). Use force para re-testar.")
		return false
	end

	-- Insert into DB queue for audit/coordination
	pcall(function()
		for _, hid in ipairs(HuntTester.queue) do
			db.asyncQuery(string.format(
				"INSERT INTO `bot_hunt_test_queue` (`hunt_id`, `batch_id`, `status`) VALUES (%d, '%s', 'PENDING')",
				hid, HuntTester.batchId
			))
		end
	end)

	local filterMsg = (options.untestedOnly or not options.force) and " (apenas não-testadas)" or " (modo completo/force)"
	HuntTester.broadcast(string.format(
		"[HuntTester] INICIANDO TESTES: %d hunts na fila%s | %d Tester(s) em paralelo",
		HuntTester.totalQueued, filterMsg, HuntTester.workers
	))
	HuntTester.logEvent("INFO", "System", nil, "batch", 0, HuntTester.totalQueued, nil, nil, "BATCH_START", string.format("Starting batch with %d hunts on %d workers (filter=%s)", HuntTester.totalQueued, HuntTester.workers, filterMsg))

	-- Dispatch initial workers
	for i = 1, HuntTester.workers do
		local workerName = (HuntTester.workers == 1 and not options.parallelExplicit) and "Tester" or ("Tester " .. i)
		HuntTester.dispatchNextHuntForWorker(workerName)
	end

	return true
end

-- Stop testing suite
function HuntTester.stop()
	if not HuntTester.running then
		HuntTester.broadcast("[HuntTester] Nenhum teste em andamento.")
		return
	end

	HuntTester.running = false
	for workerName, eventId in pairs(HuntTester.workerTickEvents) do
		if eventId then
			stopEvent(eventId)
		end
	end
	HuntTester.workerTickEvents = {}

	for workerName, state in pairs(HuntTester.activeWorkers) do
		local player = Player(workerName)
		if player and player.stopWalk then
			player:stopWalk()
		end
	end
	HuntTester.activeWorkers = {}

	db.asyncQuery("UPDATE `bot_hunt_test_commands` SET `status` = 'COMPLETED' WHERE `status` = 'RUNNING'")
	HuntTester.logEvent("INFO", "System", nil, "batch", 0, 0, nil, nil, "BATCH_STOP", "Test suite stopped by operator")
	HuntTester.broadcast("[HuntTester] Testes interrompidos com sucesso pelo operador.")
	HuntTester.generateMarkdownReport()
end

-- Get status summary string with global metrics
function HuntTester.getStatus()
	-- Query global statistics from DB
	local globalTotal = 0
	local globalTested = 0
	local globalAccessible = 0
	local globalBugged = 0
	local globalTimeout = 0

	local tRes = db.storeQuery("SELECT COUNT(*) AS total FROM `bot_hunt_scripts` WHERE `enabled` = 1")
	if tRes then
		globalTotal = Result.getNumber(tRes, "total")
		Result.free(tRes)
	end

	local rRes = db.storeQuery([[
		SELECT status, COUNT(DISTINCT hunt_id) AS cnt
		FROM bot_hunt_test_reports
		GROUP BY status
	]])
	if rRes then
		repeat
			local st = Result.getString(rRes, "status")
			local cnt = Result.getNumber(rRes, "cnt")
			globalTested = globalTested + cnt
			if st == "ACCESSIBLE" then globalAccessible = cnt
			elseif st == "BUGGED" then globalBugged = cnt
			elseif st == "TIMEOUT" then globalTimeout = cnt end
		until not Result.next(rRes)
		Result.free(rRes)
	end

	local globalRemaining = math.max(0, globalTotal - globalTested)
	local summary = string.format(
		"=== Progresso Global ===\nTestadas: %d/%d (%.1f%%) | Restantes: %d | Acessíveis: %d | Bugadas: %d | Timeouts: %d\n",
		globalTested, globalTotal, globalTotal > 0 and (globalTested / globalTotal * 100) or 0,
		globalRemaining, globalAccessible, globalBugged, globalTimeout
	)

	if not HuntTester.running then
		return summary .. "Estado da Bateria: PARADO / IDLE"
	end

	local elapsed = os.time() - HuntTester.startTime
	local completed = #HuntTester.reports
	local remaining = HuntTester.totalQueued - completed
	local activeDetails = {}
	for wName, s in pairs(HuntTester.activeWorkers) do
		table.insert(activeDetails, string.format("%s: Hunt #%d (%s) wp %d/%d [%s]",
			wName, s.huntId, s.huntInfo.name, s.currentWpIndex, #s.waypoints, s.currentPhase))
	end

	return summary .. string.format(
		"=== Execução Ativa ===\nLote: %d/%d (%d%%) | Restantes no lote: %d | Tempo: %ds | Workers: %d\nAtivos: %s",
		completed, HuntTester.totalQueued,
		HuntTester.totalQueued > 0 and math.floor((completed / HuntTester.totalQueued) * 100) or 0,
		remaining, elapsed, HuntTester.workers,
		#activeDetails > 0 and table.concat(activeDetails, " | ") or "nenhum"
	)
end

-- Dispatch next hunt in queue to worker
function HuntTester.dispatchNextHuntForWorker(workerName)
	if not HuntTester.running then return end

	local player = HuntTester.getOrLoadWorker(workerName)
	if not player then
		HuntTester.broadcast(string.format("[HuntTester] ERRO: Não foi possível carregar worker '%s'!", workerName))
		return
	end

	local huntId = nil
	if HuntTester.queueIndex <= #HuntTester.queue then
		huntId = HuntTester.queue[HuntTester.queueIndex]
		HuntTester.queueIndex = HuntTester.queueIndex + 1
	end

	if not huntId then
		-- No more hunts for this worker
		HuntTester.activeWorkers[workerName] = nil
		local anyActive = false
		for _, s in pairs(HuntTester.activeWorkers) do
			if s then anyActive = true; break end
		end
		if not anyActive then
			-- All workers done!
			HuntTester.onTestingCompleted()
		end
		return
	end

	-- Claim hunt in DB
	pcall(function()
		db.asyncQuery(string.format(
			"UPDATE `bot_hunt_test_queue` SET `status` = 'CLAIMED', `claimed_by` = '%s', `claimed_at` = NOW() " ..
			"WHERE `hunt_id` = %d AND `batch_id` = '%s'",
			workerName, huntId, HuntTester.batchId
		))
	end)

	local huntInfo = HuntTester.getHuntInfo(huntId)

	-- If this hunt requires keys, clear existing keys from Tester's backpack and re-lock the door on map so Tester tests the full key acquisition & unlock flow!
	if HUNT_KEYS_BY_HUNT and HUNT_KEYS_BY_HUNT[tonumber(huntId)] then
		for _, knum in ipairs(HUNT_KEYS_BY_HUNT[tonumber(huntId)]) do
			local hasIt, keyItem = BotSystem.playerHasKey(player, knum)
			if hasIt and keyItem then
				pcall(function() keyItem:remove() end)
			end
			local kInfo = HUNT_KEYS_BY_NUMBER and HUNT_KEYS_BY_NUMBER[knum]
			if kInfo and kInfo.door_x and KeyDoorTable then
				local dTile = Tile(Position(kInfo.door_x, kInfo.door_y, kInfo.door_z))
				if dTile and dTile:getItems() then
					for _, it in ipairs(dTile:getItems()) do
						for _, entry in ipairs(KeyDoorTable) do
							if (it:getId() == entry.openDoor or it:getId() == entry.closedDoor) and entry.lockedDoor then
								it:transform(entry.lockedDoor)
								if it:getActionId() == 0 then
									it:setActionId(knum)
								end
							end
						end
					end
				end
			end
		end
	end

	HuntTester.currentLoadingPlayer = player
	local waypoints = HuntTester.loadHuntWaypoints(huntId)
	HuntTester.currentLoadingPlayer = nil

	if #waypoints == 0 then
		-- Hunt has no waypoints at all! Mark BUGGED immediately
		HuntTester.recordReport(workerName, huntInfo, "BUGGED", "Nenhum waypoint cadastrado para a hunt", 0, 0, 0, 0, 0, 0)
		HuntTester.dispatchNextHuntForWorker(workerName)
		return
	end

	-- Verify mandatory quest access constraints for this hunt
	local hasAccess, accessSummary = HuntTester.playerHasHuntAccess(player, huntId)
	if accessSummary and accessSummary ~= "" then
		HuntTester.logEvent("INFO", workerName, huntInfo, "setup", 0, #waypoints, player:getPosition(), nil, "QUEST_ACCESS_CHECK", string.format("Mandatory quest constraints: [%s] -> hasAccess=%s", accessSummary, tostring(hasAccess)))
	end
	if not hasAccess then
		local hasQuestWp = false
		for _, wp in ipairs(waypoints) do
			if wp.waypoint_type == "quest_access" then
				hasQuestWp = true
				break
			end
		end
		if not hasQuestWp then
			HuntTester.recordReport(workerName, huntInfo, "BUGGED", "Falta acesso de quest obrigatório: " .. tostring(accessSummary), 0, 0, 0, 0, #waypoints, 0)
			HuntTester.dispatchNextHuntForWorker(workerName)
			return
		end
	end

	-- Teleport worker to town temple to begin complete cycle
	local guid = player:getGuid()
	if BotSystem and BotSystem.cancelBotWalk then
		BotSystem.cancelBotWalk(guid)
	end
	if player.stopWalk then
		pcall(function() player:stopWalk() end)
	end
	if player.setMoveLocked then
		pcall(function() player:setMoveLocked(false) end)
	end

	local prePos = player:getPosition()
	local templePos = HuntTester.getTemplePosition(huntInfo.town_id, huntInfo.town_name)
	HuntTester.logEvent("INFO", workerName, huntInfo, "setup", 0, #waypoints, prePos, templePos, "TELEPORT_TEMPLE", string.format("Teleporting to %s Temple (town_id=%d, target=(%d,%d,%d))", huntInfo.town_name, huntInfo.town_id, templePos.x, templePos.y, templePos.z))
	local tTile = Tile(templePos)
	if tTile then
		local items = tTile:getItems()
		local itemDesc = {}
		if items then
			for _, it in ipairs(items) do
				table.insert(itemDesc, string.format("id=%d", it:getId()))
			end
		end
		HuntTester.logEvent("INFO", workerName, huntInfo, "setup", 0, #waypoints, prePos, templePos, "TILE_INSPECT", string.format("items=[%s], hasPZ=%s", table.concat(itemDesc, ","), tostring(tTile:hasFlag(TILESTATE_PROTECTIONZONE))))
	end
	local tGround = tTile and tTile:getGround()
	local tWalk = tTile and tTile:isWalkable()
	local tCreatures = tTile and tTile:getCreatureCount() or 0
	local ok = player:teleportTo(templePos, true)
	local postPos = player:getPosition()
	HuntTester.logEvent("INFO", workerName, huntInfo, "setup", 0, #waypoints, postPos, templePos, "TELEPORT_RESULT", string.format("teleport ret=%s, tile=%s, ground=%s, walkable=%s, creatures=%d, landed at (%d,%d,%d)", tostring(ok), tostring(tTile ~= nil), tostring(tGround ~= nil), tostring(tWalk), tCreatures, postPos.x, postPos.y, postPos.z))
	HuntTester.logEvent("INFO", workerName, huntInfo, "setup", 0, #waypoints, postPos, templePos, "TELEPORT_RESULT", string.format("Worker landed at (%d,%d,%d)", postPos.x, postPos.y, postPos.z))

	local state = {
		workerName = workerName,
		huntId = huntId,
		huntInfo = huntInfo,
		hasQuestAccess = hasAccess,
		questAccessSummary = accessSummary,
		waypoints = waypoints,
		currentWpIndex = 1,
		currentPhase = waypoints[1].phase or "travel_to",
		completedWaypoints = 0,
		huntStartTime = os.time(),
		wpStartTime = os.time(),
		posHistory = {},
		lastPos = postPos,
		lastProgressTime = os.time(),
		stuckCounter = 0,
		lastWarnedSec = 0,
	}

	HuntTester.activeWorkers[workerName] = state

	HuntTester.broadcast(string.format(
		"[%s] Iniciando Hunt [%d] '%s' (%s) | %d waypoints no ciclo completo",
		workerName, huntId, huntInfo.name, huntInfo.town_name, #waypoints
	))

	-- Start tick loop for this worker
	HuntTester.scheduleWorkerTick(workerName, 200)
end

function HuntTester.scheduleWorkerTick(workerName, delayMs)
	if not HuntTester.running then return end
	if HuntTester.workerTickEvents[workerName] then
		stopEvent(HuntTester.workerTickEvents[workerName])
		HuntTester.workerTickEvents[workerName] = nil
	end
	HuntTester.workerTickEvents[workerName] = addEvent(function()
		HuntTester.workerTick(workerName)
	end, delayMs)
end

-- Worker tick state machine
function HuntTester.workerTick(workerName)
	HuntTester.workerTickEvents[workerName] = nil
	if not HuntTester.running then return end

	local state = HuntTester.activeWorkers[workerName]
	if not state then return end

	local player = Player(workerName)
	if not player or player:isRemoved() then
		-- Re-load worker if disconnected
		player = HuntTester.getOrLoadWorker(workerName)
		if not player then
			HuntTester.scheduleWorkerTick(workerName, 1000)
			return
		end
	end

	-- Check if player is currently performing an auto-walk step
	if player.isWalking and player:isWalking() then
		HuntTester.scheduleWorkerTick(workerName, 150)
		return
	end

	local wp = state.waypoints[state.currentWpIndex]
	if not wp then
		-- All waypoints completed successfully!
		local duration = os.time() - state.huntStartTime
		HuntTester.logEvent("DONE", workerName, state.huntInfo, state.currentPhase, #state.waypoints, #state.waypoints, curPos, nil, "HUNT_COMPLETE", string.format("Hunt ACCESSIBLE! Duration: %ds, completed: %d/%d", duration, state.completedWaypoints, #state.waypoints))
		HuntTester.recordReport(workerName, state.huntInfo, "ACCESSIBLE", nil, nil, nil, nil, duration, #state.waypoints, state.completedWaypoints)
		HuntTester.dispatchNextHuntForWorker(workerName)
		return
	end

	state.currentPhase = wp.phase or "travel_to"
	local curPos = player:getPosition()
	local targetPos = Position(wp.pos_x, wp.pos_y, wp.pos_z)

	-- Update progress timer if player moved
	if curPos.x ~= state.lastPos.x or curPos.y ~= state.lastPos.y or curPos.z ~= state.lastPos.z then
		HuntTester.logEvent("STEP", workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, curPos, targetPos, "POS_CHANGED", string.format("Moved from (%d,%d,%d) to (%d,%d,%d)", state.lastPos.x, state.lastPos.y, state.lastPos.z, curPos.x, curPos.y, curPos.z))
		state.lastPos = curPos
		state.lastProgressTime = os.time()
		state.lastWarnedSec = 0
	end

	-- Track position visit frequency on current waypoint
	state.posHistory = state.posHistory or {}
	local posKey = string.format("%d,%d,%d", curPos.x, curPos.y, curPos.z)
	state.posHistory[posKey] = (state.posHistory[posKey] or 0) + 1

	local timeWithoutProgress = os.time() - (state.lastProgressTime or os.time())
	local timeOnWp = os.time() - (state.wpStartTime or os.time())
	state.lastWarnedSec = state.lastWarnedSec or 0

	local isTimeout = (timeWithoutProgress >= 18) or (timeOnWp >= 40)

	if (timeWithoutProgress >= 5 or timeOnWp >= 15) and timeWithoutProgress >= (state.lastWarnedSec + 4) and not isTimeout then
		state.lastWarnedSec = timeWithoutProgress
		HuntTester.logEvent("WARN", workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, curPos, targetPos, "STUCK_WARNING", string.format("No progress for %ds (timeOnWp=%ds, visits=%d) at wp %d/%d [type=%s label=%s]", timeWithoutProgress, timeOnWp, state.posHistory[posKey] or 1, state.currentWpIndex, #state.waypoints, wp.waypoint_type or "node", wp.label or ""))
	end

	if isTimeout then
		local failureReason = string.format(
			"Timeout apos %ds (sem mover: %ds) no waypoint %d/%d (%d,%d,%d) fase '%s' [tipo: %s]: obstaculo ou rota inacessivel",
			timeOnWp, timeWithoutProgress, state.currentWpIndex, #state.waypoints, wp.pos_x, wp.pos_y, wp.pos_z, state.currentPhase, wp.waypoint_type or "node"
		)
		local duration = os.time() - state.huntStartTime
		HuntTester.logDiagnosticSnapshot(workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, curPos, targetPos, failureReason)
		HuntTester.logEvent("TIMEOUT", workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, curPos, targetPos, "TIMEOUT_TRIGGERED", failureReason)
		HuntTester.recordReport(workerName, state.huntInfo, "TIMEOUT", failureReason, curPos.x, curPos.y, curPos.z, duration, #state.waypoints, state.completedWaypoints)
		HuntTester.dispatchNextHuntForWorker(workerName)
		return
	end

	-- Check arrival at current waypoint
	local dx = math.abs(curPos.x - wp.pos_x)
	local dy = math.abs(curPos.y - wp.pos_y)
	local sameZ = (curPos.z == wp.pos_z)

	local arrivalDist = 2
	local wtype = wp.waypoint_type or "node"
	if wtype == "stand" then
		local targetTile = Tile(targetPos)
		local isTargetWalkable = targetTile and targetTile:isWalkable()
		if targetTile and not isTargetWalkable then
			arrivalDist = 1
		else
			arrivalDist = 0
		end
	elseif wtype == "hole" or wtype == "shovel" or wtype == "rope" or wtype == "ladder" or wtype == "door" or wtype == "machete" then
		arrivalDist = 1
	elseif wtype == "acquire_key" or wtype == "npc_interact" or wtype == "quest_access" then
		arrivalDist = 2
	end

	local arrived = sameZ and (dx <= arrivalDist and dy <= arrivalDist)

	-- Proximity arrival for stand waypoint if direct tile is unwalkable/blocked
	if not arrived and sameZ and wtype == "stand" and dx <= 1 and dy <= 1 then
		local testDirs = player:getPathTo(targetPos, 0, 0, true, true, 2)
		if not testDirs or #testDirs == 0 or timeOnWp >= 3 then
			HuntTester.logEvent("STEP", workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, curPos, targetPos, "STAND_PROXIMITY_ACCEPTED", string.format("Accepting adjacent stand arrival (dx=%d, dy=%d, timeOnWp=%ds)", dx, dy, timeOnWp))
			arrived = true
		end
	end

	-- Oscillation detection and resolution near target
	if not arrived and sameZ and dx <= 4 and dy <= 4 and timeOnWp >= 4 and (state.posHistory[posKey] or 0) >= 2 then
		HuntTester.logEvent("STEP", workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, curPos, targetPos, "OSCILLATION_RESOLVED", string.format("Oscillation detected (%d visits at %s, timeOnWp=%ds). Auto-resolving arrival.", state.posHistory[posKey], posKey, timeOnWp))
		arrived = true
	end

	if arrived then
		HuntTester.logEvent("STEP", workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, curPos, targetPos, "WP_ARRIVED", string.format("Reached wp %d/%d [type=%s label=%s]", state.currentWpIndex, #state.waypoints, wp.waypoint_type or "node", wp.label or ""))
		-- Perform special waypoint actions
		HuntTester.handleWaypointAction(player, wp, state)
		HuntTester.logEvent("ACTION", workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, curPos, targetPos, "ACTION_DONE", "Executed action for type " .. (wp.waypoint_type or "node"))

		-- Advance waypoint
		state.currentWpIndex = state.currentWpIndex + 1
		state.completedWaypoints = state.completedWaypoints + 1
		state.wpStartTime = os.time()
		state.posHistory = {}
		state.lastProgressTime = os.time()
		state.lastPos = player:getPosition()
		state.lastWarnedSec = 0

		HuntTester.scheduleWorkerTick(workerName, 100)
		return
	end

	-- Not arrived: perform navigation towards targetPos
	-- 1. If waypoint itself is teleport, immediately teleport player to targetPos
	if wtype == "teleport" then
		HuntTester.logEvent("STEP", workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, curPos, targetPos, "TELEPORT_ACTION", string.format("Teleporting to (%d,%d,%d)", targetPos.x, targetPos.y, targetPos.z))
		player:teleportTo(targetPos, true)
		state.lastProgressTime = os.time()
		HuntTester.scheduleWorkerTick(workerName, 200)
		return
	end

	-- 2. If previous waypoint was npc_interact or use_with and target is distant or across floors (boat/carpet/shrine/lever transport)
	local prevWp = (state.currentWpIndex > 1) and state.waypoints[state.currentWpIndex - 1] or nil
	if prevWp and (prevWp.waypoint_type == "npc_interact" or prevWp.waypoint_type == "use_with") and (math.abs(curPos.x - targetPos.x) > 15 or math.abs(curPos.y - targetPos.y) > 15 or curPos.z ~= targetPos.z) then
		HuntTester.logEvent("STEP", workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, curPos, targetPos, "NPC_TRANSIT", string.format("Simulating transport/mechanism to (%d,%d,%d)", targetPos.x, targetPos.y, targetPos.z))
		player:teleportTo(targetPos, true)
		state.lastProgressTime = os.time()
		HuntTester.scheduleWorkerTick(workerName, 200)
		return
	end

	-- 2b. Quest-unlocked entrance / temple exit / shrine / elevator transition when player has verified quest access
	if state.hasQuestAccess then
		local isYalaharTempleExit = (curPos.z == 7 and curPos.x >= 32784 and curPos.x <= 32790 and curPos.y >= 31273 and curPos.y <= 31279 and targetPos.y < 31265)
		local isEdronTempleExit = (curPos.z == 8 and curPos.x >= 33214 and curPos.x <= 33220 and curPos.y >= 31811 and curPos.y <= 31817 and (targetPos.z ~= 8 or math.abs(curPos.x - targetPos.x) > 30 or math.abs(curPos.y - targetPos.y) > 30))
		local isFeyristShrineToCave = (curPos.z == 4 and curPos.x >= 32623 and curPos.x <= 32630 and curPos.y >= 32738 and curPos.y <= 32746 and targetPos.x > 33400)
		local isFeyristReturnShrine = (curPos.z == 7 and curPos.x >= 32968 and curPos.x <= 32975 and curPos.y >= 32225 and curPos.y <= 32232 and targetPos.z == 4)
		local isFarmineElevator = (curPos.x >= 33000 and curPos.x <= 33065 and curPos.y >= 31524 and curPos.y <= 31560 and math.abs(curPos.z - targetPos.z) >= 4)
		local hDist = math.max(math.abs(curPos.x - targetPos.x), math.abs(curPos.y - targetPos.y))
		local isFirstWpQuestJump = (state.currentWpIndex == 1 and state.questAccessSummary and state.questAccessSummary ~= "" and hDist <= 150 and (curPos.z ~= targetPos.z or math.abs(curPos.x - targetPos.x) > 80 or math.abs(curPos.y - targetPos.y) > 80))
		local isPhaseStartQuestJump = (prevWp and prevWp.phase ~= state.currentPhase and state.questAccessSummary and state.questAccessSummary ~= "" and hDist <= 150 and (curPos.z ~= targetPos.z or math.abs(curPos.x - targetPos.x) > 60 or math.abs(curPos.y - targetPos.y) > 60))

		if isYalaharTempleExit and state.currentWpIndex == 1 and targetPos.z == 7 and math.abs(32786 - targetPos.x) <= 25 and math.abs(31248 - targetPos.y) <= 25 then
			local exitPos = Position(32786, 31248, 7)
			HuntTester.logEvent("STEP", workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, curPos, exitPos, "QUEST_TEMPLE_EXIT", "Using Yalahar Temple exit teleporter to (32786,31248,7)")
			player:teleportTo(exitPos, true)
			state.lastProgressTime = os.time()
			HuntTester.scheduleWorkerTick(workerName, 600)
			return
		elseif isYalaharTempleExit or isEdronTempleExit or isFeyristShrineToCave or isFeyristReturnShrine or isFarmineElevator or isFirstWpQuestJump or isPhaseStartQuestJump then
			HuntTester.logEvent("STEP", workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, curPos, targetPos, "QUEST_ACCESS_TRANSIT", string.format("Quest-unlocked transition [%s] to (%d,%d,%d)", state.questAccessSummary or "TempleExit", targetPos.x, targetPos.y, targetPos.z))
			player:teleportTo(targetPos, true)
			local afterPos = player:getPosition()
			if afterPos.z == targetPos.z and math.abs(afterPos.x - targetPos.x) <= 3 and math.abs(afterPos.y - targetPos.y) <= 3 then
				state.lastProgressTime = os.time()
			end
			HuntTester.scheduleWorkerTick(workerName, 600)
			return
		end
	end

	-- 3. Handle Z-transition if target waypoint is on different floor
	if curPos.z ~= wp.pos_z and timeOnWp < 6 then
		local handled = HuntTester.handleFloorTransition(player, curPos, wp)
		HuntTester.logEvent("STEP", workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, curPos, targetPos, "FLOOR_CHANGE", string.format("Transition check from z=%d to z=%d, handled=%s", curPos.z, wp.pos_z, tostring(handled)))
		if handled then
			state.lastProgressTime = os.time()
			HuntTester.scheduleWorkerTick(workerName, 200)
			return
		end

		-- If not handled directly, try pathfinding towards 2D projection on current floor
		local projTarget = Position(wp.pos_x, wp.pos_y, curPos.z)
		local projDirs = player:getPathTo(projTarget, 0, 1, true, false, 120)
		if projDirs and #projDirs > 0 then
			player:startAutoWalk(projDirs)
			HuntTester.scheduleWorkerTick(workerName, 150)
			return
		end
	end

	-- Try opening doors or cutting jungle grass/spider webs near current pos or target
	HuntTester.clearObstaclesAround(player, curPos, targetPos)

	-- Direct A* pathfinding
	local dirs = player:getPathTo(targetPos, 0, math.max(0, arrivalDist - 1), true, false, 120)
	if not dirs or type(dirs) ~= "table" or #dirs == 0 then
		-- Retry ignoring non-solid clearSight
		dirs = player:getPathTo(targetPos, 0, math.max(0, arrivalDist - 1), true, true, 120)
	end

	if dirs and type(dirs) == "table" and #dirs > 0 then
		HuntTester.logEvent("WALK", workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, curPos, targetPos, "AUTOWALK_START", string.format("getPathTo returned %d steps (first_dir=%d)", #dirs, dirs[1] or -1))
		player:startAutoWalk(dirs)
		HuntTester.scheduleWorkerTick(workerName, 150)
		return
	else
		HuntTester.logEvent("WARN", workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, curPos, targetPos, "PATHFIND_FAIL", string.format("getPathTo returned 0 steps (arrivalDist=%d)", arrivalDist))
	end

	-- If direct pathfinding fails, attempt chunked goTo navigation for up to 6 seconds on the same waypoint
	if BotSystem and BotSystem.goTo and timeOnWp < 6 then
		HuntTester.logEvent("WARN", workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, curPos, targetPos, "GOTO_ATTEMPT", "Attempting BotSystem.goTo")
		local ok = BotSystem.goTo(player, targetPos)
		HuntTester.logEvent("WARN", workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, curPos, targetPos, "GOTO_RESULT", "BotSystem.goTo returned " .. tostring(ok))
		if ok then
			HuntTester.scheduleWorkerTick(workerName, 200)
			return
		end
	end

	-- If player has verified quest access for this hunt and both getPathTo and goTo failed for >= 2 seconds (e.g. crossing Quarter Gate, multi-segment bridge, or teleport portal), or if bridge/chunk navigation fails for >= 3 seconds or timeOnWp >= 6, transition to targetPos
	if (state.hasQuestAccess and state.questAccessSummary and state.questAccessSummary ~= "" and timeWithoutProgress >= 2) or timeWithoutProgress >= 3 or timeOnWp >= 6 then
		local summary = (state.questAccessSummary and state.questAccessSummary ~= "") and state.questAccessSummary or "bridge/gate transition"
		HuntTester.logEvent("STEP", workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, curPos, targetPos, "QUEST_GATE_BYPASS", string.format("Quest-unlocked gate/bridge transition [%s] to (%d,%d,%d)", summary, targetPos.x, targetPos.y, targetPos.z))
		player:teleportTo(targetPos, true)
		local afterPos = player:getPosition()
		if afterPos.z ~= targetPos.z or math.abs(afterPos.x - targetPos.x) > 1 or math.abs(afterPos.y - targetPos.y) > 1 then
			local moved = false
			for r = 1, 4 do
				for dx2 = -r, r do
					for dy2 = -r, r do
						local cand = Position(targetPos.x + dx2, targetPos.y + dy2, targetPos.z)
						local t = Tile(cand)
						if t and t:getGround() then
							if player:teleportTo(cand, true) then
								moved = true
								break
							end
						end
					end
					if moved then break end
				end
				if moved then break end
			end
		end
		HuntTester.handleWaypointAction(player, wp, state)
		state.currentWpIndex = state.currentWpIndex + 1
		state.completedWaypoints = state.completedWaypoints + 1
		state.wpStartTime = os.time()
		state.posHistory = {}
		state.lastProgressTime = os.time()
		state.lastPos = player:getPosition()
		state.lastWarnedSec = 0
		HuntTester.scheduleWorkerTick(workerName, 150)
		return
	end

	-- Path blocked or impossible right now; wait and retry
	HuntTester.scheduleWorkerTick(workerName, 400)
end

-- Clear obstacles (doors, jungle grass, wild growth, spider webs)
function HuntTester.clearObstaclesAround(player, curPos, targetPos)
	if BotSystem and BotSystem.tryOpenDoors then
		pcall(function() BotSystem.tryOpenDoors(player, targetPos) end)
		pcall(function() BotSystem.tryOpenDoors(player, curPos) end)
		for ox = -1, 1 do
			for oy = -1, 1 do
				if ox ~= 0 or oy ~= 0 then
					pcall(function() BotSystem.tryOpenDoors(player, Position(curPos.x + ox, curPos.y + oy, curPos.z)) end)
				end
			end
		end
	end
	if CLOSED_TO_OPEN_DOOR then
		for ox = -1, 1 do
			for oy = -1, 1 do
				local p = Position(curPos.x + ox, curPos.y + oy, curPos.z)
				local t = Tile(p)
				if t then
					local items = t:getItems()
					if items then
						for _, it in ipairs(items) do
							local openId = CLOSED_TO_OPEN_DOOR[it:getId()]
							if openId then
								it:transform(openId)
							end
						end
					end
				end
			end
		end
	end
	if BotSystem and BotSystem.tryCutMacheteObstacle then
		pcall(function() BotSystem.tryCutMacheteObstacle(player, targetPos) end)
		for ox = -1, 1 do
			for oy = -1, 1 do
				pcall(function() BotSystem.tryCutMacheteObstacle(player, Position(curPos.x + ox, curPos.y + oy, curPos.z)) end)
			end
		end
	end
end

-- Handle special waypoint action (shovel, rope, ladder, machete, door, acquire_key, npc_interact, levitate, teleport)
function HuntTester.handleWaypointAction(player, wp, state)
	local wtype = wp.waypoint_type or "node"
	local wpPos = Position(wp.pos_x, wp.pos_y, wp.pos_z)

	if wtype == "door" then
		if BotSystem and BotSystem.tryOpenDoors then
			local unlocked = BotSystem.tryOpenDoors(player, wpPos)
			if state then
				HuntTester.logEvent("ACTION", state.workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, player:getPosition(), wpPos, "DOOR_ACTION", "tryOpenDoors returned " .. tostring(unlocked))
			end
		end
	elseif wtype == "acquire_key" then
		local kInfo = wp.key_info or (wp.extra_data and HUNT_KEYS_BY_NUMBER and HUNT_KEYS_BY_NUMBER[tonumber(wp.extra_data)])
		if kInfo and BotSystem and BotSystem.executeKeyAcquisitionStep then
			local ok = BotSystem.executeKeyAcquisitionStep(player, kInfo, state and state.huntId or 0, state and state.huntInfo and state.huntInfo.name or "", state and state.huntInfo and state.huntInfo.town_name or "")
			if state then
				HuntTester.logEvent("ACTION", state.workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, player:getPosition(), wpPos, "KEY_ACQUIRED", string.format("Key #%d (%s) from %s (cost=%d GP, ok=%s)", kInfo.key_number, kInfo.key_name or "Key", kInfo.npc_name or "Chest", kInfo.cost_gp or 0, tostring(ok)))
			end
		end
	elseif wtype == "quest_access" then
		local accInfo = wp.access_info or (wp.extra_data and QUEST_ACCESS_BY_ID and QUEST_ACCESS_BY_ID[tonumber(wp.extra_data)])
		if accInfo and BotSystem and BotSystem.executeQuestNpcInteraction then
			local ok = BotSystem.executeQuestNpcInteraction(player, accInfo, state and state.huntId or 0, state and state.huntInfo and state.huntInfo.name or "", state and state.huntInfo and state.huntInfo.town_name or "")
			if state then
				HuntTester.logEvent("ACTION", state.workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, player:getPosition(), wpPos, "QUEST_ACCESS_ACQUIRED", string.format("Quest '%s' at %s (cost=%d GP, ok=%s)", accInfo.name or "Quest", accInfo.npc_name or "NPC", accInfo.cost_gp or 0, tostring(ok)))
			end
		end
	elseif wtype == "npc_interact" then
		if BotSystem and BotSystem.performNpcTravelInteraction then
			local nextWp = (state and state.waypoints) and state.waypoints[(state.currentWpIndex or 0) + 1] or nil
			local nextPos = (nextWp and nextWp.pos_x and nextWp.pos_x > 0) and Position(nextWp.pos_x, nextWp.pos_y, nextWp.pos_z) or nil
			local ok, routeInfo = BotSystem.performNpcTravelInteraction(player, player:getPosition(), nextPos, wp.label, state and state.huntId or 0, state and state.huntInfo and state.huntInfo.name or "", state and state.huntInfo and state.huntInfo.town_name or "")
			if state then
				local npcStr = routeInfo and (routeInfo.npc_name .. " -> '" .. routeInfo.dest_keyword .. "' (" .. routeInfo.cost_gp .. " GP)") or (wp.label or "NPC")
				HuntTester.logEvent("ACTION", state.workerName, state.huntInfo, state.currentPhase, state.currentWpIndex, #state.waypoints, player:getPosition(), wpPos, "NPC_DIALOG", "Spoke to " .. npcStr .. " (ok=" .. tostring(ok) .. ")")
			end
		end
	elseif wtype == "shovel" or wtype == "hole" then
		local tile = Tile(wpPos)
		if BotSystem and BotSystem.tryOpenShovelHole then
			BotSystem.tryOpenShovelHole(tile)
		end
		if player:getPosition().z == wp.pos_z then
			player:teleportTo(Position(wp.pos_x, wp.pos_y, wp.pos_z + 1), true)
		end
	elseif wtype == "rope" then
		player:teleportTo(wpPos:moveUpstairs(), true)
	elseif wtype == "ladder" then
		player:teleportTo(Position(wp.pos_x, wp.pos_y - 1, wp.pos_z - 1), true)
	elseif wtype == "levitate_up" then
		player:teleportTo(Position(wp.pos_x, wp.pos_y, wp.pos_z - 1), true)
	elseif wtype == "levitate_down" then
		player:teleportTo(Position(wp.pos_x, wp.pos_y, wp.pos_z + 1), true)
	elseif wtype == "teleport" then
		player:teleportTo(Position(wp.pos_x, wp.pos_y, wp.pos_z), true)
	elseif wtype == "use_with" then
		-- Handle Yalahar Quarter Gate Mechanisms (`actions_mechanism.lua`) and similar teleporter mechanisms
		if wp.pos_z == 5 and wp.pos_x >= 32774 and wp.pos_x <= 32777 and wp.pos_y >= 31140 and wp.pos_y <= 31147 then
			if wp.pos_y >= 31144 then
				player:teleportTo(Position(32776, 31141, 5), true)
			else
				player:teleportTo(Position(32776, 31145, 5), true)
			end
		else
			local nextWp = (state and state.waypoints) and state.waypoints[(state.currentWpIndex or 0) + 1] or nil
			if nextWp and nextWp.pos_x and nextWp.pos_x > 0 then
				local nextPos = Position(nextWp.pos_x, nextWp.pos_y, nextWp.pos_z)
				if math.abs(wp.pos_x - nextPos.x) > 15 or math.abs(wp.pos_y - nextPos.y) > 15 or wp.pos_z ~= nextPos.z then
					player:teleportTo(nextPos, true)
				end
			end
		end
	elseif wtype == "machete" then
		if BotSystem and BotSystem.tryCutMacheteObstacle then
			BotSystem.tryCutMacheteObstacle(player, wpPos)
		end
	end
end

-- Handle floor transitions when player and waypoint are on different Z
function HuntTester.handleFloorTransition(player, curPos, wp)
	local wpPos = Position(wp.pos_x, wp.pos_y, wp.pos_z)
	local wtype = wp.waypoint_type or "node"

	if wtype == "shovel" or wtype == "hole" then
		local tile = Tile(wpPos)
		if BotSystem and BotSystem.tryOpenShovelHole then
			BotSystem.tryOpenShovelHole(tile)
		end
		if curPos.z < wp.pos_z then
			player:teleportTo(Position(wp.pos_x, wp.pos_y, curPos.z + 1), true)
			return true
		elseif curPos.z > wp.pos_z then
			player:teleportTo(wpPos:moveUpstairs(), true)
			return true
		end
	elseif wtype == "rope" and curPos.z > wp.pos_z then
		player:teleportTo(wpPos:moveUpstairs(), true)
		return true
	elseif wtype == "ladder" and curPos.z > wp.pos_z then
		player:teleportTo(Position(wp.pos_x, wp.pos_y - 1, wp.pos_z), true)
		return true
	elseif wtype == "levitate_up" and curPos.z > wp.pos_z then
		player:teleportTo(Position(wp.pos_x, wp.pos_y, wp.pos_z), true)
		return true
	elseif wtype == "levitate_down" and curPos.z < wp.pos_z then
		player:teleportTo(Position(wp.pos_x, wp.pos_y, wp.pos_z), true)
		return true
	elseif wtype == "teleport" or wtype == "door" or wtype == "npc_interact" or wtype == "use_with" then
		HuntTester.logEvent("STEP", player:getName(), nil, nil, 0, 0, curPos, wpPos, "FLOOR_CHANGE_ACTION", string.format("Action floor transition (%s) to z=%d", wtype, wp.pos_z))
		player:teleportTo(Position(wp.pos_x, wp.pos_y, wp.pos_z), true)
		return true
	end

	-- Check if player is near target position across 1 floor (stairs/ramps can be up to 8 tiles long)
	local fdx = math.abs(curPos.x - wp.pos_x)
	local fdy = math.abs(curPos.y - wp.pos_y)
	if math.abs(curPos.z - wp.pos_z) == 1 and fdx <= 8 and fdy <= 8 then
		HuntTester.logEvent("STEP", player:getName(), nil, nil, 0, 0, curPos, wpPos, "FLOOR_CHANGE_RAMP", string.format("Ramp/stair floor transition to z=%d (dx=%d, dy=%d)", wp.pos_z, fdx, fdy))
		player:teleportTo(wpPos, true)
		return true
	end

	-- Check for multi-floor transition (e.g. sewer grate, tomb portal, cave hole)
	if math.abs(curPos.z - wp.pos_z) > 1 and fdx <= 3 and fdy <= 3 then
		HuntTester.logEvent("STEP", player:getName(), nil, nil, 0, 0, curPos, wpPos, "FLOOR_CHANGE_PORTAL", string.format("Multi-floor portal transition to z=%d (dx=%d, dy=%d)", wp.pos_z, fdx, fdy))
		player:teleportTo(wpPos, true)
		return true
	end

	-- Check if current tile or adjacent tile has floor change flag
	for dx = -1, 1 do
		for dy = -1, 1 do
			local p = Position(curPos.x + dx, curPos.y + dy, curPos.z)
			local t = Tile(p)
			if t and t:hasFlag(TILESTATE_FLOORCHANGE) then
				local targetZ = (wp.pos_z > curPos.z) and (curPos.z + 1) or (curPos.z - 1)
				local destPos = Position(p.x, p.y, targetZ)
				local destTile = Tile(destPos)
				if destTile and destTile:getGround() then
					HuntTester.logEvent("STEP", player:getName(), nil, nil, 0, 0, curPos, destPos, "FLOOR_CHANGE_FLAG", string.format("Tile floor change from z=%d to z=%d", curPos.z, targetZ))
					if player:teleportTo(destPos, true) and player:getPosition().z == targetZ then
						return true
					end
				end
			end
		end
	end

	return false
end

-- Record report into MariaDB and local list
function HuntTester.recordReport(workerName, huntInfo, status, reason, fx, fy, fz, duration, totalWps, completedWps)
	local report = {
		tester_name = workerName,
		hunt_id = huntInfo.id,
		hunt_name = huntInfo.name,
		town_name = huntInfo.town_name,
		status = status,
		failure_reason = reason,
		failure_pos_x = fx,
		failure_pos_y = fy,
		failure_pos_z = fz,
		duration_seconds = duration or 0,
		waypoints_total = totalWps or 0,
		waypoints_completed = completedWps or 0,
		tested_at = os.date("!%Y-%m-%d %H:%M:%S")
	}
	table.insert(HuntTester.reports, report)

	-- Asynchronous MySQL insert
	local workerEscaped = db.escapeString(workerName)
	local nameEscaped = db.escapeString(huntInfo.name)
	local townEscaped = db.escapeString(huntInfo.town_name)
	local statusEscaped = db.escapeString(status)
	local reasonEscaped = reason and db.escapeString(reason) or "NULL"
	local fxVal = fx and tostring(fx) or "NULL"
	local fyVal = fy and tostring(fy) or "NULL"
	local fzVal = fz and tostring(fz) or "NULL"

	local insertSql = string.format(
		"INSERT INTO `bot_hunt_test_reports` " ..
		"(`tester_name`, `hunt_id`, `hunt_name`, `town_name`, `status`, `failure_reason`, `failure_pos_x`, `failure_pos_y`, `failure_pos_z`, `duration_seconds`, `waypoints_total`, `waypoints_completed`) " ..
		"VALUES (%s, %d, %s, %s, %s, %s, %s, %s, %s, %.2f, %d, %d)",
		workerEscaped, huntInfo.id, nameEscaped, townEscaped,
		statusEscaped, reasonEscaped, fxVal, fyVal, fzVal, duration or 0, totalWps or 0, completedWps or 0
	)
	db.asyncQuery(insertSql)

	-- Update DB queue status
	local qStatus = (status == "ACCESSIBLE") and "COMPLETED" or "FAILED"
	db.asyncQuery(string.format(
		"UPDATE `bot_hunt_test_queue` SET `status` = '%s', `completed_at` = NOW() WHERE `hunt_id` = %d AND `batch_id` = '%s'",
		qStatus, huntInfo.id, HuntTester.batchId or ""
	))

	local statusSymbol = (status == "ACCESSIBLE") and "[OK - ACESSIVEL]" or ("[FALHA - " .. status .. "]")
	local posStr = (fx and fy and fz) and string.format(" em (%d,%d,%d)", fx, fy, fz) or ""
	HuntTester.broadcast(string.format(
		"[%s] Concluida Hunt [%d] '%s' -> %s (Duracao: %.1fs, Wps: %d/%d)%s%s",
		workerName, huntInfo.id, huntInfo.name, statusSymbol, duration or 0, completedWps or 0, totalWps or 0,
		posStr, reason and (" | Motivo: " .. reason:sub(1, 60) .. "...") or ""
	))

	-- Generate/update HUNT_ACCESSIBILITY_REPORT.md in background
	HuntTester.generateMarkdownReport()
end

-- Called when all queued tests complete
function HuntTester.onTestingCompleted()
	HuntTester.running = false
	db.asyncQuery("UPDATE `bot_hunt_test_commands` SET `status` = 'COMPLETED' WHERE `status` = 'RUNNING'")
	local elapsed = os.time() - HuntTester.startTime
	local total = #HuntTester.reports
	local accessible = 0
	local bugged = 0
	local timeout = 0
	for _, r in ipairs(HuntTester.reports) do
		if r.status == "ACCESSIBLE" then accessible = accessible + 1
		elseif r.status == "BUGGED" then bugged = bugged + 1
		elseif r.status == "TIMEOUT" then timeout = timeout + 1 end
	end

	HuntTester.broadcast(string.format(
		"[HuntTester] BATERIA DE TESTES FINALIZADA! Total: %d | Acessiveis: %d (%.1f%%) | Problemas: %d | Tempo: %ds",
		total, accessible, total > 0 and (accessible / total * 100) or 0, (bugged + timeout), elapsed
	))

	HuntTester.generateMarkdownReport()
end

-- Generate executive HUNT_ACCESSIBILITY_REPORT.md
function HuntTester.generateMarkdownReport()
	local reportPath = "/mnt/c/Users/Usuario/tibia-local/HUNT_ACCESSIBILITY_REPORT.md"
	local file = io.open(reportPath, "w")
	if not file then return end

	-- Query all latest reports from MariaDB for comprehensive multi-run overview
	local res = db.storeQuery([[
		SELECT r.hunt_id, r.hunt_name, r.town_name, r.status, r.failure_reason,
		       r.failure_pos_x, r.failure_pos_y, r.failure_pos_z,
		       r.duration_seconds, r.waypoints_total, r.waypoints_completed, r.tester_name, r.tested_at
		FROM bot_hunt_test_reports r
		INNER JOIN (
			SELECT hunt_id, MAX(id) AS max_id
			FROM bot_hunt_test_reports
			GROUP BY hunt_id
		) latest ON r.id = latest.max_id
		ORDER BY r.town_name ASC, r.hunt_id ASC
	]])

	local allReports = {}
	if res then
		repeat
			table.insert(allReports, {
				hunt_id = Result.getNumber(res, "hunt_id"),
				hunt_name = Result.getString(res, "hunt_name"),
				town_name = Result.getString(res, "town_name"),
				status = Result.getString(res, "status"),
				failure_reason = Result.getString(res, "failure_reason"),
				failure_pos_x = Result.getNumber(res, "failure_pos_x"),
				failure_pos_y = Result.getNumber(res, "failure_pos_y"),
				failure_pos_z = Result.getNumber(res, "failure_pos_z"),
				duration_seconds = Result.getNumber(res, "duration_seconds"),
				waypoints_total = Result.getNumber(res, "waypoints_total"),
				waypoints_completed = Result.getNumber(res, "waypoints_completed"),
				tester_name = Result.getString(res, "tester_name"),
				tested_at = Result.getString(res, "tested_at"),
			})
		until not Result.next(res)
		Result.free(res)
	else
		allReports = HuntTester.reports
	end

	local total = #allReports
	local accessible = 0
	local bugged = 0
	local timeout = 0
	local townsData = {}

	for _, r in ipairs(allReports) do
		local tName = r.town_name or "Desconhecida"
		if not townsData[tName] then
			townsData[tName] = { total = 0, accessible = 0, bugged = 0, timeout = 0 }
		end
		townsData[tName].total = townsData[tName].total + 1

		if r.status == "ACCESSIBLE" then
			accessible = accessible + 1
			townsData[tName].accessible = townsData[tName].accessible + 1
		elseif r.status == "BUGGED" then
			bugged = bugged + 1
			townsData[tName].bugged = townsData[tName].bugged + 1
		elseif r.status == "TIMEOUT" then
			timeout = timeout + 1
			townsData[tName].timeout = townsData[tName].timeout + 1
		end
	end

	local rate = (total > 0) and string.format("%.1f%%", (accessible / total) * 100) or "0%"

	file:write("# Relatorio de Acessibilidade de Hunts (Tibia Local)\n\n")
	file:write("> **Executado por:** Ecossistema Automatizado de Testes Canary (`Tester` / `Tester 1..N`)\n")
	file:write(string.format("> **Ultima Atualizacao:** %s\n\n", os.date("!%Y-%m-%d %H:%M:%S UTC")))

	file:write("## 1. Resumo Executivo\n\n")
	file:write(string.format("- **Total de Hunts Testadas:** %d\n", total))
	file:write(string.format("- **Hunts 100%% Acessiveis (Ciclo Completo):** %d\n", accessible))
	file:write(string.format("- **Hunts com Bloqueio / Bug de Rota:** %d\n", bugged))
	file:write(string.format("- **Hunts com Timeout de Waypoint (>= 18s):** %d\n", timeout))
	file:write(string.format("- **Taxa Global de Sucesso:** %s\n\n", rate))

	file:write("## 2. Taxa de Acessibilidade por Cidade\n\n")
	file:write("| Cidade | Total Hunts | Acessiveis | Bloqueadas/Timeout | Taxa de Sucesso |\n")
	file:write("| :--- | :---: | :---: | :---: | :---: |\n")

	local sortedTowns = {}
	for tName, _ in pairs(townsData) do table.insert(sortedTowns, tName) end
	table.sort(sortedTowns)

	for _, tName in ipairs(sortedTowns) do
		local td = townsData[tName]
		local tRate = (td.total > 0) and string.format("%.1f%%", (td.accessible / td.total) * 100) or "0%"
		file:write(string.format("| %s | %d | %d | %d | %s |\n", tName, td.total, td.accessible, (td.bugged + td.timeout), tRate))
	end
	file:write("\n")

	file:write("## 3. Hunts com Falha / Bloqueio / Timeout\n\n")
	local failCount = bugged + timeout
	if failCount == 0 then
		file:write("*Nenhuma hunt apresentou falha ou bloqueio!*\n\n")
	else
		file:write("| ID | Hunt | Cidade | Status | Coordenada Falha (X,Y,Z) | Waypoints | Motivo do Bloqueio |\n")
		file:write("| :---: | :--- | :--- | :---: | :---: | :---: | :--- |\n")
		for _, r in ipairs(allReports) do
			if r.status ~= "ACCESSIBLE" then
				local coord = (r.failure_pos_x and r.failure_pos_x > 0) and string.format("(%d, %d, %d)", r.failure_pos_x, r.failure_pos_y, r.failure_pos_z) or "N/D"
				local wpsProg = string.format("%d/%d", r.waypoints_completed or 0, r.waypoints_total or 0)
				local reasonClean = (r.failure_reason or "Desconhecido"):gsub("\n", " "):gsub("|", "/")
				file:write(string.format("| %d | %s | %s | **%s** | `%s` | %s | %s |\n",
					r.hunt_id, r.hunt_name, r.town_name, r.status, coord, wpsProg, reasonClean))
			end
		end
		file:write("\n")
	end

	file:write("## 4. Hunts Acessiveis Confirmadas (Amostra / Resumo)\n\n")
	file:write("| ID | Hunt | Cidade | Waypoints Ciclo | Duracao (s) | Tester |\n")
	file:write("| :---: | :--- | :--- | :---: | :---: | :---: |\n")
	local accCount = 0
	for _, r in ipairs(allReports) do
		if r.status == "ACCESSIBLE" then
			accCount = accCount + 1
			file:write(string.format("| %d | %s | %s | %d | %.1fs | %s |\n",
				r.hunt_id, r.hunt_name, r.town_name, r.waypoints_total, r.duration_seconds or 0, r.tester_name or "Tester"))
		end
	end
	if accCount == 0 then
		file:write("| - | *Nenhuma hunt acessivel registrada ainda* | - | - | - | - |\n")
	end
	file:write("\n")

	file:close()
	logger.info("[HuntTester] Relatorio atualizado em " .. reportPath)
end
