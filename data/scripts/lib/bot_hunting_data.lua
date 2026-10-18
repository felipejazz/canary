-- Bot Hunting Data Loader
-- Loads all hunt scripts, waypoints, targets, and city routes from MySQL
-- into Lua tables for fast lookup by the bot system.
-- Must be loaded before bot_manager.lua (alphabetically "bot_h" < "bot_m")

BotHuntData = {
	scripts = {},       -- {[script_id] = {name, town_id, min_level, max_level, vocation_mask, source, script_type, spawn_group}}
	waypoints = {},     -- {[script_id] = {travel_to={...}, hunt_patrol={...}, travel_from={...}}}
	targets = {},       -- {[script_id] = {{monster_name, priority, behavior, proximity_radius}, ...}}
	fields = {},        -- {[script_id] = {{field_type, action}, ...}}
	cityRoutes = {},    -- {[town_id] = {[route_type] = {{waypoint_type, pos_x, pos_y, pos_z, action_label}, ...}}}
	routeGraph = {},    -- {[town_id] = {pairs={[src]={[dst]={wps}}}, pois={[name]={x,y,z}}}}
	byTown = {},        -- {[town_id] = {script_id, ...}} -- index for fast lookup
	activeHunts = {},   -- {[script_id] = bot_id or nil} -- tracks which bot has which script
	activeSpawnGroups = {},  -- {[spawn_group] = bot_id or nil} -- 1 bot per physical spawn
}

function BotHuntData.loadAll()
	local startTime = os.clock()
	BotHuntData.scripts = {}
	BotHuntData.waypoints = {}
	BotHuntData.targets = {}
	BotHuntData.fields = {}
	BotHuntData.cityRoutes = {}
	BotHuntData.routeGraph = {}
	BotHuntData.byTown = {}
	BotHuntData.activeHunts = {}
	BotHuntData.activeSpawnGroups = {}

	BotHuntData._loadScripts()
	BotHuntData._loadWaypoints()
	BotHuntData._loadTargets()
	BotHuntData._loadFields()
	BotHuntData._loadCityRoutes()
	BotHuntData._loadRouteGraph()
	BotHuntData._buildTownIndex()

	local elapsed = math.floor((os.clock() - startTime) * 1000)
	local scriptCount = 0
	for _ in pairs(BotHuntData.scripts) do scriptCount = scriptCount + 1 end
	local townCount = 0
	for _ in pairs(BotHuntData.byTown) do townCount = townCount + 1 end
	local routeCount = 0
	for _, routes in pairs(BotHuntData.cityRoutes) do
		for _ in pairs(routes) do routeCount = routeCount + 1 end
	end

	-- Count spawn groups
	local spawnGroupSet = {}
	for _, script in pairs(BotHuntData.scripts) do
		if script.spawn_group then
			spawnGroupSet[script.spawn_group] = (spawnGroupSet[script.spawn_group] or 0) + 1
		end
	end
	local groupCount = 0
	local multiGroupCount = 0
	for _, cnt in pairs(spawnGroupSet) do
		groupCount = groupCount + 1
		if cnt > 1 then multiGroupCount = multiGroupCount + 1 end
	end

	-- Count route graph pairs
	local graphPairCount = 0
	for _, graph in pairs(BotHuntData.routeGraph) do
		for _, dsts in pairs(graph.pairs) do
			for _ in pairs(dsts) do graphPairCount = graphPairCount + 1 end
		end
	end

	logger.info("[BotHuntData] Loaded {} hunt scripts across {} towns, {} city routes, {} route pairs, {} spawn groups ({} shared) ({}ms)",
		scriptCount, townCount, routeCount, graphPairCount, groupCount, multiGroupCount, elapsed)
end

function BotHuntData._loadScripts()
	local resultId = db.storeQuery(
		"SELECT `id`, `name`, `source`, `source_file`, `town_name`, `town_id`, " ..
		"`min_level`, `max_level`, `vocation_mask`, `script_type` " ..
		"FROM `bot_hunt_scripts` WHERE `enabled` = 1"
	)
	if not resultId then
		logger.warn("[BotHuntData] No enabled hunt scripts found")
		return
	end

	repeat
		local id = Result.getNumber(resultId, "id")
		local name = Result.getString(resultId, "name")
		-- spawn_group column removed: after the per-vocation hunt-route de-dup there is one row
		-- per physical spawn, so the lowercased name IS the 1-bot-per-spawn reservation key.
		local spawnGroup = name:lower()
		BotHuntData.scripts[id] = {
			name = name,
			source = Result.getString(resultId, "source"),
			town_name = Result.getString(resultId, "town_name"),
			town_id = Result.getNumber(resultId, "town_id"),
			min_level = Result.getNumber(resultId, "min_level"),
			max_level = Result.getNumber(resultId, "max_level"),
			vocation_mask = Result.getNumber(resultId, "vocation_mask"),
			script_type = Result.getString(resultId, "script_type"),
			spawn_group = spawnGroup,
		}
	until not Result.next(resultId)
	Result.free(resultId)
end

function BotHuntData._loadWaypoints()
	local resultId = db.storeQuery(
		"SELECT w.`script_id`, w.`phase`, w.`seq`, w.`waypoint_type`, " ..
		"w.`pos_x`, w.`pos_y`, w.`pos_z`, w.`label`, w.`extra_data` " ..
		"FROM `bot_hunt_waypoints` w " ..
		"JOIN `bot_hunt_scripts` s ON s.`id` = w.`script_id` " ..
		"WHERE s.`enabled` = 1 " ..
		"ORDER BY w.`script_id`, w.`phase`, w.`seq`"
	)
	if not resultId then return end

	repeat
		local scriptId = Result.getNumber(resultId, "script_id")
		local phase = Result.getString(resultId, "phase")

		if not BotHuntData.waypoints[scriptId] then
			BotHuntData.waypoints[scriptId] = {
				travel_to = {},
				hunt_patrol = {},
				travel_from = {},
			}
		end

		local wp = {
			waypoint_type = Result.getString(resultId, "waypoint_type"),
			pos_x = Result.getNumber(resultId, "pos_x"),
			pos_y = Result.getNumber(resultId, "pos_y"),
			pos_z = Result.getNumber(resultId, "pos_z"),
			label = Result.getString(resultId, "label"),
			extra_data = Result.getString(resultId, "extra_data"),
		}

		local phaseList = BotHuntData.waypoints[scriptId][phase]
		if phaseList then
			phaseList[#phaseList + 1] = wp
		end
	until not Result.next(resultId)
	Result.free(resultId)
end

function BotHuntData._loadTargets()
	local resultId = db.storeQuery(
		"SELECT t.`script_id`, t.`monster_name`, t.`priority`, t.`behavior`, " ..
		"t.`min_hp_percent`, t.`max_hp_percent`, t.`count`, t.`proximity_radius` " ..
		"FROM `bot_hunt_targets` t " ..
		"JOIN `bot_hunt_scripts` s ON s.`id` = t.`script_id` " ..
		"WHERE s.`enabled` = 1 " ..
		"ORDER BY t.`script_id`, t.`priority` DESC"
	)
	if not resultId then return end

	repeat
		local scriptId = Result.getNumber(resultId, "script_id")
		if not BotHuntData.targets[scriptId] then
			BotHuntData.targets[scriptId] = {}
		end

		local target = {
			monster_name = Result.getString(resultId, "monster_name"),
			priority = Result.getNumber(resultId, "priority"),
			behavior = Result.getString(resultId, "behavior"),
			min_hp_percent = Result.getNumber(resultId, "min_hp_percent"),
			max_hp_percent = Result.getNumber(resultId, "max_hp_percent"),
			count = Result.getNumber(resultId, "count"),
			proximity_radius = Result.getNumber(resultId, "proximity_radius"),
		}

		BotHuntData.targets[scriptId][#BotHuntData.targets[scriptId] + 1] = target
	until not Result.next(resultId)
	Result.free(resultId)
end

function BotHuntData._loadFields()
	local resultId = db.storeQuery(
		"SELECT f.`script_id`, f.`field_type`, f.`action` " ..
		"FROM `bot_hunt_fields` f " ..
		"JOIN `bot_hunt_scripts` s ON s.`id` = f.`script_id` " ..
		"WHERE s.`enabled` = 1"
	)
	if not resultId then return end

	repeat
		local scriptId = Result.getNumber(resultId, "script_id")
		if not BotHuntData.fields[scriptId] then
			BotHuntData.fields[scriptId] = {}
		end

		BotHuntData.fields[scriptId][#BotHuntData.fields[scriptId] + 1] = {
			field_type = Result.getString(resultId, "field_type"),
			action = Result.getString(resultId, "action"),
		}
	until not Result.next(resultId)
	Result.free(resultId)
end

function BotHuntData._loadCityRoutes()
	local resultId = db.storeQuery(
		"SELECT r.`town_id`, r.`route_type`, " ..
		"w.`seq`, w.`waypoint_type`, w.`pos_x`, w.`pos_y`, w.`pos_z`, w.`action_label` " ..
		"FROM `bot_city_routes` r " ..
		"JOIN `bot_city_route_waypoints` w ON w.`route_id` = r.`id` " ..
		"WHERE r.`enabled` = 1 " ..
		"ORDER BY r.`town_id`, r.`route_type`, w.`seq`"
	)
	if not resultId then return end

	repeat
		local townId = Result.getNumber(resultId, "town_id")
		local routeType = Result.getString(resultId, "route_type")

		if not BotHuntData.cityRoutes[townId] then
			BotHuntData.cityRoutes[townId] = {}
		end
		if not BotHuntData.cityRoutes[townId][routeType] then
			BotHuntData.cityRoutes[townId][routeType] = {}
		end

		local wp = {
			waypoint_type = Result.getString(resultId, "waypoint_type"),
			pos_x = Result.getNumber(resultId, "pos_x"),
			pos_y = Result.getNumber(resultId, "pos_y"),
			pos_z = Result.getNumber(resultId, "pos_z"),
			action_label = Result.getString(resultId, "action_label"),
		}

		local route = BotHuntData.cityRoutes[townId][routeType]
		route[#route + 1] = wp
	until not Result.next(resultId)
	Result.free(resultId)
end

function BotHuntData._buildTownIndex()
	for scriptId, script in pairs(BotHuntData.scripts) do
		local townId = script.town_id
		if not BotHuntData.byTown[townId] then
			BotHuntData.byTown[townId] = {}
		end
		BotHuntData.byTown[townId][#BotHuntData.byTown[townId] + 1] = scriptId
	end
end

-- ============================================================================
-- Route Graph: full source→destination route pairs for city navigation
-- ============================================================================

function BotHuntData._loadRouteGraph()
	-- Load ALL city routes with source_name to build the full route graph
	local resultId = db.storeQuery(
		"SELECT r.`id`, r.`town_id`, r.`source_name`, " ..
		"w.`seq`, w.`waypoint_type`, w.`pos_x`, w.`pos_y`, w.`pos_z`, w.`action_label` " ..
		"FROM `bot_city_routes` r " ..
		"JOIN `bot_city_route_waypoints` w ON w.`route_id` = r.`id` " ..
		"ORDER BY r.`id`, w.`seq`"
	)
	if not resultId then
		logger.warn("[BotHuntData] No city route waypoints found")
		return
	end

	-- Collect waypoints grouped by route id
	local routeWps = {}      -- {[routeId] = {waypoints}}
	local routeMeta = {}     -- {[routeId] = {townId, sourceName}}

	repeat
		local routeId = Result.getNumber(resultId, "id")
		local townId = Result.getNumber(resultId, "town_id")
		local sourceName = Result.getString(resultId, "source_name")

		if not routeWps[routeId] then
			routeWps[routeId] = {}
			routeMeta[routeId] = { townId = townId, sourceName = sourceName }
		end

		routeWps[routeId][#routeWps[routeId] + 1] = {
			waypoint_type = Result.getString(resultId, "waypoint_type"),
			pos_x = Result.getNumber(resultId, "pos_x"),
			pos_y = Result.getNumber(resultId, "pos_y"),
			pos_z = Result.getNumber(resultId, "pos_z"),
			action_label = Result.getString(resultId, "action_label"),
		}
	until not Result.next(resultId)
	Result.free(resultId)

	-- Parse each route's source_name and build the graph
	local totalPairs = 0
	local totalPois = 0

	for routeId, wps in pairs(routeWps) do
		local meta = routeMeta[routeId]
		local townId = meta.townId
		local src, dst = BotHuntData._parseRouteName(meta.sourceName)
		if not src or not dst then
			-- Skip unparseable routes
			goto continue_route
		end

		-- Normalize to lowercase
		src = src:lower()
		dst = dst:lower()

		-- Initialize town graph
		if not BotHuntData.routeGraph[townId] then
			BotHuntData.routeGraph[townId] = { pairs = {}, pois = {} }
		end
		local graph = BotHuntData.routeGraph[townId]

		-- Store route pair
		if not graph.pairs[src] then
			graph.pairs[src] = {}
		end
		graph.pairs[src][dst] = wps
		totalPairs = totalPairs + 1

		-- Extract POI positions from route endpoints
		-- Source POI = first stand/node waypoint
		if not graph.pois[src] and #wps > 0 then
			local firstWp = wps[1]
			if firstWp.pos_x > 0 then
				graph.pois[src] = { x = firstWp.pos_x, y = firstWp.pos_y, z = firstWp.pos_z }
				totalPois = totalPois + 1
			end
		end
		-- Destination POI = last stand/node waypoint
		if not graph.pois[dst] and #wps > 0 then
			local lastWp = wps[#wps]
			if lastWp.pos_x > 0 then
				graph.pois[dst] = { x = lastWp.pos_x, y = lastWp.pos_y, z = lastWp.pos_z }
				totalPois = totalPois + 1
			end
		end

		::continue_route::
	end

	-- Log summary per town
	for townId, graph in pairs(BotHuntData.routeGraph) do
		local pairCount = 0
		local srcCount = 0
		for src, dsts in pairs(graph.pairs) do
			srcCount = srcCount + 1
			for _ in pairs(dsts) do pairCount = pairCount + 1 end
		end
		local poiCount = 0
		for _ in pairs(graph.pois) do poiCount = poiCount + 1 end
		logger.info("[BotHuntData] Town {} route graph: {} pairs, {} sources, {} POIs",
			townId, pairCount, srcCount, poiCount)
	end

	logger.info("[BotHuntData] Route graph loaded: {} total pairs, {} POI positions", totalPairs, totalPois)
end

-- Parse source_name like "venore|temple~bank:" → "temple", "bank"
function BotHuntData._parseRouteName(sourceName)
	if not sourceName or sourceName == "" then return nil, nil end
	-- Format: "townname|source~destination:" or "townname|source~dest:"
	local afterPipe = sourceName:match("|(.+)")
	if not afterPipe then return nil, nil end
	afterPipe = afterPipe:gsub(":$", "")
	local src, dst = afterPipe:match("^(.+)~(.+)$")
	return src, dst
end

-- Get a direct route between two POIs in a town
function BotHuntData.getDirectRoute(townId, source, destination)
	local graph = BotHuntData.routeGraph[townId]
	if not graph or not graph.pairs[source] then return nil end
	return graph.pairs[source][destination]
end

-- Get route reversed (look for dst→src and reverse waypoints)
function BotHuntData.getRouteReversed(townId, source, destination)
	local fwd = BotHuntData.getDirectRoute(townId, destination, source)
	if not fwd then return nil end
	local rev = {}
	for i = #fwd, 1, -1 do
		rev[#rev + 1] = fwd[i]
	end
	return rev
end

function BotHuntData.ensureLoaded()
	if not BotHuntData._loaded or next(BotHuntData.scripts) == nil then
		BotHuntData._loaded = true
		BotHuntData.loadAll()
	end
end

-- Find a route between two POIs (direct first, then reversed)
function BotHuntData.findRoute(townId, source, destination)
	BotHuntData.ensureLoaded()
	source = source:lower()
	destination = destination:lower()
	-- 1. Direct route
	local route = BotHuntData.getDirectRoute(townId, source, destination)
	if route then return route, false end
	-- 2. Reversed route
	route = BotHuntData.getRouteReversed(townId, source, destination)
	if route then return route, true end
	return nil, nil
end

-- Detect nearest POI to a position in a town
function BotHuntData.detectNearestPOI(townId, pos)
	BotHuntData.ensureLoaded()
	local graph = BotHuntData.routeGraph[townId]
	if not graph or not graph.pois then return nil, 999 end
	local best, bestDist = nil, 999
	for name, p in pairs(graph.pois) do
		local d = math.abs(pos.x - p.x) + math.abs(pos.y - p.y) + math.abs(pos.z - p.z) * 10
		if d < bestDist then
			bestDist = d
			best = name
		end
	end
	return best, bestDist
end

-- List all POI names for a town
function BotHuntData.listPOIs(townId)
	BotHuntData.ensureLoaded()
	local graph = BotHuntData.routeGraph[townId]
	if not graph or not graph.pois then return {} end
	local names = {}
	for name, _ in pairs(graph.pois) do
		names[#names + 1] = name
	end
	table.sort(names)
	return names
end

-- List all route pairs for a town (returns list of {src, dst})
function BotHuntData.listRoutes(townId)
	BotHuntData.ensureLoaded()
	local graph = BotHuntData.routeGraph[townId]
	if not graph or not graph.pairs then return {} end
	local routes = {}
	for src, dsts in pairs(graph.pairs) do
		for dst, _ in pairs(dsts) do
			routes[#routes + 1] = { src = src, dst = dst }
		end
	end
	table.sort(routes, function(a, b)
		if a.src ~= b.src then return a.src < b.src end
		return a.dst < b.dst
	end)
	return routes
end

-- ============================================================================

-- Find eligible hunt scripts for a bot player
-- Returns a list of {scriptId, script} sorted by preference
function BotHuntData.findHuntsForBot(player, botData, archetype, state)
	BotHuntData.ensureLoaded()
	local level = player:getLevel()
	local vocation = player:getVocation()
	local vocId = vocation and vocation:getId() or 0
	-- Map vocation ID to bitmask: 1=MS(1,5), 2=ED(2,6), 4=RP(3,7), 8=EK(4,8)
	local vocBit = 0
	local baseVoc = vocId > 4 and (vocId - 4) or vocId
	if baseVoc == 1 then vocBit = 1      -- Sorcerer / Master Sorcerer
	elseif baseVoc == 2 then vocBit = 2  -- Druid / Elder Druid
	elseif baseVoc == 3 then vocBit = 4  -- Paladin / Royal Paladin
	elseif baseVoc == 4 then vocBit = 8  -- Knight / Elite Knight
	else vocBit = 15 end                 -- No vocation = any

	local currentTownId = botData.townId
	local eligible = {}

	local levelOffset = (archetype and archetype.levelOffset) or 0
	local effectiveLevel = level + levelOffset

	for scriptId, script in pairs(BotHuntData.scripts) do
		-- Level check (incorporates personality level offset bonus)
		if effectiveLevel >= script.min_level and level <= (script.max_level + 3) then
			-- Skip training spots (slimes, goblins) from regular hunting
			if script.script_type == "train" then
				goto continue_script
			end

			-- Vocation check (bitmask AND)
			if bit.band(script.vocation_mask, vocBit) > 0 then
				-- Up to 2-bots-per-spawn check
				local spawnKey = script.spawn_group or tostring(scriptId)
				BotHuntData.activeSpawnOccupants = BotHuntData.activeSpawnOccupants or {}
				local sOcc = BotHuntData.activeSpawnOccupants[spawnKey] or {}
				local sCount = 0
				for _ in pairs(sOcc) do sCount = sCount + 1 end
				local spawnFull = (sCount >= 2)

				if not spawnFull then
					-- Has waypoints and targets?
					local wps = BotHuntData.waypoints[scriptId]
					local tgts = BotHuntData.targets[scriptId]
					if wps and #wps.hunt_patrol > 0 and tgts and #tgts > 0 then
						-- Reachability & preference scoring (underground caves are valid, especially with travel_to routes)
						local huntTownZ = CITY_WALK_Z and CITY_WALK_Z[script.town_id]
						local hasSurfaceStart = false
						if huntTownZ then
							if wps.travel_to and #wps.travel_to > 0 and wps.travel_to[1].pos_z == huntTownZ then
								hasSurfaceStart = true
							else
								for _, wp in ipairs(wps.hunt_patrol) do
									if wp.pos_z and wp.pos_z == huntTownZ then
										hasSurfaceStart = true
										break
									end
								end
							end
						else
							hasSurfaceStart = true
						end

						local preference = 0
						-- Strong preference for hunts in current town (no boat travel needed)
						if script.town_id == currentTownId then
							preference = preference + 100
						end
						if hasSurfaceStart then
							preference = preference + 25
						end
						-- Slight preference for scripts matching exact vocation
						if script.vocation_mask ~= 15 then
							preference = preference + 10
						end

						-- Personalidade & Resposta a Morte:
						-- 1. Vingança do Arrojado: quer voltar na mesma cave onde morreu
						if state and state.revengeHuntId and state.revengeHuntId == scriptId then
							preference = preference + 250
						end
						-- 2. Cauteloso: evita a cave onde acabou de morrer
						if state and state.lastDeathCaveId and state.lastDeathCaveId == scriptId then
							if archetype and archetype.id == 1 then
								preference = preference - 500
							end
						end
						-- 3. Arrojado: bônus para caves com min_level maior que o level atual (mais XP / perigo)
						if archetype and archetype.id == 2 then
							if script.min_level > level then
								preference = preference + 50
							end
						end
						-- 4. Mercenário: bônus para caves com monstros que dropam itens de valor e ouro
						if archetype and archetype.id == 3 and script.name then
							local sname = script.name:lower()
							if sname:find("rotworm") or sname:find("mino") or sname:find("dwarf")
								or sname:find("amazon") or sname:find("elf") or sname:find("larva") then
								preference = preference + 60
							end
						end

						eligible[#eligible + 1] = {
							scriptId = scriptId,
							script = script,
							preference = preference,
						}
					end
				end
			end
		end
		::continue_script::
	end

	-- Assign random tiebreak values, then sort by preference descending
	for _, entry in ipairs(eligible) do
		entry._rand = math.random()
	end
	table.sort(eligible, function(a, b)
		if a.preference ~= b.preference then
			return a.preference > b.preference
		end
		return a._rand < b._rand
	end)

	logger.info(string.format("[BotHunt] Bot %s (Lvl %d, Town %d) found %d eligible hunts",
		player:getName(), level, currentTownId or 0, #eligible))

	return eligible
end

-- Reserve a hunt script for a bot (returns true if successful, allowing up to 2 bots per spawn)
function BotHuntData.reserveHunt(scriptId, botId)
	BotHuntData.activeHuntOccupants = BotHuntData.activeHuntOccupants or {}
	BotHuntData.activeSpawnOccupants = BotHuntData.activeSpawnOccupants or {}

	local hOccupants = BotHuntData.activeHuntOccupants[scriptId] or {}
	local hCount = 0
	for _ in pairs(hOccupants) do hCount = hCount + 1 end
	if hCount >= 2 then
		return false -- already 2 bots on this script
	end

	-- Check spawn_group reservation (allows up to 2 bots at same physical spawn)
	local script = BotHuntData.scripts[scriptId]
	local spawnKey = script and script.spawn_group or tostring(scriptId)
	local sOccupants = BotHuntData.activeSpawnOccupants[spawnKey] or {}
	local sCount = 0
	for _ in pairs(sOccupants) do sCount = sCount + 1 end
	if sCount >= 2 then
		return false -- already 2 bots in this physical spawn
	end

	hOccupants[botId] = true
	BotHuntData.activeHuntOccupants[scriptId] = hOccupants
	sOccupants[botId] = true
	BotHuntData.activeSpawnOccupants[spawnKey] = sOccupants

	BotHuntData.activeHunts[scriptId] = botId
	BotHuntData.activeSpawnGroups[spawnKey] = botId

	local p = Player(botId)
	if p and script then
		logger.info(string.format("[HuntAssign] %s (lv%d voc%d) -> '%s' (id=%d town=%s) spawn=%s [occupants=%d/2]",
			p:getName(), p:getLevel(), p:getVocation():getId(),
			script.name or "?", scriptId, script.town_name or "?", spawnKey, sCount + 1))
	end

	return true
end

-- Release a hunt script reservation
function BotHuntData.releaseHunt(scriptId, botId)
	BotHuntData.activeHuntOccupants = BotHuntData.activeHuntOccupants or {}
	BotHuntData.activeSpawnOccupants = BotHuntData.activeSpawnOccupants or {}

	local released = false
	if BotHuntData.activeHuntOccupants[scriptId] and BotHuntData.activeHuntOccupants[scriptId][botId] then
		BotHuntData.activeHuntOccupants[scriptId][botId] = nil
		released = true
	end

	local script = BotHuntData.scripts[scriptId]
	local spawnKey = script and script.spawn_group or tostring(scriptId)
	if BotHuntData.activeSpawnOccupants[spawnKey] and BotHuntData.activeSpawnOccupants[spawnKey][botId] then
		BotHuntData.activeSpawnOccupants[spawnKey][botId] = nil
		released = true
	end

	if BotHuntData.activeHunts[scriptId] == botId then
		BotHuntData.activeHunts[scriptId] = nil
	end
	if BotHuntData.activeSpawnGroups[spawnKey] == botId then
		BotHuntData.activeSpawnGroups[spawnKey] = nil
	end

	return released
end

-- Get the waypoint list for a specific phase of a hunt
function BotHuntData.getPhaseWaypoints(scriptId, phase)
	local wps = BotHuntData.waypoints[scriptId]
	if not wps then return nil end
	return wps[phase]
end

-- Get targets for a hunt script
function BotHuntData.getTargets(scriptId)
	return BotHuntData.targets[scriptId] or {}
end

-- Get city route waypoints for a town
function BotHuntData.getCityRoute(townId, routeType)
	local routes = BotHuntData.cityRoutes[townId]
	if not routes then return nil end
	return routes[routeType]
end

-- Get all available route types for a town
function BotHuntData.getCityRouteTypes(townId)
	local routes = BotHuntData.cityRoutes[townId]
	if not routes then return {} end
	local types = {}
	for routeType, _ in pairs(routes) do
		types[#types + 1] = routeType
	end
	return types
end
