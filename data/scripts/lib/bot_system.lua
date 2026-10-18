-- ============================================================================
-- Bot Player System -- Gesior-style auto-walk for Canary 13.x
-- 200 bots across all cities, inter-city travel, fight/flight, random PK
-- Uses creature:startAutoWalk() + creature:isWalking() (server-side walk scheduler)
-- ============================================================================

if db and not db.botAsyncStoreQuery then
	db.botAsyncStoreQuery = db.asyncStoreQuery or function(q, cb) local res = db.storeQuery(q); if cb then cb(res) end end
end
if db and not db.botAsyncQuery then
	db.botAsyncQuery = db.asyncQuery or function(q, cb) local res = db.query(q); if cb then cb(res) end end
end

if Player and not Player.isBotPlayer then
	function Player.isBotPlayer(self)
		if not self then return false end
		local name = self:getName()
		return (BotPlayers and BotPlayers[self:getGuid()] ~= nil) or (name and name:sub(1, 4) == "Bot ")
	end
end

if Player and not Player.getCastViewerCount then
	function Player.getCastViewerCount(self)
		return 0
	end
end

local botWalkQueues = {}
local botWalkEvents = {}

local function stepBotWalk(guid)
	botWalkEvents[guid] = nil
	local player = BotPlayers and BotPlayers[guid]
	if not player or player:isRemoved() then
		botWalkQueues[guid] = nil
		return
	end

	local s = BotState and BotState[guid]
	if s and s.manualControl then
		botWalkQueues[guid] = nil
		return
	end

	local queue = botWalkQueues[guid]
	if not queue or #queue == 0 then
		botWalkQueues[guid] = nil
		return
	end

	-- Canary A* (Map::getPathMatching) builds dirList from destination back to start,
	-- so the first step from the bot's current position is at the END of the table (#queue).
	local dir = table.remove(queue)
	local ret = player:move(dir)
	local noError = rawget(_G, "RETURNVALUE_NOERROR") or 0
	if ret ~= noError and ret ~= true and ret ~= 0 then
		botWalkQueues[guid] = nil
		return
	end

	if #queue > 0 then
		local speed = player:getSpeed() or 120
		local delay = math.max(150, math.min(500, math.floor(35000 / math.max(speed, 50))))
		botWalkEvents[guid] = addEvent(stepBotWalk, delay, guid)
	else
		botWalkQueues[guid] = nil
	end
end

local function implIsWalking(self)
	if not self then return false end
	local guid = self.getGuid and self:getGuid() or (self.getId and self:getId())
	if not guid then return false end
	local q = botWalkQueues[guid]
	return q ~= nil and #q > 0
end

local function implStartAutoWalk(self, dirs)
	if not self then return false end
	local guid = self.getGuid and self:getGuid() or (self.getId and self:getId())
	if not guid then return false end
	if botWalkEvents[guid] then
		stopEvent(botWalkEvents[guid])
		botWalkEvents[guid] = nil
	end
	if not dirs or type(dirs) ~= "table" or #dirs == 0 then
		botWalkQueues[guid] = nil
		return false
	end
	local q = {}
	for _, d in ipairs(dirs) do
		table.insert(q, d)
	end
	botWalkQueues[guid] = q
	stepBotWalk(guid)
	return true
end

local function implStopWalk(self)
	if not self then return end
	local guid = self.getGuid and self:getGuid() or (self.getId and self:getId())
	if not guid then return end
	if botWalkEvents[guid] then
		stopEvent(botWalkEvents[guid])
		botWalkEvents[guid] = nil
	end
	botWalkQueues[guid] = nil
end

local function implSetChaseMode(self, chase)
	if not self then return false end
	if chase then
		local target = self.getTarget and self:getTarget() or nil
		if target and self.setFollowCreature then
			pcall(function() self:setFollowCreature(target) end)
		end
	else
		if self.setFollowCreature then
			pcall(function() self:setFollowCreature(nil) end)
		end
	end
	return true
end

local function implSetFightMode(self, _mode)
	return true
end

local function implSetSlotItem(self, slot, itemId, count)
	if not self or not slot or not itemId or itemId <= 0 then return false end
	local cur = self.getSlotItem and self:getSlotItem(slot) or nil
	if cur then
		pcall(function() cur:remove() end)
	end
	local item = Game.createItem(itemId, count or 1)
	if not item then return false end
	local flags = rawget(_G, "FLAG_NOLIMIT") or 1
	local ok, ret = pcall(function() return self:addItemEx(item, false, slot, flags) end)
	if not ok then return false end
	local noError = rawget(_G, "RETURNVALUE_NOERROR") or 0
	return ret == noError or ret == true or ret == 0
end

local function implCastSpell(self, spellName, target)
	if not self or self:isRemoved() or not spellName then return false end
	target = target or (self.getTarget and self:getTarget() or nil)
	if not target or target:isRemoved() or target:getHealth() <= 0 then return false end

	local pos = self:getPosition()
	local tpos = target:getPosition()
	if pos.z ~= tpos.z then return false end

	-- Find spell metadata in BOT_SPELLS
	local spellDef = nil
	if BOT_SPELLS then
		for _, list in pairs(BOT_SPELLS) do
			for _, sp in ipairs(list) do
				if sp.name == spellName then
					spellDef = sp
					break
				end
			end
			if spellDef then break end
		end
	end

	self:say(spellName, TALKTYPE_MONSTER_SAY)
	if spellDef and spellDef.projectile then
		pcall(function() pos:sendDistanceEffect(tpos, spellDef.projectile) end)
	end
	if spellDef and spellDef.effect then
		pcall(function() tpos:sendMagicEffect(spellDef.effect) end)
	end

	-- For monsters, apply damage via doTargetCombatHealth (PvP damage is handled by doCastSpell)
	local isTargetPlayer = Player(target:getId()) ~= nil
	if not isTargetPlayer then
		local baseDmg = (spellDef and spellDef.baseDmg) or 22
		local level = self.getLevel and self:getLevel() or 20
		local minDmg = math.max(8, math.floor(baseDmg * (1 + level / 80) * 0.85))
		local maxDmg = math.max(minDmg + 4, math.floor(baseDmg * (1 + level / 80) * 1.25))
		local ctype = (spellDef and spellDef.combatType) or COMBAT_PHYSICALDAMAGE
		local eff = (spellDef and spellDef.effect) or CONST_ME_HITAREA
		if doTargetCombatHealth then
			pcall(function()
				doTargetCombatHealth(self, target, ctype, -minDmg, -maxDmg, eff)
			end)
		else
			pcall(function()
				target:addHealth(-math.random(minDmg, maxDmg), ctype, self)
			end)
		end
	end

	return true
end

local function formatTibiaChatText(text)
	if type(text) ~= "string" or text == "" then return text or "" end
	-- 3-byte UTF-8 punctuation
	text = text:gsub("\226\128\148", "-")  -- em-dash —
	text = text:gsub("\226\128\147", "-")  -- en-dash –
	text = text:gsub("\226\128\156", '"')  -- left smart quote “
	text = text:gsub("\226\128\157", '"')  -- right smart quote ”
	text = text:gsub("\226\128\152", "'")  -- left single quote ‘
	text = text:gsub("\226\128\153", "'")  -- right single quote ’
	text = text:gsub("\226\128\166", "...") -- ellipsis …
	-- 2-byte UTF-8 Portuguese / Latin-1 supplement characters (\195\xxx)
	local utf8Map = {
		["\195\161"] = "a", ["\195\160"] = "a", ["\195\162"] = "a", ["\195\163"] = "a", ["\195\164"] = "a",
		["\195\129"] = "A", ["\195\128"] = "A", ["\195\130"] = "A", ["\195\131"] = "A", ["\195\132"] = "A",
		["\195\169"] = "e", ["\195\168"] = "e", ["\195\170"] = "e", ["\195\171"] = "e",
		["\195\137"] = "E", ["\195\136"] = "E", ["\195\138"] = "E", ["\195\139"] = "E",
		["\195\173"] = "i", ["\195\172"] = "i", ["\195\174"] = "i", ["\195\175"] = "i",
		["\195\141"] = "I", ["\195\140"] = "I", ["\195\142"] = "I", ["\195\143"] = "I",
		["\195\179"] = "o", ["\195\178"] = "o", ["\195\180"] = "o", ["\195\181"] = "o", ["\195\182"] = "o",
		["\195\147"] = "O", ["\195\146"] = "O", ["\195\148"] = "O", ["\195\149"] = "O", ["\195\150"] = "O",
		["\195\186"] = "u", ["\195\185"] = "u", ["\195\187"] = "u", ["\195\188"] = "u",
		["\195\154"] = "U", ["\195\153"] = "U", ["\195\155"] = "U", ["\195\156"] = "U",
		["\195\167"] = "c", ["\195\135"] = "C",
		["\195\177"] = "n", ["\195\145"] = "N",
	}
	for k, v in pairs(utf8Map) do
		text = text:gsub(k, v)
	end
	-- Strip any remaining non-ASCII bytes and normalize whitespace
	text = text:gsub("[\128-\255]+", "")
	text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	return text
end

_G._origCanaryCreatureSay = _G._origCanaryCreatureSay or (Creature and Creature.say or nil)
_G._origCanaryPlayerSay = _G._origCanaryPlayerSay or (Player and Player.say or nil)

local function implFormattedSay(self, text, speakType, ghost, echo, pos)
	if type(text) == "string" then
		text = formatTibiaChatText(text)
	end
	local fn = _G._origCanaryPlayerSay or _G._origCanaryCreatureSay
	if not fn then return false end
	if pos ~= nil then
		return fn(self, text, speakType, ghost, echo, pos)
	elseif echo ~= nil then
		return fn(self, text, speakType, ghost, echo)
	elseif ghost ~= nil then
		return fn(self, text, speakType, ghost)
	elseif speakType ~= nil then
		return fn(self, text, speakType)
	else
		return fn(self, text)
	end
end

local function implSetMana(self, targetMana)
	if not self then return false end
	local cur = self.getMana and self:getMana() or 0
	local diff = (tonumber(targetMana) or 0) - cur
	if diff ~= 0 and self.addMana then
		self:addMana(diff)
	end
	return true
end

if Player then
	Player.isWalking = implIsWalking
	Player.startAutoWalk = implStartAutoWalk
	Player.stopWalk = implStopWalk
	Player.setChaseMode = Player.setChaseMode or implSetChaseMode
	Player.setFightMode = Player.setFightMode or implSetFightMode
	Player.setSlotItem = Player.setSlotItem or implSetSlotItem
	Player.castSpell = Player.castSpell or implCastSpell
	Player.setMana = Player.setMana or implSetMana
	Player.say = implFormattedSay
end
if Creature then
	Creature.isWalking = implIsWalking
	Creature.startAutoWalk = implStartAutoWalk
	Creature.stopWalk = implStopWalk
	Creature.setChaseMode = Creature.setChaseMode or implSetChaseMode
	Creature.setFightMode = Creature.setFightMode or implSetFightMode
	Creature.castSpell = Creature.castSpell or implCastSpell
	Creature.say = implFormattedSay
end

-- Configuration
BOT_CONFIG = {
	-- TEMP TEST 1 (2026-05-21): master disable for GAP_SLOW infrastructure-cause test.
	-- When true, all bot-driven globalevents short-circuit and TARGET_ONLINE forced to 0.
	-- Test 1 RESULT: 1 GAP_SLOW in 10 min with bots off vs ~139/hr with bots on (~23× drop).
	-- Confirms: bots are the load source. Now testing taskset CPU pinning.
	MASTER_DISABLE = false,
	BOT_ACCOUNT_ID = 65000,
	-- Active bot count comes from config.lua botPlayersOnline (default 75 if unset).
	-- Capped by BotStartup against the actual DB pool size.
	TARGET_ONLINE = 3,
	-- Sole consumer is botManager:interval() (bot_manager.lua), whose onThink body is now
	-- ONLY the bot_commands queue poll — the population manager it was named for is disabled.
	-- Was 10000, which made every /cavebot command wait 0-10s (mean 5s) and made agentic
	-- debugging impractical. The 10s was never a DB-safety value: `git show ad4210bcd~1`
	-- shows this interval predated the DB poll, pacing a population ramp at 2 bots/tick.
	-- Safe to lower: the poll is async on the dedicated bot-DB worker (g_botDatabaseTasks,
	-- own thread + own connection, never touches databaseLock), and GlobalEvents::think()
	-- already runs a 200ms floor in production via jitter_heartbeat.lua.
	MANAGER_INTERVAL = 1000,          -- ms between bot_commands queue polls
	THINK_INTERVAL = 100,             -- ms between AI ticks (100ms for smooth walking)
	THINK_INTERVAL_WALK = 500,        -- ms for bots walking/traveling (engine handles steps)
	THINK_INTERVAL_IDLE = 2000,       -- ms between AI ticks for IDLE/DWELLING bots
	PATH_MAX_DIST = 50,              -- max A* search distance
	WAYPOINT_DIST = 20,              -- intermediate waypoint distance for long walks
	CHAT_CHANCE = 300,               -- 1/N chance per tick to say something
	HEAL_THRESHOLD_PERCENT = 60,
	ATTACK_COOLDOWN = 2,             -- seconds between attacks
	HEAL_COOLDOWN = 1,               -- seconds between heals
	DEAD_POSITION = Position(31970, 32283, 7),  -- staging area for inactive bots
	LOG_INTERVAL = 30,               -- log position every N ticks (~30 seconds)
	POI_DWELL_MIN = 10,              -- 10 seconds min dwell at POI (fast testing)
	POI_DWELL_MAX = 25,              -- 25 seconds max dwell at POI (fast testing)
	POI_ARRIVAL_DIST = 3,            -- tiles from POI center to count as "arrived"
	STUCK_THRESHOLD = 5,             -- consecutive POI failures before switching POI
	-- Loitering removed: real players walk to destinations, not stop mid-road
	TRAVEL_CHANCE_PER_TICK = 1000,   -- 1/N per tick (~0.1%, travel every ~15-20 min)
	TRAVEL_PAUSE_MIN = 5,            -- seconds to "wait at dock"
	TRAVEL_PAUSE_MAX = 12,
	PK_CHANCE_PER_TICK = 400,        -- 1/N per tick (~0.25%) to PK a real player
	PK_BOT_CHANCE_PER_TICK = 4000,   -- 1/N per tick (~0.025%) to PK another bot
	PK_TIMEOUT = 15,                 -- seconds before PK bot gives up
	COMBAT_TIMEOUT = 30,             -- seconds before combat/flee state resets
	COMBAT_LEASH_DIST = 15,         -- max distance to chase attacker before giving up
	FLEE_DISTANCE = 15,              -- tiles to run when fleeing
	-- Hunting config
	HUNT_CHANCE_PER_TICK = 3,        -- 1/N per tick (~33%) to start a hunt when idle/dwelling
	HUNT_DURATION_MIN = 1800,        -- 30 min minimum hunt duration
	HUNT_DURATION_MAX = 10800,       -- 3 hr maximum hunt duration
	HUNT_COOLDOWN_MIN = 30,          -- 30s min between hunts
	HUNT_COOLDOWN_MAX = 90,          -- 90s max between hunts
	HUNT_RESUPPLY_BANK_MIN = 5,      -- seconds at bank NPC
	HUNT_RESUPPLY_BANK_MAX = 10,
	HUNT_RESUPPLY_DEPOT_MIN = 8,     -- seconds at depot
	HUNT_RESUPPLY_DEPOT_MAX = 15,
	HUNT_RESUPPLY_SHOP_MIN = 5,      -- seconds at each shop NPC
	HUNT_RESUPPLY_SHOP_MAX = 10,
	MACRO_DECISION_COOLDOWN = 40,    -- seconds per bot between autonomous Node.js macro decisions
	DIALOGUE_COOLDOWN = 180,         -- seconds per bot between Bot-to-Bot conversations
	DIALOGUE_GLOBAL_COOLDOWN = 45,   -- seconds global between Bot-to-Bot conversations
	HUNT_MONSTER_SCAN_RADIUS = 7,
	HUNT_MONSTER_ATTACK_CD = 2,      -- seconds between monster attacks
	HUNT_SAFETY_TIMEOUT = 14400,     -- 4h max per hunt session
	HUNT_WAYPOINT_SKIP_DELAY = 200,  -- ms delay when trying next waypoint on failure
	HUNT_STUCK_THRESHOLD = 30,       -- consecutive skips without progress before abort
	HUNT_NODE_ARRIVAL_DIST = 2,      -- tiles from node to count as arrived
	HUNT_CHASE_FAIL_LIMIT = 8,       -- ticks of failed chase before giving up on target
	HUNT_IGNORE_DURATION = 30,       -- seconds to ignore an unreachable monster
	HUNT_BLOCKER_FAIL_LIMIT = 10,    -- ticks before giving up on a path blocker
	DEBUG_COMBAT = true,             -- enable combat debug logging
	DEBUG_COMBAT_INTERVAL = 5,       -- seconds between debug log entries per bot
	-- Debug mode: set to true to load only 1 bot for testing z-transitions
	DEBUG_MODE = false,
	DEBUG_BOT_NAME = "Bashana Parra",  -- nil = first bot in DB; set "BotName" to pick specific bot
	-- 2026-05-28: when TARGET_ONLINE (i.e. config.lua botPlayersOnline) is set to 1, BotManager
	-- will load the named bot specifically instead of the lowest-id bot from stratification.
	-- Set to "" to use default stratified pick. Useful for isolated cast-watch testing.
	SINGLE_BOT_NAME = "Dya Blackwind",
	-- Cached at load time: true when binary compiled with -DDEBUG_LOG (cmake Debug build)
	IS_DEBUG_BUILD = Game.isDebugBuild and Game.isDebugBuild() or false,
}

-- State enum
BOT_STATE = {
	INACTIVE  = 0,
	IDLE      = 1,   -- walking between POIs
	DWELLING  = 2,   -- standing at a POI (simulating interaction)
	COMBAT    = 3,   -- fighting back against attacker
	FLEEING   = 4,   -- running away from attacker
	TRAVELING = 5,   -- paused at dock, about to teleport to another city
	PK_ATTACK = 6,   -- randomly attacking a nearby player
	HUNTING   = 7,   -- hunting monsters (travel/patrol/leave/resupply)
	PARTY     = 8,   -- following a player in a party (/party command)
	TRAINING  = 9,   -- walking to offline training statue, logging out & auto-relogging with target skill
}

HUNT_PHASE = {
	PREPARING    = 0,  -- depot box + shops BEFORE heading to spawn
	TRAVEL_TO    = 1,  -- city -> spawn entrance
	PATROLLING   = 2,  -- hunt loop: walk waypoints + fight monsters
	LEAVING      = 3,  -- spawn exit -> city
	RESUPPLYING  = 4,  -- bank -> depot -> shops -> re-hunt or end
}

-- Floor change sub-states (multi-tick state machine, BBot-inspired)
FLOOR_CHANGE_STATE = {
	NONE        = 0,  -- no floor change in progress
	SCANNING    = 1,  -- finding transitions nearby
	WALKING_TO  = 2,  -- pathfinding to adjacent tile
	STEPPING_ON = 3,  -- stepping onto the floor-change tile
	VERIFYING   = 4,  -- waiting to confirm z changed (~2 ticks)
	USING_ITEM  = 5,  -- using rope/shovel/ladder on tile
	COMPLETED   = 6,  -- z-change confirmed, resume navigation
	FAILED      = 7,  -- all attempts exhausted
}

-- ============================================================================
-- Spell tables: per vocation, level-gated, with cooldowns
-- ============================================================================

BOT_SPELLS = {
	[1] = { -- Sorcerer (base voc 1)
		{level = 1,   name = "exori vis",          combatType = COMBAT_ENERGYDAMAGE, range = 3, effect = CONST_ME_ENERGYHIT,    cd = 2, baseDmg = 15},
		{level = 23,  name = "exori mort",         combatType = COMBAT_DEATHDAMAGE,  range = 3, effect = CONST_ME_MORTAREA,     cd = 2, baseDmg = 25},
		{level = 28,  name = "exevo vis lux",      combatType = COMBAT_ENERGYDAMAGE, range = 5, effect = CONST_ME_ENERGYAREA,   cd = 4, baseDmg = 30},
		{level = 45,  name = "adori vita vis",     combatType = COMBAT_DEATHDAMAGE,  range = 5, effect = CONST_ME_MORTAREA,     cd = 4, baseDmg = 50, isRune = true, pvpOnly = true},
		{level = 60,  name = "exori gran vis",     combatType = COMBAT_ENERGYDAMAGE, range = 3, effect = CONST_ME_ENERGYHIT,    cd = 8, baseDmg = 45},
	},
	[2] = { -- Druid (base voc 2)
		{level = 1,   name = "exori flam",         combatType = COMBAT_FIREDAMAGE,   range = 3, effect = CONST_ME_FIREATTACK,   cd = 2, baseDmg = 15},
		{level = 21,  name = "exori frigo",        combatType = COMBAT_ICEDAMAGE,    range = 3, effect = CONST_ME_ICEATTACK,    cd = 2, baseDmg = 20},
		{level = 28,  name = "exevo frigo hur",    combatType = COMBAT_ICEDAMAGE,    range = 5, effect = CONST_ME_ICEAREA,      cd = 4, baseDmg = 30},
		{level = 45,  name = "adori vita vis",     combatType = COMBAT_DEATHDAMAGE,  range = 5, effect = CONST_ME_MORTAREA,     cd = 4, baseDmg = 50, isRune = true, pvpOnly = true},
		{level = 60,  name = "exori gran frigo",   combatType = COMBAT_ICEDAMAGE,    range = 3, effect = CONST_ME_ICEAREA,      cd = 8, baseDmg = 45},
	},
	[3] = { -- Paladin (base voc 3)
		{level = 1,   name = "exori san",          combatType = COMBAT_HOLYDAMAGE,   range = 5, effect = CONST_ME_HOLYDAMAGE,   cd = 2, baseDmg = 20, projectile = CONST_ANI_ROYALSPEAR},
		{level = 24,  name = "exori con",          combatType = COMBAT_PHYSICALDAMAGE,range = 5, cd = 2, baseDmg = 25, projectile = CONST_ANI_ROYALSPEAR},
		{level = 60,  name = "exori gran con",     combatType = COMBAT_PHYSICALDAMAGE,range = 5, cd = 6, baseDmg = 40, projectile = CONST_ANI_ROYALSPEAR},
	},
	[4] = { -- Knight (base voc 4)
		{level = 1,   name = "exori min",          combatType = COMBAT_PHYSICALDAMAGE, range = 1, effect = CONST_ME_HITAREA,    cd = 2, baseDmg = 15},
		{level = 20,  name = "exori",              combatType = COMBAT_PHYSICALDAMAGE, range = 1, effect = CONST_ME_HITAREA,    cd = 2, baseDmg = 25},
		{level = 35,  name = "exori hur",          combatType = COMBAT_PHYSICALDAMAGE, range = 1, effect = CONST_ME_HITAREA,    cd = 4, baseDmg = 35},
		{level = 45,  name = "exori gran",         combatType = COMBAT_PHYSICALDAMAGE, range = 1, effect = CONST_ME_HITAREA,    cd = 6, baseDmg = 50},
		{level = 90,  name = "exori gran ico",     combatType = COMBAT_ICEDAMAGE,      range = 1, effect = CONST_ME_ICEATTACK,  cd = 8, baseDmg = 60},
	},
}

BOT_HEAL_SPELLS = {
	[1] = { -- Sorcerer
		{level = 1,  name = "exura",       heal = 80,   cd = 1},
		{level = 30, name = "exura vita",  heal = 200,  cd = 2},
	},
	[2] = { -- Druid
		{level = 1,  name = "exura",       heal = 80,   cd = 1},
		{level = 30, name = "exura vita",  heal = 200,  cd = 2},
	},
	[3] = { -- Paladin
		{level = 1,  name = "exura",       heal = 80,   cd = 1},
		{level = 30, name = "exura san",   heal = 250,  cd = 2},
	},
	[4] = { -- Knight
		{level = 1,  name = "exura",       heal = 80,   cd = 1},
		{level = 30, name = "exura ico",   heal = 300,  cd = 2},
	},
}

-- ============================================================================
-- City Points of Interest (POIs) — keyed by town_id
-- Coordinates from NPC spawn data in otservbr-npc.xml
-- Positions are street-side (not inside buildings)
-- ============================================================================

-- Walking z-level per city (may differ from temple z-level)
-- e.g. Ankrahmun temple is underground z=8 but city streets are z=7
CITY_WALK_Z = {
	[5]  = 7,   -- Ab'Dendriel (surface)
	[6]  = 7,   -- Carlin (surface)
	[7]  = 11,  -- Kazordoon (underground dwarf city at z=11)
	[8]  = 7,   -- Thais (surface)
	[9]  = 7,   -- Venore (surface)
	[10] = 7,   -- Ankrahmun (temple underground z=8, city surface z=7)
	[11] = 8,   -- Edron (mountain city z=8)
	[12] = 10,  -- Farmine (temple z=11, city surface z=10)
	[13] = 7,   -- Darashia (temple at z=1 tower, city surface z=7)
	[14] = 7,   -- Liberty Bay (surface)
	[15] = 7,   -- Port Hope (surface)
	[16] = 7,   -- Svargrond (surface)
	[17] = 7,   -- Yalahar (surface)
	[18] = 9,   -- Gray Beach (surface z=9)
	[19] = 8,   -- Krailos (surface z=8)
	[20] = 6,   -- Rathleton (main level z=6)
	[21] = 6,   -- Roshamuul (main level z=6)
	[22] = 5,   -- Issavi (main level z=5)
	[24] = 7,   -- Cobra Bastion (surface)
	[25] = 7,   -- Bounac (surface)
	[26] = 7,   -- Feyrist (surface)
	[27] = 14,  -- Gnomprona (deep underground z=14)
	[28] = 7,   -- Marapur (surface)
	[29] = 7,   -- Candia (surface)
	[30] = 7,   -- Silvertides (surface)
	[31] = 5,   -- Moonfall (z=5)
}

CITY_POIS = {
	[8] = { -- Thais (temple: 32369,32241,7)
		{ name = "Thais Depot",          pos = Position(32365, 32212, 7), type = "depot" },
		{ name = "Thais Temple",         pos = Position(32369, 32241, 7), type = "temple" },
		{ name = "Sam's General Store",  pos = Position(32362, 32196, 7), type = "shop" },
		{ name = "Frodo's Tavern",       pos = Position(32360, 32211, 7), type = "shop" },
		{ name = "Gorn's Armour Shop",   pos = Position(32376, 32202, 7), type = "shop" },
		{ name = "Xodet's Magic Shop",   pos = Position(32395, 32224, 7), type = "shop" },
		{ name = "Oswald's Shop",        pos = Position(32380, 32222, 7), type = "shop" },
		{ name = "Benjamin (Post)",      pos = Position(32348, 32221, 7), type = "npc" },
		{ name = "Elane (Paladin GM)",   pos = Position(32344, 32233, 7), type = "npc" },
		{ name = "Quentin (Monk)",       pos = Position(32369, 32238, 7), type = "npc" },
		{ name = "Aruda (Equipment)",    pos = Position(32369, 32216, 7), type = "shop" },
	},
	[6] = { -- Carlin (temple: 32360,31782,7)
		{ name = "Carlin Depot",         pos = Position(32360, 31785, 7), type = "depot" },
		{ name = "Carlin Temple",        pos = Position(32360, 31782, 7), type = "temple" },
		{ name = "Carlin Bank",          pos = Position(32343, 31828, 7), type = "npc" },
		{ name = "Carlin Armour Shop",   pos = Position(32370, 31795, 7), type = "shop" },
	},
	[5] = { -- Ab'Dendriel (temple: 32732,31634,7)
		{ name = "Ab'Dendriel Depot",    pos = Position(32734, 31634, 7), type = "depot" },
		{ name = "Ab'Dendriel Temple",   pos = Position(32732, 31634, 7), type = "temple" },
		{ name = "Amarie (Equipment)",   pos = Position(32693, 31658, 7), type = "shop" },
		{ name = "Shiriel (Spells)",     pos = Position(32669, 31657, 7), type = "npc" },
	},
	[9] = { -- Venore (temple: 32957,32076,7)
		{ name = "Venore Depot",         pos = Position(32957, 32076, 7), type = "depot" },
		{ name = "Venore Temple",        pos = Position(32957, 32076, 7), type = "temple" },
		{ name = "Venore Market",        pos = Position(32960, 32090, 7), type = "shop" },
		{ name = "Venore Magic Shop",    pos = Position(32970, 32075, 7), type = "shop" },
	},
	[11] = { -- Edron (temple: 33217,31814,8)
		{ name = "Edron Depot",          pos = Position(33217, 31814, 8), type = "depot" },
		{ name = "Edron Temple",         pos = Position(33217, 31814, 8), type = "temple" },
		{ name = "Edron Academy",        pos = Position(33230, 31830, 8), type = "npc" },
		{ name = "Edron Weapon Shop",    pos = Position(33210, 31800, 8), type = "shop" },
	},
	[7] = { -- Kazordoon (temple: 32649,31925,11) — underground dwarf city
		{ name = "Kazordoon Depot",      pos = Position(32649, 31911, 11), type = "depot" },
		{ name = "Kazordoon Temple",     pos = Position(32649, 31925, 11), type = "temple" },
		{ name = "Kazordoon Forge",      pos = Position(32653, 31926, 11), type = "shop" },
	},
	[13] = { -- Darashia (temple: 33213,32454,1 — tower/roof; city streets z=7)
		{ name = "Darashia Depot",       pos = Position(33217, 32423, 7), type = "depot" },
		{ name = "Darashia Temple",      pos = Position(33213, 32453, 7), type = "temple" },
		{ name = "Darashia Bazaar",      pos = Position(33232, 32430, 7), type = "shop" },
		{ name = "Darashia Magic Shop",  pos = Position(33225, 32434, 7), type = "shop" },
	},
	[10] = { -- Ankrahmun (temple: 33194,32853,8 — underground; city surface z=7)
		{ name = "Ankrahmun Depot",      pos = Position(33195, 32855, 7), type = "depot" },
		{ name = "Ankrahmun Temple",     pos = Position(33197, 32851, 7), type = "temple" },
		{ name = "Ankrahmun Trade St",   pos = Position(33181, 32883, 7), type = "shop" },
		{ name = "Ankrahmun Shop",       pos = Position(33158, 32849, 7), type = "shop" },
	},
	[14] = { -- Liberty Bay (temple: 32317,32826,7)
		{ name = "Liberty Bay Depot",    pos = Position(32317, 32826, 7), type = "depot" },
		{ name = "Liberty Bay Temple",   pos = Position(32317, 32826, 7), type = "temple" },
		{ name = "Liberty Bay Market",   pos = Position(32310, 32840, 7), type = "shop" },
	},
	[15] = { -- Port Hope (temple: 32594,32745,7)
		{ name = "Port Hope Depot",      pos = Position(32595, 32745, 7), type = "depot" },
		{ name = "Port Hope Temple",     pos = Position(32594, 32745, 7), type = "temple" },
		{ name = "Port Hope Trader",     pos = Position(32590, 32735, 7), type = "shop" },
	},
	[16] = { -- Svargrond (temple: 32212,31132,7)
		{ name = "Svargrond Depot",      pos = Position(32212, 31132, 7), type = "depot" },
		{ name = "Svargrond Temple",     pos = Position(32212, 31132, 7), type = "temple" },
		{ name = "Svargrond Tavern",     pos = Position(32230, 31140, 7), type = "shop" },
	},
	[17] = { -- Yalahar (temple: 32787,31276,7)
		{ name = "Yalahar Depot",        pos = Position(32787, 31277, 7), type = "depot" },
		{ name = "Yalahar Temple",       pos = Position(32787, 31276, 7), type = "temple" },
		{ name = "Yalahar Trade Quarter",pos = Position(32810, 31251, 7), type = "shop" },
	},
	[20] = { -- Rathleton (temple: 33594,31899,6)
		{ name = "Rathleton Depot",      pos = Position(33593, 31899, 6), type = "depot" },
		{ name = "Rathleton Temple",     pos = Position(33594, 31899, 6), type = "temple" },
		{ name = "Rathleton Workshop",   pos = Position(33622, 31883, 6), type = "shop" },
		{ name = "Rathleton Shop",       pos = Position(33611, 31886, 6), type = "shop" },
	},
	[22] = { -- Issavi (temple: 33921,31477,5)
		{ name = "Issavi Depot",         pos = Position(33924, 31476, 5), type = "depot" },
		{ name = "Issavi Temple",        pos = Position(33921, 31477, 5), type = "temple" },
		{ name = "Issavi Market",        pos = Position(33935, 31484, 5), type = "shop" },
		{ name = "Issavi Shop",          pos = Position(33909, 31495, 5), type = "shop" },
	},
	[12] = { -- Farmine (temple: 33023,31521,11; city z=10)
		{ name = "Farmine Depot",        pos = Position(33023, 31542, 10), type = "depot" },
		{ name = "Farmine Temple",       pos = Position(33023, 31521, 11), type = "temple" },
		{ name = "Farmine Esrik",        pos = Position(33036, 31530, 10), type = "npc" },
		{ name = "Farmine Cael",         pos = Position(33028, 31513, 10), type = "npc" },
	},
	[19] = { -- Krailos (temple: 33657,31665,8)
		{ name = "Krailos Depot",        pos = Position(33657, 31665, 8), type = "depot" },
		{ name = "Krailos Temple",       pos = Position(33657, 31665, 8), type = "temple" },
	},
	[21] = { -- Roshamuul (temple: 33513,32363,6)
		{ name = "Roshamuul Depot",      pos = Position(33513, 32363, 6), type = "depot" },
		{ name = "Roshamuul Temple",     pos = Position(33513, 32363, 6), type = "temple" },
	},
	[25] = { -- Bounac (temple: 32424,32445,7)
		{ name = "Bounac Depot",         pos = Position(32424, 32445, 7), type = "depot" },
		{ name = "Bounac Temple",        pos = Position(32424, 32445, 7), type = "temple" },
	},
	[26] = { -- Feyrist (temple: 33490,32221,7)
		{ name = "Feyrist Depot",        pos = Position(33490, 32221, 7), type = "depot" },
		{ name = "Feyrist Temple",       pos = Position(33490, 32221, 7), type = "temple" },
		{ name = "Feyrist Taegen",       pos = Position(33492, 32227, 7), type = "npc" },
		{ name = "Feyrist Maelyrra",     pos = Position(33485, 32236, 7), type = "npc" },
	},
}

-- POI type weights for IDLE priority selection
-- Shops/NPCs removed from IDLE rotation (visited during hunt resupply only)
POI_TYPE_WEIGHTS = {
	depot         = 35,   -- inside depot area (50% chance walk to locker)
	depot_outside = 12,   -- ±3-5 tiles from depot entrance
	temple        = 25,   -- temple area
	boat          = 15,   -- boat NPC position (z may differ from city walk z)
	shop          = 0,    -- excluded from IDLE selection
	npc           = 0,    -- excluded from IDLE selection
}

-- Hardcoded boat captain NPC positions (fallback when route graph has no boat POI)
BOAT_POSITIONS = {
	[5]  = Position(33175, 31763, 6),   -- Ab'Dendriel (Captain Seahorse)
	[6]  = Position(32310, 32210, 6),   -- Carlin (Captain Bluebear)
	[7]  = Position(33791, 31383, 6),   -- Kazordoon (Captain Jack Rat) [actually carts/steamship]
	[8]  = Position(32387, 31822, 6),   -- Thais (Captain Greyhound)
	[9]  = Position(32954, 32022, 6),   -- Venore (Captain Fearless)
	[10] = Position(33092, 32883, 6),   -- Ankrahmun (Captain Sinbeard)
	[11] = Position(33173, 31764, 6),   -- Edron (Captain Gulliver)
	[12] = Position(32097, 31964, 6),   -- Farmine (Captain Kurt) [steamship]
	[13] = Position(33289, 32480, 6),   -- Darashia (Captain Fearless)
	[14] = Position(32285, 32892, 6),   -- Liberty Bay (Captain Bluebear)
	[15] = Position(32527, 32784, 6),   -- Port Hope (Captain Bravesoul)
	[16] = Position(32341, 31108, 6),   -- Svargrond (Captain Haba)
	[17] = Position(32805, 31272, 6),   -- Yalahar (near Captain Cookie, walkable floor)
	[19] = Position(33492, 31712, 6),   -- Krailos (NPC)
	[20] = Position(32298, 32895, 6),   -- Rathleton (Captain Max)
	[21] = Position(33286, 31955, 6),   -- Roshamuul (Pemaret)
	[22] = Position(32056, 32368, 6),   -- Issavi (Captain Tiberius)
	[25] = Position(32346, 32859, 7),   -- Bounac (Captain Waverider)
	[26] = Position(33561, 32196, 6),   -- Feyrist (NPC)
}

-- Travel routes (simulating boat connections)
TRAVEL_DESTINATIONS = {
	[8]  = { 6, 9, 5, 14, 15, 25 },   -- Thais -> Carlin, Venore, Ab'D, LB, PH, Bounac
	[6]  = { 8, 5, 16 },              -- Carlin -> Thais, Ab'D, Svargrond
	[5]  = { 8, 6, 9, 11, 26 },       -- Ab'D -> Thais, Carlin, Venore, Edron, Feyrist
	[9]  = { 8, 5, 13, 10, 14, 15 },  -- Venore -> many destinations
	[11] = { 5, 9, 17, 12 },          -- Edron -> Ab'D, Venore, Yalahar, Farmine
	[7]  = { 8, 9 },                  -- Kazordoon -> Thais, Venore
	[12] = { 11 },                    -- Farmine -> Edron (steamship)
	[13] = { 9, 10, 14 },             -- Darashia -> Venore, Ankrahmun, LB
	[10] = { 9, 13, 14, 15 },         -- Ankrahmun -> Venore, Darashia, LB, PH
	[14] = { 8, 9, 10, 15 },          -- Liberty Bay -> Thais, Venore, Ankr, PH
	[15] = { 9, 10, 14 },             -- Port Hope -> Venore, Ankrahmun, LB
	[16] = { 6, 17 },                 -- Svargrond -> Carlin, Yalahar
	[17] = { 11, 16, 20, 19 },        -- Yalahar -> Edron, Svargrond, Rathleton, Krailos
	[19] = { 17 },                    -- Krailos -> Yalahar
	[20] = { 17, 22, 21 },            -- Rathleton -> Yalahar, Issavi, Roshamuul
	[21] = { 20 },                    -- Roshamuul -> Rathleton (boat)
	[22] = { 20 },                    -- Issavi -> Rathleton
	[25] = { 8 },                     -- Bounac -> Thais (boat)
	[26] = { 5 },                     -- Feyrist -> Ab'Dendriel (portal)
}

-- Chat phrases
BOT_CHAT = {
	idle = {
		"afk 5 min", "brb", "anyone want to hunt?", "nice server", "hi all",
		"looking for team", "selling loot", "checking depot", "nice outfit",
		"gg", "lol", "sup everyone", "back", "hey", "just chilling",
		"anyone online?", "love this server", "bored",
		"gonna go hunt soon", "need a healer", "ty",
		"gl hunting", "be right back", "morning", "any raids?",
	},
	depot = {
		"checking depot", "need to store some loot", "brb depot",
		"organizing my stuff", "where did i put that...",
	},
	shop = {
		"buying supplies", "need some pots", "selling loot",
		"how much for this?", "ty for the trade",
	},
	temple = {
		"need a heal", "checking blessings", "just died lol",
		"afk temple", "waiting for team",
	},
	npc = {
		"hi", "trade", "one moment", "done", "ty",
	},
	travel = {
		"heading out", "time to travel", "taking the boat",
		"gonna explore another city", "see you guys later",
		"brb switching cities", "off to trade elsewhere",
	},
	combat = {
		"bring it on!", "you want to fight?", "stop!",
		"leave me alone!", "help!",
	},
	flee = {
		"gotta run!", "nope nope nope", "help!!",
		"someone help me!", "running away!",
	},
	greeting = {
		"hi", "hey", "hello", "sup", "yo", "hail", "greetings",
		"good morning", "good evening", "howdy", "whats up",
	},
	hunting = {
		"nice loot", "exp is good here", "almost done",
		"need to refill soon", "this spawn is great",
		"one more round", "careful with that monster",
	},
}

-- Build closed->open door lookup from door tables (loaded from data/libs/tables/doors.lua)
-- Only regular and key doors — quest/level doors should NOT be opened by bots
CLOSED_TO_OPEN_DOOR = {}
if KeyDoorTable then
	for _, entry in ipairs(KeyDoorTable) do
		if entry.closedDoor and entry.openDoor then
			CLOSED_TO_OPEN_DOOR[entry.closedDoor] = entry.openDoor
		end
	end
end
if CustomDoorTable then
	for _, entry in ipairs(CustomDoorTable) do
		if entry.closedDoor and entry.openDoor then
			CLOSED_TO_OPEN_DOOR[entry.closedDoor] = entry.openDoor
		end
	end
end

-- Runtime state tables
BotPlayers = BotPlayers or {}    -- {[guid] = playerRef}
BotState = BotState or {}        -- {[guid] = state_table}
BotActive = BotActive or {}      -- {[guid] = true/false}
BotOfflineTraining = BotOfflineTraining or {} -- {[guid] = {name, guid, relogPos, info, eventId}}
botThinkEvents = botThinkEvents or {}         -- {[guid] = eventId}
CITY_TRAINING_STATUES = CITY_TRAINING_STATUES or {} -- {[townId] = {x, y, z, itemId}}
-- Debug-pinned bots: {[guid] = true}. Set by `reload debug,<names|N>`, cleared by
-- `reload debug off`. bot_hibernation.lua refuses to hibernate these so a bot under
-- observation stays awake indefinitely; the C++ side separately refuses to give them tasks.
BotDebugPinned = BotDebugPinned or {}

BotSystem = BotSystem or {}
BotSystem.formatChatText = formatTibiaChatText

-- Parse the argument of `reload debug,<arg>`.
--   numeric  -> that many bots, chosen automatically (legacy behaviour)
--   names    -> semicolon-separated bot NAMES, e.g. `reload debug,Isolde Torehkeron;Naji Bot`
--   "off"    -> leave debug mode
-- Returns (countOrOff, namesListOrNil). MUST be given the ORIGINAL-CASE command: bot names
-- are display-cased and Player(name) lookups need them intact, which is why the callers
-- cannot reuse their lowercased copy for this.
function BotSystem.parseDebugSpec(rawCmd)
	local low = rawCmd:lower()
	if low:match("^reload%s+debug%s+off") or low:match("^reload%s+debug%-off") then
		return "off", nil
	end
	local arg = rawCmd:match("^%s*[Rr][Ee][Ll][Oo][Aa][Dd]%s+[Dd][Ee][Bb][Uu][Gg]%s*,%s*(.+)$")
	if not arg then
		return nil, nil
	end
	arg = arg:gsub("^%s+", ""):gsub("%s+$", "")
	if arg:match("^%d+$") then
		return tonumber(arg), nil
	end
	local names = {}
	for n in arg:gmatch("[^;]+") do
		n = n:gsub("^%s+", ""):gsub("%s+$", "")
		if n ~= "" then
			names[#names + 1] = n
		end
	end
	if #names == 0 then
		return nil, nil
	end
	return #names, names
end

-- ============================================================================
-- Core Navigation (Gesior-style: getPathTo -> startAutoWalk)
-- ============================================================================

function BotSystem.goTo(player, targetPos, state)
	if player:isWalking() then
		return true
	end

	-- Throttle pathfinding retries: if we failed recently, wait ~1s before trying again
	if state then
		local now = os.time()
		if state.goToFailTime and (now - state.goToFailTime) < 1 then
			return false
		end
	end

	local pos = player:getPosition()
	if pos.z ~= targetPos.z then
		return false
	end

	local dx = targetPos.x - pos.x
	local dy = targetPos.y - pos.y
	local dist = math.max(math.abs(dx), math.abs(dy))

	local walkTo = targetPos
	if dist > BOT_CONFIG.PATH_MAX_DIST then
		local ratio = BOT_CONFIG.WAYPOINT_DIST / dist
		walkTo = Position(
			math.floor(pos.x + dx * ratio),
			math.floor(pos.y + dy * ratio),
			pos.z
		)
	end

	local dirs = player:getPathTo(walkTo, 0, 3, true, false, BOT_CONFIG.PATH_MAX_DIST)
	if not dirs or type(dirs) ~= "table" or #dirs == 0 then
		-- Try small random offsets
		for _ = 1, 3 do
			local offsetPos = Position(
				walkTo.x + math.random(-2, 2),
				walkTo.y + math.random(-2, 2),
				walkTo.z
			)
			dirs = player:getPathTo(offsetPos, 0, 3, true, false, BOT_CONFIG.PATH_MAX_DIST)
			if dirs and type(dirs) == "table" and #dirs > 0 then
				break
			end
		end
		-- For long distances, try axis-aligned and larger offsets
		if (not dirs or type(dirs) ~= "table" or #dirs == 0) and dist > BOT_CONFIG.PATH_MAX_DIST then
			local stepDist = math.min(BOT_CONFIG.WAYPOINT_DIST, dist)
			local alternatives = {
				Position(pos.x + (dx > 0 and stepDist or -stepDist), pos.y, pos.z), -- x-only
				Position(pos.x, pos.y + (dy > 0 and stepDist or -stepDist), pos.z), -- y-only
				Position(pos.x + (dx > 0 and stepDist or -stepDist), pos.y + math.random(-10, 10), pos.z),
				Position(pos.x + math.random(-10, 10), pos.y + (dy > 0 and stepDist or -stepDist), pos.z),
			}
			for _, altPos in ipairs(alternatives) do
				dirs = player:getPathTo(altPos, 0, 3, true, false, BOT_CONFIG.PATH_MAX_DIST)
				if dirs and type(dirs) == "table" and #dirs > 0 then
					break
				end
			end
		end
		if not dirs or type(dirs) ~= "table" or #dirs == 0 then
			-- Try opening doors that may be blocking the path
			BotSystem.tryOpenDoors(player, walkTo)
			if state then state.goToFailTime = os.time() end
			return false
		end
	end

	if state then state.goToFailTime = nil end
	player:startAutoWalk(dirs)
	return true
end

-- ============================================================================
-- Z-Level Recovery (uses CITY_WALK_Z, not temple z, since some temples are underground)
-- ============================================================================

function BotSystem.getExpectedZ(player)
	local town = player:getTown()
	if not town then return 7 end
	local townId = town:getId()
	return CITY_WALK_Z[townId] or town:getTemplePosition().z
end

function BotSystem.getSpawnPosition(player)
	-- Get a walkable spawn position at the correct z-level for this city
	local town = player:getTown()
	if not town then return player:getPosition() end
	local townId = town:getId()
	local walkZ = CITY_WALK_Z[townId] or town:getTemplePosition().z
	local templePos = town:getTemplePosition()

	-- If temple z matches walk z, use temple position directly
	if templePos.z == walkZ then
		return templePos
	end

	-- Temple is on a different z (underground/tower) — use first POI position instead
	local pois = CITY_POIS[townId]
	if pois and #pois > 0 then
		return pois[1].pos
	end

	-- Fallback: temple position with z overridden
	return Position(templePos.x, templePos.y, walkZ)
end

function BotSystem.checkZLevel(player, state)
	-- Don't force z-recovery during combat pursuit, return navigation, party, or cavebot commands
	if state.state == BOT_STATE.COMBAT or state.state == BOT_STATE.FLEEING
		or state.state == BOT_STATE.PK_ATTACK or state.state == BOT_STATE.PARTY
		or state.returningHome or state.cavebotCommand
		or state.floorChangeState ~= FLOOR_CHANGE_STATE.NONE then
		return false
	end

	local pos = player:getPosition()
	local expectedZ = BotSystem.getExpectedZ(player)
	if pos.z == expectedZ then
		return false
	end

	local spawnPos = BotSystem.getSpawnPosition(player)
	logger.info("[Bot] " .. player:getName() ..
		" z-level recovery: was at z=" .. pos.z ..
		", expected z=" .. expectedZ .. ", teleporting to city surface")
	player:teleportTo(spawnPos)
	state.walkTarget = nil
	state.currentPOI = nil
	state.pathFailCount = 0
	return true
end

-- ============================================================================
-- Debug Logging & Walk History (cavebot debug framework)
-- ============================================================================

-- Rate-limit floor-change debug spam: suppress repeated FC messages per bot (30s cooldown)
local fcDebugLastLog = {} -- [botName] = os.time()
local FC_DEBUG_COOLDOWN = 30

function BotSystem.debugLog(state, msg)
	if state and state.verboseLog then
		-- Rate-limit floor-change state machine messages (SCANNING, WALKING_TO, FLOOR_CHANGE, etc.)
		local c1 = msg:sub(1, 1)
		local isFC = c1 == "S" and (msg:sub(1, 8) == "SCANNING" or msg:sub(1, 11) == "STEPPING_ON"
				or msg:sub(1, 8) == "Starting")
			or c1 == "W" and msg:sub(1, 10) == "WALKING_TO"
			or c1 == "V" and msg:sub(1, 9) == "VERIFYING"
			or c1 == "F" and msg:sub(1, 12) == "FLOOR_CHANGE"
			or c1 == "U" and msg:sub(1, 10) == "USING_ITEM"
			or c1 == " "
		if isFC then
			local name = state.botName or "?"
			local now = os.time()
			if fcDebugLastLog[name] and (now - fcDebugLastLog[name]) < FC_DEBUG_COOLDOWN then
				return
			end
			fcDebugLastLog[name] = now
		end
		logger.info("[CavebotDebug:" .. (state.botName or "?") .. "] " .. msg)
	end
end

-- Cast Chat channel ID (0x50 = 80, defined in const.hpp as CHANNEL_CAST)
local CHANNEL_CAST = 0x50
-- Talk type for white text in Cast Chat (CHANNEL_MANAGER = 6 renders white in OTClient)
local CAST_TALK_TYPE = TALKTYPE_CHANNEL_Y

-- Send debug message to Cast Chat channel (visible to cast viewers).
-- Only active when verbose logging is enabled for this bot.
function BotSystem.castDebug(player, state, msg)
	if not player then return end
	if state and state.verboseLog then
		player:sendChannelMessage("", "[Bot] " .. msg, CAST_TALK_TYPE, CHANNEL_CAST)
		logger.info("[CavebotDebug:" .. (state.botName or "?") .. "] " .. msg)
	end
end

function BotSystem.recordPosition(state, pos)
	state.walkHistoryIdx = (state.walkHistoryIdx % 8) + 1
	state.walkHistory[state.walkHistoryIdx] = { x = pos.x, y = pos.y, z = pos.z }
end

function BotSystem.isStuck(state)
	if not state.walkHistory or #state.walkHistory < 5 then return false end
	local ref = state.walkHistory[state.walkHistoryIdx]
	if not ref then return false end
	local sameCount = 0
	for _, p in ipairs(state.walkHistory) do
		if p.x == ref.x and p.y == ref.y and p.z == ref.z then
			sameCount = sameCount + 1
		end
	end
	return sameCount >= 5
end

-- ============================================================================
-- Floor Change State Machine (multi-tick, BBot-inspired)
-- ============================================================================

-- Compute the correct destination position for a floor-change tile based on its flags
function BotSystem.computeFloorChangeDestination(fcPos, goDown)
	local destX, destY, destZ = fcPos.x, fcPos.y, fcPos.z
	if goDown then
		destZ = fcPos.z + 1
		-- For going DOWN: the tile at the current z has FLOORCHANGE_DOWN flag;
		-- the tile below determines directional offset
		local belowTile = Tile(Position(fcPos.x, fcPos.y, fcPos.z + 1))
		if belowTile then
			if belowTile:hasFlag(TILESTATE_FLOORCHANGE_NORTH) then destY = destY + 1 end
			if belowTile:hasFlag(TILESTATE_FLOORCHANGE_SOUTH) then destY = destY - 1 end
			if belowTile:hasFlag(TILESTATE_FLOORCHANGE_SOUTH_ALT) then destY = destY - 2 end
			if belowTile:hasFlag(TILESTATE_FLOORCHANGE_EAST) then destX = destX - 1 end
			if belowTile:hasFlag(TILESTATE_FLOORCHANGE_EAST_ALT) then destX = destX - 2 end
			if belowTile:hasFlag(TILESTATE_FLOORCHANGE_WEST) then destX = destX + 1 end
		end
	else
		destZ = fcPos.z - 1
		-- For going UP: the tile at the current z has FLOORCHANGE flags with directions
		local tile = Tile(fcPos)
		if tile then
			if tile:hasFlag(TILESTATE_FLOORCHANGE_NORTH) then destY = destY - 1 end
			if tile:hasFlag(TILESTATE_FLOORCHANGE_SOUTH) then destY = destY + 1 end
			if tile:hasFlag(TILESTATE_FLOORCHANGE_SOUTH_ALT) then destY = destY + 2 end
			if tile:hasFlag(TILESTATE_FLOORCHANGE_EAST) then destX = destX + 1 end
			if tile:hasFlag(TILESTATE_FLOORCHANGE_EAST_ALT) then destX = destX + 2 end
			if tile:hasFlag(TILESTATE_FLOORCHANGE_WEST) then destX = destX - 1 end
		end
	end
	return Position(destX, destY, destZ)
end

-- Magic Wall & Wild Growth item IDs across Tibia/Canary versions
local TRAP_MWALL_IDS = {
	[1497] = true, [1498] = true, [1499] = true,
	[2128] = true, [2129] = true, [2130] = true,
	[10181] = true, [10182] = true,
}

-- Realistic blocker/trap handler: never teleports or force-steps through traps!
-- Returns "monster" | "mwall" | "player" | "none"
function BotSystem.checkTrapOrBlocker(player, state, targetPos)
	local pos = player:getPosition()
	local checkTiles = {}
	if targetPos and targetPos.z == pos.z then
		local dx = targetPos.x - pos.x
		local dy = targetPos.y - pos.y
		local ndx = dx > 0 and 1 or (dx < 0 and -1 or 0)
		local ndy = dy > 0 and 1 or (dy < 0 and -1 or 0)
		if ndx ~= 0 or ndy ~= 0 then
			table.insert(checkTiles, Position(pos.x + ndx, pos.y + ndy, pos.z))
		end
		if ndx ~= 0 then table.insert(checkTiles, Position(pos.x + ndx, pos.y, pos.z)) end
		if ndy ~= 0 then table.insert(checkTiles, Position(pos.x, pos.y + ndy, pos.z)) end
	end
	for ox = -1, 1 do
		for oy = -1, 1 do
			if ox ~= 0 or oy ~= 0 then
				table.insert(checkTiles, Position(pos.x + ox, pos.y + oy, pos.z))
			end
		end
	end

	local foundPlayerBlocker = nil
	for _, tpos in ipairs(checkTiles) do
		local tile = Tile(tpos)
		if tile then
			-- 1. Check Magic Wall / Wild Growth items
			local items = tile:getItems()
			if items then
				for _, item in ipairs(items) do
					if TRAP_MWALL_IDS[item:getId()] then
						BotSystem.doHealing(player, state)
						logger.info("[BotTrap] " .. player:getName() .. " blocked by Magic Wall/Wild Growth at ("
							.. tpos.x .. "," .. tpos.y .. "," .. tpos.z .. "), waiting/healing")
						return "mwall"
					end
				end
			end
			-- 2. Check creatures (Monsters first, then Players)
			local topCreature = tile:getTopCreature()
			if topCreature and topCreature ~= player and not topCreature:isRemoved() and topCreature:getHealth() > 0 then
				if topCreature:isMonster() then
					BotSystem.doHealing(player, state)
					BotSystem.doAttackCreature(player, state, topCreature)
					logger.info("[BotTrap] " .. player:getName() .. " fighting blocking monster "
						.. topCreature:getName() .. " at (" .. tpos.x .. "," .. tpos.y .. "," .. tpos.z .. ")")
					return "monster"
				elseif topCreature:isPlayer() and not foundPlayerBlocker then
					foundPlayerBlocker = topCreature
				end
			end
		end
	end

	if foundPlayerBlocker then
		local now = os.time()
		if not state.lastBlockerChatTime or (now - state.lastBlockerChatTime) >= 12 then
			state.lastBlockerChatTime = now
			local phrases = { "da licenca ai mano", "sai da frente pls", "deixa eu passar", "licenca!" }
			player:say(phrases[math.random(1, #phrases)], TALKTYPE_SAY)
		end
		return "player"
	end

	return "none"
end

-- Main floor-change handler — called when floorChangeState ~= NONE
function BotSystem.handleFloorChange(player, state)
	local pos = player:getPosition()

	-- Timeout: if >15 seconds in any non-NONE state, force FAILED
	if state.floorChangeStartTime and (os.time() - state.floorChangeStartTime) > 15 then
		BotSystem.debugLog(state, "FLOOR_CHANGE TIMEOUT after 15 seconds")
		state.floorChangeState = FLOOR_CHANGE_STATE.FAILED
	end

	if state.floorChangeState == FLOOR_CHANGE_STATE.SCANNING then
		-- Find transitions nearby
		local goDown = state.floorChangeTarget and state.floorChangeTarget.goDown or false
		local targetPos = state.floorChangeTarget and state.floorChangeTarget.targetPos or pos

		local allTransitions = {}
		local seen = {}
		local function addFrom(center)
			local transitions = BotSystem.findZTransitions(center, 12, goDown)
			for _, entry in ipairs(transitions) do
				local key = entry.pos.x .. "," .. entry.pos.y .. "," .. entry.type
				if not seen[key] then
					seen[key] = true
					table.insert(allTransitions, entry)
				end
			end
		end

		addFrom(Position(pos.x, pos.y, pos.z))
		if targetPos then
			addFrom(Position(targetPos.x, targetPos.y, pos.z))
		end

		-- Use extra search centers if provided (e.g., midpoint between hunt waypoints)
		local extras = state.floorChangeTarget and state.floorChangeTarget.extraSearchCenters
		if extras then
			for _, center in ipairs(extras) do
				addFrom(Position(center.x, center.y, pos.z))
			end
		end

		-- Sort transitions: for hunt navigation, prefer transitions closest to the hint/targetPos
		local isHunt = state.floorChangeTarget and state.floorChangeTarget.source == "hunt"
		local refPos = pos
		if isHunt then
			if extras and #extras > 0 then
				refPos = extras[1]
			elseif targetPos then
				refPos = targetPos
			end
		end
		table.sort(allTransitions, function(a, b)
			local da = math.abs(refPos.x - a.pos.x) + math.abs(refPos.y - a.pos.y)
			local db = math.abs(refPos.x - b.pos.x) + math.abs(refPos.y - b.pos.y)
			if da ~= db then
				return da < db
			end
			local pa = math.abs(pos.x - a.pos.x) + math.abs(pos.y - a.pos.y)
			local pb = math.abs(pos.x - b.pos.x) + math.abs(pos.y - b.pos.y)
			return pa < pb
		end)

		BotSystem.debugLog(state, "SCANNING: found " .. #allTransitions .. " transitions ("
			.. (goDown and "DOWN" or "UP") .. ")")
		for i, t in ipairs(allTransitions) do
			BotSystem.debugLog(state, "  #" .. i .. ": " .. t.type .. " at ("
				.. t.pos.x .. "," .. t.pos.y .. "," .. t.pos.z .. ") dist=" .. t.dist)
		end

		if #allTransitions == 0 then
			BotSystem.debugLog(state, "SCANNING: no transitions found, FAILED")
			state.floorChangeState = FLOOR_CHANGE_STATE.FAILED
			return
		end

		state.floorChangeTransitions = allTransitions
		state.floorChangeTransIdx = 1
		state.floorChangeState = FLOOR_CHANGE_STATE.WALKING_TO
		BotSystem.debugLog(state, "SCANNING -> WALKING_TO (target: " .. allTransitions[1].type
			.. " at " .. allTransitions[1].pos.x .. "," .. allTransitions[1].pos.y .. ")")

	elseif state.floorChangeState == FLOOR_CHANGE_STATE.WALKING_TO then
		if player:isWalking() then return end

		local trans = state.floorChangeTransitions[state.floorChangeTransIdx]
		if not trans then
			state.floorChangeState = FLOOR_CHANGE_STATE.FAILED
			return
		end

		local fc = trans.pos
		local dist = math.max(math.abs(pos.x - fc.x), math.abs(pos.y - fc.y))

		BotSystem.debugLog(state, "WALKING_TO: " .. trans.type .. " at ("
			.. fc.x .. "," .. fc.y .. "," .. fc.z .. ") dist=" .. dist)

		if trans.type == "ladder" or trans.type == "sewer" or trans.type == "rope" or trans.type == "shovel" then
			local useMaxDist = (trans.type == "shovel") and 1 or 0
			if dist <= useMaxDist then
				-- On/adjacent to the tile: transition to USING_ITEM
				state.floorChangeState = FLOOR_CHANGE_STATE.USING_ITEM
				BotSystem.debugLog(state, "WALKING_TO -> USING_ITEM (on " .. trans.type .. " tile)")
				return
			end
			-- Path directly to the tile (or adjacent for shovel holes)
			local dirs = player:getPathTo(fc, 0, useMaxDist, true, false, BOT_CONFIG.PATH_MAX_DIST)
			if not dirs or type(dirs) ~= "table" or #dirs == 0 then
				dirs = player:getPathTo(fc, 0, useMaxDist, true, true, BOT_CONFIG.PATH_MAX_DIST)
			end
			if dirs and type(dirs) == "table" and #dirs > 0 then
				player:startAutoWalk(dirs)
				BotSystem.debugLog(state, "WALKING_TO: pathing to " .. trans.type .. " tile, " .. #dirs .. " steps")
			else
				BotSystem.tryOpenDoors(player, fc)
				local blocker = BotSystem.checkTrapOrBlocker(player, state, fc)
				if blocker == "monster" or blocker == "mwall" then
					return -- wait or fight blocker realistically
				end
				BotSystem.debugLog(state, "WALKING_TO: path failed, trying next transition")
				state.floorChangeTransIdx = state.floorChangeTransIdx + 1
				if state.floorChangeTransIdx > #state.floorChangeTransitions then
					state.floorChangeState = FLOOR_CHANGE_STATE.FAILED
				end
			end
		else
			-- Stairs (FLOORCHANGE tiles) — A* rejects them, path to adjacent
			if dist == 0 then
				-- On stairs but z didn't change — step off onto an adjacent walkable tile, never teleport
				state.floorChangeState = FLOOR_CHANGE_STATE.STEPPING_ON
				BotSystem.debugLog(state, "WALKING_TO -> STEPPING_ON (already on stairs)")
				return
			end
			if dist == 1 then
				-- Adjacent — check if diagonal
				local isDiagonal = (pos.x ~= fc.x and pos.y ~= fc.y)
				if isDiagonal then
					-- Route through a cardinal-adjacent tile first
					local cardinalAdj = {
						Position(fc.x, pos.y, pos.z),
						Position(pos.x, fc.y, pos.z),
					}
					local stepped = false
					for _, adj in ipairs(cardinalAdj) do
						local tile = Tile(adj)
						if tile and tile:getGround() and not tile:hasFlag(TILESTATE_BLOCKSOLID) then
							local d = Position.getDirectionTo(pos, adj)
							if d then
								player:startAutoWalk({ d })
								BotSystem.debugLog(state, "WALKING_TO: diagonal fix -> stepping cardinal to ("
									.. adj.x .. "," .. adj.y .. ")")
								stepped = true
								break
							end
						end
					end
					if not stepped then
						-- Can't find cardinal route, try diagonal step directly
						local stepDir = Position.getDirectionTo(pos, fc)
						if stepDir then
							player:startAutoWalk({ stepDir })
							BotSystem.debugLog(state, "WALKING_TO: diagonal direct step toward stairs")
						end
					end
				else
					-- Cardinal adjacent — go to STEPPING_ON
					state.floorChangeState = FLOOR_CHANGE_STATE.STEPPING_ON
					BotSystem.debugLog(state, "WALKING_TO -> STEPPING_ON (adjacent, dist=1)")
				end
				return
			end
			-- Far from stairs — path to within 1 tile
			local dirs = player:getPathTo(fc, 1, 1, true, false, BOT_CONFIG.PATH_MAX_DIST)
			if dirs and type(dirs) == "table" and #dirs > 0 then
				player:startAutoWalk(dirs)
				BotSystem.debugLog(state, "WALKING_TO: pathing near stairs, " .. #dirs .. " steps")
			else
				-- Try opening doors or clearing traps/blockers between us and the stairs
				BotSystem.tryOpenDoors(player, fc)
				local blocker = BotSystem.checkTrapOrBlocker(player, state, fc)
				if blocker == "monster" or blocker == "mwall" then
					return -- wait or fight blocker realistically
				end
				BotSystem.debugLog(state, "WALKING_TO: path near stairs failed, trying next transition")
				state.floorChangeTransIdx = state.floorChangeTransIdx + 1
				if state.floorChangeTransIdx > #state.floorChangeTransitions then
					state.floorChangeState = FLOOR_CHANGE_STATE.FAILED
				end
			end
		end

	elseif state.floorChangeState == FLOOR_CHANGE_STATE.STEPPING_ON then
		if player:isWalking() then return end

		local trans = state.floorChangeTransitions[state.floorChangeTransIdx]
		if not trans then
			state.floorChangeState = FLOOR_CHANGE_STATE.FAILED
			return
		end

		local fc = trans.pos
		local dist = math.max(math.abs(pos.x - fc.x), math.abs(pos.y - fc.y))

		state.floorChangePreZ = pos.z
		state.floorChangeAttempts = state.floorChangeAttempts + 1

		if dist == 0 then
			-- Standing on stair tile but z hasn't changed — do NOT teleport; try stepping off and trying next transition
			BotSystem.debugLog(state, "STEPPING_ON: on stair tile without z change, advancing to next transition")
			state.floorChangeTransIdx = state.floorChangeTransIdx + 1
			state.floorChangeAttempts = 0
			if state.floorChangeTransIdx > #state.floorChangeTransitions then
				state.floorChangeState = FLOOR_CHANGE_STATE.FAILED
			else
				state.floorChangeState = FLOOR_CHANGE_STATE.WALKING_TO
			end
			return
		end

		if dist == 1 then
			-- Step onto the stair tile
			local stepDir = Position.getDirectionTo(pos, fc)
			if stepDir then
				-- Use creature:move() (FLAG_NOLIMIT) to guarantee stepping onto floor-change tile
				player:move(stepDir)
				BotSystem.debugLog(state, "STEPPING_ON: move(" .. stepDir .. ") toward stairs at ("
					.. fc.x .. "," .. fc.y .. "," .. fc.z .. ")")
				state.floorChangeState = FLOOR_CHANGE_STATE.VERIFYING
			else
				BotSystem.debugLog(state, "STEPPING_ON: no direction to stairs? FAILED")
				state.floorChangeState = FLOOR_CHANGE_STATE.FAILED
			end
		else
			-- Still too far — go back to WALKING_TO
			BotSystem.debugLog(state, "STEPPING_ON: dist=" .. dist .. ", back to WALKING_TO")
			state.floorChangeState = FLOOR_CHANGE_STATE.WALKING_TO
		end

	elseif state.floorChangeState == FLOOR_CHANGE_STATE.VERIFYING then
		-- Check if z changed (give 1-2 ticks for the move to process)
		local preZ = state.floorChangePreZ
		if not preZ then
			state.floorChangeState = FLOOR_CHANGE_STATE.FAILED
			return
		end

		if pos.z ~= preZ then
			-- Z changed — success!
			BotSystem.debugLog(state, "VERIFYING: SUCCESS z=" .. preZ .. " -> " .. pos.z)
			state.floorChangeState = FLOOR_CHANGE_STATE.COMPLETED
		else
			-- Z didn't change — retry with creature:move() or try next transition
			if state.floorChangeAttempts < 3 then
				BotSystem.debugLog(state, "VERIFYING: z still " .. pos.z .. " (attempt "
					.. state.floorChangeAttempts .. "/3), retrying with move()")
				local trans = state.floorChangeTransitions[state.floorChangeTransIdx]
				if trans then
					local fc = trans.pos
					local dist = math.max(math.abs(pos.x - fc.x), math.abs(pos.y - fc.y))
					if dist <= 1 then
						local stepDir = Position.getDirectionTo(pos, fc)
						if stepDir then
							player:move(stepDir) -- FLAG_NOLIMIT
						end
					end
				end
				state.floorChangeState = FLOOR_CHANGE_STATE.STEPPING_ON
			else
				-- 3 attempts failed — try next transition in list
				BotSystem.debugLog(state, "VERIFYING: 3 attempts failed, trying next transition")
				state.floorChangeTransIdx = state.floorChangeTransIdx + 1
				state.floorChangeAttempts = 0
				if state.floorChangeTransIdx > #state.floorChangeTransitions then
					state.floorChangeState = FLOOR_CHANGE_STATE.FAILED
				else
					state.floorChangeState = FLOOR_CHANGE_STATE.WALKING_TO
				end
			end
		end

	elseif state.floorChangeState == FLOOR_CHANGE_STATE.USING_ITEM then
		-- For ladders/sewers: simulate "use" by teleporting to destination
		local trans = state.floorChangeTransitions[state.floorChangeTransIdx]
		if not trans then
			state.floorChangeState = FLOOR_CHANGE_STATE.FAILED
			return
		end

		local fc = trans.pos
		state.floorChangePreZ = pos.z

		if trans.type == "ladder" then
			-- Ladder goes UP: z-1, and offset 1 tile south (+y) to land next to the hole
			local destPos = Position(fc.x, fc.y - 1, fc.z - 1)
			player:teleportTo(destPos, true)
			BotSystem.debugLog(state, "USING_ITEM: ladder at (" .. fc.x .. "," .. fc.y .. "," .. fc.z
				.. ") -> teleport to (" .. destPos.x .. "," .. destPos.y .. "," .. destPos.z .. ")")
		elseif trans.type == "sewer" then
			-- Sewer/trapdoor goes DOWN: z+1 (no offset — you land on the same x,y below)
			local destPos = Position(fc.x, fc.y, fc.z + 1)
			player:teleportTo(destPos, true)
			BotSystem.debugLog(state, "USING_ITEM: sewer at (" .. fc.x .. "," .. fc.y .. "," .. fc.z
				.. ") -> teleport to (" .. destPos.x .. "," .. destPos.y .. "," .. destPos.z .. ")")
		elseif trans.type == "rope" then
			-- Rope goes UP — use moveUpstairs() same as magic_rope.lua
			local ropePos = Position(fc.x, fc.y, fc.z)
			local destPos = ropePos:moveUpstairs()
			player:teleportTo(destPos, true)
			BotSystem.debugLog(state, "USING_ITEM: rope at (" .. fc.x .. "," .. fc.y .. "," .. fc.z
				.. ") -> teleport to (" .. destPos.x .. "," .. destPos.y .. "," .. destPos.z .. ")")
		elseif trans.type == "shovel" then
			-- Shovel opens closed stone/sand pile and descends to z+1
			local holeTile = Tile(fc)
			BotSystem.tryOpenShovelHole(holeTile)
			local destPos = Position(fc.x, fc.y, fc.z + 1)
			player:teleportTo(destPos, true)
			BotSystem.debugLog(state, "USING_ITEM: shovel at (" .. fc.x .. "," .. fc.y .. "," .. fc.z
				.. ") -> opened hole & teleport to (" .. destPos.x .. "," .. destPos.y .. "," .. destPos.z .. ")")
		end

		state.floorChangeState = FLOOR_CHANGE_STATE.VERIFYING

	elseif state.floorChangeState == FLOOR_CHANGE_STATE.COMPLETED then
		BotSystem.debugLog(state, "FLOOR_CHANGE COMPLETED at (" .. pos.x .. "," .. pos.y .. "," .. pos.z .. ")")
		local source = state.floorChangeTarget and state.floorChangeTarget.source or nil
		BotSystem.resetFloorChangeState(state)
		state.floorChangeResult = "completed"
		state.floorChangeSource = source

	elseif state.floorChangeState == FLOOR_CHANGE_STATE.FAILED then
		BotSystem.debugLog(state, "FLOOR_CHANGE FAILED at (" .. pos.x .. "," .. pos.y .. "," .. pos.z .. ")")
		local source = state.floorChangeTarget and state.floorChangeTarget.source or nil
		BotSystem.resetFloorChangeState(state)
		state.floorChangeResult = "failed"
		state.floorChangeSource = source
	end
end

function BotSystem.resetFloorChangeState(state)
	state.floorChangeState = FLOOR_CHANGE_STATE.NONE
	state.floorChangeTarget = nil
	state.floorChangePreZ = nil
	state.floorChangeAttempts = 0
	state.floorChangeStartTime = nil
	state.floorChangeTransitions = nil
	state.floorChangeTransIdx = 0
	-- Note: floorChangeResult and floorChangeSource are NOT cleared here
	-- They persist for one tick so callers can check the outcome
end

-- Initiate a floor change toward a target z-level
-- extraSearchCenters: optional table of Position objects to also scan for transitions
-- source: optional string identifying what triggered this ("hunt", "cavebot", etc.)
function BotSystem.startFloorChange(state, goDown, targetPos, extraSearchCenters, source)
	state.floorChangeState = FLOOR_CHANGE_STATE.SCANNING
	state.floorChangeTarget = {
		goDown = goDown,
		targetPos = targetPos,
		extraSearchCenters = extraSearchCenters,
		source = source or "unknown",
	}
	state.floorChangePreZ = nil
	state.floorChangeAttempts = 0
	state.floorChangeStartTime = os.time()
	state.floorChangeTransitions = nil
	state.floorChangeTransIdx = 0
	BotSystem.debugLog(state, "Starting floor change: " .. (goDown and "DOWN" or "UP")
		.. " toward (" .. (targetPos and (targetPos.x .. "," .. targetPos.y .. "," .. targetPos.z) or "nil") .. ")"
		.. " source=" .. (source or "unknown")
		.. (extraSearchCenters and (" +" .. #extraSearchCenters .. " extra centers") or ""))
end

-- ============================================================================
-- Bot Quest / Access Storages helper
-- Sets storages so bots can access doors, wagons, shrines, levers, teleports
-- ============================================================================
function BotSystem.applyQuestStorages(player)
	if not player or not Storage or not Storage.Quest then return end
	local botStorages = {
		-- The New Frontier (Farmine access — full quest complete)
		[Storage.Quest.U8_54.TheNewFrontier.Questline] = 29,
		[Storage.Quest.U8_54.TheNewFrontier.Mission01] = 3,
		[Storage.Quest.U8_54.TheNewFrontier.Mission02[1]] = 4,
		[Storage.Quest.U8_54.TheNewFrontier.Mission02.Beaver1] = 1,
		[Storage.Quest.U8_54.TheNewFrontier.Mission02.Beaver2] = 1,
		[Storage.Quest.U8_54.TheNewFrontier.Mission02.Beaver3] = 1,
		[Storage.Quest.U8_54.TheNewFrontier.Mission03] = 3,
		[Storage.Quest.U8_54.TheNewFrontier.Mission04] = 2,
		[Storage.Quest.U8_54.TheNewFrontier.Mission05[1]] = 2,
		[Storage.Quest.U8_54.TheNewFrontier.Mission05.KingTibianus] = 1,
		[Storage.Quest.U8_54.TheNewFrontier.Mission05.Leeland] = 1,
		[Storage.Quest.U8_54.TheNewFrontier.Mission05.Angus] = 1,
		[Storage.Quest.U8_54.TheNewFrontier.Mission05.Wyrdin] = 1,
		[Storage.Quest.U8_54.TheNewFrontier.Mission05.Telas] = 1,
		[Storage.Quest.U8_54.TheNewFrontier.Mission05.Humgolf] = 1,
		[Storage.Quest.U8_54.TheNewFrontier.Mission06] = 5,
		[Storage.Quest.U8_54.TheNewFrontier.Mission07[1]] = 2,
		[Storage.Quest.U8_54.TheNewFrontier.Mission08] = 2,
		[Storage.Quest.U8_54.TheNewFrontier.Mission09[1]] = 3,
		[Storage.Quest.U8_54.TheNewFrontier.Mission10[1]] = 2,
		[Storage.Quest.U8_54.TheNewFrontier.Mission10.MagicCarpetDoor] = 1,
		[Storage.Quest.U8_54.TheNewFrontier.TomeofKnowledge] = 12,
		[Storage.Quest.U8_54.TheNewFrontier.ZaoPalaceDoors] = 1,
		[Storage.Quest.U8_54.TheNewFrontier.SnakeHeadTeleport] = 1,
		[Storage.Quest.U8_54.TheNewFrontier.CorruptionHole] = 1,
		-- Children of the Revolution
		[Storage.Quest.U8_54.ChildrenOfTheRevolution.Questline] = 21,
		[Storage.Quest.U8_54.ChildrenOfTheRevolution.Mission00] = 2,
		[Storage.Quest.U8_54.ChildrenOfTheRevolution.Mission01] = 3,
		[Storage.Quest.U8_54.ChildrenOfTheRevolution.Mission02] = 5,
		[Storage.Quest.U8_54.ChildrenOfTheRevolution.Mission03] = 3,
		[Storage.Quest.U8_54.ChildrenOfTheRevolution.Mission04] = 6,
		[Storage.Quest.U8_54.ChildrenOfTheRevolution.Mission05] = 3,
		[Storage.Quest.U8_54.ChildrenOfTheRevolution.SpyBuilding01] = 1,
		[Storage.Quest.U8_54.ChildrenOfTheRevolution.SpyBuilding02] = 1,
		[Storage.Quest.U8_54.ChildrenOfTheRevolution.SpyBuilding03] = 1,
		[Storage.Quest.U8_54.ChildrenOfTheRevolution.StrangeSymbols] = 1,
		[Storage.Quest.U8_54.ChildrenOfTheRevolution.teleportAccess] = 1,
		-- Wrath of the Emperor
		[Storage.Quest.U8_6.WrathOfTheEmperor.Questline] = 29,
		[Storage.Quest.U8_6.WrathOfTheEmperor.Mission01] = 3,
		[Storage.Quest.U8_6.WrathOfTheEmperor.Mission02] = 3,
		[Storage.Quest.U8_6.WrathOfTheEmperor.Mission03] = 3,
		[Storage.Quest.U8_6.WrathOfTheEmperor.Mission04] = 3,
		[Storage.Quest.U8_6.WrathOfTheEmperor.Mission05] = 3,
		[Storage.Quest.U8_6.WrathOfTheEmperor.Mission06] = 5,
		[Storage.Quest.U8_6.WrathOfTheEmperor.Mission07] = 6,
		[Storage.Quest.U8_6.WrathOfTheEmperor.Mission08] = 2,
		[Storage.Quest.U8_6.WrathOfTheEmperor.Mission09] = 2,
		[Storage.Quest.U8_6.WrathOfTheEmperor.Mission10] = 6,
		[Storage.Quest.U8_6.WrathOfTheEmperor.Mission11] = 2,
		[Storage.Quest.U8_6.WrathOfTheEmperor.Mission12] = 1,
		[Storage.Quest.U8_6.WrathOfTheEmperor.TeleportAccess.Rebel] = 1,
		[Storage.Quest.U8_6.WrathOfTheEmperor.TeleportAccess.Zlak] = 1,
		[Storage.Quest.U8_6.WrathOfTheEmperor.TeleportAccess.Zizzle] = 1,
		[Storage.Quest.U8_6.WrathOfTheEmperor.TeleportAccess.SleepingDragon] = 2,
		[Storage.Quest.U8_6.WrathOfTheEmperor.TeleportAccess.InnerSanctum] = 1,
		[Storage.Quest.U8_6.WrathOfTheEmperor.TeleportAccess.AwarnessEmperor] = 1,
		[Storage.Quest.U8_6.WrathOfTheEmperor.TeleportAccess.Wote10] = 1,
		[Storage.Quest.U8_6.WrathOfTheEmperor.TeleportAccess.BossRoom] = 1,
		[Storage.Quest.U8_6.WrathOfTheEmperor.Bosses.Fury] = 1,
		[Storage.Quest.U8_6.WrathOfTheEmperor.Bosses.Wrath] = 1,
		[Storage.Quest.U8_6.WrathOfTheEmperor.Bosses.Scorn] = 1,
		[Storage.Quest.U8_6.WrathOfTheEmperor.Bosses.Spite] = 1,
		-- Threatened Dreams
		[Storage.Quest.U11_40.ThreatenedDreams.Mission01[1]] = 16,
		-- In Service of Yalahar
		[Storage.Quest.U8_4.InServiceOfYalahar.TheWayToYalahar] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.Questline] = 51,
		[Storage.Quest.U8_4.InServiceOfYalahar.Mission01] = 6,
		[Storage.Quest.U8_4.InServiceOfYalahar.Mission02] = 8,
		[Storage.Quest.U8_4.InServiceOfYalahar.Mission03] = 6,
		[Storage.Quest.U8_4.InServiceOfYalahar.Mission04] = 6,
		[Storage.Quest.U8_4.InServiceOfYalahar.Mission05] = 8,
		[Storage.Quest.U8_4.InServiceOfYalahar.Mission06] = 5,
		[Storage.Quest.U8_4.InServiceOfYalahar.Mission07] = 5,
		[Storage.Quest.U8_4.InServiceOfYalahar.Mission08] = 4,
		[Storage.Quest.U8_4.InServiceOfYalahar.Mission09] = 2,
		[Storage.Quest.U8_4.InServiceOfYalahar.Mission10] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.SewerPipe01] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.SewerPipe02] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.SewerPipe03] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.SewerPipe04] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.DiseasedDan] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.DiseasedBill] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.DiseasedFred] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.AlchemistFormula] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.BadSide] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.GoodSide] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.MrWestDoor] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.MrWestStatus] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.TamerinStatus] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.MorikSummon] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.QuaraState] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.QuaraSplasher] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.QuaraSharptooth] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.QuaraInky] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.MatrixState] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.NotesPalimuth] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.NotesAzerus] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.DoorToAzerus] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.DoorToBog] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.DoorToLastFight] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.DoorToMatrix] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.DoorToQuara] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.SearoutesAroundYalahar.TownsCounter] = 5,
		[Storage.Quest.U8_4.InServiceOfYalahar.SearoutesAroundYalahar.AbDendriel] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.SearoutesAroundYalahar.Darashia] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.SearoutesAroundYalahar.Venore] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.SearoutesAroundYalahar.Ankrahmun] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.SearoutesAroundYalahar.PortHope] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.SearoutesAroundYalahar.Thais] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.SearoutesAroundYalahar.LibertyBay] = 1,
		[Storage.Quest.U8_4.InServiceOfYalahar.SearoutesAroundYalahar.Carlin] = 1,
		-- Forgotten Knowledge
		[Storage.Quest.U11_02.ForgottenKnowledge.Tomes] = 1,
		[Storage.Quest.U11_02.ForgottenKnowledge.AccessDeath] = 1,
		[Storage.Quest.U11_02.ForgottenKnowledge.AccessViolet] = 1,
		[Storage.Quest.U11_02.ForgottenKnowledge.AccessEarth] = 1,
		[Storage.Quest.U11_02.ForgottenKnowledge.AccessFire] = 1,
		[Storage.Quest.U11_02.ForgottenKnowledge.AccessIce] = 1,
		[Storage.Quest.U11_02.ForgottenKnowledge.AccessGolden] = 1,
		[Storage.Quest.U11_02.ForgottenKnowledge.AccessLast] = 1,
		[Storage.Quest.U11_02.ForgottenKnowledge.AccessPortals] = 1,
		[Storage.Quest.U11_02.ForgottenKnowledge.AccessMachine] = 1,
		[Storage.Quest.U11_02.ForgottenKnowledge.AccessLavaTeleport] = 1,
		[Storage.Quest.U11_02.ForgottenKnowledge.LadyTenebrisKilled] = 1,
		[Storage.Quest.U11_02.ForgottenKnowledge.LloydKilled] = 1,
		[Storage.Quest.U11_02.ForgottenKnowledge.ThornKnightKilled] = 1,
		[Storage.Quest.U11_02.ForgottenKnowledge.DragonkingKilled] = 1,
		[Storage.Quest.U11_02.ForgottenKnowledge.HorrorKilled] = 1,
		[Storage.Quest.U11_02.ForgottenKnowledge.TimeGuardianKilled] = 1,
		[Storage.Quest.U11_02.ForgottenKnowledge.LastLoreKilled] = 1,
		-- The Secret Library
		[Storage.Quest.U11_80.TheSecretLibrary.Questlog] = 1,
		[Storage.Quest.U11_80.TheSecretLibrary.LibraryPermission] = 7,
		[Storage.Quest.U11_80.TheSecretLibrary.Asuras.Questline] = 7,
		[Storage.Quest.U11_80.TheSecretLibrary.Asuras.FlammingOrchid] = 1,
		[Storage.Quest.U11_80.TheSecretLibrary.Asuras.SkeletonNotes] = 1,
		[Storage.Quest.U11_80.TheSecretLibrary.Asuras.StrandHair] = 1,
		[Storage.Quest.U11_80.TheSecretLibrary.Asuras.LotusKey] = 1,
		[Storage.Quest.U11_80.TheSecretLibrary.Asuras.EyeKey] = 1,
		[Storage.Quest.U11_80.TheSecretLibrary.Asuras.ScribbledNotes] = 1,
		[Storage.Quest.U11_80.TheSecretLibrary.Asuras.EbonyPiece] = 1,
		[Storage.Quest.U11_80.TheSecretLibrary.Asuras.PeacockBallad] = 1,
		[Storage.Quest.U11_80.TheSecretLibrary.Asuras.BlackSkull] = 1,
		[Storage.Quest.U11_80.TheSecretLibrary.Asuras.SilverChimes] = 1,
		[Storage.Quest.U11_80.TheSecretLibrary.Asuras.Fragrance] = 1,
		[Storage.Quest.U11_80.TheSecretLibrary.FalconBastion.Questline] = 3,
		[Storage.Quest.U11_80.TheSecretLibrary.FalconBastion.FalconBastionAccess] = 1,
		[Storage.Quest.U11_80.TheSecretLibrary.FalconBastion.KillingBosses] = 5,
		[Storage.Quest.U11_80.TheSecretLibrary.Darashia.Questline] = 9,
		[Storage.Quest.U11_80.TheSecretLibrary.LiquidDeath.Questline] = 8,
		[Storage.Quest.U11_80.TheSecretLibrary.MoTA.Questline] = 8,
		[Storage.Quest.U11_80.TheSecretLibrary.MoTA.LeverPermission] = 1,
		[Storage.Quest.U11_80.TheSecretLibrary.MoTA.FinalBasin] = 1,
		[Storage.Quest.U11_80.TheSecretLibrary.MoTA.SkullSample] = 1,
		[Storage.Quest.U11_80.TheSecretLibrary.MoTA.YellowGem] = 1,
		[Storage.Quest.U11_80.TheSecretLibrary.MoTA.GreenGem] = 1,
		[Storage.Quest.U11_80.TheSecretLibrary.MoTA.RedGem] = 1,
		[Storage.Quest.U11_80.TheSecretLibrary.SmallIslands.Questline] = 4,
		-- Kilmaresh
		[Storage.Quest.U12_20.KilmareshQuest.AccessDoor] = 1,
		[Storage.Quest.U12_20.KilmareshQuest.Second.Investigating] = 1,
		[Storage.Quest.U12_20.KilmareshQuest.Sixth.GryphonMask] = 1,
		[Storage.Quest.U12_20.KilmareshQuest.Sixth.MirrorMask] = 1,
		[Storage.Quest.U12_20.KilmareshQuest.Sixth.IvoryMask] = 1,
		[Storage.Quest.U12_20.KilmareshQuest.Sixth.SilverMask] = 1,
		-- Ferumbras Ascension
		[Storage.Quest.U10_90.FerumbrasAscension.Access] = 1,
		[Storage.Quest.U10_90.FerumbrasAscension.FirstDoor] = 1,
		[Storage.Quest.U10_90.FerumbrasAscension.MonsterDoor] = 1,
		[Storage.Quest.U10_90.FerumbrasAscension.TarbazDoor] = 1,
		[Storage.Quest.U10_90.FerumbrasAscension.HabitatsAccess] = 1,
		[Storage.Quest.U10_90.FerumbrasAscension.TheLordOfTheLiceAccess] = 1,
		[Storage.Quest.U10_90.FerumbrasAscension.Statue] = 1,
		-- The Lost Brother
		[Storage.Quest.U10_80.TheLostBrotherQuest] = 3,
		-- Lion's Rock
		[Storage.Quest.U10_70.LionsRock.Questline] = 11,
		[Storage.Quest.U10_70.LionsRock.OuterSanctum.Skeleton] = 1,
		[Storage.Quest.U10_70.LionsRock.OuterSanctum.LionsStrength] = 1,
		[Storage.Quest.U10_70.LionsRock.OuterSanctum.LionsBeauty] = 1,
		[Storage.Quest.U10_70.LionsRock.OuterSanctum.LionsTears] = 1,
		[Storage.Quest.U10_70.LionsRock.InnerSanctum.SnakeSign] = 1,
		[Storage.Quest.U10_70.LionsRock.InnerSanctum.LizardSign] = 1,
		[Storage.Quest.U10_70.LionsRock.InnerSanctum.ScorpionSign] = 1,
		[Storage.Quest.U10_70.LionsRock.InnerSanctum.HyenaSign] = 1,
		[Storage.Quest.U10_70.LionsRock.InnerSanctum.Message] = 1,
		-- Wagon Ticket
		[Storage.WagonTicket] = 2147483647,
	}
	for key, value in pairs(botStorages) do
		player:setStorageValue(key, value)
	end
end

-- ============================================================================
-- Dynamic Population Adjustment & Hot-Reload
-- Cleanly despawns/removes active bots and loads the exact targetCount from DB.
-- ============================================================================
function BotSystem.setPopulation(targetCount, opts)
	opts = opts or {}
	local source = opts.source or "manual"
	local emit = opts.emit or function(msg) logger.info("[BotPopulation:{}] {}", source, msg) end
	targetCount = math.max(0, tonumber(targetCount) or 0)

	emit(string.format("Ajustando populacao para %d bots...", targetCount))

	-- 1. Desativar e deslogar todos os bots atualmente online no mundo
	local despawned = 0
	if Game.getPlayers then
		for _, p in ipairs(Game.getPlayers()) do
			if p and not p:isRemoved() then
				local name = p:getName()
				local acc = p:getAccountId()
				if name:sub(1, 4) == "Bot " or acc == BOT_CONFIG.BOT_ACCOUNT_ID or (acc >= 77 and acc <= 151) then
					local guid = p:getGuid()
					if botThinkEvents and botThinkEvents[guid] then
						stopEvent(botThinkEvents[guid])
						botThinkEvents[guid] = nil
					end
					pcall(BotSystem.deactivateBot, p)
					pcall(function() p:remove() end)
					despawned = despawned + 1
				end
			end
		end
	end

	-- Limpa registros em BotPlayers
	for guid, p in pairs(BotPlayers or {}) do
		if p and not p:isRemoved() then
			if botThinkEvents and botThinkEvents[guid] then
				stopEvent(botThinkEvents[guid])
				botThinkEvents[guid] = nil
			end
			pcall(BotSystem.deactivateBot, p)
			pcall(function() p:remove() end)
			despawned = despawned + 1
		end
	end

	BotPlayers = {}
	BotActive = {}
	BotState = {}
	if BotDebugPinned then BotDebugPinned = {} end

	-- Limpa registros de bots em players_online
	db.botAsyncQuery(string.format(
		"DELETE FROM `players_online` WHERE `player_id` IN (SELECT `id` FROM `players` WHERE `account_id` = %d OR `account_id` BETWEEN 77 AND 151 OR `name` LIKE 'Bot %%%%')",
		BOT_CONFIG.BOT_ACCOUNT_ID
	))

	emit(string.format("Deslogados e removidos %d bots ativos.", despawned))

	-- Atualiza configuracao em memoria e no banco
	BOT_CONFIG.TARGET_ONLINE = targetCount
	db.botAsyncQuery(string.format(
		"INSERT INTO `bot_startup_config` (`config_key`, `config_value`) VALUES ('debug_active_count', '%d') ON DUPLICATE KEY UPDATE `config_value` = '%d'",
		targetCount, targetCount
	))

	if targetCount == 0 then
		emit("Populacao zerada. Nenhum bot ativo no mundo.")
		return { ok = true, message = "Populacao zerada com sucesso", count = 0 }
	end

	-- 2. Buscar bots no banco de dados
	local query = "SELECT `id`, `name` FROM `players` WHERE (`account_id` = " .. BOT_CONFIG.BOT_ACCOUNT_ID
		.. " OR `name` LIKE 'Bot %') AND `deletion` = 0 ORDER BY `id` ASC"
	local resultId = db.storeQuery(query)
	if not resultId then
		emit("Nenhum bot encontrado no banco de dados!")
		return { ok = false, message = "Nenhum bot encontrado no banco", count = 0 }
	end

	local allBotNames = {}
	repeat
		table.insert(allBotNames, Result.getString(resultId, "name"))
	until not Result.next(resultId)
	Result.free(resultId)

	local total = #allBotNames
	local botNames = {}

	-- Se houver nomes alvos especificos
	if opts.targetNames and #opts.targetNames > 0 then
		local inDb = {}
		for _, n in ipairs(allBotNames) do inDb[n:lower()] = n end
		for _, wanted in ipairs(opts.targetNames) do
			local actual = inDb[wanted:lower()]
			if actual and #botNames < targetCount then
				table.insert(botNames, actual)
			end
		end
	end

	-- Bots de teste preferidos se poucos bots
	if #botNames == 0 and targetCount <= 5 then
		local preferredTestBots = { "Bot Titus", "Bot Kallum", "Bot Eamon", "Bot Valdemar", "Bot Sylas" }
		local inDb = {}
		for _, n in ipairs(allBotNames) do inDb[n] = true end
		for _, pref in ipairs(preferredTestBots) do
			if #botNames < targetCount and inDb[pref] then
				table.insert(botNames, pref)
			end
		end
	end

	-- Selecao estratificada
	if #botNames < targetCount then
		local chosen = {}
		for _, n in ipairs(botNames) do chosen[n] = true end
		if targetCount >= total then
			for _, n in ipairs(allBotNames) do
				if not chosen[n] and #botNames < targetCount then
					table.insert(botNames, n)
					chosen[n] = true
				end
			end
		else
			for i = 0, targetCount - 1 do
				local idx = math.floor(i * total / targetCount) + 1
				local candidate = allBotNames[idx]
				if not chosen[candidate] and #botNames < targetCount then
					table.insert(botNames, candidate)
					chosen[candidate] = true
				end
			end
		end
	end

	emit(string.format("Carregando %d bots selecionados (de %d no banco)...", #botNames, total))

	-- Carregamento escalonado (staggered, 50ms)
	local STAGGER_MS = 50
	for i, name in ipairs(botNames) do
		addEvent(function()
			local p = Game.loadBotPlayer(name)
			if p then
				local guid = p:getGuid()
				BotPlayers[guid] = p
				p:registerEvent("BotDeath")

				-- Aplica storages necessarios
				BotSystem.applyQuestStorages(p)

				-- Ativa inteligencia do bot
				local ok, err = pcall(BotSystem.activateBot, p)
				if not ok then
					logger.error("[BotPopulation] Erro ao ativar " .. name .. ": " .. tostring(err))
				end

				if #botNames <= 10 and BotState and BotState[guid] then
					BotState[guid].verboseLog = true
					BotState[guid].verboseLogAutoEnabled = true
				end

				-- Sincroniza em players_online
				db.botAsyncQuery("INSERT IGNORE INTO `players_online` (`player_id`) VALUES (" .. guid .. ")")

				if i % 10 == 0 or i == #botNames then
					emit(string.format("Carregado e ativado bot %d/%d: %s", i, #botNames, name))
				end
			else
				logger.warn("[BotPopulation] Falha ao carregar bot: " .. name)
			end
		end, i * STAGGER_MS)
	end

	return {
		ok = true,
		message = string.format("Populacao ajustada para %d bots", #botNames),
		count = #botNames
	}
end

-- ============================================================================
-- Shared reload — invoked by /cavebot reload talkaction AND by bot_commands queue.
-- opts = {
--   source       = "talkaction" | "queue" | nil  -- caller tag for logs
--   player       = <player obj> | nil           -- for sendTextMessage feedback (talkaction only)
--   debugCount   = nil | <N> | "off"            -- nil = no debug-mode change (preserve active set)
--                                                -- N = re-activate only the first N online bots, disable debug for others
--                                                -- "off" = re-activate ALL bots in BotPlayers, clear debug streams
--   debugBotName = nil | <name>                 -- explicit bot to debug (overrides "first online")
-- }
-- Returns { ok = bool, message = string, lines = { ... } }
-- Re-entrancy guard: reload is async (step 4b stagger), so a second invocation
-- arriving mid-materialization would corrupt counter state. Module-level flag
-- blocks entry until finalizeReload clears it.
BotSystem._reloadInProgress = BotSystem._reloadInProgress or false

function BotSystem.executeReload(opts)
	opts = opts or {}
	local source = opts.source or "?"
	local lines = {}
	local function emit(msg)
		lines[#lines + 1] = msg
		-- Guard isRemoved — async window is wider than before; talkaction player
		-- could log out between when the reload starts and when finalizeReload fires.
		if opts.player and not opts.player:isRemoved() then
			opts.player:sendTextMessage(MESSAGE_STATUS, "[cavebot] " .. msg)
		end
		logger.info("[reload:{}] {}", source, msg)
	end

	if BotSystem._reloadInProgress then
		emit("reload already in progress — ignoring concurrent request")
		return { ok = false, message = "reload already in progress", lines = lines }
	end

	-- Monolithic binary support: when dynamic .so engine (Game.botReload) is not present,
	-- delegate reload directly to the native Lua population manager.
	if not Game.botReload then
		local count = opts.debugCount
		if count == "off" then
			count = BOT_CONFIG.TARGET_ONLINE or 80
		elseif type(count) ~= "number" then
			count = 0
			for _, p in pairs(BotPlayers or {}) do
				if p and not p:isRemoved() then count = count + 1 end
			end
			if count == 0 then count = BOT_CONFIG.TARGET_ONLINE or 80 end
		end
		return BotSystem.setPopulation(count, { emit = emit, source = source, targetNames = opts.debugBotNames })
	end

	-- BOT_CSV pre-flight. Authored data lives in data/bot/authored/*.csv, and
	-- Game.botReload() DESTROYS the engine before the new one parses those files —
	-- so a malformed CSV has nothing to fall back to. It poisons the fresh engine and
	-- every bot refuses to activate until a human fixes the file.
	--
	-- Asking the still-live engine to parse-check first turns that outage into a
	-- refused reload with the population untouched. Runs BEFORE _reloadInProgress is
	-- set and before anything is deactivated, so an abort leaves zero residue.
	--
	-- Caveat: this validates with the CURRENTLY LOADED .so. If the .so is also
	-- changing in this deploy, the check uses the old parser — it is a sanity check,
	-- not a proof. tools/bot_csv/validate.py is the real gate and runs pre-deploy.
	do
		local ok, csvResult = pcall(Game.botCommand, "_global", "csvcheck")
		if ok and type(csvResult) == "string" and csvResult ~= "" then
			if csvResult:sub(1, 2) ~= "OK" then
				emit("reload ABORTED — authored CSV failed to parse, nothing was touched:")
				emit("  " .. csvResult)
				emit("  Fix the file (or: git checkout -- data/bot/authored) and reload again.")
				return { ok = false, message = "csv pre-flight failed: " .. csvResult, lines = lines }
			end
			logger.info("[reload:{}] csv pre-flight {}", source, csvResult)
		else
			-- Older .so without csvcheck, or an unexpected return: do not block the
			-- reload on a missing diagnostic. Say so, so it is visible rather than
			-- silently skipped.
			logger.warn("[reload:{}] csv pre-flight unavailable — proceeding without it", source)
		end
	end

	BotSystem._reloadInProgress = true

	-- Steps 1-4 are synchronous; wrap in pcall so a Lua error in the prefix
	-- (e.g., unexpected return type from a C++ binding) clears the re-entrancy
	-- flag and surfaces the error instead of leaving _reloadInProgress=true
	-- forever (which would block every future reload until canary restarts).
	local onlineGuids, hibernatedNames
	local prefixOk, prefixErr = pcall(function()
		-- 1. Detect currently-active bots (via C++ engine active flag)
		onlineGuids = {}
		for guid, p in pairs(BotPlayers or {}) do
			local isActive = (BotActive and BotActive[guid])
			if isActive == nil and Game.botIsActive then
				isActive = Game.botIsActive(guid)
			elseif isActive == nil then
				isActive = true
			end
			if p and not p:isRemoved() and isActive then
				onlineGuids[#onlineGuids + 1] = guid
			end
		end
		emit("Found " .. #onlineGuids .. " online bots to preserve")

		-- 1b. Snapshot hibernated bot names from OLD engine BEFORE force-deactivate / dlclose.
		-- The hibernationPool_ (in the .so) holds the only strong refs to hibernated Player
		-- objects; those refs die with the .so unload. We re-materialize them from DB after
		-- the reload via Game.loadBotPlayer(name) — same path as startup.
		hibernatedNames = {}
		local hibStates = (Game.getBotHibernationStates and Game.getBotHibernationStates()) or nil
		if hibStates then
			for i = 1, #hibStates do
				local b = hibStates[i]
				if b.hibernated then
					hibernatedNames[#hibernatedNames + 1] = b.name
				end
			end
		end
		-- Debug-by-NAME only ever runs the bots you asked for; every other bot is despawned a few
		-- lines later ("despawned 499/500 non-target bots"). Materializing them first is pure
		-- waste, and it is SLOW waste: step 4b staggers one DB load per 100ms on purpose (to
		-- avoid the dispatcher freeze that ping-timeouts real players), so 467 bots cost ~67s of
		-- wall clock before the reload finalizes. Load only the targets.
		if opts.debugBotNames and #opts.debugBotNames > 0 then
			local wanted = {}
			for _, n in ipairs(opts.debugBotNames) do
				wanted[n:lower()] = true
			end
			local filtered = {}
			for _, n in ipairs(hibernatedNames) do
				if wanted[n:lower()] then
					filtered[#filtered + 1] = n
				end
			end
			local skipped = #hibernatedNames - #filtered
			hibernatedNames = filtered
			if skipped > 0 then
				emit("debug mode: skipping re-materialization of " .. skipped
					.. " non-target hibernated bot(s) (~" .. math.floor(skipped * 0.1) .. "s saved)")
			end
		end
		emit("Found " .. #hibernatedNames .. " hibernated bots to re-load from DB")

		-- 2. Force-deactivate all online bots in OLD engine (clears hunt reservations, preserves cast streams)
		for _, guid in ipairs(onlineGuids) do
			if Game.botForceDeactivateForReload then
				Game.botForceDeactivateForReload(guid)
			end
		end

		-- 3. Reload the .so + hunt data — this destroys old hibernationPool_
		if Game.botReload then
			local result = Game.botReload()
			emit(tostring(result))
		end

		-- 4. Restart the 100ms tick loop (old cycleEvent may be stale after dlclose/dlopen)
		if Game.botStartTickLoop then
			Game.botStartTickLoop()
		end
	end)
	if not prefixOk then
		BotSystem._reloadInProgress = false
		logger.error("[reload:{}] prefix error: {}", source, tostring(prefixErr))
		return { ok = false, message = "reload prefix failed: " .. tostring(prefixErr), lines = lines }
	end

	-- 4b. Re-materialize hibernated bots from DB asynchronously.
	-- luaAddEvent clamps delay to min 100ms (global_functions.cpp:702), so passing no
	-- delay puts all N callbacks at the same T+100ms deadline → all fire in one
	-- dispatcher sweep → ~150ms × N freeze → real-player ping-timeout kicks at
	-- N>=500. We index-stagger so each bot lands on its own dispatcher iteration.
	-- After the last materialization completes, finalizeReload runs steps 5-9.
	local BOT_MATERIALIZE_INTERVAL_MS = 100
	local materializedCount = 0
	local pendingMaterializations = #hibernatedNames

	-- All post-materialization steps live inside finalizeReload so they wait for
	-- step 4b to complete. Captured locals: opts, lines, emit, onlineGuids, source.
	-- Defensive double-call guard + pcall wrapper: if finalizeReload errors out
	-- partway through, we MUST still clear _reloadInProgress, otherwise the
	-- re-entrancy guard locks out all future reloads. The `finalized` flag
	-- prevents accidental re-entry if some future change calls it twice.
	local finalized = false
	local function finalizeReload()
		if finalized then
			logger.warn("[reload:{}] finalizeReload called twice — skipping", source)
			return
		end
		finalized = true
		local finalizeOk, finalizeErr = pcall(function()
		if materializedCount > 0 then
			emit("Re-materialized " .. materializedCount .. " hibernated bots from DB")
		end

		-- 5. Re-register all bot players with the new engine (awake survivors + freshly materialized)
		local count = 0
		if Game.botReregisterAll then
			count = Game.botReregisterAll()
		end
		emit("Re-registered " .. count .. " bots.")

		-- 5b. Defensive orphan recovery: any bot in BotPlayers that's still not active in
		-- the new engine (e.g., botReregisterAll missed it for some edge case reason).
		-- With the materialize-from-DB step above, this loop normally finds 0; kept as a
		-- safety net.
		local orphanCount = 0
		for guid, p in pairs(BotPlayers or {}) do
			local isActive = (BotActive and BotActive[guid])
			if isActive == nil and Game.botIsActive then
				isActive = Game.botIsActive(guid)
			end
			if p and not isActive and Game.botRecoverOrphanForReload then
				if Game.botRecoverOrphanForReload(guid, p) then
					orphanCount = orphanCount + 1
				end
			end
		end
		if orphanCount > 0 then
			emit("Recovered " .. orphanCount .. " orphan bot(s)")
		end

		-- 6. Determine target set for re-activation based on debugCount
		local debugCount = opts.debugCount
		local activateGuids = {}
		local debugTargets = {}
		local debugTargetNames = {}  -- guid -> name; survives async materialization

		if debugCount == "off" then
			-- Clear persisted debug mode, re-activate everything
			db.query("INSERT INTO `bot_startup_config` (`config_key`, `config_value`) "
				.. "VALUES ('debug_active_count', '0') "
				.. "ON DUPLICATE KEY UPDATE `config_value` = '0'")
			-- Re-enable C++ population scheduler so it can manage normal active counts
			if Game.botCommand then
				Game.botCommand("_global", "schedule on")
			end
			emit("scheduler ON")
			for guid, _ in pairs(BotPlayers or {}) do
				activateGuids[#activateGuids + 1] = guid
			end
			emit("debug mode OFF — activating ALL " .. #activateGuids .. " registered bots")
		elseif type(debugCount) == "number" and debugCount > 0 then
			-- Persist new debug count
			db.query("INSERT INTO `bot_startup_config` (`config_key`, `config_value`) "
				.. "VALUES ('debug_active_count', '" .. debugCount .. "') "
				.. "ON DUPLICATE KEY UPDATE `config_value` = '" .. debugCount .. "'")
			-- Disable C++ population scheduler — otherwise it re-activates the 199 we just turned off
			if Game.botCommand then
				Game.botCommand("_global", "schedule off")
			end
			emit("scheduler OFF (debug mode controls active set)")

			-- Pick which bots to debug.
			-- Priority: explicit NAME LIST (reload debug,<Name>[;<Name2>]) > opts.debugBotName >
			-- BOT_CONFIG.DEBUG_BOT_NAME > first N from onlineGuids > first N from BotPlayers.
			local picked = {}
			if opts.debugBotNames then
				-- Resolve names against the REGISTERED bot map, not Player(name): during a
				-- reload the pool is re-materialized asynchronously, so Player(name) can still
				-- return nil for a bot that is perfectly well registered. Match case-insensitively
				-- so the operator does not have to reproduce display casing exactly.
				local byName = {}
				for g, ref in pairs(BotPlayers or {}) do
					if ref and not ref:isRemoved() then
						byName[ref:getName():lower()] = g
					end
				end
				for _, wanted in ipairs(opts.debugBotNames) do
					local g = byName[wanted:lower()]
					if not g then
						local p = Player(wanted) -- fallback for bots not yet in BotPlayers
						if p then g = p:getGuid() end
					end
					if g then
						if not picked[g] then
							picked[g] = true
							activateGuids[#activateGuids + 1] = g
							debugTargetNames[g] = wanted
						end
					else
						emit("debug: bot '" .. wanted .. "' not found/registered — skipped")
					end
				end
			end

			local preferredName = opts.debugBotName
			if not preferredName and BOT_CONFIG.DEBUG_BOT_NAME and BOT_CONFIG.DEBUG_BOT_NAME ~= "" then
				preferredName = BOT_CONFIG.DEBUG_BOT_NAME
			end

			if preferredName and not opts.debugBotNames then
				local prefP = Player(preferredName)
				if prefP then
					local prefGuid = prefP:getGuid()
					if BotPlayers[prefGuid] then
						picked[prefGuid] = true
						activateGuids[#activateGuids + 1] = prefGuid
					end
				end
			end

			-- Fill remaining slots from onlineGuids (preserves "previously online" preference)
			for _, guid in ipairs(onlineGuids) do
				if #activateGuids >= debugCount then break end
				if not picked[guid] then
					picked[guid] = true
					activateGuids[#activateGuids + 1] = guid
				end
			end

			-- Still not enough? Fall back to any registered bot
			if #activateGuids < debugCount then
				for guid, _ in pairs(BotPlayers or {}) do
					if #activateGuids >= debugCount then break end
					if not picked[guid] then
						picked[guid] = true
						activateGuids[#activateGuids + 1] = guid
					end
				end
			end

			-- These are the debug targets — debug stream will be enabled on them.
			-- Record the NAME too: step 8 runs while the pool may still be materializing, so
			-- BotPlayers[guid] can be nil for a perfectly valid target. Game.botCommand resolves
			-- against the engine's own registry by name, so a name is enough.
			for _, guid in ipairs(activateGuids) do
				debugTargets[guid] = true
				if not debugTargetNames[guid] then
					local ref = (BotPlayers or {})[guid]
					if ref and not ref:isRemoved() then
						debugTargetNames[guid] = ref:getName()
					end
				end
			end
			emit("debug mode ON — activating " .. #activateGuids .. " bot(s); rest stay offline")
		else
			-- No debug change: preserve previously-online set
			activateGuids = onlineGuids
		end

		-- 7. Re-activate selected bots
		-- Primary path: botReactivateForReload preserves state for bots that were active before the reload.
		-- Fallback: botActivate is the canonical fresh-activation path (teleport to temple, state=IDLE) for
		-- bots that weren't in a preserved state — e.g., during "debug off" we want to bring back bots that
		-- may have been INACTIVE before the debug session started.
		local reactivated = 0
		local fallbackActivated = 0
		for _, guid in ipairs(activateGuids) do
			if Game.botReactivateForReload and Game.botReactivateForReload(guid) then
				reactivated = reactivated + 1
			elseif Game.botActivate and Game.botActivate(guid) then
				reactivated = reactivated + 1
				fallbackActivated = fallbackActivated + 1
			end
		end
		if fallbackActivated > 0 then
			emit("Re-activated " .. reactivated .. "/" .. #activateGuids .. " bots ("
				.. fallbackActivated .. " via fresh-activate fallback).")
		else
			emit("Re-activated " .. reactivated .. "/" .. #activateGuids .. " bots.")
		end

		-- 7b. Debug mode: REMOVE every non-target bot from the world.
		-- "rest stay offline" only ever cleared the AI flag; the reload had already
		-- re-materialized all 500 as live Player objects, so 499 of them stayed standing in
		-- the world as motionless statues. That defeats the entire point of debug mode (and is
		-- what an operator sees in-game as "why are there still bots everywhere?").
		-- botForceDeactivateForReload despawns them, leaving exactly the debug targets.
		if type(debugCount) == "number" and debugCount > 0 then
			-- Iterate the ENGINE's registry, not BotPlayers: materialization is async, so
			-- BotPlayers held only ~10 entries here and the first attempt despawned 9 of 500.
			-- getBotHibernationStates is the same authoritative list the hibernation loop uses.
			local despawned = 0
			local all = (Game.getBotHibernationStates and Game.getBotHibernationStates()) or {}
			if #all == 0 and BotPlayers then
				for g, _ in pairs(BotPlayers) do
					all[#all + 1] = { guid = g }
				end
			end
			for i = 1, #all do
				local guid = all[i].guid
				if guid and not debugTargets[guid] then
					if Game.botForceDeactivateForReload then
						if Game.botForceDeactivateForReload(guid) then
							despawned = despawned + 1
						end
					else
						local p = (BotPlayers and BotPlayers[guid]) or Player(guid)
						if p and not p:isRemoved() then
							p:remove()
							despawned = despawned + 1
						end
					end
					if BotActive ~= nil then BotActive[guid] = false end
					if BotPlayers ~= nil then BotPlayers[guid] = nil end
				end
			end
			emit("debug mode: despawned " .. despawned .. "/" .. #all .. " non-target bot(s) from the world")
		end

		-- 8. Toggle debug stream on the chosen targets (one per active bot in debug mode)
		if debugCount == "off" then
			-- Best-effort: turn off debug for all bots that might have had it on, and UNPIN
			-- everything so the normal AI resumes (a leftover pin would freeze a bot forever).
			for guid, _ in pairs(BotPlayers or {}) do
				local p = BotPlayers[guid]
				if p and not p:isRemoved() and Game.botCommand then
					Game.botCommand(p:getName(), "debug off")
					Game.botCommand(p:getName(), "pin off")
				end
			end
			BotDebugPinned = {}
		elseif type(debugCount) == "number" and debugCount > 0 then
			for guid, _ in pairs(debugTargets) do
				local p = BotPlayers[guid]
				local nm = debugTargetNames[guid] or (p and not p:isRemoved() and p:getName()) or nil
				if nm and Game.botCommand then
					local r = Game.botCommand(nm, "debug on")
					-- PIN the debug bot: no self-assigned tasks (the C++ activity reroll returns
					-- early) and no hibernation (BotDebugPinned is checked by bot_hibernation).
					-- Without this the bot picks a hunt mid-observation and any manual `goto` is
					-- silently overwritten, which is exactly what made debug mode unusable for
					-- watching one bot do one thing.
					Game.botCommand(nm, "pin on")
					BotDebugPinned[guid] = true
					emit("debug stream + PIN enabled on '" .. nm .. "' — " .. tostring(r))
				end
			end
		end

		-- 9. Show git commit info so admin knows what version is running (talkaction-only — slow popen)
		if opts.source == "talkaction" then
			local handle = io.popen("git log -1 --pretty=format:'%h %s' 2>/dev/null")
			if handle then
				local gitInfo = handle:read("*a")
				handle:close()
				if gitInfo and gitInfo ~= "" then
					emit("Rev: " .. gitInfo)
				end
			end
		end

		emit("reload finalized; active=" .. reactivated .. " debug=" .. (debugCount and tostring(debugCount) or "preserve"))
		end) -- pcall wrap of finalize body
		if not finalizeOk then
			logger.error("[reload:{}] finalize error: {}", source, tostring(finalizeErr))
			-- Surface to admin if possible (player ref may be stale by now — emit guards it)
			emit("reload finalize FAILED: " .. tostring(finalizeErr))
		end
		BotSystem._reloadInProgress = false
	end -- finalizeReload

	-- Dispatch step 4b: stagger each loadBotPlayer onto its own dispatcher iteration.
	-- pcall guards per-bot failures so the counter still decrements even if one bot
	-- errors out — otherwise pendingMaterializations would never hit 0 and the reload
	-- would stay "in progress" forever, blocking future reloads (re-entrancy guard).
	if pendingMaterializations == 0 then
		finalizeReload()
	else
		for i, name in ipairs(hibernatedNames) do
			addEvent(function()
				local ok, err = pcall(function()
					if not Player(name) then
						if Game.loadBotPlayer(name) then
							materializedCount = materializedCount + 1
						end
					end
				end)
				if not ok then
					logger.error("[reload:materialize] error loading bot '" .. name .. "': " .. tostring(err))
				end
				pendingMaterializations = pendingMaterializations - 1
				if pendingMaterializations == 0 then
					finalizeReload()
				end
			end, i * BOT_MATERIALIZE_INTERVAL_MS)
		end
	end

	-- Sync return: caller (bot_commands queue) gets an "in progress" message.
	-- Final state lands in the journal via emit() inside finalizeReload.
	return {
		ok = true,
		message = (#hibernatedNames > 0)
			and ("reload started; materializing " .. #hibernatedNames .. " hibernated bots async (~"
				 .. math.ceil(#hibernatedNames * BOT_MATERIALIZE_INTERVAL_MS / 1000) .. "s)")
			or "reload started; no hibernated bots to materialize",
		lines = lines,
	}
end

-- ============================================================================
-- Command Queue Polling (MySQL-based, for automated testing)
-- ============================================================================

-- Global command queue poll: ONE query for all bots (called from bot_manager every 10s)
function BotSystem.pollGlobalCommandQueue()
	local resultId = db.storeQuery(
		"SELECT `id`, `bot_name`, `command` FROM `bot_commands` WHERE `processed` = 0 ORDER BY `id` ASC LIMIT 10")
	if not resultId then return end
	repeat
		local cmdId = Result.getNumber(resultId, "id")
		local botName = Result.getString(resultId, "bot_name")
		local cmd = Result.getString(resultId, "command")
		-- Mark processed immediately
		db.botAsyncQuery("UPDATE `bot_commands` SET `processed` = 1 WHERE `id` = " .. cmdId)
		-- Find the bot and execute
		local player = Player(botName)
		if player then
			local guid = player:getGuid()
			local state = BotState[guid]
			if state then
				logger.info("[CavebotDebug:" .. botName .. "] Command from queue: " .. cmd)
				local result = BotSystem.executeCavebotCommand(player, state, cmd)
				if result then
					logger.info("[CavebotDebug:" .. botName .. "] " .. result)
					BotSystem.castDebug(player, state, "CMD result: " .. result)
				end
			end
		else
			logger.warn("[CavebotDebug:" .. botName .. "] Bot not found for command: " .. cmd)
		end
	until not Result.next(resultId)
	Result.free(resultId)
end

-- Clear all active tasks/state so a new command starts clean
function BotSystem.clearAllTasks(player, state)
	-- Release hunt reservation
	if state.huntScriptId then
		BotHuntData.releaseHunt(state.huntScriptId, player:getGuid())
	end
	-- Hunt state
	state.huntScriptId = nil
	state.huntPhase = nil
	state.huntWaypoints = nil
	state.huntWaypointIdx = 0
	state.huntTargets = nil
	state.huntStartTime = nil
	state.huntEndTime = nil
	state.huntKillCount = nil
	state.huntTownId = nil
	state.huntMonsterTarget = nil
	state.huntWaypointSkipCount = 0
	state.huntLastPos = nil
	state.huntCycles = nil
	state.huntScanCooldown = nil
	-- Cavebot/navigation state
	state.cavebotCommand = nil
	state.cavebotTarget = nil
	state.cavebotNavRoute = nil
	state.cavebotNavSrc = nil
	state.cavebotNavDest = nil
	state.cavebotSequence = nil
	state.cavebotSequenceIdx = nil
	state.routeIdx = nil
	state.routeStuckCount = nil
	state.routeStuckSince = nil
	state.routeStuckLogged = nil
	state.navDepotTarget = nil
	state.navDepotWaitUntil = nil
	state.seqDepotTarget = nil
	state.seqWaitUntil = nil
	state.seqWaitPOI = nil
	-- Travel state
	state.travelDestTownId = nil
	state.travelDestTownName = nil
	state.travelPhase = nil
	state.travelBoatNpcPos = nil
	state.travelWaitUntil = nil
	state.walkToPOITarget = nil
	state.walkToPOIFailCount = nil
	state.pendingHuntAfterTravel = nil
	-- Resupply state
	state.resupplyStep = nil
	state.resupplyUntil = 0
	state.resupplyWalkTarget = nil
	state.resupplyRoute = nil
	state.resupplyStartTime = nil
	state.resupplyDepotTarget = nil
	state.resupplyLastPOI = nil
	-- General
	state.walkTarget = nil
	state.currentPOI = nil
	BotSystem.resetFloorChangeState(state)
	-- Clear target
	if player:getTarget() then player:setTarget(nil) end
end

-- Parse and execute a cavebot command string
function BotSystem.executeCavebotCommand(player, state, cmdStr)
	local cmd, args = cmdStr:match("^(%S+)%s*(.*)")
	if not cmd then return end
	cmd = cmd:lower()
	if cmd == "apply_edit" then
		local data = {}
		for k, v in args:gmatch('"(%w+)"%s*:%s*([^,}]+)') do
			v = v:gsub('^"(.-)"$', '%1')
			if tonumber(v) then v = tonumber(v) end
			if v == "true" then v = true elseif v == "false" then v = false end
			data[k] = v
		end

		if data.level and player.getLevel and player.addExperience then
			local curLvl = player:getLevel()
			if data.level > curLvl then
				local targetExp = Game.getExperienceForLevel(data.level)
				local curExp = player:getExperience()
				if targetExp and targetExp > curExp then
					player:addExperience(targetExp - curExp, false)
				end
			end
		end

		if (data.healthmax or data.maxhealth) and player.setMaxHealth then
			player:setMaxHealth(tonumber(data.healthmax or data.maxhealth))
		end
		if data.health and player.addHealth then
			local curH = player:getHealth()
			local diffH = data.health - curH
			player:addHealth(diffH)
		end

		if (data.manamax or data.maxmana) and player.setMaxMana then
			player:setMaxMana(tonumber(data.manamax or data.maxmana))
		end
		if data.mana and player.addMana then
			local curM = player:getMana()
			local diffM = data.mana - curM
			player:addMana(diffM)
		end

		if data.town_id and player.setTown then
			pcall(function() player:setTown(Town(tonumber(data.town_id))) end)
		end
		if data.vocation and player.setVocation then
			local vocNum = tonumber(data.vocation)
			if vocNum then
				pcall(function() player:setVocation(Vocation(vocNum)) end)
			end
		end

		if data.skill_sword and player.addSkillLevel then
			local diff = data.skill_sword - player:getSkillLevel(SKILL_SWORD)
			if diff > 0 then player:addSkillLevel(SKILL_SWORD, diff) end
		end
		if data.skill_axe and player.addSkillLevel then
			local diff = data.skill_axe - player:getSkillLevel(SKILL_AXE)
			if diff > 0 then player:addSkillLevel(SKILL_AXE, diff) end
		end
		if data.skill_club and player.addSkillLevel then
			local diff = data.skill_club - player:getSkillLevel(SKILL_CLUB)
			if diff > 0 then player:addSkillLevel(SKILL_CLUB, diff) end
		end
		if data.skill_dist and player.addSkillLevel then
			local diff = data.skill_dist - player:getSkillLevel(SKILL_DISTANCE)
			if diff > 0 then player:addSkillLevel(SKILL_DISTANCE, diff) end
		end
		if data.skill_shielding and player.addSkillLevel then
			local diff = data.skill_shielding - player:getSkillLevel(SKILL_SHIELD)
			if diff > 0 then player:addSkillLevel(SKILL_SHIELD, diff) end
		end
		if data.maglevel and player.addMagicLevel then
			local diff = data.maglevel - player:getBaseMagicLevel()
			if diff > 0 then player:addMagicLevel(diff) end
		end

		if data.personality and state then
			state.archetypeId = tonumber(data.personality)
		end

		if data.teleport_temple then
			if state then
				BotSystem.clearAllTasks(player, state)
				state.state = BOT_STATE.IDLE
			end
			local town = player:getTown()
			if town then
				player:teleportTo(town:getTemplePosition())
			end
		end

		if player.save then
			pcall(function() player:save() end)
		end

		logger.info("[CavebotDebug:" .. player:getName() .. "] apply_edit applied live!")
		return "Edit applied live"

	elseif cmd == "status" then
		local town = player:getTown()
		local townName = town and town:getName() or "?"
		local msg = "Status: " .. player:getName()
			.. " pos=(" .. pos.x .. "," .. pos.y .. "," .. pos.z .. ")"
			.. " state=" .. state.state
			.. " city=" .. townName
			.. " hp=" .. player:getHealth() .. "/" .. player:getMaxHealth()
		if state.huntScriptId then
			local scriptName = BotHuntData.scripts[state.huntScriptId]
				and BotHuntData.scripts[state.huntScriptId].name or "?"
			msg = msg .. " hunt=" .. scriptName
				.. " phase=" .. (state.huntPhase or "?")
				.. " wp=" .. (state.huntWaypointIdx or 0)
		end
		if state.cavebotCommand then
			msg = msg .. " cmd=" .. state.cavebotCommand
		end
		msg = msg .. " fc_state=" .. state.floorChangeState
		logger.info("[CavebotDebug:" .. player:getName() .. "] " .. msg)
		return msg

	elseif cmd == "pos" then
		local msg = player:getName() .. " at (" .. pos.x .. "," .. pos.y .. "," .. pos.z .. ")"
		logger.info("[CavebotDebug:" .. player:getName() .. "] " .. msg)
		return msg

	elseif cmd == "goto" then
		BotSystem.clearAllTasks(player, state)
		local x, y, z = args:match("(%d+),(%d+),(%d+)")
		if not x then
			x, y, z = args:match("(%d+)%s+(%d+)%s+(%d+)")
		end
		if not x then return "Usage: goto x,y,z" end
		state.cavebotCommand = "goto"
		state.cavebotTarget = Position(tonumber(x), tonumber(y), tonumber(z))
		state.state = BOT_STATE.HUNTING -- prevent z-recovery
		state.verboseLog = true
		logger.info("[CavebotDebug:" .. player:getName() .. "] goto " .. x .. "," .. y .. "," .. z)
		return "Walking to " .. x .. "," .. y .. "," .. z

	elseif cmd == "stairs" then
		BotSystem.clearAllTasks(player, state)
		local goDown = (args:lower() == "down")
		local transitions = BotSystem.findZTransitions(pos, 15, goDown)
		local msg = (goDown and "DOWN" or "UP") .. " transitions: " .. #transitions
		logger.info("[CavebotDebug:" .. player:getName() .. "] " .. msg)
		for i, t in ipairs(transitions) do
			logger.info("[CavebotDebug:" .. player:getName() .. "]   #" .. i .. ": "
				.. t.type .. " at (" .. t.pos.x .. "," .. t.pos.y .. "," .. t.pos.z .. ") dist=" .. t.dist)
		end
		if #transitions > 0 then
			state.cavebotCommand = "stairs"
			state.state = BOT_STATE.HUNTING
			state.verboseLog = true
			BotSystem.startFloorChange(state, goDown, nil, nil, "cavebot")
		end
		return msg

	elseif cmd == "scan" then
		local radius = tonumber(args) or 10
		local upT = BotSystem.findZTransitions(pos, radius, false)
		local downT = BotSystem.findZTransitions(pos, radius, true)
		logger.info("[CavebotDebug:" .. player:getName() .. "] SCAN radius=" .. radius)
		logger.info("[CavebotDebug:" .. player:getName() .. "] UP transitions: " .. #upT)
		for _, t in ipairs(upT) do
			logger.info("[CavebotDebug:" .. player:getName() .. "]   " .. t.type
				.. " at (" .. t.pos.x .. "," .. t.pos.y .. "," .. t.pos.z .. ") dist=" .. t.dist)
		end
		logger.info("[CavebotDebug:" .. player:getName() .. "] DOWN transitions: " .. #downT)
		for _, t in ipairs(downT) do
			logger.info("[CavebotDebug:" .. player:getName() .. "]   " .. t.type
				.. " at (" .. t.pos.x .. "," .. t.pos.y .. "," .. t.pos.z .. ") dist=" .. t.dist)
		end
		return "UP=" .. #upT .. " DOWN=" .. #downT

	elseif cmd == "step" then
		local dirMap = {
			north = DIRECTION_NORTH, south = DIRECTION_SOUTH,
			east = DIRECTION_EAST, west = DIRECTION_WEST,
			ne = DIRECTION_NORTHEAST, nw = DIRECTION_NORTHWEST,
			se = DIRECTION_SOUTHEAST, sw = DIRECTION_SOUTHWEST,
		}
		local dir = dirMap[args:lower()]
		if not dir then return "Usage: step north|south|east|west|ne|nw|se|sw" end
		player:move(dir)
		local newPos = player:getPosition()
		logger.info("[CavebotDebug:" .. player:getName() .. "] step " .. args
			.. " -> (" .. newPos.x .. "," .. newPos.y .. "," .. newPos.z .. ")")
		return "Moved " .. args

	elseif cmd == "teleport" or cmd == "tp" then
		local x, y, z = args:match("(%d+),(%d+),(%d+)")
		if not x then
			x, y, z = args:match("(%d+)%s+(%d+)%s+(%d+)")
		end
		if not x then return "Usage: teleport x,y,z" end
		player:teleportTo(Position(tonumber(x), tonumber(y), tonumber(z)))
		local newPos = player:getPosition()
		logger.info("[CavebotDebug:" .. player:getName() .. "] teleported to ("
			.. newPos.x .. "," .. newPos.y .. "," .. newPos.z .. ")")
		return "Teleported"

	elseif cmd == "stop" then
		BotSystem.clearAllTasks(player, state)
		state.state = BOT_STATE.IDLE
		logger.info("[CavebotDebug:" .. player:getName() .. "] stopped")
		return "Stopped"

	elseif cmd == "resume" then
		BotSystem.clearAllTasks(player, state)
		state.state = BOT_STATE.IDLE
		state.verboseLog = false
		logger.info("[CavebotDebug:" .. player:getName() .. "] resumed normal AI")
		return "Resumed"

	elseif cmd == "advstone" then
		-- Adventurer's Stone trip — bot must be standing in a temple PZ.
		-- All trip state lives in C++; we just forward to executeCommand which
		-- runs startAdventurerStoneTrip(). Useful as a SQL test trigger:
		--   INSERT INTO bot_commands (bot_name, command) VALUES ('<Bot>', 'advstone');
		local result = Game.botCommand(player:getName(), "advstone")
		logger.info("[CavebotDebug:" .. player:getName() .. "] " .. tostring(result))
		return result

	elseif cmd == "log" then
		if args:lower() == "on" then
			state.verboseLog = true
			logger.info("[CavebotDebug:" .. player:getName() .. "] verbose logging ON")
			return "Logging ON"
		elseif args:lower() == "off" then
			state.verboseLog = false
			logger.info("[CavebotDebug:" .. player:getName() .. "] verbose logging OFF")
			return "Logging OFF"
		end
		return "Usage: log on|off"

	elseif cmd == "hunt" then
		local scriptId = tonumber(args)
		if not scriptId then
			-- Try finding by name
			for id, script in pairs(BotHuntData.scripts or {}) do
				if script.name and script.name:lower():find(args:lower(), 1, true) then
					scriptId = id
					break
				end
			end
		end
		if not scriptId then return "Hunt script not found: " .. args end
		BotSystem.clearAllTasks(player, state)
		state.verboseLog = true
		-- Force start this hunt
		local ok = BotHuntData.reserveHunt(scriptId, player:getGuid())
		if ok then
			local script = BotHuntData.scripts[scriptId]
			local huntTownId = script and script.town_id or nil
			local botTownId = player:getTown() and player:getTown():getId() or nil

			state.huntScriptId = scriptId
			state.huntStartTime = os.time()
			state.huntEndTime = os.time() + 3600
			state.huntKillCount = 0
			state.huntTargets = BotHuntData.getTargets(scriptId)
			state.huntTownId = huntTownId

			-- Check if hunt is in a different city — travel there first
			if huntTownId and botTownId and huntTownId ~= botTownId then
				local townName = script.town_name or ("town " .. huntTownId)
				logger.info("[CavebotDebug:" .. player:getName() .. "] hunt " .. scriptId
					.. " is in " .. townName .. " (bot in town " .. botTownId .. "), traveling first")
				BotSystem.castDebug(player, state, "Hunt: need to travel to " .. townName .. " first")
				-- Set up travel to the hunt's city
				state.pendingHuntAfterTravel = true
				-- Use the cavebot travel system
				local destTownName = townName:lower()
				BotSystem.startCavebotTravel(player, state, huntTownId, destTownName)
				return "Hunt " .. scriptId .. ": traveling to " .. townName .. " first"
			end

			BotSystem.beginHuntPhase(player, state, HUNT_PHASE.PREPARING)
			logger.info("[CavebotDebug:" .. player:getName() .. "] starting hunt script " .. scriptId)
			return "Hunt started: " .. scriptId .. " (preparing: depot + shops)"
		else
			return "Hunt script " .. scriptId .. " already reserved"
		end

	elseif cmd == "info" then
		local upT = BotSystem.findZTransitions(pos, 15, false)
		local downT = BotSystem.findZTransitions(pos, 15, true)
		local msg = "Bot at (" .. pos.x .. "," .. pos.y .. "," .. pos.z .. ")"
			.. " UP=" .. #upT .. " DOWN=" .. #downT
			.. " state=" .. state.state
			.. " fc_state=" .. state.floorChangeState
			.. " stuck=" .. tostring(BotSystem.isStuck(state))
		logger.info("[CavebotDebug:" .. player:getName() .. "] " .. msg)
		return msg

	elseif cmd == "poi" then
		local townId = player:getTown() and player:getTown():getId() or 0
		local poiName, poiDist = BotHuntData.detectNearestPOI(townId, player:getPosition())
		local msg = "Nearest POI: " .. (poiName or "none") .. " (dist=" .. (poiDist or 999) .. ")"
			.. " townId=" .. townId
		logger.info("[CavebotDebug:" .. player:getName() .. "] " .. msg)
		return msg

	elseif cmd == "routes" then
		local townId = player:getTown() and player:getTown():getId() or 0
		local pois = BotHuntData.listPOIs(townId)
		local routes = BotHuntData.listRoutes(townId)
		local msg = "Town " .. townId .. ": " .. #pois .. " POIs, " .. #routes .. " route pairs"
		logger.info("[CavebotDebug:" .. player:getName() .. "] " .. msg)
		logger.info("[CavebotDebug:" .. player:getName() .. "]   POIs: " .. table.concat(pois, ", "))
		-- Log first 20 routes
		for i = 1, math.min(20, #routes) do
			local r = routes[i]
			logger.info("[CavebotDebug:" .. player:getName() .. "]   " .. r.src .. " -> " .. r.dst)
		end
		return msg .. "\nPOIs: " .. table.concat(pois, ", ")

	elseif cmd == "navigate" or cmd == "nav" then
		local destination = args:lower():match("^(%S+)")
		if not destination then return "Usage: navigate <poi>" end
		BotSystem.clearAllTasks(player, state)

		local townId = player:getTown() and player:getTown():getId() or 0
		-- Detect current POI
		local currentPOI, poiDist = BotHuntData.detectNearestPOI(townId, player:getPosition())
		if not currentPOI or poiDist > 50 then
			return "Can't detect current location (nearest=" .. (currentPOI or "none") .. " dist=" .. (poiDist or 999) .. ")"
		end

		-- Find route
		local waypoints, reversed = BotHuntData.findRoute(townId, currentPOI, destination)
		if not waypoints then
			return "No route from " .. currentPOI .. " to " .. destination .. " in town " .. townId
		end

		-- Set up navigation
		state.cavebotCommand = "navigate"
		state.cavebotNavRoute = waypoints
		state.cavebotNavDest = destination
		state.cavebotNavSrc = currentPOI
		state.routeIdx = 1
		state.routeStuckCount = 0
		state.state = BOT_STATE.HUNTING -- prevent z-recovery
		state.verboseLog = true
		BotSystem.castDebug(player, state, "Navigate: " .. currentPOI .. " -> " .. destination
			.. " (" .. #waypoints .. " wps" .. (reversed and ", reversed" or "") .. ")")
		return "Navigating from " .. currentPOI .. " to " .. destination
			.. " (" .. #waypoints .. " waypoints" .. (reversed and ", reversed" or "") .. ")"

	elseif cmd == "sequence" or cmd == "seq" then
		-- Parse comma-separated POI list: "temple,depot,bank,boat"
		local pois = {}
		for poi in args:gmatch("([^,]+)") do
			local trimmed = poi:match("^%s*(.-)%s*$"):lower()
			if trimmed ~= "" then
				pois[#pois + 1] = trimmed
			end
		end
		if #pois < 2 then return "Need at least 2 POIs (comma-separated): sequence temple,depot,bank" end
		BotSystem.clearAllTasks(player, state)

		state.cavebotCommand = "sequence"
		state.cavebotSequence = pois
		state.cavebotSequenceIdx = 1
		state.state = BOT_STATE.HUNTING
		state.verboseLog = true
		BotSystem.castDebug(player, state, "Sequence: " .. table.concat(pois, " -> "))
		return "Starting sequence: " .. table.concat(pois, " -> ")

	elseif cmd == "travel" then
		local destCity = args:match("^%s*(.-)%s*$") -- trim whitespace, keep full name
		if not destCity or destCity == "" then return "Usage: travel <city>" end
		destCity = destCity:lower()
		BotSystem.clearAllTasks(player, state)

		local townId = player:getTown() and player:getTown():getId() or 0
		-- Find destination town ID (exact match first, then partial)
		local destTownId = nil
		local destTownName = nil
		-- Pass 1: exact match
		for _, town in ipairs(Game.getTowns() or {}) do
			if town:getName():lower() == destCity then
				destTownId = town:getId()
				destTownName = town:getName()
				break
			end
		end
		-- Pass 2: partial match (e.g. "liberty" matches "Liberty Bay")
		if not destTownId then
			for _, town in ipairs(Game.getTowns() or {}) do
				if town:getName():lower():find(destCity, 1, true) then
					destTownId = town:getId()
					destTownName = town:getName()
					break
				end
			end
		end
		if not destTownId then return "Unknown city: " .. destCity end

		-- Get boat NPC position in destination town (BOAT_POSITIONS preferred — actual NPC coords)
		local destBoatPos = BOAT_POSITIONS[destTownId]
		if not destBoatPos then
			-- Fallback to route graph POI
			local destGraph = BotHuntData.routeGraph[destTownId]
			if destGraph and destGraph.pois and destGraph.pois["boat"] then
				local p = destGraph.pois["boat"]
				destBoatPos = Position(p.x, p.y, p.z)
			end
		end
		if not destBoatPos then
			return "No boat position for destination city " .. (destTownName or destCity)
		end

		-- Get current city's boat NPC position (BOAT_POSITIONS preferred)
		local srcBoatPos = BOAT_POSITIONS[townId]

		-- Try to detect current POI and find a walking route to boat
		local currentPOI, poiDist = BotHuntData.detectNearestPOI(townId, player:getPosition())
		local waypoints = nil
		if currentPOI and poiDist <= 50 and currentPOI ~= "boat" then
			waypoints = BotHuntData.findRoute(townId, currentPOI, "boat")
		end

		state.cavebotCommand = "travel"
		state.travelDestTownId = destTownId
		state.travelDestTownName = destTownName or destCity
		state.travelDestBoatPos = destBoatPos
		state.travelPhase = "going_to_boat"
		state.state = BOT_STATE.HUNTING
		state.verboseLog = true

		if currentPOI == "boat" and poiDist and poiDist < 5 then
			-- Already near boat — walk to the exact boat spot
			if srcBoatPos then
				state.travelPhase = "walking_to_npc"
				state.travelBoatNpcPos = srcBoatPos
				BotSystem.castDebug(player, state, "Travel: near boat, walking to boat spot")
			else
				state.travelPhase = "at_boat"
				state.travelWaitUntil = os.time() + math.random(3, 10)
			end
		elseif waypoints then
			-- Have a walking route to boat
			state.cavebotNavRoute = waypoints
			state.cavebotNavDest = "boat"
			state.cavebotNavSrc = currentPOI
			state.routeIdx = 1
			state.routeStuckCount = 0
			BotSystem.castDebug(player, state, "Travel: " .. currentPOI .. " -> boat -> "
				.. (destTownName or destCity) .. " (" .. #waypoints .. " wps)")
		elseif srcBoatPos then
			-- No walking route — teleport directly to current city's boat NPC
			player:teleportTo(srcBoatPos)
			BotSystem.castDebug(player, state, "Travel: no route to boat, teleported to boat NPC at ("
				.. srcBoatPos.x .. "," .. srcBoatPos.y .. "," .. srcBoatPos.z .. ")")
			state.travelPhase = "at_boat"
			state.travelWaitUntil = os.time() + math.random(3, 10)
		else
			return "No boat position for current city (townId=" .. townId .. ")"
		end
		return "Traveling to " .. (destTownName or destCity)

	elseif cmd == "pk" then
		-- Force bot to PK a named target: pk TargetName
		local targetName = args
		if not targetName or targetName == "" then
			return "Usage: pk <target name>"
		end
		local target = Player(targetName)
		if not target then
			return "Target not found or offline: " .. targetName
		end
		if target:getId() == player:getId() then
			return "Cannot PK self"
		end
		BotSystem.clearAllTasks(player, state)
		state.state = BOT_STATE.PK_ATTACK
		state.pkTarget = target:getId()
		state.pkStartTime = os.time()
		state.lastAttackTime = 0
		state.lastCombatProgress = os.time()
		player:setTarget(target)
		BotSystem.castDebug(player, state, "PK FORCED: attacking " .. target:getName()
			.. " (id=" .. target:getId() .. ")")
		return "PK initiated on " .. target:getName()

	else
		return "Unknown command: " .. cmd
	end
end

-- ============================================================================
-- Cavebot "goto" Command Navigation (handles same-z pathfinding + z-transitions)
-- ============================================================================

function BotSystem.processCavebotGoto(player, state)
	if player:isWalking() then return end

	local pos = player:getPosition()
	local target = state.cavebotTarget
	if not target then
		state.cavebotCommand = nil
		return
	end

	local dx = math.abs(pos.x - target.x)
	local dy = math.abs(pos.y - target.y)
	local dist = math.max(dx, dy)

	-- Check arrival
	if dx <= 1 and dy <= 1 and pos.z == target.z then
		BotSystem.debugLog(state, "GOTO: arrived at (" .. target.x .. "," .. target.y .. "," .. target.z .. ")")
		state.cavebotCommand = nil
		state.cavebotTarget = nil
		return
	end

	-- Z-transition needed?
	if pos.z ~= target.z then
		local goDown = target.z > pos.z
		BotSystem.debugLog(state, "GOTO: z-mismatch pos.z=" .. pos.z .. " target.z=" .. target.z
			.. " -> starting floor change " .. (goDown and "DOWN" or "UP"))
		BotSystem.startFloorChange(state, goDown, target, nil, "cavebot")
		return
	end

	-- Same z: pathfind to target
	BotSystem.debugLog(state, "GOTO: same z, walking to (" .. target.x .. "," .. target.y .. ") dist=" .. dist)
	local ok = BotSystem.goTo(player, target)
	if not ok then
		BotSystem.tryOpenDoors(player, target)
		ok = BotSystem.goTo(player, target)
		if not ok then
			-- Check if stuck
			if BotSystem.isStuck(state) then
				BotSystem.debugLog(state, "GOTO: STUCK - aborting")
				state.cavebotCommand = nil
				state.cavebotTarget = nil
			else
				BotSystem.debugLog(state, "GOTO: path failed, retrying next tick")
			end
		end
	end
end

-- ============================================================================
-- startCavebotTravel: programmatic travel setup (used by hunt command)
-- ============================================================================

function BotSystem.startCavebotTravel(player, state, destTownId, destTownName)
	local townId = player:getTown() and player:getTown():getId() or 0

	-- Get boat position for destination
	local destBoatPos = BOAT_POSITIONS[destTownId]
	if not destBoatPos then
		local destGraph = BotHuntData.routeGraph[destTownId]
		if destGraph and destGraph.pois and destGraph.pois["boat"] then
			local p = destGraph.pois["boat"]
			destBoatPos = Position(p.x, p.y, p.z)
		end
	end

	-- Get current city's boat NPC position
	local srcBoatPos = BOAT_POSITIONS[townId]

	-- Try to detect current POI and find a walking route to boat
	local currentPOI, poiDist = BotHuntData.detectNearestPOI(townId, player:getPosition())
	local waypoints = nil
	if currentPOI and poiDist <= 50 and currentPOI ~= "boat" then
		waypoints = BotHuntData.findRoute(townId, currentPOI, "boat")
	end

	state.cavebotCommand = "travel"
	state.travelDestTownId = destTownId
	state.travelDestTownName = destTownName or ("town " .. destTownId)
	state.travelDestBoatPos = destBoatPos
	state.travelPhase = "going_to_boat"
	state.state = BOT_STATE.HUNTING
	state.verboseLog = true
	BotSystem.resetFloorChangeState(state)

	if not destBoatPos then
		-- No destination boat — teleport directly to temple
		local destTown = Town(destTownId)
		if destTown then
			player:teleportTo(destTown:getTemplePosition())
			BotSystem.castDebug(player, state, "Travel: no boat pos for dest, teleported to temple")
		end
		state.cavebotCommand = nil
		state.travelPhase = nil
		return false
	end

	if currentPOI == "boat" and poiDist and poiDist < 5 then
		if srcBoatPos then
			state.travelPhase = "walking_to_npc"
			state.travelBoatNpcPos = srcBoatPos
			BotSystem.castDebug(player, state, "Travel: near boat, walking to boat spot")
		else
			state.travelPhase = "at_boat"
			state.travelWaitUntil = os.time() + math.random(3, 10)
		end
	elseif waypoints then
		state.cavebotNavRoute = waypoints
		state.cavebotNavDest = "boat"
		state.cavebotNavSrc = currentPOI
		state.routeIdx = 1
		state.routeStuckCount = 0
		BotSystem.castDebug(player, state, "Travel: " .. currentPOI .. " -> boat -> "
			.. (destTownName or "?") .. " (" .. #waypoints .. " wps)")
	elseif srcBoatPos then
		-- No DB route — use runtime pathfinding to walk to boat
		state.travelPhase = "walking_to_poi"
		state.walkToPOITarget = srcBoatPos
		state.walkToPOIFailCount = 0
		BotSystem.castDebug(player, state, "Travel: no route to boat, pathfinding to ("
			.. srcBoatPos.x .. "," .. srcBoatPos.y .. "," .. srcBoatPos.z .. ")")
	else
		-- No source boat either — teleport to dest temple
		local destTown = Town(destTownId)
		if destTown then
			player:teleportTo(destTown:getTemplePosition())
			BotSystem.castDebug(player, state, "Travel: no boat info, teleported to dest temple")
		end
		state.cavebotCommand = nil
		state.travelPhase = nil
		return false
	end
	return true
end

-- ============================================================================
-- Cavebot "navigate" Command: route-graph based POI-to-POI navigation
-- ============================================================================

function BotSystem.processCavebotNavigate(player, state)
	-- Sub-state: walking to depot locker (after route arrival at depot)
	if state.navDepotTarget then
		local pos = player:getPosition()
		local dp = state.navDepotTarget

		local dist = math.max(math.abs(pos.x - dp.x), math.abs(pos.y - dp.y))
		if dist <= 1 and pos.z == dp.z then
			-- Adjacent to depot locker — start the delay
			BotSystem.castDebug(player, state, "Navigate: reached depot locker at ("
				.. dp.x .. "," .. dp.y .. "," .. dp.z .. "), starting delay")
			if math.random(1, 2) == 1 then
				BotSystem.sayRandom(player, state, "depot")
			end
			state.navDepotTarget = nil
			local delay = { min = 60, max = 180 }
			local waitSeconds = math.random(delay.min, delay.max)
			state.navDepotWaitUntil = os.time() + waitSeconds
			BotSystem.castDebug(player, state, "Navigate: waiting " .. waitSeconds .. "s at depot locker")
			return
		end

		-- Not adjacent yet — walk toward it
		if not player:isWalking() then
			local foundPath = false
			local adjacentOffsets = {{0,-1},{0,1},{-1,0},{1,0},{-1,-1},{1,-1},{-1,1},{1,1}}
			for _, off in ipairs(adjacentOffsets) do
				local adjPos = Position(dp.x + off[1], dp.y + off[2], dp.z)
				local adjTile = Tile(adjPos)
				if adjTile and adjTile:isWalkable() then
					local dirs = player:getPathTo(adjPos, 0, 0, true, true, BOT_CONFIG.PATH_MAX_DIST)
					if dirs and type(dirs) == "table" and #dirs > 0 then
						player:startAutoWalk(dirs)
						foundPath = true
						break
					end
				end
			end

			if not foundPath then
				BotSystem.castDebug(player, state, "Navigate: depot locker unreachable, finding another")
				local newLocker = BotSystem.findReachableDepotLocker(player, state)
				if newLocker and (newLocker.x ~= dp.x or newLocker.y ~= dp.y) then
					state.navDepotTarget = newLocker
				else
					-- No reachable locker — just wait here
					BotSystem.castDebug(player, state, "Navigate: no reachable locker, waiting here")
					state.navDepotTarget = nil
					local waitSeconds = math.random(60, 180)
					state.navDepotWaitUntil = os.time() + waitSeconds
				end
			end
		end
		return
	end

	-- Sub-state: waiting at depot locker
	if state.navDepotWaitUntil then
		if os.time() >= state.navDepotWaitUntil then
			BotSystem.castDebug(player, state, "Navigate: depot wait complete, done")
			logger.info("[CavebotDebug:" .. player:getName() .. "] Navigate depot visit complete")
			state.navDepotWaitUntil = nil
			state.cavebotCommand = nil
			state.cavebotNavRoute = nil
			state.cavebotNavDest = nil
			state.cavebotNavSrc = nil
			state.routeIdx = nil
			state.routeStuckCount = nil
		end
		return
	end

	local result = BotSystem.followCityRoute(player, state, state.cavebotNavRoute)
	if result == "arrived" then
		local dest = state.cavebotNavDest or "?"
		BotSystem.castDebug(player, state, "Navigate: ARRIVED at " .. dest)
		logger.info("[CavebotDebug:" .. player:getName() .. "] Navigate arrived at " .. dest)

		-- If destination is depot, find and walk to a depot locker
		if dest == "depot" then
			local lockerPos = BotSystem.findReachableDepotLocker(player, state)
			if lockerPos then
				local pos = player:getPosition()
				local dist = math.max(math.abs(pos.x - lockerPos.x), math.abs(pos.y - lockerPos.y))
				if dist <= 1 and pos.z == lockerPos.z then
					-- Already adjacent — start delay immediately
					BotSystem.castDebug(player, state, "Navigate: already adjacent to depot locker")
					if math.random(1, 2) == 1 then
						BotSystem.sayRandom(player, state, "depot")
					end
					local waitSeconds = math.random(60, 180)
					state.navDepotWaitUntil = os.time() + waitSeconds
					BotSystem.castDebug(player, state, "Navigate: waiting " .. waitSeconds .. "s at depot")
				else
					-- Walk to the locker
					BotSystem.castDebug(player, state, "Navigate: walking to depot locker at ("
						.. lockerPos.x .. "," .. lockerPos.y .. "," .. lockerPos.z
						.. ") dist=" .. dist)
					state.navDepotTarget = lockerPos
				end
			else
				-- No locker found — just wait at current position
				BotSystem.castDebug(player, state, "Navigate: no depot locker found, waiting here")
				local waitSeconds = math.random(60, 180)
				state.navDepotWaitUntil = os.time() + waitSeconds
			end
			-- Keep cavebotCommand active — depot sub-state will clear it when done
			state.cavebotNavRoute = nil
			state.routeIdx = nil
			state.routeStuckCount = nil
			return
		end

		-- Non-depot destination — check for pending hunt, then clear
		state.cavebotNavRoute = nil
		state.cavebotNavDest = nil
		state.cavebotNavSrc = nil
		state.routeIdx = nil
		state.routeStuckCount = nil
		if state.pendingHuntAfterTravel and state.huntScriptId then
			state.pendingHuntAfterTravel = nil
			state.cavebotCommand = nil
			BotSystem.castDebug(player, state, "Navigate complete, preparing for hunt " .. state.huntScriptId)
			BotSystem.beginHuntPhase(player, state, HUNT_PHASE.PREPARING)
		else
			state.cavebotCommand = nil
		end
	elseif result == "failed" then
		BotSystem.castDebug(player, state, "Navigate: FAILED to reach " .. (state.cavebotNavDest or "?"))
		logger.warn("[CavebotDebug:" .. player:getName() .. "] Navigate failed to reach " .. (state.cavebotNavDest or "?"))
		state.cavebotNavRoute = nil
		state.cavebotNavDest = nil
		state.cavebotNavSrc = nil
		state.routeIdx = nil
		state.routeStuckCount = nil
		if state.pendingHuntAfterTravel and state.huntScriptId then
			state.pendingHuntAfterTravel = nil
			state.cavebotCommand = nil
			BotSystem.castDebug(player, state, "Navigate failed, preparing for hunt anyway " .. state.huntScriptId)
			BotSystem.beginHuntPhase(player, state, HUNT_PHASE.PREPARING)
		else
			state.cavebotCommand = nil
		end
	end
	-- "walking" = still in progress
end

-- ============================================================================
-- Cavebot "sequence" Command: multi-leg navigation (poi1->poi2->poi3->...)
-- ============================================================================

-- POI delay ranges (in seconds): how long bots wait at each POI type
local POI_DELAYS = {
	depot    = { min = 60,  max = 180 }, -- 1-3 minutes (using depot box)
	bank     = { min = 10,  max = 90  }, -- talking to NPC
	potions  = { min = 10,  max = 90  },
	runes    = { min = 10,  max = 90  },
	ammo     = { min = 10,  max = 90  },
	food     = { min = 10,  max = 90  },
	boat     = { min = 5,   max = 10  }, -- quick travel interaction
	carpet   = { min = 5,   max = 10  },
}

-- Scan for all depot lockers in a wide area around the bot.
-- Returns a sorted list: { {pos, dist, occupied, id}, ... }
-- Sorted by: unoccupied first, then closest.
function BotSystem.findAllDepotLockers(player, state)
	local pos = player:getPosition()
	local lockers = {}
	-- Scan 15x15 area (radius 7) — depots can be spread across a large room
	for dx = -7, 7 do
		for dy = -7, 7 do
			local checkPos = Position(pos.x + dx, pos.y + dy, pos.z)
			local tile = Tile(checkPos)
			if tile and tile:hasFlag(TILESTATE_DEPOT) then
				local items = tile:getItems()
				if items then
					for _, item in ipairs(items) do
						local iid = item:getId()
						if iid >= 3497 and iid <= 3500 then
							local dist = math.abs(dx) + math.abs(dy)
							local occupied = false
							local topCreature = tile:getTopCreature()
							if topCreature and topCreature:getId() ~= player:getId() then
								occupied = true
							end
							lockers[#lockers + 1] = { pos = checkPos, dist = dist, occupied = occupied, id = iid }
						end
					end
				end
			end
		end
	end

	-- Sort: prefer unoccupied, then closest
	table.sort(lockers, function(a, b)
		if a.occupied ~= b.occupied then return not a.occupied end
		return a.dist < b.dist
	end)

	return lockers
end

-- Find the first reachable, unoccupied depot locker. Tries pathing to each one.
-- Returns lockerPos or nil.
function BotSystem.findReachableDepotLocker(player, state)
	local lockers = BotSystem.findAllDepotLockers(player, state)
	if #lockers == 0 then
		BotSystem.castDebug(player, state, "Depot: no lockers found in 15x15 area")
		return nil
	end

	BotSystem.castDebug(player, state, "Depot: found " .. #lockers .. " lockers, testing reachability...")

	local adjacentOffsets = {{0,-1},{0,1},{-1,0},{1,0},{-1,-1},{1,-1},{-1,1},{1,1}}
	for i, locker in ipairs(lockers) do
		if not locker.occupied then
			-- Try to find a walkable adjacent tile we can path to
			for _, off in ipairs(adjacentOffsets) do
				local adjPos = Position(locker.pos.x + off[1], locker.pos.y + off[2], locker.pos.z)
				local adjTile = Tile(adjPos)
				if adjTile and adjTile:isWalkable() then
					local dirs = player:getPathTo(adjPos, 0, 0, true, true, BOT_CONFIG.PATH_MAX_DIST)
					if dirs and type(dirs) == "table" and #dirs >= 0 then
						BotSystem.castDebug(player, state, "Depot: locker #" .. i .. " (id=" .. locker.id
							.. ") at (" .. locker.pos.x .. "," .. locker.pos.y .. "," .. locker.pos.z
							.. ") is reachable via (" .. adjPos.x .. "," .. adjPos.y .. ")")
						return locker.pos
					end
				end
			end
		end
	end

	-- All unoccupied lockers unreachable — try occupied ones as fallback
	for i, locker in ipairs(lockers) do
		if locker.occupied then
			for _, off in ipairs(adjacentOffsets) do
				local adjPos = Position(locker.pos.x + off[1], locker.pos.y + off[2], locker.pos.z)
				local adjTile = Tile(adjPos)
				if adjTile and adjTile:isWalkable() then
					local dirs = player:getPathTo(adjPos, 0, 0, true, true, BOT_CONFIG.PATH_MAX_DIST)
					if dirs and type(dirs) == "table" and #dirs >= 0 then
						BotSystem.castDebug(player, state, "Depot: locker #" .. i .. " (OCCUPIED, id=" .. locker.id
							.. ") at (" .. locker.pos.x .. "," .. locker.pos.y .. ") is reachable (fallback)")
						return locker.pos
					end
				end
			end
		end
	end

	BotSystem.castDebug(player, state, "Depot: no reachable locker found")
	return nil
end

function BotSystem.processCavebotSequence(player, state)
	local seq = state.cavebotSequence
	local idx = state.cavebotSequenceIdx or 1

	-- Sub-state: walking to depot locker (must reach it before delay starts)
	if state.seqDepotTarget then
		local pos = player:getPosition()
		local dp = state.seqDepotTarget
		local dist = math.max(math.abs(pos.x - dp.x), math.abs(pos.y - dp.y))

		if dist <= 1 and pos.z == dp.z then
			-- Adjacent to depot locker — start the delay now
			BotSystem.castDebug(player, state, "Depot: reached locker at ("
				.. dp.x .. "," .. dp.y .. "," .. dp.z .. "), starting delay")
			if math.random(1, 2) == 1 then
				BotSystem.sayRandom(player, state, "depot")
			end
			state.seqDepotTarget = nil
			local delay = POI_DELAYS["depot"]
			local waitSeconds = math.random(delay.min, delay.max)
			state.seqWaitUntil = os.time() + waitSeconds
			state.seqWaitPOI = "depot"
			BotSystem.castDebug(player, state, "Sequence: waiting " .. waitSeconds .. "s at depot")
			return
		end

		-- Not adjacent yet — walk toward it
		if not player:isWalking() then
			-- Find a walkable adjacent tile and path to it
			local foundPath = false
			local adjacentOffsets = {{0,-1},{0,1},{-1,0},{1,0},{-1,-1},{1,-1},{-1,1},{1,1}}
			for _, off in ipairs(adjacentOffsets) do
				local adjPos = Position(dp.x + off[1], dp.y + off[2], dp.z)
				local adjTile = Tile(adjPos)
				if adjTile and adjTile:isWalkable() then
					local dirs = player:getPathTo(adjPos, 0, 0, true, true, BOT_CONFIG.PATH_MAX_DIST)
					if dirs and type(dirs) == "table" and #dirs > 0 then
						player:startAutoWalk(dirs)
						foundPath = true
						break
					end
				end
			end

			if not foundPath then
				-- This locker became unreachable — find a new one
				BotSystem.castDebug(player, state, "Depot: locker unreachable, finding another")
				local newLocker = BotSystem.findReachableDepotLocker(player, state)
				if newLocker and (newLocker.x ~= dp.x or newLocker.y ~= dp.y) then
					state.seqDepotTarget = newLocker
				else
					-- No reachable locker at all — just wait here
					BotSystem.castDebug(player, state, "Depot: no reachable locker, waiting here")
					state.seqDepotTarget = nil
					local delay = POI_DELAYS["depot"]
					local waitSeconds = math.random(delay.min, delay.max)
					state.seqWaitUntil = os.time() + waitSeconds
					state.seqWaitPOI = "depot"
				end
			end
		end
		return
	end

	-- Check if we're waiting at a POI (delay timer)
	if state.seqWaitUntil then
		if os.time() < state.seqWaitUntil then
			return -- still waiting at POI
		end
		-- Delay done
		local poiName = state.seqWaitPOI or "?"
		BotSystem.castDebug(player, state, "Sequence: done waiting at " .. poiName)
		state.seqWaitUntil = nil
		state.seqWaitPOI = nil
	end

	-- If no active leg, start the next one
	if not state.cavebotNavRoute then
		if idx >= #seq then
			-- All legs done
			BotSystem.castDebug(player, state, "Sequence: ALL LEGS COMPLETE")
			logger.info("[CavebotDebug:" .. player:getName() .. "] Sequence complete")
			state.cavebotCommand = nil
			state.cavebotSequence = nil
			state.cavebotSequenceIdx = nil
			state.seqWaitUntil = nil
			state.seqWaitPOI = nil
			state.seqDepotTarget = nil
			return
		end

		local src = seq[idx]
		local dst = seq[idx + 1]
		local townId = player:getTown() and player:getTown():getId() or 0

		-- Auto-detect source POI if first leg
		if idx == 1 then
			local detectedPOI, poiDist = BotHuntData.detectNearestPOI(townId, player:getPosition())
			if detectedPOI and poiDist < 30 then
				src = detectedPOI
				BotSystem.castDebug(player, state, "Sequence: detected current POI as '" .. src .. "' (dist=" .. poiDist .. ")")
			end
		end

		local waypoints, reversed = BotHuntData.findRoute(townId, src, dst)
		if not waypoints then
			BotSystem.castDebug(player, state, "Sequence: no route from " .. src .. " to " .. dst .. ", aborting")
			logger.warn("[CavebotDebug:" .. player:getName() .. "] Sequence: no route " .. src .. " -> " .. dst)
			state.cavebotCommand = nil
			state.cavebotSequence = nil
			return
		end

		BotSystem.castDebug(player, state, "Sequence leg " .. idx .. "/" .. (#seq - 1)
			.. ": " .. src .. " -> " .. dst .. " (" .. #waypoints .. " wps"
			.. (reversed and ", reversed" or "") .. ")")

		state.cavebotNavRoute = waypoints
		state.cavebotNavDest = dst
		state.cavebotNavSrc = src
		state.routeIdx = 1
		state.routeStuckCount = 0
	end

	-- Process the current leg
	local result = BotSystem.followCityRoute(player, state, state.cavebotNavRoute)
	if result == "arrived" then
		local dest = state.cavebotNavDest or "?"
		BotSystem.castDebug(player, state, "Sequence leg " .. idx .. ": ARRIVED at " .. dest)

		-- Clear current leg, advance to next
		state.cavebotNavRoute = nil
		state.cavebotNavDest = nil
		state.cavebotNavSrc = nil
		state.routeIdx = nil
		state.routeStuckCount = nil
		state.cavebotSequenceIdx = idx + 1

		-- POI-specific actions and delays
		local delay = POI_DELAYS[dest]
		if dest == "depot" then
			-- Find nearest available depot locker and walk to it
			local lockerPos = BotSystem.findReachableDepotLocker(player, state)
			if lockerPos then
				local pos = player:getPosition()
				local dist = math.max(math.abs(pos.x - lockerPos.x), math.abs(pos.y - lockerPos.y))
				if dist <= 1 and pos.z == lockerPos.z then
					-- Already adjacent — start delay immediately
					BotSystem.castDebug(player, state, "Depot: already adjacent to locker")
					if math.random(1, 2) == 1 then
						BotSystem.sayRandom(player, state, "depot")
					end
					local waitSeconds = math.random(delay.min, delay.max)
					state.seqWaitUntil = os.time() + waitSeconds
					state.seqWaitPOI = "depot"
					BotSystem.castDebug(player, state, "Sequence: waiting " .. waitSeconds .. "s at depot")
				else
					-- Need to walk to locker first
					BotSystem.castDebug(player, state, "Depot: walking to locker at ("
						.. lockerPos.x .. "," .. lockerPos.y .. "," .. lockerPos.z
						.. ") dist=" .. dist)
					state.seqDepotTarget = lockerPos
				end
			else
				-- No locker found, just wait at current position
				local waitSeconds = math.random(delay.min, delay.max)
				state.seqWaitUntil = os.time() + waitSeconds
				state.seqWaitPOI = "depot"
				BotSystem.castDebug(player, state, "Sequence: no locker found, waiting " .. waitSeconds .. "s at depot")
			end
		elseif dest == "boat" or dest == "carpet" then
			player:say("hi", TALKTYPE_SAY)
			BotSystem.castDebug(player, state, "Saying 'hi' at " .. dest)
			if delay and (idx < #seq) then
				local waitSeconds = math.random(delay.min, delay.max)
				state.seqWaitUntil = os.time() + waitSeconds
				state.seqWaitPOI = dest
				BotSystem.castDebug(player, state, "Sequence: waiting " .. waitSeconds .. "s at " .. dest)
			end
		elseif dest == "bank" or dest == "potions" or dest == "runes"
			or dest == "ammo" or dest == "food" then
			player:say("hi", TALKTYPE_SAY)
			BotSystem.castDebug(player, state, "Saying 'hi' at " .. dest)
			if delay and (idx < #seq) then
				local waitSeconds = math.random(delay.min, delay.max)
				state.seqWaitUntil = os.time() + waitSeconds
				state.seqWaitPOI = dest
				BotSystem.castDebug(player, state, "Sequence: waiting " .. waitSeconds .. "s at " .. dest)
			end
		else
			-- Non-standard POI, no delay
			if delay and (idx < #seq) then
				local waitSeconds = math.random(delay.min, delay.max)
				state.seqWaitUntil = os.time() + waitSeconds
				state.seqWaitPOI = dest
				BotSystem.castDebug(player, state, "Sequence: waiting " .. waitSeconds .. "s at " .. dest)
			end
		end
	elseif result == "failed" then
		BotSystem.castDebug(player, state, "Sequence leg " .. idx .. ": FAILED")
		state.cavebotCommand = nil
		state.cavebotSequence = nil
	end
end

-- ============================================================================
-- Cavebot "travel" Command: inter-city boat travel
-- ============================================================================

function BotSystem.processCavebotTravel(player, state)
	local phase = state.travelPhase or "going_to_boat"

	if phase == "going_to_boat" then
		-- Navigate to boat in current city
		if not state.cavebotNavRoute then
			BotSystem.castDebug(player, state, "Travel: no route to boat, aborting")
			state.cavebotCommand = nil
			return
		end
		local result = BotSystem.followCityRoute(player, state, state.cavebotNavRoute)
		if result == "arrived" then
			state.cavebotNavRoute = nil
			state.routeIdx = nil
			state.routeStuckCount = nil
			-- Walk to the actual boat NPC position
			local townId = player:getTown() and player:getTown():getId() or 0
			local boatNpcPos = BOAT_POSITIONS[townId]
			if boatNpcPos then
				state.travelPhase = "walking_to_npc"
				state.travelBoatNpcPos = boatNpcPos
				BotSystem.castDebug(player, state, "Travel: route done, walking to boat NPC at ("
					.. boatNpcPos.x .. "," .. boatNpcPos.y .. "," .. boatNpcPos.z .. ")")
			else
				-- No NPC position known — just say hi and proceed
				BotSystem.castDebug(player, state, "Travel: arrived at boat, saying hi...")
				player:say("hi", TALKTYPE_SAY)
				state.travelPhase = "at_boat"
				state.travelWaitUntil = os.time() + math.random(3, 10)
			end
		elseif result == "failed" then
			BotSystem.castDebug(player, state, "Travel: FAILED to reach boat")
			state.cavebotCommand = nil
		end

	elseif phase == "walking_to_npc" then
		-- Walk the last few tiles to the actual boat NPC
		local npcPos = state.travelBoatNpcPos
		if not npcPos then
			state.travelPhase = "at_boat"
			state.travelWaitUntil = os.time() + math.random(3, 10)
			return
		end
		local pos = player:getPosition()
		local dist = math.max(math.abs(pos.x - npcPos.x), math.abs(pos.y - npcPos.y))
		if dist <= 2 and pos.z == npcPos.z then
			-- Adjacent or near NPC — say hi and proceed
			BotSystem.castDebug(player, state, "Travel: at boat NPC, saying hi...")
			player:say("hi", TALKTYPE_SAY)
			state.travelPhase = "at_boat"
			state.travelWaitUntil = os.time() + math.random(3, 6)
			state.travelBoatNpcPos = nil
			return
		end
		-- Z mismatch — need floor change
		if pos.z ~= npcPos.z then
			if state.floorChangeResult == "failed" then
				state.floorChangeResult = nil
				state.floorChangeSource = nil
				BotSystem.castDebug(player, state, "Travel: floor change to boat NPC failed, aborting travel")
				if state.pendingHuntAfterTravel and state.huntScriptId then
					BotHuntData.releaseHunt(state.huntScriptId, player:getGuid())
					state.huntScriptId = nil
					state.pendingHuntAfterTravel = nil
				end
				state.cavebotCommand = nil
				state.travelPhase = nil
				state.travelBoatNpcPos = nil
				state.state = BOT_STATE.IDLE
				return
			end
			if state.floorChangeState == FLOOR_CHANGE_STATE.NONE then
				local goDown = npcPos.z > pos.z
				BotSystem.startFloorChange(state, goDown, npcPos, nil, "route")
			end
			return
		end
		-- Walk to NPC
		if not player:isWalking() then
			local dirs = player:getPathTo(npcPos, 0, 2, true, true, BOT_CONFIG.PATH_MAX_DIST)
			if dirs and #dirs > 0 then
				player:startAutoWalk(dirs)
			else
				local blocker = BotSystem.checkTrapOrBlocker(player, state, npcPos)
				if blocker == "monster" or blocker == "mwall" then
					return
				end
				state.walkToNpcFailCount = (state.walkToNpcFailCount or 0) + 1
				if state.walkToNpcFailCount >= 5 then
					state.walkToNpcFailCount = nil
					BotSystem.castDebug(player, state, "Travel: can't reach boat NPC, aborting travel")
					if state.pendingHuntAfterTravel and state.huntScriptId then
						BotHuntData.releaseHunt(state.huntScriptId, player:getGuid())
						state.huntScriptId = nil
						state.pendingHuntAfterTravel = nil
					end
					state.cavebotCommand = nil
					state.travelPhase = nil
					state.travelBoatNpcPos = nil
					state.state = BOT_STATE.IDLE
				end
			end
		end

	elseif phase == "at_boat" then
		-- Wait a bit then board boat to destination (NPC boat travel is a legitimate game mechanic)
		if os.time() < (state.travelWaitUntil or 0) then return end

		local destBoatPos = state.travelDestBoatPos
		if not destBoatPos then
			BotSystem.castDebug(player, state, "Travel: no destination boat position, aborting")
			state.cavebotCommand = nil
			state.travelPhase = nil
			state.state = BOT_STATE.IDLE
			return
		end

		-- Board boat to destination dock
		local destPos = Position(destBoatPos.x, destBoatPos.y, destBoatPos.z)
		player:teleportTo(destPos)
		BotSystem.castDebug(player, state, "Travel: sailed to " .. (state.travelDestTownName or "?")
			.. " boat at (" .. destPos.x .. "," .. destPos.y .. "," .. destPos.z .. ")")

		-- Change bot's town to destination
		local destTownId = state.travelDestTownId
		if destTownId then
			local town = Town(destTownId)
			if town then
				player:setTown(town)
				BotSystem.castDebug(player, state, "Travel: set town to " .. town:getName())
			end
		end

		-- Now navigate from boat to temple in destination city
		state.travelPhase = "arrived_dest"
		state.travelWaitUntil = os.time() + 2 -- short pause after arrival

	elseif phase == "walking_to_poi" then
		-- Runtime pathfinding to a POI (boat or temple) when no DB route exists
		local target = state.walkToPOITarget
		local function finishOrAbortWalkToPOI(arrived)
			local wasTemple = state.walkToPOIIsTemple
			state.walkToPOITarget = nil
			state.walkToPOIFailCount = nil
			state.walkToPOIIsTemple = nil
			state.floorChangeResult = nil
			state.floorChangeSource = nil

			if wasTemple then
				-- We are already in the destination city; proceed with hunt prep or IDLE
				BotSystem.castDebug(player, state, "Travel: finished post-boat walk in destination city")
				state.cavebotCommand = nil
				state.travelPhase = nil
				state.travelDestTownId = nil
				state.travelDestTownName = nil
				state.travelDestBoatPos = nil
				if state.pendingHuntAfterTravel and state.huntScriptId then
					state.pendingHuntAfterTravel = nil
					BotSystem.beginHuntPhase(player, state, HUNT_PHASE.PREPARING)
				else
					state.state = BOT_STATE.IDLE
				end
			elseif arrived then
				local townId = player:getTown() and player:getTown():getId() or 0
				local boatNpcPos = BOAT_POSITIONS[townId]
				if boatNpcPos then
					state.travelPhase = "walking_to_npc"
					state.travelBoatNpcPos = boatNpcPos
				else
					state.travelPhase = "at_boat"
					state.travelWaitUntil = os.time() + math.random(3, 6)
				end
			else
				-- Failed to reach source boat without teleporting: abort travel cleanly
				BotSystem.castDebug(player, state, "Travel: could not path to source boat, aborting travel")
				if state.pendingHuntAfterTravel and state.huntScriptId then
					BotHuntData.releaseHunt(state.huntScriptId, player:getGuid())
					state.huntScriptId = nil
					state.pendingHuntAfterTravel = nil
				end
				state.cavebotCommand = nil
				state.travelPhase = nil
				state.travelDestTownId = nil
				state.travelDestTownName = nil
				state.travelDestBoatPos = nil
				state.state = BOT_STATE.IDLE
			end
		end

		if not target then
			finishOrAbortWalkToPOI(false)
			return
		end

		local pos = player:getPosition()
		local dist = math.max(math.abs(pos.x - target.x), math.abs(pos.y - target.y))

		-- Arrival check (within 3 tiles, allow ±1 z for boat docks)
		if dist <= 3 and math.abs(pos.z - target.z) <= 1 then
			BotSystem.castDebug(player, state, "Travel: pathfinding arrived near target")
			finishOrAbortWalkToPOI(true)
			return
		end

		-- Z mismatch — need floor change
		if pos.z ~= target.z then
			if state.floorChangeResult == "failed" then
				state.floorChangeResult = nil
				state.floorChangeSource = nil
				state.walkToPOIFailCount = (state.walkToPOIFailCount or 0) + 5
				if state.walkToPOIFailCount >= 10 then
					finishOrAbortWalkToPOI(false)
					return
				end
			end
			if state.floorChangeState == FLOOR_CHANGE_STATE.NONE then
				local goDown = target.z > pos.z
				BotSystem.startFloorChange(state, goDown, target, nil, "route")
			end
			return
		end

		-- Walk toward target using goTo()
		if not player:isWalking() then
			local ok = BotSystem.goTo(player, target, state)
			if not ok then
				local blocker = BotSystem.checkTrapOrBlocker(player, state, target)
				if blocker == "monster" or blocker == "mwall" then
					return
				end
				state.walkToPOIFailCount = (state.walkToPOIFailCount or 0) + 1
				if state.walkToPOIFailCount >= 10 then
					finishOrAbortWalkToPOI(false)
				end
			else
				state.walkToPOIFailCount = 0
			end
		end

	elseif phase == "arrived_dest" then
		if os.time() < (state.travelWaitUntil or 0) then return end

		local destTownId = state.travelDestTownId
		-- Try to navigate boat -> temple in destination city
		local waypoints, reversed = BotHuntData.findRoute(destTownId, "boat", "temple")
		if waypoints then
			BotSystem.castDebug(player, state, "Travel: navigating boat -> temple in "
				.. (state.travelDestTownName or "?") .. " (" .. #waypoints .. " wps)")
			state.cavebotCommand = "navigate"
			state.cavebotNavRoute = waypoints
			state.cavebotNavDest = "temple"
			state.cavebotNavSrc = "boat"
			state.routeIdx = 1
			state.routeStuckCount = 0
		else
			-- No DB route — use runtime pathfinding to walk to temple
			local destTown = Town(destTownId)
			if destTown then
				local templePos = destTown:getTemplePosition()
				local walkZ = CITY_WALK_Z[destTownId] or templePos.z
				local walkTarget = Position(templePos.x, templePos.y, walkZ)
				state.travelPhase = "walking_to_poi"
				state.walkToPOITarget = walkTarget
				state.walkToPOIFailCount = 0
				state.walkToPOIIsTemple = true
				BotSystem.castDebug(player, state, "Travel: no boat->temple route, pathfinding to ("
					.. walkTarget.x .. "," .. walkTarget.y .. "," .. walkTarget.z .. ")")
			else
				BotSystem.castDebug(player, state, "Travel: no route and no town data, done")
				if state.pendingHuntAfterTravel and state.huntScriptId then
					state.pendingHuntAfterTravel = nil
					state.cavebotCommand = nil
					BotSystem.beginHuntPhase(player, state, HUNT_PHASE.PREPARING)
				else
					state.cavebotCommand = nil
				end
			end
		end

		-- Clear travel sub-state (keep travelPhase if walking_to_poi was set)
		if state.travelPhase ~= "walking_to_poi" then
			state.travelPhase = nil
			state.travelDestTownId = nil
			state.travelDestTownName = nil
			state.travelDestBoatPos = nil
		end
		state.travelWaitUntil = nil
	end
end

-- ============================================================================
-- Bot Lifecycle
-- ============================================================================

function BotSystem.initBot(player)
	local guid = player:getGuid()
	BotPlayers[guid] = player
	BotActive[guid] = false
	BotState[guid] = {
		state = BOT_STATE.INACTIVE,
		walkTarget = nil,
		currentPOI = nil,
		dwellUntil = 0,
		lastHealTime = 0,
		lastAttackTime = 0,
		lastChatTime = 0,
		lastKnownHp = player:getMaxHealth(),
		tickCounter = 0,
		pathFailCount = 0,
		consecutivePOIFails = 0,
		visitedPOIs = {},
		-- Combat state
		combatDecision = nil,     -- "fight", "flee", or "ignore"
		combatStartTime = nil,
		lastCombatProgress = nil, -- resets on attacks, z-transitions, mob clears, pathfinding
		attackerId = nil,         -- creature ID of who attacked us
		targetLastSameZPos = nil, -- target's last position on same z (for stair pursuit)
		ignoredAttackerId = nil,  -- attacker we decided to ignore (too weak)
		ignoredHitBack = false,   -- did we already retaliate once while ignoring?
		preCombatPos = nil,       -- position before combat started (for return navigation)
		zBreadcrumbs = {},        -- z-transitions taken during combat: {{fromPos, toZ, type}}
		returningHome = false,    -- true when navigating back after combat
		returnBreadcrumbs = {},   -- reversed z-breadcrumbs for return trip
		-- Vigilante memory: PKers we already decided NOT to attack
		seenPKers = {},           -- {[creatureId] = os.time()} — cleared 60s after PKer leaves screen
		-- PK state
		pkTarget = nil,
		pkStartTime = nil,
		-- Travel state
		travelDestTownId = nil,
		travelUntil = nil,
		-- Hunting state
		huntScriptId = nil,        -- active hunt script DB id
		huntPhase = nil,           -- HUNT_PHASE enum
		huntWaypoints = nil,       -- current phase waypoint list
		huntWaypointIdx = 0,       -- current waypoint index
		huntTargets = nil,         -- monster targets for this hunt
		huntStartTime = nil,       -- when the hunt started (os.time)
		huntEndTime = nil,         -- when the hunt should end (os.time)
		huntCooldownUntil = 0,     -- next hunt allowed after this time
		huntKillCount = 0,         -- monsters killed this hunt
		huntMonsterTarget = nil,   -- creature ID of monster being attacked
		huntWaypointSkipCount = 0, -- consecutive skips without movement
		huntLastPos = nil,         -- position at last successful waypoint
		huntTownId = nil,          -- town the hunt is based in
		-- Resupply sub-state
		resupplyStep = nil,        -- "bank", "depot", "shop1", "shop2", "done"
		resupplyUntil = 0,         -- when current resupply step ends
		resupplyWalkTarget = nil,  -- where we're walking to for resupply
		-- Cavebot debug/command state
		verboseLog = false,        -- per-bot verbose z-transition logging
		botName = player:getName(),
		cavebotCommand = nil,      -- active cavebot command ("goto", "stairs", "hunt", etc.)
		cavebotTarget = nil,       -- target position for goto/waypoint commands
		cavebotStairsTarget = nil, -- selected transition for stairs command
		cavebotStairsGoDown = nil, -- direction for stairs command
		-- Floor change state machine
		floorChangeState = FLOOR_CHANGE_STATE.NONE,
		floorChangeTarget = nil,   -- {pos, type, goDown}
		floorChangePreZ = nil,     -- z before attempting step
		floorChangeAttempts = 0,   -- retry counter (max 3)
		floorChangeStartTime = nil,  -- for timeout detection (os.time())
		floorChangeTransitions = nil, -- list of found transitions (try next on failure)
		floorChangeTransIdx = 0,   -- current index in transitions list
		-- Walk history for stuck detection (BBot-inspired, circular buffer of 8)
		walkHistory = {},
		walkHistoryIdx = 0,
	}
end

function BotSystem.activateBot(player, opts)
	opts = opts or {}
	local guid = player:getGuid()
	if not BotState[guid] then
		BotSystem.initBot(player)
	end

	local state = BotState[guid]
	BotActive[guid] = true

	-- Teleport to city temple at correct walk z-level unless relogging at training statue
	local town = player:getTown()
	if opts.fromTraining and opts.relogPos then
		player:teleportTo(Position(opts.relogPos.x, opts.relogPos.y, opts.relogPos.z))
	elseif town then
		local townId = town:getId()
		local templePos = town:getTemplePosition()
		local walkZ = CITY_WALK_Z[townId] or templePos.z
		player:teleportTo(Position(templePos.x, templePos.y, walkZ))
	end

	state.state = BOT_STATE.IDLE
	state.walkTarget = nil
	state.currentPOI = nil
	state.dwellUntil = 0
	state.lastKnownHp = player:getMaxHealth()
	state.tickCounter = 0
	state.pathFailCount = 0
	state.consecutivePOIFails = 0
	state.visitedPOIs = {}
	state.combatDecision = nil
	state.combatStartTime = nil
	state.attackerId = nil
	state.targetLastSameZPos = nil
	state.ignoredAttackerId = nil
	state.ignoredHitBack = false
	state.seenPKers = {}
	state.pkTarget = nil
	state.pkStartTime = nil
	state.travelDestTownId = nil
	state.travelUntil = nil
	state.trainStatuePos = nil
	state.trainStandPos = nil
	state.trainForce = nil
	-- Hunt state reset
	if state.huntScriptId then
		BotHuntData.releaseHunt(state.huntScriptId, player:getGuid())
	end
	state.huntScriptId = nil
	state.huntPhase = nil
	state.huntWaypoints = nil
	state.huntWaypointIdx = 0
	state.huntTargets = nil
	state.huntStartTime = nil
	state.huntEndTime = nil
	state.huntCooldownUntil = 0
	state.huntKillCount = 0
	state.huntMonsterTarget = nil
	state.huntWaypointSkipCount = 0
	state.huntLastPos = nil
	state.huntTownId = nil
	state.resupplyStep = nil
	state.resupplyUntil = 0
	state.resupplyWalkTarget = nil
	state.pendingLootPos = nil
	state.pendingLootMonster = nil
	state.pendingLootExpire = nil
	-- Cavebot debug state reset
	state.cavebotCommand = nil
	state.cavebotTarget = nil
	state.cavebotStairsTarget = nil
	state.cavebotStairsGoDown = nil
	BotSystem.resetFloorChangeState(state)
	state.walkHistory = {}
	state.walkHistoryIdx = 0
	-- Keep verboseLog and botName across resets

	-- Preserve trained skills on normal activation; only reset to 10 on hard reset
	if opts.isHardReset then
		player:setMagicLevel(0)
		player:setSkillLevel(SKILL_FIST, 10)
		player:setSkillLevel(SKILL_CLUB, 10)
		player:setSkillLevel(SKILL_SWORD, 10)
		player:setSkillLevel(SKILL_AXE, 10)
		player:setSkillLevel(SKILL_DISTANCE, 10)
		player:setSkillLevel(SKILL_SHIELD, 10)
		player:setSkillLevel(SKILL_FISHING, 10)
	elseif not opts.fromTraining then
		for _, sk in ipairs({SKILL_FIST, SKILL_CLUB, SKILL_SWORD, SKILL_AXE, SKILL_DISTANCE, SKILL_SHIELD, SKILL_FISHING}) do
			if (player:getSkillLevel(sk) or 0) < 10 then
				player:setSkillLevel(sk, 10)
			end
		end
	end

	player:addHealth(player:getMaxHealth())
	player:addMana(player:getMaxMana())

	-- Set fight mode to full attack (1) if available
	if player.setFightMode then
		player:setFightMode(1)
	end

	-- Learn all spells for this vocation (attack + healing)
	BotSystem.learnAllSpells(player)

	-- Equip best gear for level and vocation
	BotSystem.equipBot(player)

	-- Enable cast broadcasting so viewers can watch this bot (if supported)
	if player.setCastBroadcasting then
		player:setCastBroadcasting(true)
		pcall(function()
			db.query("INSERT INTO `cast_broadcasters` (`player_id`, `player_name`) VALUES ("
				.. guid .. ", " .. db.escapeString(player:getName())
				.. ") ON DUPLICATE KEY UPDATE `player_name` = " .. db.escapeString(player:getName()))
		end)
	end

	local pos = player:getPosition()
	local townName = town and town:getName() or "unknown"
	logger.info("[Bot] Activated " .. player:getName() ..
		" in " .. townName ..
		" at (" .. pos.x .. "," .. pos.y .. "," .. pos.z .. ")" ..
		" speed=" .. player:getSpeed() ..
		" level=" .. player:getLevel())

	player:registerEvent("BotDeath")
	if botThinkEvents[guid] then
		stopEvent(botThinkEvents[guid])
		botThinkEvents[guid] = nil
	end
	-- Stagger think start so 200 bots don't all fire on the same tick
	botThinkEvents[guid] = addEvent(BotSystem.thinkEvent, BOT_CONFIG.THINK_INTERVAL + math.random(0, 500), guid)
end

function BotSystem.deactivateBot(player)
	local guid = player:getGuid()
	BotActive[guid] = false
	if botThinkEvents[guid] then
		stopEvent(botThinkEvents[guid])
		botThinkEvents[guid] = nil
	end
	if BotState[guid] then
		-- Release any active hunt reservation
		if BotState[guid].huntScriptId then
			BotHuntData.releaseHunt(BotState[guid].huntScriptId, guid)
		end
		BotState[guid].state = BOT_STATE.INACTIVE
	end
	if player.stopWalk then
		player:stopWalk()
	end
	if player.setCastBroadcasting then
		player:setCastBroadcasting(false)
		pcall(function()
			db.query("DELETE FROM `cast_broadcasters` WHERE `player_id` = " .. guid)
		end)
	end
	if not player:teleportTo(BOT_CONFIG.DEAD_POSITION) then
		-- Fallback position if storage tile fails
		player:teleportTo(Position(31970, 32283, 7))
	end
end

-- ============================================================================
-- Bot Archetypes & Personality Risk Profiles
-- ============================================================================

BotSystem.ARCHETYPES = {
	[1] = {
		id = 1,
		name = "Cauteloso",
		title = "O Estudioso Metodico",
		riskTolerance = 1,      -- 1 (baixo) a 5 (extremo)
		levelOffset = 0,        -- caves com min_level <= player:getLevel()
		allowUnderlevelHunts = false,
		statueTrainingPriority = "HIGH", -- prioriza treino se skill abaixo da meta
		shouldTrain = function(player, state, skillInfo)
			return skillInfo and skillInfo.needsTraining
		end,
		hpHealThreshold = 75,
		hpFleeThreshold = 45,
		deathReaction = "TRAIN_OR_SAFE",
		deathPhrases = {
			"Essa cave e muito perigosa pra mim... vou treinar um pouco antes de arriscar de novo.",
			"Preciso me preparar melhor e treinar antes de tentar isso de novo.",
			"Muito arriscado, vou recuperar minhas forcas com calma na cidade.",
		},
		levelUpPhrases = {
			"Upei! Mas com calma, sem dar passo maior que a perna.",
			"Mais um level conquistado com prudencia e paciencia.",
			"Boa! Subi de level, vou manter o ritmo seguro.",
		},
	},
	[2] = {
		id = 2,
		name = "Arrojado",
		title = "O Rusher Destemido",
		riskTolerance = 5,      -- 1 a 5
		levelOffset = 4,        -- aceita caves com min_level ate level + 4!
		allowUnderlevelHunts = true,
		statueTrainingPriority = "NEVER", -- ignora treino nas estatuas
		shouldTrain = function(player, state, skillInfo)
			return false -- "treinar pra que? o bicho morre na raca!"
		end,
		hpHealThreshold = 35,
		hpFleeThreshold = 20,
		deathReaction = "REVENGE_OR_RUSH",
		deathPhrases = {
			"Foi azar e lag! Vou voltar la agora mesmo e me vingar daquele bicho!",
			"Nao vai ficar assim! Vou voltar e limpar aquele respawn!",
			"Cai mas levanto! Partiu voltar pra cave terminar o servico!",
		},
		levelUpPhrases = {
			"UP LEVEL! Agora o bicho pega, vou rushar num respawn mais pesado!",
			"Level up rapido! Ninguem me segura, bora pro proximo desafio!",
			"Boa! Subi de nivel, ja aguento coisa bem maior agora!",
		},
	},
	[3] = {
		id = 3,
		name = "Mercenario",
		title = "O Cacador de Ouro",
		riskTolerance = 2,      -- 1 a 5
		levelOffset = 1,        -- caves ate level + 1
		allowUnderlevelHunts = false,
		statueTrainingPriority = "LOW",
		shouldTrain = function(player, state, skillInfo)
			if not skillInfo or not skillInfo.needsTraining then return false end
			return (skillInfo.targetSkill - skillInfo.currentSkill) >= 15
		end,
		hpHealThreshold = 55,
		hpFleeThreshold = 35,
		deathReaction = "FARM_SAFE_GOLD",
		deathPhrases = {
			"Droga, perdi xp e suprimentos... vou cacar algo facil pra repor o gold.",
			"Prejuizo feio! Hora de farmar grana segura pra pagar as pots.",
			"Perdi grana nessa morte... preciso recuperar o prejuizo no farm.",
		},
		levelUpPhrases = {
			"Level up! Mais cap livre pra carregar mais loot!",
			"Subi de level! Tomara que renda mais profit agora.",
			"Boa, mais level e mais ouro no bolso!",
		},
	},
	[4] = {
		id = 4,
		name = "Gladiador",
		title = "O Combatente Agressivo",
		riskTolerance = 4,      -- 1 a 5
		levelOffset = 2,        -- caves ate level + 2
		allowUnderlevelHunts = true,
		statueTrainingPriority = "MODERATE",
		shouldTrain = function(player, state, skillInfo)
			if not skillInfo or not skillInfo.needsTraining then return false end
			return skillInfo.currentSkill < (skillInfo.targetSkill - 5)
		end,
		hpHealThreshold = 50,
		hpFleeThreshold = 25,
		deathReaction = "BRAWL_BACK",
		deathPhrases = {
			"Morri lutando! Mas ja to pronto pra outra briga!",
			"Aquele combate foi insano... vou voltar la com sangue nos olhos!",
			"Guerreiro nao desiste! Ja estou pronto pro confronto de novo!",
		},
		levelUpPhrases = {
			"UP! Mais dano de ataque! Agora o pau vai cantar!",
			"Subi de nivel! Minha forca bruta aumentou, venham todos!",
			"Mais level, mais forca! Quem quiser testar e so vir!",
		},
	},
	[5] = {
		id = 5,
		name = "Explorador",
		title = "O Andarilho Aventureiro",
		riskTolerance = 3,      -- 1 a 5
		levelOffset = 2,
		allowUnderlevelHunts = true,
		statueTrainingPriority = "CASUAL",
		shouldTrain = function(player, state, skillInfo)
			if not skillInfo or not skillInfo.needsTraining then return false end
			return math.random(1, 4) == 1
		end,
		hpHealThreshold = 60,
		hpFleeThreshold = 35,
		deathReaction = "TRAVEL_NEW_CITY",
		deathPhrases = {
			"Faz parte da jornada do aventureiro! Vou dar uma volta e explorar outra regiao.",
			"A aventura tem dessas coisas... que tal pegar o barco e conhecer outro continente?",
			"E assim que se aprende! Hora de explorar novos caminhos por ai.",
		},
		levelUpPhrases = {
			"Eba, upei de level! Bora explorar uma regiao nova!",
			"Mais um level na bagagem! Alguem quer viajar ou explorar comigo?",
			"Upei! O mapa e gigante, partiu desbravar novas terras!",
		},
	},
}

function BotSystem.getBotArchetype(player, state)
	local pId = (state and state.personality) or (player and ((player:getGuid() % 5) + 1)) or 2
	return BotSystem.ARCHETYPES[pId] or BotSystem.ARCHETYPES[2]
end

function BotSystem.shouldBotTrain(player, state, skillInfo)
	if not skillInfo or not skillInfo.needsTraining then return false end
	if state and state.trainForce then return true end
	local arch = BotSystem.getBotArchetype(player, state)
	if arch and arch.shouldTrain then
		return arch.shouldTrain(player, state, skillInfo)
	end
	return false
end

function BotSystem.onBotDeath(player, killer, mostDamageKiller)
	if not player or player:isRemoved() then return end
	local guid = player:getGuid()
	local state = BotState and BotState[guid]
	if not state then return end

	local killerName = (killer and killer:getName()) or (mostDamageKiller and mostDamageKiller:getName()) or "monstro"
	state.lastDeathTime = os.time()
	state.deathCount = (state.deathCount or 0) + 1

	local diedInHunt = state.huntScriptId
	state.lastDeathCaveId = diedInHunt

	local arch = BotSystem.getBotArchetype(player, state)

	if diedInHunt then
		state.recentDeathsInCave = (state.recentDeathsInCave or 0) + 1
		BotHuntData.releaseHunt(diedInHunt, guid)
		state.huntScriptId = nil
	end

	player:setTarget(nil)
	state.walkTarget = nil
	state.currentPOI = nil
	state.huntPhase = nil
	state.huntWaypoints = nil
	state.huntMonsterTarget = nil
	state.pendingLootPos = nil
	state.cavebotCommand = nil
	state.state = BOT_STATE.IDLE

	if arch and arch.deathPhrases and #arch.deathPhrases > 0 then
		local phrase = arch.deathPhrases[math.random(1, #arch.deathPhrases)]
		player:say(phrase, TALKTYPE_SAY)
	end

	logger.info(string.format("[BotDeath] %s (Archetype: %s) died to %s in cave %s (death #%d, caveDeaths=%d)",
		player:getName(), arch.name, killerName, tostring(diedInHunt), state.deathCount, state.recentDeathsInCave or 0))

	if arch.id == 2 then -- Arrojado (Rusher)
		if diedInHunt and (state.recentDeathsInCave or 0) < 2 then
			state.revengeHuntId = diedInHunt
			state.huntCooldownUntil = os.time() + 10 -- rush back quickly!
			logger.info(string.format("[BotDeath] %s wants REVENGE in cave %s! Will re-attempt immediately.",
				player:getName(), tostring(diedInHunt)))
		else
			state.revengeHuntId = nil
			state.recentDeathsInCave = 0
			state.huntCooldownUntil = os.time() + 60
			logger.info(string.format("[BotDeath] %s died multiple times in cave %s, cooling off.", player:getName(), tostring(diedInHunt)))
		end
	elseif arch.id == 1 then -- Cauteloso
		state.revengeHuntId = nil
		state.recentDeathsInCave = 0
		state.huntCooldownUntil = os.time() + 180
		state.postDeathTraining = true
	elseif arch.id == 3 then -- Mercenario
		state.revengeHuntId = nil
		state.huntCooldownUntil = os.time() + 30
	elseif arch.id == 5 then -- Explorador
		state.revengeHuntId = nil
		state.huntCooldownUntil = os.time() + 45
		state.wantTravelAfterDeath = true
	end
end

function BotSystem.onBotAdvance(player, skill, oldLevel, newLevel)
	if not player or player:isRemoved() then return end
	if skill ~= SKILL_LEVEL or newLevel <= oldLevel then return end

	local guid = player:getGuid()
	local state = BotState and BotState[guid]
	local arch = BotSystem.getBotArchetype(player, state)

	logger.info(string.format("[BotAdvance] %s (Archetype: %s) advanced to level %d!",
		player:getName(), arch.name, newLevel))

	if arch and arch.levelUpPhrases and #arch.levelUpPhrases > 0 then
		local phrase = arch.levelUpPhrases[math.random(1, #arch.levelUpPhrases)]
		player:say(phrase, TALKTYPE_SAY)
	end

	if arch.id == 2 and state and state.state == BOT_STATE.HUNTING then
		local script = state.huntScriptId and BotHuntData.scripts and BotHuntData.scripts[state.huntScriptId]
		if script and newLevel >= (script.min_level + 3) then
			player:say("Upei e essa cave ficou pequena pro meu nivel! Partiu achar um respawn mais forte!", TALKTYPE_SAY)
			logger.info(string.format("[BotAdvance] %s outgrew cave %s at lv %d, leaving early for higher challenge!",
				player:getName(), script.name or "?", newLevel))
			BotSystem.beginHuntPhase(player, state, HUNT_PHASE.LEAVING)
		end
	end
end

BotSystem.SKILL_TARGETS_BY_LEVEL = {
	{ minLevel = 8,   maxLevel = 19,  melee = 45, knightShield = 40, knightML = 3, dist = 45, paladinShield = 35, paladinML = 5,  mageML = 25, mageShield = 22 },
	{ minLevel = 20,  maxLevel = 39,  melee = 60, knightShield = 55, knightML = 4, dist = 60, paladinShield = 45, paladinML = 10, mageML = 40, mageShield = 25 },
	{ minLevel = 40,  maxLevel = 59,  melee = 75, knightShield = 70, knightML = 6, dist = 75, paladinShield = 55, paladinML = 15, mageML = 55, mageShield = 28 },
	{ minLevel = 60,  maxLevel = 99,  melee = 85, knightShield = 80, knightML = 7, dist = 85, paladinShield = 65, paladinML = 20, mageML = 70, mageShield = 30 },
	{ minLevel = 100, maxLevel = 999, melee = 95, knightShield = 90, knightML = 9, dist = 95, paladinShield = 75, paladinML = 25, mageML = 85, mageShield = 35 },
}

local STATUE_ITEM_IDS = {
	[16198] = true, -- Sword
	[16199] = true, -- Axe
	[16200] = true, -- Club
	[16201] = true, -- Distance
	[16202] = true, -- Magic Level
	[50296] = true, -- Fist
}

function BotSystem.getSkillTargetInfo(player)
	local level = player:getLevel() or 8
	local voc = player:getVocation()
	local baseVoc = voc and voc:getBaseId() or 4

	local bracket = BotSystem.SKILL_TARGETS_BY_LEVEL[#BotSystem.SKILL_TARGETS_BY_LEVEL]
	for _, b in ipairs(BotSystem.SKILL_TARGETS_BY_LEVEL) do
		if level >= b.minLevel and level <= b.maxLevel then
			bracket = b
			break
		end
	end

	local primarySkill = SKILL_SWORD
	local statueId = 16198
	local dbColumn = "skill_sword"
	local skillLabel = "sword"
	local currentSkill = 10
	local targetSkill = 45
	local currentShield = player:getSkillLevel(SKILL_SHIELD) or 10
	local targetShield = 40
	local targetML = 3

	if baseVoc == 4 then
		-- Knight: check highest melee skill (default to sword)
		local sw = player:getSkillLevel(SKILL_SWORD) or 10
		local ax = player:getSkillLevel(SKILL_AXE) or 10
		local cl = player:getSkillLevel(SKILL_CLUB) or 10
		if ax > sw and ax >= cl then
			primarySkill = SKILL_AXE
			statueId = 16199
			dbColumn = "skill_axe"
			skillLabel = "axe"
			currentSkill = ax
		elseif cl > sw and cl > ax then
			primarySkill = SKILL_CLUB
			statueId = 16200
			dbColumn = "skill_club"
			skillLabel = "club"
			currentSkill = cl
		else
			primarySkill = SKILL_SWORD
			statueId = 16198
			dbColumn = "skill_sword"
			skillLabel = "sword"
			currentSkill = sw
		end
		targetSkill = bracket.melee
		targetShield = bracket.knightShield
		targetML = bracket.knightML
	elseif baseVoc == 3 then
		primarySkill = SKILL_DISTANCE
		statueId = 16201
		dbColumn = "skill_dist"
		skillLabel = "distance"
		currentSkill = player:getSkillLevel(SKILL_DISTANCE) or 10
		targetSkill = bracket.dist
		targetShield = bracket.paladinShield
		targetML = bracket.paladinML
	else
		primarySkill = SKILL_MAGLEVEL
		statueId = 16202
		dbColumn = "maglevel"
		skillLabel = "magic level"
		currentSkill = player:getMagicLevel() or 0
		targetSkill = bracket.mageML
		targetShield = bracket.mageShield
		targetML = bracket.mageML
	end

	local needsTraining = (currentSkill < targetSkill) or (currentShield < targetShield)
	return {
		baseVoc = baseVoc,
		primarySkill = primarySkill,
		statueId = statueId,
		dbColumn = dbColumn,
		skillLabel = skillLabel,
		currentSkill = currentSkill,
		targetSkill = targetSkill,
		currentShield = currentShield,
		targetShield = targetShield,
		targetML = targetML,
		needsTraining = needsTraining,
	}
end

function BotSystem.findOrEnsureTrainingStatue(player, state, statueId)
	local pos = player:getPosition()
	local town = player:getTown()
	local townId = town and town:getId() or 8
	local walkZ = CITY_WALK_Z[townId] or pos.z
	local adjOffsets = {{0, 1}, {0, -1}, {1, 0}, {-1, 0}, {1, 1}, {-1, 1}, {1, -1}, {-1, -1}}

	local function getReachableStandPos(sPos)
		for _, off in ipairs(adjOffsets) do
			local adj = Position(sPos.x + off[1], sPos.y + off[2], sPos.z)
			local adjTile = Tile(adj)
			if adjTile and adjTile:isWalkable() then
				local dist = math.max(math.abs(pos.x - adj.x), math.abs(pos.y - adj.y))
				if dist == 0 then
					return adj
				end
				local dirs = player:getPathTo(adj, 0, 0, true, true, BOT_CONFIG.PATH_MAX_DIST)
				if dirs and type(dirs) == "table" and #dirs > 0 then
					return adj
				end
			end
		end
		return nil
	end

	-- 1. Check cached statue for this town if on same floor
	local cached = CITY_TRAINING_STATUES[townId]
	if cached and cached.z == pos.z then
		local cPos = Position(cached.x, cached.y, cached.z)
		local cTile = Tile(cPos)
		if cTile then
			local hasStatue = false
			local items = cTile:getItems()
			if items then
				for _, it in ipairs(items) do
					if STATUE_ITEM_IDS[it:getId()] then
						hasStatue = true
						break
					end
				end
			end
			if not hasStatue then
				Game.createItem(statueId or 16198, 1, cPos)
			end
			local stand = getReachableStandPos(cPos)
			if stand then
				return cPos, stand
			end
		end
	end

	-- 2. Scan within 22 SQMs around bot for any existing training statue
	for r = 1, 22 do
		for dx = -r, r do
			for dy = -r, r do
				if math.abs(dx) == r or math.abs(dy) == r then
					local scanPos = Position(pos.x + dx, pos.y + dy, pos.z)
					local tile = Tile(scanPos)
					if tile then
						local items = tile:getItems()
						if items then
							for _, it in ipairs(items) do
								if STATUE_ITEM_IDS[it:getId()] then
									local stand = getReachableStandPos(scanPos)
									if stand then
										CITY_TRAINING_STATUES[townId] = { x = scanPos.x, y = scanPos.y, z = scanPos.z, itemId = it:getId() }
										return scanPos, stand
									end
								end
							end
						end
					end
				end
			end
		end
	end

	-- 3. Ensure a reachable training statue near the city Temple/Depot on walkZ
	local anchorPos = pos
	if town then
		local tPos = town:getTemplePosition()
		if pos.z ~= walkZ or math.max(math.abs(pos.x - tPos.x), math.abs(pos.y - tPos.y)) > 25 then
			anchorPos = Position(tPos.x, tPos.y, walkZ)
			player:teleportTo(anchorPos)
			pos = player:getPosition()
		end
	end

	for dist = 2, 6 do
		for dx = -dist, dist do
			for dy = -dist, dist do
				if math.abs(dx) == dist or math.abs(dy) == dist then
					local candPos = Position(pos.x + dx, pos.y + dy, pos.z)
					local tile = Tile(candPos)
					if tile and tile:isWalkable() and not tile:hasFlag(TILESTATE_FLOORCHANGE) then
						-- Check that placing a statue here leaves adjacent walkable tiles
						local stand = getReachableStandPos(candPos)
						if stand and (stand.x ~= candPos.x or stand.y ~= candPos.y) then
							local created = Game.createItem(statueId or 16198, 1, candPos)
							if created then
								CITY_TRAINING_STATUES[townId] = { x = candPos.x, y = candPos.y, z = candPos.z, itemId = statueId or 16198 }
								logger.info(string.format("[BotTraining] Placed training statue (%d) at (%d,%d,%d) in %s",
									statueId or 16198, candPos.x, candPos.y, candPos.z, town and town:getName() or "town"))
								return candPos, stand
							end
						end
					end
				end
			end
		end
	end

	return nil, nil
end

function BotSystem.startStatueTraining(player, state, forceTrain)
	if not player or player:isRemoved() or not state then return false end
	local info = BotSystem.getSkillTargetInfo(player)
	if not info.needsTraining and not forceTrain then
		return false
	end

	-- Release any active hunt reservation before going to train
	if state.huntScriptId then
		BotHuntData.releaseHunt(state.huntScriptId, player:getGuid())
		state.huntScriptId = nil
	end
	state.huntPhase = nil
	state.huntWaypoints = nil
	state.huntMonsterTarget = nil
	state.walkTarget = nil
	state.currentPOI = nil
	state.trainForce = forceTrain or false

	local statuePos, standPos = BotSystem.findOrEnsureTrainingStatue(player, state, info.statueId)
	if not statuePos or not standPos then
		return false
	end

	state.trainStatuePos = statuePos
	state.trainStandPos = standPos
	state.state = BOT_STATE.TRAINING

	local bName = player:getName()
	logger.info(string.format("[BotTraining] %s heading to training statue at (%d,%d,%d) [%s %d -> %d]",
		bName, statuePos.x, statuePos.y, statuePos.z,
		info.skillLabel, info.currentSkill, info.targetSkill))
	pcall(function()
		db.asyncQuery(string.format(
			"REPLACE INTO `bot_macro_states` (`bot_name`, `current_action`, `target_destination`, `started_at`, `next_evaluation`, `reasoning`) VALUES (%s, 'TRAIN', 'Training Statue', NOW(), DATE_ADD(NOW(), INTERVAL 15 MINUTE), 'Statue Training')",
			db.escapeString(bName)
		))
	end)
	return true
end

function BotSystem.relogTrainedBot(botGuid)
	local entry = BotOfflineTraining[botGuid]
	if not entry then return end
	BotOfflineTraining[botGuid] = nil

	local info = entry.info
	-- Ensure DB has the trained skills before Game.loadBotPlayer reads from MySQL
	if info.baseVoc == 1 or info.baseVoc == 2 then
		db.query(string.format(
			"UPDATE `players` SET `maglevel` = %d, `skill_shielding` = %d, `offlinetraining_skill` = -1, `posx` = %d, `posy` = %d, `posz` = %d WHERE `id` = %d",
			info.targetSkill, info.targetShield, entry.relogPos.x, entry.relogPos.y, entry.relogPos.z, botGuid
		))
	else
		db.query(string.format(
			"UPDATE `players` SET `%s` = %d, `skill_shielding` = %d, `maglevel` = GREATEST(`maglevel`, %d), `offlinetraining_skill` = -1, `posx` = %d, `posy` = %d, `posz` = %d WHERE `id` = %d",
			info.dbColumn, info.targetSkill, info.targetShield, info.targetML, entry.relogPos.x, entry.relogPos.y, entry.relogPos.z, botGuid
		))
	end

	local relogged = Game.loadBotPlayer(entry.name)
	if not relogged then
		logger.error("[BotTraining] Failed to relog bot " .. tostring(entry.name))
		return
	end

	BotPlayers[botGuid] = relogged

	if info.baseVoc == 1 or info.baseVoc == 2 then
		relogged:setMagicLevel(info.targetSkill)
		relogged:setSkillLevel(SKILL_SHIELD, info.targetShield)
	else
		relogged:setSkillLevel(info.primarySkill, info.targetSkill)
		relogged:setSkillLevel(SKILL_SHIELD, info.targetShield)
		if (relogged:getMagicLevel() or 0) < info.targetML then
			relogged:setMagicLevel(info.targetML)
		end
	end

	db.botAsyncQuery("INSERT IGNORE INTO `players_online` (`player_id`) VALUES (" .. botGuid .. ")")

	BotSystem.activateBot(relogged, { fromTraining = true, relogPos = entry.relogPos })
	if BotState[botGuid] then
		BotState[botGuid].verboseLog = entry.verboseLog or false
		BotState[botGuid].verboseLogAutoEnabled = entry.verboseLogAutoEnabled or false
		BotState[botGuid].huntCooldownUntil = 0
	end

	local rPos = relogged:getPosition()
	rPos:sendMagicEffect(CONST_ME_TELEPORT)
	relogged:say(string.format("Treino concluido! Peguei %s %d e shield %d, bora cacar!",
		info.skillLabel, info.targetSkill, info.targetShield), TALKTYPE_SAY)

	logger.info(string.format("[BotTraining] %s relogged after statue training with %s=%d shield=%d (lv=%d)",
		entry.name, info.skillLabel, info.targetSkill, info.targetShield, relogged:getLevel()))
end

function BotSystem.doTraining(player, state)
	if player:isWalking() then return end

	local info = BotSystem.getSkillTargetInfo(player)
	if state.trainForce and not info.needsTraining then
		info.targetSkill = math.min(110, info.currentSkill + 2)
		info.targetShield = math.min(105, info.currentShield + 2)
	end

	if not state.trainStatuePos or not state.trainStandPos then
		local sPos, stPos = BotSystem.findOrEnsureTrainingStatue(player, state, info.statueId)
		if not sPos or not stPos then
			state.state = BOT_STATE.IDLE
			return
		end
		state.trainStatuePos = sPos
		state.trainStandPos = stPos
	end

	local pos = player:getPosition()
	local sPos = state.trainStatuePos
	local distToStatue = math.max(math.abs(pos.x - sPos.x), math.abs(pos.y - sPos.y))

	if pos.z == sPos.z and distToStatue <= 1 then
		-- Reached the Offline Training Statue! Use it, log out, and schedule auto-relog with target skill
		local botGuid = player:getGuid()
		local botName = player:getName()
		local relogPos = { x = pos.x, y = pos.y, z = pos.z }

		player:stopWalk()
		player:say(string.format("Vou treinar na estatua ate pegar %s %d!", info.skillLabel, info.targetSkill), TALKTYPE_SAY)
		pos:sendMagicEffect(CONST_ME_MAGIC_GREEN)
		sPos:sendMagicEffect(CONST_ME_MAGIC_BLUE)

		-- Apply target skills in memory before removePlayer saves to DB
		if info.baseVoc == 1 or info.baseVoc == 2 then
			player:setMagicLevel(info.targetSkill)
			player:setSkillLevel(SKILL_SHIELD, info.targetShield)
		else
			player:setSkillLevel(info.primarySkill, info.targetSkill)
			player:setSkillLevel(SKILL_SHIELD, info.targetShield)
			if (player:getMagicLevel() or 0) < info.targetML then
				player:setMagicLevel(info.targetML)
			end
		end
		if player.setOfflineTrainingSkill then
			player:setOfflineTrainingSkill(info.primarySkill)
		end

		if info.baseVoc == 1 or info.baseVoc == 2 then
			db.query(string.format(
				"UPDATE `players` SET `maglevel` = %d, `skill_shielding` = %d, `offlinetraining_skill` = %d, `posx` = %d, `posy` = %d, `posz` = %d WHERE `id` = %d",
				info.targetSkill, info.targetShield, info.primarySkill, relogPos.x, relogPos.y, relogPos.z, botGuid
			))
		else
			db.query(string.format(
				"UPDATE `players` SET `%s` = %d, `skill_shielding` = %d, `maglevel` = GREATEST(`maglevel`, %d), `offlinetraining_skill` = %d, `posx` = %d, `posy` = %d, `posz` = %d WHERE `id` = %d",
				info.dbColumn, info.targetSkill, info.targetShield, info.targetML, info.primarySkill, relogPos.x, relogPos.y, relogPos.z, botGuid
			))
		end

		logger.info(string.format("[BotTraining] %s used training statue at (%d,%d,%d), logging out -> target %s=%d shield=%d",
			botName, sPos.x, sPos.y, sPos.z, info.skillLabel, info.targetSkill, info.targetShield))

		if botThinkEvents[botGuid] then
			stopEvent(botThinkEvents[botGuid])
			botThinkEvents[botGuid] = nil
		end
		BotActive[botGuid] = false
		BotPlayers[botGuid] = nil
		db.botAsyncQuery("DELETE FROM `players_online` WHERE `player_id` = " .. botGuid)

		local eventId = addEvent(function()
			BotSystem.relogTrainedBot(botGuid)
		end, 3000)

		BotOfflineTraining[botGuid] = {
			name = botName,
			guid = botGuid,
			relogPos = relogPos,
			info = info,
			verboseLog = state.verboseLog,
			verboseLogAutoEnabled = state.verboseLogAutoEnabled,
			eventId = eventId,
		}

		player:remove(false)
		return
	end

	-- Walk to standPos adjacent to statue
	local standPos = state.trainStandPos
	local dirs = player:getPathTo(standPos, 0, 0, true, true, BOT_CONFIG.PATH_MAX_DIST)
	if dirs and type(dirs) == "table" and #dirs > 0 then
		player:startAutoWalk(dirs)
	else
		-- Direct fallback teleport adjacent to statue if path blocked
		player:teleportTo(standPos)
	end
end

-- Full Hard Reset: behaves as if the server shut down, wiped all bot data/state, and booted fresh at Level 8
function BotSystem.hardResetAllBots(initiatorPlayer)
	logger.info("[BotReset] Executing full HARD RESET of all bots (wiping DB & memory state to fresh Level 8)...")

	-- 1. Cancel any pending offline training relogs and bring offline bots back online first
	for guid, entry in pairs(BotOfflineTraining or {}) do
		if entry.eventId then
			stopEvent(entry.eventId)
		end
		BotOfflineTraining[guid] = nil
		local p = Game.loadBotPlayer(entry.name)
		if p then
			BotPlayers[guid] = p
		end
	end

	-- 2. Clear all in-memory reservations and tables
	if BotHuntData then
		BotHuntData.reservations = {}
	end
	_lastSpeakerBroadcastHandled = {}

	-- 3. Wipe DB persistence, reservations, items, and reset players table to fresh Level 8
	pcall(function() db.query("DELETE FROM `bot_state_persistence`") end)
	pcall(function() db.query("UPDATE `bot_startup_config` SET `config_value` = '0' WHERE `config_key` = 'should_restore_states'") end)
	pcall(function() db.query("DELETE FROM `bot_macro_states`") end)
	pcall(function() db.query("DELETE FROM `player_items` WHERE `player_id` IN (SELECT `id` FROM `players` WHERE `account_id` = 65000 OR `name` LIKE 'Bot %')") end)
	pcall(function() db.query("DELETE FROM `player_depotitems` WHERE `player_id` IN (SELECT `id` FROM `players` WHERE `account_id` = 65000 OR `name` LIKE 'Bot %')") end)
	pcall(function()
		db.query(
			"UPDATE `players` SET `level` = 8, `experience` = 4200, `health` = 185, `healthmax` = 185, "
			.. "`mana` = 90, `manamax` = 90, `maglevel` = 0, `manaspent` = 0, "
			.. "`skill_fist` = 10, `skill_fist_tries` = 0, "
			.. "`skill_club` = 10, `skill_club_tries` = 0, "
			.. "`skill_sword` = 10, `skill_sword_tries` = 0, "
			.. "`skill_axe` = 10, `skill_axe_tries` = 0, "
			.. "`skill_dist` = 10, `skill_dist_tries` = 0, "
			.. "`skill_shielding` = 10, `skill_shielding_tries` = 0, "
			.. "`skill_fishing` = 10, `skill_fishing_tries` = 0, "
			.. "`cap` = 470, `soul` = 100, `stamina` = 2520, "
			.. "`offlinetraining_time` = 43200, `offlinetraining_skill` = -1 "
			.. "WHERE `account_id` = 65000 OR `name` LIKE 'Bot %'"
		)
	end)

	-- 4. Reset every active bot in memory and re-run fresh startup activation
	local count = 0
	for _, p in ipairs(Game.getPlayers()) do
		if p:isBotPlayer() and not p:isRemoved() then
			local guid = p:getGuid()
			BotPlayers[guid] = p

			if p.stopWalk then p:stopWalk() end
			p:setTarget(nil)
			if p.setFollowCreature then p:setFollowCreature(nil) end

			-- Clear inventory slots (including backpack and any looted items inside)
			for slot = CONST_SLOT_FIRST, CONST_SLOT_LAST do
				local item = p:getSlotItem(slot)
				if item then
					pcall(function() item:remove() end)
				end
			end

			-- Reset level, experience, HP, mana, capacity, skills, and magic level
			p:setLevel(8)
			p:setMaxHealth(185)
			p:setHealth(185)
			p:setMaxMana(90)
			p:setMana(90)
			if p.setCapacity then
				pcall(function() p:setCapacity(47000) end)
			end
			p:setMagicLevel(0)
			p:setSkillLevel(SKILL_FIST, 10)
			p:setSkillLevel(SKILL_CLUB, 10)
			p:setSkillLevel(SKILL_SWORD, 10)
			p:setSkillLevel(SKILL_AXE, 10)
			p:setSkillLevel(SKILL_DISTANCE, 10)
			p:setSkillLevel(SKILL_SHIELD, 10)
			p:setSkillLevel(SKILL_FISHING, 10)

			-- Preserve debug flags across reset
			local prevVerbose = BotState[guid] and BotState[guid].verboseLog or false
			local prevAutoVerbose = BotState[guid] and BotState[guid].verboseLogAutoEnabled or false
			BotState[guid] = nil

			BotSystem.activateBot(p, { isHardReset = true })
			if BotState[guid] then
				BotState[guid].verboseLog = prevVerbose
				BotState[guid].verboseLogAutoEnabled = prevAutoVerbose
			end

			count = count + 1
		end
	end

	logger.info(string.format("[BotReset] Full HARD RESET completed for %d online bots.", count))
	return count
end

-- ============================================================================
-- Think Loop
-- ============================================================================

function BotSystem.thinkEvent(guid)
	botThinkEvents[guid] = nil
	-- JITTER DIAGNOSTIC: per-bot thinkEvent timing. Threshold 10ms.
	local jitter_thinkStart = Game.monotonicMs and Game.monotonicMs() or 0
	local jitter_botName = nil

	local player = BotPlayers[guid]
	if not player or player:isRemoved() then
		BotActive[guid] = false
		return
	end
	jitter_botName = player:getName()
	if not BotActive[guid] then
		local s = BotState[guid]
		if s and s.state == BOT_STATE.INACTIVE then
			if player.isCastBroadcasting and player:isCastBroadcasting() then
				if player.setCastBroadcasting then
					player:setCastBroadcasting(false)
				end
				pcall(function()
					db.query("DELETE FROM `cast_broadcasters` WHERE `player_id` = " .. guid)
				end)
			end
		end
		return
	end

	local state = BotState[guid]
	if not state then return end

	if state.manualControl then
		botThinkEvents[guid] = addEvent(BotSystem.thinkEvent, 1000, guid)
		return
	end

	local ok, err = pcall(function()
		-- Floor change state machine: if active, handle it before anything else
		if state.floorChangeState ~= FLOOR_CHANGE_STATE.NONE then
			-- During hunt patrol: check for nearby targets BEFORE running floor change.
			-- If a monster is right here on our z-level, cancel the z-transition and fight it.
			if state.floorChangeSource == "hunt"
				and state.huntPhase == HUNT_PHASE.PATROLLING
				and not state.huntMonsterTarget then
				if BotSystem.scanAndAttackHuntTarget(player, state) then
					-- Found a target! Cancel the floor change and fight
					BotSystem.resetFloorChangeState(state)
					state.floorChangeResult = nil
					state.floorChangeSource = nil
					return
				end
			end

			BotSystem.handleFloorChange(player, state)
			-- If completed or failed, process result for the source that triggered it
			if state.floorChangeState == FLOOR_CHANGE_STATE.NONE then
				local result = state.floorChangeResult
				local source = state.floorChangeSource

				if source == "route" then
					-- Route floor-change: leave result for followCityRoute() to consume
					-- Don't clear floorChangeResult/floorChangeSource here
				else
					state.floorChangeResult = nil
					state.floorChangeSource = nil

					if source == "cavebot" or state.cavebotCommand == "stairs" then
						-- Cavebot command finished
						if state.cavebotCommand == "stairs" then
							state.cavebotCommand = nil
						end
					elseif source == "hunt" and result == "failed" then
						-- Hunt z-transition failed — skip the current waypoint
						logger.warn("[Bot:" .. player:getName() .. "] HUNTING floor change FAILED, skipping waypoint "
							.. (state.huntWaypointIdx or "?"))
						BotSystem.skipHuntWaypoint(player, state, "z-transition failed")
					end
					-- For "completed" during hunt: normal AI will run and navigateToHuntWaypoint
					-- will see the z matches and proceed with same-z pathfinding
				end
			end
			if state.floorChangeState ~= FLOOR_CHANGE_STATE.NONE then
				return -- don't run normal AI while floor change in progress
			end
		end

		-- Cavebot command processing: goto navigation
		if state.cavebotCommand == "goto" and state.cavebotTarget then
			BotSystem.processCavebotGoto(player, state)
			return -- skip normal AI
		end

		-- Cavebot command processing: navigate (route graph or depot sub-state)
		if state.cavebotCommand == "navigate" and (state.cavebotNavRoute or state.navDepotTarget or state.navDepotWaitUntil) then
			BotSystem.processCavebotNavigate(player, state)
			return -- skip normal AI
		end

		-- Cavebot command processing: sequence (multi-leg navigate)
		if state.cavebotCommand == "sequence" and state.cavebotSequence then
			BotSystem.processCavebotSequence(player, state)
			return -- skip normal AI
		end

		-- Cavebot command processing: travel (inter-city via boat)
		if state.cavebotCommand == "travel" then
			BotSystem.processCavebotTravel(player, state)
			return -- skip normal AI
		end

		-- Z-level recovery (slow: once per 60s, skip during HUNTING — hunts go underground)
		local now = os.time()
		if state.state ~= BOT_STATE.HUNTING and state.state ~= BOT_STATE.TRAINING then
			if now - (state.lastZCheck or 0) >= 60 then
				state.lastZCheck = now
				if BotSystem.checkZLevel(player, state) then
					return
				end
			end
		end

		-- Execucao da Inteligencia Artificial nativa por estado
		if state.state == BOT_STATE.IDLE then
			BotSystem.doIdle(player, state)
		elseif state.state == BOT_STATE.DWELLING then
			BotSystem.doDwelling(player, state)
		elseif state.state == BOT_STATE.HUNTING then
			BotSystem.doHunting(player, state)
		elseif state.state == BOT_STATE.TRAINING then
			BotSystem.doTraining(player, state)
		elseif state.state == BOT_STATE.COMBAT then
			BotSystem.doSelfDefense(player, state)
		elseif state.state == BOT_STATE.FLEEING then
			BotSystem.doFlee(player, state, state.attackerId and Creature(state.attackerId))
		elseif state.state == BOT_STATE.TRAVELING then
			BotSystem.doTraveling(player, state)
		end
	end)

	if not ok then
		-- Log the error but keep the think loop alive
		state.thinkErrors = (state.thinkErrors or 0) + 1
		-- Log every error for the first 5, then every 60th to avoid spam
		if state.thinkErrors <= 5 or state.thinkErrors % 60 == 0 then
			logger.error("[Bot] " .. player:getName() .. " thinkEvent error #"
				.. state.thinkErrors .. ": " .. tostring(err))
		end
	end

	-- Reagendamento do think loop com cadencia adequada para movimento suave
	if BotActive[guid] then
		local interval = 1000
		if state then
			local isWalking = player.isWalking and player:isWalking() or false
			if state.floorChangeState ~= FLOOR_CHANGE_STATE.NONE or isWalking
				or state.state == BOT_STATE.HUNTING or state.state == BOT_STATE.TRAINING
				or state.state == BOT_STATE.COMBAT then
				interval = 500
			elseif state.state == BOT_STATE.DWELLING then
				interval = 1500
			end
		end
		botThinkEvents[guid] = addEvent(BotSystem.thinkEvent, interval, guid)
	end

	-- JITTER DIAGNOSTIC: log if this bot's thinkEvent body exceeded 10ms
	if Game.monotonicMs then
		local jitter_thinkMs = Game.monotonicMs() - jitter_thinkStart
		if jitter_thinkMs > 10 then
			logger.warn(string.format("[THINK_SLOW] guid=%d name=%s duration=%dms",
				guid, jitter_botName or "?", jitter_thinkMs))
		end
	end
end

-- ============================================================================
-- Return Home: retrace z-transitions after combat ends
-- ============================================================================

function BotSystem.doReturnHome(player, state)
	if player:isWalking() then return end

	local pos = player:getPosition()

	-- Process breadcrumbs: each entry has a z-transition to reverse
	if state.returnBreadcrumbs and #state.returnBreadcrumbs > 0 then
		local nextBC = state.returnBreadcrumbs[1]

		-- Are we on the correct z-level to use this transition?
		-- The transitionPos is where the original transition was — we need to find
		-- the reverse transition on our CURRENT z-level
		if pos.z ~= nextBC.targetZ then
			-- Need to transition to nextBC.targetZ
			local goDown = nextBC.targetZ > pos.z
			local transitions = BotSystem.findZTransitions(pos, 10, goDown)

			-- Also search around the original transition position (projected to our z)
			local origProjected = Position(nextBC.transitionPos.x, nextBC.transitionPos.y, pos.z)
			local moreTransitions = BotSystem.findZTransitions(origProjected, 10, goDown)
			-- Merge and dedupe
			local seen = {}
			local allT = {}
			for _, t in ipairs(transitions) do
				local key = t.pos.x .. "," .. t.pos.y .. "," .. t.type
				if not seen[key] then seen[key] = true; table.insert(allT, t) end
			end
			for _, t in ipairs(moreTransitions) do
				local key = t.pos.x .. "," .. t.pos.y .. "," .. t.type
				if not seen[key] then seen[key] = true; table.insert(allT, t) end
			end

			-- Sort by distance from bot
			table.sort(allT, function(a, b)
				local da = math.abs(pos.x - a.pos.x) + math.abs(pos.y - a.pos.y)
				local db = math.abs(pos.x - b.pos.x) + math.abs(pos.y - b.pos.y)
				return da < db
			end)

			if #allT > 0 then
				local walked = false
				for _, entry in ipairs(allT) do
					local fc = entry.pos
					local dist = math.max(math.abs(pos.x - fc.x), math.abs(pos.y - fc.y))

					if entry.type == "ladder" or entry.type == "sewer" then
						if dist == 0 then
							local destPos = Position(fc.x, fc.y, fc.z)
							if entry.type == "ladder" then
								destPos.z = destPos.z - 1 -- ladder goes UP (z decreases)
								destPos.y = destPos.y - 1 -- offset north to land next to hole
							else
								destPos.z = destPos.z + 1
							end
							player:teleportTo(destPos, true)
							logger.info("[Bot] " .. player:getName() .. " return: used " .. entry.type
								.. " at (" .. fc.x .. "," .. fc.y .. "," .. fc.z
								.. ") -> (" .. destPos.x .. "," .. destPos.y .. "," .. destPos.z .. ")")
							table.remove(state.returnBreadcrumbs, 1)
							walked = true
							break
						end
						local dirs = player:getPathTo(fc, 0, 0, true, false, BOT_CONFIG.PATH_MAX_DIST)
						if dirs and type(dirs) == "table" and #dirs > 0 then
							player:startAutoWalk(dirs)
							walked = true
							break
						end
					else
						-- Stairs
						if dist == 0 then
							walked = true
							break
						end
						if dist == 1 then
							local stepDir = Position.getDirectionTo(pos, fc)
							if stepDir then
								player:startAutoWalk({stepDir})
								table.remove(state.returnBreadcrumbs, 1)
								walked = true
								break
							end
						end
						local dirs = player:getPathTo(fc, 1, 1, true, false, BOT_CONFIG.PATH_MAX_DIST)
						if dirs and type(dirs) == "table" and #dirs > 0 then
							player:startAutoWalk(dirs)
							walked = true
							break
						end
					end
				end

				if not walked then
					-- Can't reach any transition — try clearing blocking creatures
					BotSystem.tryAttackBlockingCreature(player, state, allT[1].pos)
				end
			else
				-- No transitions found — give up returning, just z-recover normally
				logger.info("[Bot] " .. player:getName() .. " return: no transitions found, giving up")
				state.returningHome = false
				state.returnBreadcrumbs = {}
				state.returnDestination = nil
			end
		else
			-- We're on the right z for this breadcrumb — pop it and continue
			table.remove(state.returnBreadcrumbs, 1)
		end
		return
	end

	-- All z-transitions done — walk back to the pre-combat XY position
	if state.returnDestination then
		local dest = state.returnDestination
		if pos.z == dest.z then
			local dist = math.max(math.abs(pos.x - dest.x), math.abs(pos.y - dest.y))
			if dist <= 3 then
				-- Close enough — done returning
				logger.info("[Bot] " .. player:getName() .. " returned home successfully")
				state.returningHome = false
				state.returnBreadcrumbs = {}
				state.returnDestination = nil
				return
			end
			-- Walk toward pre-combat position
			local destPos = Position(dest.x, dest.y, dest.z)
			local dirs = player:getPathTo(destPos, 0, 3, true, true, BOT_CONFIG.PATH_MAX_DIST)
			if dirs and type(dirs) == "table" and #dirs > 0 then
				player:startAutoWalk(dirs)
			else
				-- Can't path — close enough or blocked, give up
				logger.info("[Bot] " .. player:getName() .. " return: can't path to origin, stopping")
				state.returningHome = false
				state.returnBreadcrumbs = {}
				state.returnDestination = nil
			end
		else
			-- Still on wrong z but no breadcrumbs left — give up
			logger.info("[Bot] " .. player:getName() .. " return: wrong z but no breadcrumbs, giving up")
			state.returningHome = false
			state.returnBreadcrumbs = {}
			state.returnDestination = nil
		end
		return
	end

	-- Nothing to return to — clear flag
	state.returningHome = false
end

-- ============================================================================
-- IDLE State: walk between POIs, loiter, travel
-- ============================================================================

function BotSystem.doIdle(player, state)
	-- Follow player mode (triggered when obeying a FOLLOW command from GOD or player)
	if state.followPlayerGuid then
		local leader = Player(state.followPlayerGuid)
		if not leader or leader:isRemoved() then
			state.followPlayerGuid = nil
		else
			local pos = player:getPosition()
			local lpos = leader:getPosition()
			if pos.z ~= lpos.z then
				BotSystem.chaseTarget(player, state, leader)
				return
			end
			local dist = math.max(math.abs(pos.x - lpos.x), math.abs(pos.y - lpos.y))
			if dist > 40 then
				state.followPlayerGuid = nil
			elseif dist > 2 and not player:isWalking() then
				local dirs = player:getPathTo(lpos, 0, 2, true, true, BOT_CONFIG.PATH_MAX_DIST)
				if dirs and type(dirs) == "table" and #dirs > 0 then
					player:startAutoWalk(dirs)
				else
					BotSystem.checkTrapOrBlocker(player, state, lpos)
				end
				return
			else
				return
			end
		end
	end

	-- Try initiating a 5-turn Bot <-> Bot conversation if a human player is nearby
	if BotSystem.tryBotToBotDialogue then
		BotSystem.tryBotToBotDialogue(player, state)
	end

	-- If auto-walk in progress, let it continue
	if player:isWalking() then
		return
	end

	-- Automatic Statue Training check: only if bot archetype/personality demands training
	local skillInfo = BotSystem.getSkillTargetInfo and BotSystem.getSkillTargetInfo(player)
	if skillInfo and BotSystem.shouldBotTrain(player, state, skillInfo) then
		if BotSystem.startStatueTraining(player, state, false) then
			return
		end
	end

	-- Autonomous Macro-Decision via Node.js (bot-decision-service :3001)
	if not state.walkTarget and BotSystem.requestNodeMacroDecision then
		local now = os.time()
		if now >= (state.nextMacroDecisionTime or 0) then
			state.nextMacroDecisionTime = now + (BOT_CONFIG.MACRO_DECISION_COOLDOWN or 40) + math.random(0, 15)
			BotSystem.requestNodeMacroDecision(player, state)
		end
	end

	-- Hunt roll (only when idle and cooldown expired)
	if not state.walkTarget and os.time() >= (state.huntCooldownUntil or 0) then
		if math.random(1, BOT_CONFIG.HUNT_CHANCE_PER_TICK) == 1 then
			if BotSystem.tryStartHunt(player, state) then
				return
			end
		end
	end

	-- Travel roll (only when idle and not walking to a target)
	if not state.walkTarget then
		if math.random(1, BOT_CONFIG.TRAVEL_CHANCE_PER_TICK) == 1 then
			BotSystem.startTravel(player, state)
			return
		end
	end

	-- Check arrival at current POI
	if state.currentPOI and state.walkTarget then
		local pos = player:getPosition()
		local dx = math.abs(pos.x - state.walkTarget.x)
		local dy = math.abs(pos.y - state.walkTarget.y)
		local dz = math.abs(pos.z - state.walkTarget.z)
		-- Arrival distance: 3 tiles on same z, or 1 tile z-diff (for boat at z=6 when city is z=7)
		if dx <= BOT_CONFIG.POI_ARRIVAL_DIST and dy <= BOT_CONFIG.POI_ARRIVAL_DIST and dz <= 1 then
			state.consecutivePOIFails = 0
			local dwellTime = math.random(BOT_CONFIG.POI_DWELL_MIN, BOT_CONFIG.POI_DWELL_MAX)
			state.state = BOT_STATE.DWELLING
			state.dwellUntil = os.time() + dwellTime

			BotSystem.castDebug(player, state, "IDLE: arrived at " .. state.currentPOI.name
				.. ", dwelling for " .. math.floor(dwellTime / 60) .. "m" .. (dwellTime % 60) .. "s")
			logger.info("[Bot] " .. player:getName() ..
				" arrived at " .. state.currentPOI.name ..
				", dwelling for " .. math.floor(dwellTime / 60) .. "m" .. (dwellTime % 60) .. "s")

			-- Depot arrival: 50% chance to walk to a depot locker
			local poiType = state.currentPOI.type
			if poiType == "depot" and math.random(1, 2) == 1 then
				local lockerPos = BotSystem.findReachableDepotLocker(player, state)
				if lockerPos then
					state.idleDepotTarget = lockerPos
					BotSystem.castDebug(player, state, "IDLE: walking to depot locker at ("
						.. lockerPos.x .. "," .. lockerPos.y .. "," .. lockerPos.z .. ")")
				end
			end

			return
		end
	end

	-- Pick a new POI if needed
	if not state.walkTarget then
		local poi = BotSystem.pickNextPOI(player, state)
		if poi then
			state.currentPOI = poi
			state.walkTarget = poi.pos
			state.pathFailCount = 0

			local pos = player:getPosition()
			BotSystem.castDebug(player, state, "IDLE: heading to " .. poi.name
				.. " (" .. poi.pos.x .. "," .. poi.pos.y .. "," .. poi.pos.z .. ")")
			logger.info("[Bot] " .. player:getName() ..
				" heading to " .. poi.name ..
				" from (" .. pos.x .. "," .. pos.y .. ")")
		end
	end

	-- Navigate to current target
	if state.walkTarget then
		local ok = BotSystem.goTo(player, state.walkTarget, state)
		if not ok then
			local blocker = BotSystem.checkTrapOrBlocker(player, state, state.walkTarget)
			if blocker == "monster" or blocker == "mwall" then
				return -- realistically fight monster or wait for Magic Wall to expire
			end
			state.pathFailCount = (state.pathFailCount or 0) + 1
			if state.pathFailCount >= 3 then
				state.consecutivePOIFails = (state.consecutivePOIFails or 0) + 1
				state.walkTarget = nil
				state.currentPOI = nil
				state.pathFailCount = 0

				if state.consecutivePOIFails >= BOT_CONFIG.STUCK_THRESHOLD then
					logger.info("[Bot] " .. player:getName() ..
						" could not reach POIs after " .. state.consecutivePOIFails .. " attempts, resetting POI history")
					state.consecutivePOIFails = 0
					state.visitedPOIs = {}
				end
			end
		else
			state.pathFailCount = 0
		end
	end
end

-- ============================================================================
-- DWELLING State: standing at a POI
-- ============================================================================

function BotSystem.doDwelling(player, state)
	-- Depot locker walk sub-state: walk to locker while dwelling
	if state.idleDepotTarget then
		if not player:isWalking() then
			local pos = player:getPosition()
			local dp = state.idleDepotTarget
			local dist = math.max(math.abs(pos.x - dp.x), math.abs(pos.y - dp.y))
			if dist <= 1 and pos.z == dp.z then
				-- Arrived at depot locker
				state.idleDepotTarget = nil
			else
				-- Walk toward locker
				local walked = false
				local adjacentOffsets = {{0,-1},{0,1},{-1,0},{1,0},{-1,-1},{1,-1},{-1,1},{1,1}}
				for _, off in ipairs(adjacentOffsets) do
					local adjPos = Position(dp.x + off[1], dp.y + off[2], dp.z)
					local adjTile = Tile(adjPos)
					if adjTile and adjTile:isWalkable() then
						local dirs = player:getPathTo(adjPos, 0, 0, true, true, BOT_CONFIG.PATH_MAX_DIST)
						if dirs and type(dirs) == "table" and #dirs > 0 then
							player:startAutoWalk(dirs)
							walked = true
							break
						end
					end
				end
				if not walked then
					state.idleDepotTarget = nil
				end
			end
		end
		-- Don't interrupt depot walking with hunt/travel rolls — let it finish first
		if state.idleDepotTarget then return end
	end

	-- Try initiating a 5-turn Bot <-> Bot conversation if a human player is nearby
	if BotSystem.tryBotToBotDialogue then
		BotSystem.tryBotToBotDialogue(player, state)
	end

	if os.time() >= state.dwellUntil then
		BotSystem.castDebug(player, state, "DWELLING: time up at " .. (state.currentPOI and state.currentPOI.name or "?")
			.. ", requesting Node.js macro decision")
		state.state = BOT_STATE.IDLE
		state.walkTarget = nil
		state.currentPOI = nil
		state.pathFailCount = 0
		state.idleDepotTarget = nil
		if BotSystem.requestNodeMacroDecision then
			state.nextMacroDecisionTime = os.time() + (BOT_CONFIG.MACRO_DECISION_COOLDOWN or 40)
			BotSystem.requestNodeMacroDecision(player, state)
		end
	end
end

-- ============================================================================
-- TRAVELING State: inter-city travel
-- ============================================================================

function BotSystem.startTravel(player, state)
	local town = player:getTown()
	if not town then return end
	local townId = town:getId()
	local destinations = TRAVEL_DESTINATIONS[townId]
	if not destinations or #destinations == 0 then return end

	local destTownId = destinations[math.random(1, #destinations)]
	local destTown = Town(destTownId)
	if not destTown then return end

	if math.random(1, 3) == 1 then
		BotSystem.sayRandom(player, state, "travel")
	end

	state.walkTarget = nil
	state.currentPOI = nil

	BotSystem.castDebug(player, state, "TRAVEL: " .. town:getName() .. " -> " .. destTown:getName())
	logger.info("[Bot] " .. player:getName() .. " traveling from " ..
		town:getName() .. " to " .. destTown:getName())

	-- Use proper boat travel: walk to boat -> say hi -> wait -> teleport -> walk from boat
	BotSystem.startCavebotTravel(player, state, destTownId, destTown:getName())
end

function BotSystem.doTraveling(player, state)
	-- Legacy fallback: startTravel() now uses boat-based travel via startCavebotTravel(),
	-- so this state should no longer be reached. If it is, recover gracefully.
	logger.warn("[Bot] " .. player:getName() .. " in legacy TRAVELING state, recovering to IDLE")
	state.state = BOT_STATE.IDLE
	state.travelDestTownId = nil
	state.travelUntil = nil
end

-- ============================================================================
-- Self-Defense: Fight or Flight
-- ============================================================================

function BotSystem.doSelfDefense(player, state)
	-- Don't interrupt PK mode or party mode
	if state.state == BOT_STATE.PK_ATTACK then return end
	if state.state == BOT_STATE.PARTY then return end

	local pos = player:getPosition()

	-- Handle "ignore" mode: we decided this attacker is too weak to bother with.
	-- Optionally hit them once, then continue normal behavior.
	if state.ignoredAttackerId then
		local ignored = Creature(state.ignoredAttackerId)
		if not ignored or ignored:isRemoved() or ignored:getHealth() <= 0 then
			-- Ignored attacker is gone — clear
			state.ignoredAttackerId = nil
			state.ignoredHitBack = false
			return
		end
		-- Check if they're still targeting us
		local target = ignored:getTarget()
		if not target or target:getId() ~= player:getId() then
			-- They stopped attacking us — clear
			state.ignoredAttackerId = nil
			state.ignoredHitBack = false
			return
		end
		-- Hit back once (50% chance) then go about our business
		if not state.ignoredHitBack then
			state.ignoredHitBack = true
			if math.random(1, 2) == 1 then
				player:setTarget(ignored)
				BotSystem.doCastSpell(player, state, ignored)
			end
		end
		return  -- Continue normal IDLE/DWELLING behavior
	end

	-- Find our target: remembered attacker (any z) or new attacker from spectators
	local attacker = nil
	local attackerOnSameZ = false

	-- Check remembered attacker (may be on different z for z-pursuit through stairs)
	if state.attackerId then
		local remembered = Creature(state.attackerId)
		if remembered and not remembered:isRemoved() and remembered:getHealth() > 0 then
			local rpos = remembered:getPosition()
			if rpos.z == pos.z then
				local dist = math.max(math.abs(pos.x - rpos.x), math.abs(pos.y - rpos.y))
				if dist <= BOT_CONFIG.COMBAT_LEASH_DIST then
					attacker = remembered
					attackerOnSameZ = true
				end
			else
				-- Different z — pursue through stairs if attacker is still a threat
				local skull = remembered:getSkull()
				local stillTargeting = remembered:getTarget() and remembered:getTarget():getId() == player:getId()
				if stillTargeting or (skull and skull >= 3) then
					attacker = remembered
					attackerOnSameZ = false
				end
			end
		end
	end

	-- Scan spectators for new PLAYER attackers targeting us (same z only, takes priority)
	-- Only consider Players — monsters/NPCs targeting the bot should never trigger combat
	-- Throttle: scan every 20 ticks if remembered attacker, 10 ticks if not
	-- At 500ms walk interval: 10s/5s; at 2s idle interval: 20s/10s
	local scanInterval = attacker and 20 or 10
	state.defenseScanCooldown = (state.defenseScanCooldown or 0) - 1
	if state.defenseScanCooldown <= 0 then
		state.defenseScanCooldown = scanInterval
		local spectators = Game.getSpectators(pos, false, false, 7, 7, 5, 5)
		if spectators and #spectators > 0 then
			local bestDist = 999
			for _, creature in ipairs(spectators) do
				if creature ~= player and not creature:isRemoved() and creature:getHealth() > 0
					and Player(creature) then
					local target = creature:getTarget()
					if target and target:getId() == player:getId() then
						local tpos = creature:getPosition()
						if tpos.z == pos.z then
							local dist = math.max(math.abs(pos.x - tpos.x), math.abs(pos.y - tpos.y))
							if dist < bestDist then
								bestDist = dist
								attacker = creature
								attackerOnSameZ = true
							end
						end
					end
				end
			end
		end
	end

	-- If no attacker found, check skull-based memory for off-screen attacker
	if not attacker and state.attackerId then
		local remembered = Creature(state.attackerId)
		if remembered and not remembered:isRemoved() and remembered:getHealth() > 0 then
			local skull = remembered:getSkull()
			if skull and skull >= 3 then
				state.lastAttackerSeen = state.lastAttackerSeen or os.time()
				if os.time() - state.lastAttackerSeen < 60 then
					-- Stay in combat — chase through stairs if on different z
					if state.state == BOT_STATE.COMBAT then
						BotSystem.chaseTarget(player, state, remembered)
					end
					return
				end
			end
		end
	end

	if not attacker then
		-- No attacker found and memory expired — exit combat
		if state.state == BOT_STATE.COMBAT or state.state == BOT_STATE.FLEEING then
			BotSystem.exitCombat(player, state)
		end
		return
	end

	-- Attacker found — reset the memory timer
	state.lastAttackerSeen = os.time()

	-- Enter combat if not already in a combat state
	if state.state ~= BOT_STATE.COMBAT and state.state ~= BOT_STATE.FLEEING then
		state.combatStartTime = os.time()
		state.lastCombatProgress = os.time()
		state.attackerId = attacker:getId()
		state.walkTarget = nil
		state.currentPOI = nil
		state.returningHome = false
		state.returnBreadcrumbs = {}
		-- Remember where we were before combat so we can return
		local combatPos = player:getPosition()
		state.preCombatPos = { x = combatPos.x, y = combatPos.y, z = combatPos.z }
		state.zBreadcrumbs = {}

		-- Level-based combat decision:
		-- If bot significantly outlevels attacker (6x+ level),
		-- fight chance drops from 50% to ~17%, and "ignore" replaces "flee".
		local botLevel = player:getLevel()
		local attackerLevel = 0
		local ap = Player(attacker:getId())
		if ap then attackerLevel = ap:getLevel() end

		local outleveling = (attackerLevel > 0 and botLevel >= attackerLevel * 6)

		if outleveling then
			-- High-level bot vs weak attacker: 17% fight, 83% ignore
			local roll = math.random(1, 6)
			if roll == 1 then
				state.state = BOT_STATE.COMBAT
				state.combatDecision = "fight"
				if math.random(1, 2) == 1 then
					BotSystem.sayRandom(player, state, "combat")
				end
				logger.info("[Bot] " .. player:getName() .. " (lv" .. botLevel ..
					") FIGHTING weaker attacker " .. attacker:getName() .. " (lv" .. attackerLevel .. ")")
			else
				-- Ignore: hit once maybe, then go back to normal
				state.ignoredAttackerId = attacker:getId()
				state.ignoredHitBack = false
				state.combatDecision = nil
				state.combatStartTime = nil
				state.attackerId = nil
				logger.info("[Bot] " .. player:getName() .. " (lv" .. botLevel ..
					") IGNORING weak attacker " .. attacker:getName() .. " (lv" .. attackerLevel .. ")")
				return
			end
		else
			-- Normal case: 50% fight, 50% flee
			if math.random(1, 2) == 1 then
				state.state = BOT_STATE.COMBAT
				state.combatDecision = "fight"
				if math.random(1, 2) == 1 then
					BotSystem.sayRandom(player, state, "combat")
				end
				logger.info("[Bot] " .. player:getName() .. " FIGHTING " .. attacker:getName())
			else
				state.state = BOT_STATE.FLEEING
				state.combatDecision = "flee"
				if math.random(1, 2) == 1 then
					BotSystem.sayRandom(player, state, "flee")
				end
				logger.info("[Bot] " .. player:getName() .. " FLEEING from " .. attacker:getName())
			end
		end
	end

	-- Update remembered attacker (in case a new closer one appeared)
	state.attackerId = attacker:getId()

	-- Re-check: if attacker stopped targeting us AND has no PK skull, disengage
	-- (They gave up or skull expired — no reason to keep fighting)
	if state.state == BOT_STATE.COMBAT or state.state == BOT_STATE.FLEEING then
		local target = attacker:getTarget()
		local stillTargeting = target and target:getId() == player:getId()
		local skull = attacker:getSkull()
		local hasPKSkull = skull and skull >= 3
		if not stillTargeting and not hasPKSkull then
			logger.info("[Bot] " .. player:getName() .. " disengaging: attacker "
				.. attacker:getName() .. " no longer targeting us and no skull")
			BotSystem.exitCombat(player, state)
			return
		end
	end

	-- Execute decision
	if state.state == BOT_STATE.COMBAT then
		-- Set target (server auto-attacks with weapon) + cast spell
		if player:getTarget() ~= attacker then
			player:setTarget(attacker)
		end
		BotSystem.doCastSpell(player, state, attacker)
		BotSystem.chaseTarget(player, state, attacker)  -- chaseTarget handles z-pursuit
	elseif state.state == BOT_STATE.FLEEING then
		if attackerOnSameZ then
			BotSystem.doFlee(player, state, attacker)
		end
	end
end

-- Cache ladder IDs at load time for z-transition item detection
BOT_LADDER_IDS = {}
if Game and Game.getLadderIds then
	local ids = Game.getLadderIds()
	if ids then
		for _, id in ipairs(ids) do
			BOT_LADDER_IDS[id] = true
		end
	end
end
-- Item 435 is a sewer grate / trapdoor (goes DOWN)
BOT_SEWER_ID = 435

-- Closed shovel/pick hole item IDs -> open hole item IDs
BOT_SHOVEL_HOLE_IDS = {
	[593] = 594,     -- stone pile -> hole
	[606] = 607,     -- loose stone pile -> hole
	[608] = 609,     -- loose ice pile -> hole
	[867] = 868,     -- large hole (closed) -> hole
	[21341] = 21342, -- covered hole -> open hole
	[7749] = 594,    -- tutorial stone pile -> hole
}

function BotSystem.findClosedShovelHole(tile)
	if not tile then return nil, nil end
	local function checkItem(item)
		if not item then return nil end
		local id = item:getId()
		if BOT_SHOVEL_HOLE_IDS[id] then
			return BOT_SHOVEL_HOLE_IDS[id]
		end
		local aid = item:getActionId()
		if id == 231 and aid == 100 then
			return 615
		elseif (id == 354 or id == 355) and aid == 101 then
			return 394
		end
		return nil
	end

	local ground = tile:getGround()
	local openId = checkItem(ground)
	if openId then
		return ground, openId
	end

	local items = tile:getItems()
	if items then
		for _, item in ipairs(items) do
			openId = checkItem(item)
			if openId then
				return item, openId
			end
		end
	end
	return nil, nil
end

function BotSystem.tryOpenShovelHole(tile)
	local item, openId = BotSystem.findClosedShovelHole(tile)
	if item and openId then
		local pos = tile:getPosition()
		item:transform(openId)
		item:decay()
		if pos then
			pos:sendMagicEffect(CONST_ME_POFF)
		end
		return true
	end
	return false
end

function BotSystem.findZTransitions(centerPos, radius, goDown)
	-- Find all ways to change z-level within radius of centerPos.
	-- goDown=true: find transitions going DOWN (z increases)
	-- goDown=false: find transitions going UP (z decreases)
	-- Returns list of {pos=Position, type="stairs"|"ladder"|"sewer"|"rope"|"shovel", dist=N}
	local results = {}
	for dx = -radius, radius do
		for dy = -radius, radius do
			local checkPos = Position(centerPos.x + dx, centerPos.y + dy, centerPos.z)
			local tile = Tile(checkPos)
			if tile then
				local d = math.abs(dx) + math.abs(dy)
				-- Check floor-change tiles (stairs/ramps/open holes)
				if goDown and tile:hasFlag(TILESTATE_FLOORCHANGE_DOWN) then
					table.insert(results, { pos = checkPos, type = "stairs", dist = d })
				elseif not goDown and tile:hasFlag(TILESTATE_FLOORCHANGE)
					and not tile:hasFlag(TILESTATE_FLOORCHANGE_DOWN) then
					table.insert(results, { pos = checkPos, type = "stairs", dist = d })
				end
				-- Check closed shovel/pick holes (going DOWN only)
				if goDown then
					local holeItem, _ = BotSystem.findClosedShovelHole(tile)
					if holeItem then
						table.insert(results, { pos = checkPos, type = "shovel", dist = d })
					end
				end
				-- Check useable items (ladders go UP, sewers go DOWN)
				local items = tile:getItems()
				if items then
					for _, item in ipairs(items) do
						local itemId = item:getId()
						if not goDown and BOT_LADDER_IDS[itemId] then
							table.insert(results, { pos = checkPos, type = "ladder", dist = d })
							break
						elseif goDown and itemId == BOT_SEWER_ID then
							table.insert(results, { pos = checkPos, type = "sewer", dist = d })
							break
						end
					end
				end
				-- Check rope spots (going UP only) — uses Tile:isRopeSpot() from tile.lua
				if not goDown and tile:isRopeSpot() then
					table.insert(results, { pos = checkPos, type = "rope", dist = d })
				end
			end
		end
	end
	table.sort(results, function(a, b) return a.dist < b.dist end)
	return results
end

function BotSystem.chaseTarget(player, state, target)
	local pos = player:getPosition()
	local tpos = target:getPosition()

	-- PZ check: stop chasing if target is in protection zone
	local tTile = Tile(tpos)
	if tTile and tTile:hasFlag(TILESTATE_PROTECTIONZONE) then
		return
	end

	-- Z-level pursuit: if target went to different floor, find and walk to
	-- the floor-change tile near their last same-z position.
	-- The last known position might be 1-2 tiles from the actual stair/portal,
	-- so we scan a radius around it for TILESTATE_FLOORCHANGE tiles.
	if pos.z ~= tpos.z then
		-- Target on different z-level — find directionally correct transitions
		local goDown = tpos.z > pos.z  -- target is below us (higher z number = lower in world)

		-- Collect transitions from multiple search centers, deduped
		local allTransitions = {}
		local seen = {}

		local function addFrom(center)
			local transitions = BotSystem.findZTransitions(center, 10, goDown)
			for _, entry in ipairs(transitions) do
				local key = entry.pos.x .. "," .. entry.pos.y .. "," .. entry.type
				if not seen[key] then
					seen[key] = true
					table.insert(allTransitions, entry)
				end
			end
		end

		if state.targetLastSameZPos then
			addFrom(Position(state.targetLastSameZPos.x, state.targetLastSameZPos.y, pos.z))
		end
		addFrom(Position(pos.x, pos.y, pos.z))
		addFrom(Position(tpos.x, tpos.y, pos.z))

		-- Sort by distance from bot
		table.sort(allTransitions, function(a, b)
			local da = math.abs(pos.x - a.pos.x) + math.abs(pos.y - a.pos.y)
			local db = math.abs(pos.x - b.pos.x) + math.abs(pos.y - b.pos.y)
			return da < db
		end)

		-- NOTE: Canary's A* pathfinder rejects floor-change tiles (tile.cpp:610).
		-- For stairs: path to 1 tile away, then manually step onto them.
		-- For ladders/sewers: path to the tile, then teleport (simulating "use").
		if #allTransitions > 0 and not player:isWalking() then
			local walked = false
			for _, entry in ipairs(allTransitions) do
				local fc = entry.pos
				local dist = math.max(math.abs(pos.x - fc.x), math.abs(pos.y - fc.y))

				if entry.type == "ladder" or entry.type == "sewer" then
					-- Ladder/sewer: need to be ON the tile, then teleport
					if dist == 0 then
						-- We're on the item — simulate "use" via teleport
						local destPos = Position(fc.x, fc.y, fc.z)
						if entry.type == "ladder" then
							destPos.z = destPos.z - 1 -- ladder goes UP (z decreases)
							destPos.y = destPos.y - 1 -- offset north to land next to hole
						else
							destPos.z = destPos.z + 1
						end
						player:teleportTo(destPos, true)
						state.lastCombatProgress = os.time()
						-- Record breadcrumb for return navigation
						table.insert(state.zBreadcrumbs, {
							fromPos = { x = fc.x, y = fc.y, z = fc.z },
							toZ = destPos.z,
							type = entry.type
						})
						logger.info("[Bot] " .. player:getName() .. " z-pursuit: used " .. entry.type
							.. " at (" .. fc.x .. "," .. fc.y .. "," .. fc.z
							.. ") -> z=" .. destPos.z)
						walked = true
						break
					end
					-- Path directly to the ladder/sewer tile (these aren't FLOORCHANGE tiles,
					-- so the pathfinder doesn't reject them)
					local dirs = player:getPathTo(fc, 0, 0, true, false, BOT_CONFIG.PATH_MAX_DIST)
					if dirs and type(dirs) == "table" and #dirs > 0 then
						player:startAutoWalk(dirs)
						logger.info("[Bot] " .. player:getName() .. " z-pursuit: walking to "
							.. entry.type .. " at (" .. fc.x .. "," .. fc.y .. "," .. fc.z
							.. ") dist=" .. dist)
						walked = true
						break
					end
				else
					-- Stairs: A* rejects these tiles, so path to adjacent then step on
					if dist == 0 then
						logger.info("[Bot] " .. player:getName() .. " ON stairs at ("
							.. fc.x .. "," .. fc.y .. "," .. fc.z .. ") waiting for z-transition")
						walked = true
						break
					end
					if dist == 1 then
						-- Adjacent — manually step onto the stair
						local stepDir = Position.getDirectionTo(pos, fc)
						if stepDir then
							player:startAutoWalk({stepDir})
							state.lastCombatProgress = os.time()
							-- Record breadcrumb for return navigation
							local destZ = goDown and (fc.z + 1) or (fc.z - 1)
							table.insert(state.zBreadcrumbs, {
								fromPos = { x = fc.x, y = fc.y, z = fc.z },
								toZ = destZ,
								type = "stairs"
							})
							logger.info("[Bot] " .. player:getName() .. " z-pursuit: stepping onto stairs at ("
								.. fc.x .. "," .. fc.y .. "," .. fc.z .. ")")
							walked = true
							break
						end
					end
					-- Path to within 1 tile of the stairs
					local dirs = player:getPathTo(fc, 1, 1, true, false, BOT_CONFIG.PATH_MAX_DIST)
					if dirs and type(dirs) == "table" and #dirs > 0 then
						player:startAutoWalk(dirs)
						logger.info("[Bot] " .. player:getName() .. " z-pursuit: walking near stairs at ("
							.. fc.x .. "," .. fc.y .. "," .. fc.z .. ") dist=" .. dist)
						walked = true
						break
					end
				end
			end
			if not walked then
				-- Try doors first, then clear blocking monsters toward nearest transition
				if not BotSystem.tryOpenDoors(player, allTransitions[1].pos) then
					BotSystem.tryAttackBlockingCreature(player, state, allTransitions[1].pos)
				end
				logger.info("[Bot] " .. player:getName() .. " z-pursuit: can't reach any of "
					.. #allTransitions .. " transitions (" .. (goDown and "DOWN" or "UP") .. ")")
			end
		elseif #allTransitions == 0 then
			logger.info("[Bot] " .. player:getName() .. " z-pursuit: no "
				.. (goDown and "DOWN" or "UP") .. " transitions found")
		end
		return
	end

	-- Same floor — track target's position for z-level pursuit
	state.targetLastSameZPos = { x = tpos.x, y = tpos.y, z = tpos.z }

	-- Get attack range based on vocation
	local voc = player:getVocation()
	local baseVoc = voc and voc:getBaseId() or 4
	local attackRange = 1  -- Knight: melee
	if baseVoc == 1 then attackRange = 3      -- Sorcerer
	elseif baseVoc == 2 then attackRange = 3  -- Druid
	elseif baseVoc == 3 then attackRange = 5  -- Paladin
	end

	local dist = math.max(math.abs(pos.x - tpos.x), math.abs(pos.y - tpos.y))

	-- Only stop if in range AND have clear line of sight (no wall between us)
	if dist <= attackRange and pos:isSightClear(tpos, true) then return end

	-- If walking, check if target moved enough to justify recalculating
	if player:isWalking() then
		if state.chaseLastTargetPos then
			local old = state.chaseLastTargetPos
			local moved = math.max(math.abs(tpos.x - old.x), math.abs(tpos.y - old.y))
			if moved < 3 then return end -- target hasn't moved much
		else
			return
		end
	end

	-- Pathfind to target with clearSight=true so path goes AROUND walls
	state.chaseLastTargetPos = { x = tpos.x, y = tpos.y, z = tpos.z }
	local dirs = player:getPathTo(tpos, 0, attackRange, true, true, BOT_CONFIG.PATH_MAX_DIST)
	if not dirs or type(dirs) ~= "table" or #dirs == 0 then
		-- Fallback: try without clearSight (get as close as possible)
		dirs = player:getPathTo(tpos, 0, attackRange, true, false, BOT_CONFIG.PATH_MAX_DIST)
	end
	if not dirs or type(dirs) ~= "table" or #dirs == 0 then
		-- Try slight offsets as last resort
		for _ = 1, 3 do
			local offsetPos = Position(
				tpos.x + math.random(-1, 1),
				tpos.y + math.random(-1, 1),
				tpos.z
			)
			dirs = player:getPathTo(offsetPos, 0, attackRange, true, true, BOT_CONFIG.PATH_MAX_DIST)
			if dirs and type(dirs) == "table" and #dirs > 0 then break end
		end
	end

	-- If pathfinding still fails, try clearing obstacles
	if not dirs or type(dirs) ~= "table" or #dirs == 0 then
		-- Try doors first
		if BotSystem.tryOpenDoors(player, tpos) then return end
		-- Try attacking blocking monsters/NPCs between us and the target
		BotSystem.tryAttackBlockingCreature(player, state, tpos)
		return
	end

	state.lastCombatProgress = os.time()
	player:startAutoWalk(dirs)
end

-- Attack the nearest monster or NPC blocking the path toward a target position.
-- This lets bots clear their way through sewers/caves when pursuing a player.
function BotSystem.tryAttackBlockingCreature(player, state, targetPos)
	local pos = player:getPosition()
	local dx = targetPos.x - pos.x
	local dy = targetPos.y - pos.y
	local dist = math.max(math.abs(dx), math.abs(dy), 1)
	local ndx = dx > 0 and 1 or (dx < 0 and -1 or 0)
	local ndy = dy > 0 and 1 or (dy < 0 and -1 or 0)

	-- Check tiles in the direction of the target (primary diagonal, then cardinal)
	local tilesToCheck = {}
	if ndx ~= 0 or ndy ~= 0 then
		table.insert(tilesToCheck, Position(pos.x + ndx, pos.y + ndy, pos.z))
	end
	if ndx ~= 0 then
		table.insert(tilesToCheck, Position(pos.x + ndx, pos.y, pos.z))
	end
	if ndy ~= 0 then
		table.insert(tilesToCheck, Position(pos.x, pos.y + ndy, pos.z))
	end

	-- Also check tiles 2 away for ranged vocations
	if ndx ~= 0 or ndy ~= 0 then
		table.insert(tilesToCheck, Position(pos.x + ndx * 2, pos.y + ndy * 2, pos.z))
	end

	for _, tilePos in ipairs(tilesToCheck) do
		local tile = Tile(tilePos)
		if tile then
			local creatures = tile:getCreatures()
			if creatures then
				for _, creature in ipairs(creatures) do
					if creature ~= player and not creature:isRemoved() and creature:getHealth() > 0
						and not Player(creature) then
						-- Found a monster/NPC blocking the path — attack it
						BotSystem.doAttackCreature(player, state, creature)
						return
					end
				end
			end
		end
	end
end

-- Attack any creature (monster/NPC) to clear path.
-- Uses native targeting: setAttackedCreature (server auto-attacks) + cast a spell.
function BotSystem.doAttackCreature(player, state, target)
	local now = os.time()
	if now - state.lastAttackTime < BOT_CONFIG.ATTACK_COOLDOWN then return end

	local pos = player:getPosition()
	local tpos = target:getPosition()
	if pos.z ~= tpos.z then return end

	local dist = math.max(math.abs(pos.x - tpos.x), math.abs(pos.y - tpos.y))
	if dist > 5 then return end -- too far

	local hasLOS = pos:isSightClear(tpos, true)

	-- Set target (server handles weapon auto-attacks if LOS is clear)
	if player:getTarget() ~= target then
		player:setTarget(target)
	end

	-- Ensure mana
	if player:getMana() < player:getMaxMana() * 0.3 then
		player:addMana(player:getMaxMana())
	end

	-- Also cast a spell for extra damage (requires LOS)
	if hasLOS then
		local spell = BotSystem.selectAttackSpell(player, state, target)
		if spell then
			local ok = player:castSpell(spell.name, target)
			if ok then
				state.lastAttackTime = now
				state.lastCombatProgress = now
				state["spellCd_" .. spell.name] = now + spell.cd
			end
		else
			state.lastAttackTime = now
		end
	else
		-- No LOS — weapon auto-attack won't work either
		-- Just set cooldown so we don't spam
		state.lastAttackTime = now
		BotSystem.combatLog(player, state, "HUNT-ATTACK-NOLOS: " .. target:getName()
			.. " dist=" .. dist
			.. " at (" .. tpos.x .. "," .. tpos.y .. "," .. tpos.z .. ")")
	end
end

function BotSystem.tryOpenDoors(player, targetPos)
	local pos = player:getPosition()
	-- Direction toward target
	local dx = targetPos.x - pos.x
	local dy = targetPos.y - pos.y
	local ndx = dx > 0 and 1 or (dx < 0 and -1 or 0)
	local ndy = dy > 0 and 1 or (dy < 0 and -1 or 0)

	-- Check tiles in the direction of the target (primary + orthogonal)
	local tilesToCheck = {}
	if ndx ~= 0 or ndy ~= 0 then
		table.insert(tilesToCheck, Position(pos.x + ndx, pos.y + ndy, pos.z))
	end
	if ndx ~= 0 then
		table.insert(tilesToCheck, Position(pos.x + ndx, pos.y, pos.z))
	end
	if ndy ~= 0 then
		table.insert(tilesToCheck, Position(pos.x, pos.y + ndy, pos.z))
	end

	for _, tilePos in ipairs(tilesToCheck) do
		local tile = Tile(tilePos)
		if tile then
			local items = tile:getItems()
			if items then
				for _, item in ipairs(items) do
					local itemId = item:getId()
					local openId = CLOSED_TO_OPEN_DOOR[itemId]
					if openId then
						item:transform(openId)
						logger.info("[Bot] " .. player:getName() ..
							" opened door at (" .. tilePos.x .. "," .. tilePos.y .. "," .. tilePos.z .. ")")
						return true
					end
				end
			end
		end
	end
	return false
end

function BotSystem.doFlee(player, state, attacker)
	if player:isWalking() then return end

	local pos = player:getPosition()
	local apos = attacker:getPosition()
	local dx = pos.x - apos.x
	local dy = pos.y - apos.y
	local dist = math.max(math.abs(dx), math.abs(dy), 1)
	local fleeX = pos.x + math.floor(dx / dist * BOT_CONFIG.FLEE_DISTANCE)
	local fleeY = pos.y + math.floor(dy / dist * BOT_CONFIG.FLEE_DISTANCE)

	BotSystem.goTo(player, Position(fleeX, fleeY, pos.z))
end

function BotSystem.exitCombat(player, state)
	player:setTarget(nil)
	player:setFollowCreature(nil)

	state.combatDecision = nil
	state.combatStartTime = nil
	state.lastCombatProgress = nil
	state.attackerId = nil
	state.lastAttackerSeen = nil
	state.chaseLastTargetPos = nil
	state.targetLastSameZPos = nil
	state.ignoredAttackerId = nil
	state.ignoredHitBack = false
	state.walkTarget = nil
	state.currentPOI = nil
	state.pvpManaSpent = nil
	state.combatHpCheckTime = nil
	state.combatHpBaseline = nil
	state.combatStalemateCount = nil

	-- Resume hunting if a hunt was in progress (hunt fields preserved during combat)
	if state.huntScriptId then
		state.returningHome = false
		state.returnBreadcrumbs = {}
		state.returnDestination = nil
		state.preCombatPos = nil
		state.zBreadcrumbs = {}
		state.state = BOT_STATE.HUNTING
		BotSystem.castDebug(player, state, "COMBAT EXIT: resuming hunt phase=" .. (state.huntPhase or "?"))
		logger.info("[Bot] " .. player:getName() .. " exiting combat, resuming hunt "
			.. (state.huntScriptId or "?") .. " phase=" .. (state.huntPhase or "?"))
		return
	end

	-- If we took z-transitions during combat, navigate back the way we came
	if state.preCombatPos and state.zBreadcrumbs and #state.zBreadcrumbs > 0 then
		-- Reverse the breadcrumbs so we retrace in opposite order
		local reversed = {}
		for i = #state.zBreadcrumbs, 1, -1 do
			local bc = state.zBreadcrumbs[i]
			table.insert(reversed, {
				-- To return: go to where we arrived (bc.toZ) and use the transition
				-- to get back to where we came from (bc.fromPos.z)
				targetZ = bc.fromPos.z,
				transitionPos = bc.fromPos,  -- the original transition tile
				type = bc.type
			})
		end
		state.returningHome = true
		state.returnBreadcrumbs = reversed
		state.returnDestination = state.preCombatPos
		state.state = BOT_STATE.IDLE
		logger.info("[Bot] " .. player:getName() .. " exiting combat, returning home via "
			.. #reversed .. " z-transition(s)")
	else
		state.returningHome = false
		state.returnBreadcrumbs = {}
		state.returnDestination = nil
		state.state = BOT_STATE.IDLE
		logger.info("[Bot] " .. player:getName() .. " exiting combat (attacker left or dead)")
	end

	state.preCombatPos = nil
	state.zBreadcrumbs = {}
end

-- ============================================================================
-- Cave Encounter & Dispute (NotJev System 1: PK, PARTY, SHARE, LEAVE)
-- ============================================================================

function BotSystem.checkCaveEncounter(player, state)
	if not player or player:isRemoved() or not state then return false end
	if state.state ~= BOT_STATE.HUNTING or state.huntPhase ~= HUNT_PHASE.PATROLLING then
		return false
	end

	-- Check 15-minute dispute cooldown to prevent request overload & FSM freeze
	local now = os.time()
	if now < (state.caveDisputeCooldownUntil or 0) then
		return false
	end

	-- In-flight request protection
	if state.caveDisputeInFlight then
		return false
	end

	-- Don't dispute within 30s of death or inside PZ
	if state.lastDeathTime and (now - state.lastDeathTime) < 30 then return false end
	local pos = player:getPosition()
	local myTile = Tile(pos)
	if myTile and myTile:hasFlag(TILESTATE_PROTECTIONZONE) then return false end

	-- Look for other players/bots on the same screen (same z)
	local spectators = Game.getSpectators(pos, false, true, 7, 7, 5, 5)
	if not spectators or #spectators == 0 then return false end

	local rival = nil
	local myParty = player:getParty()

	for _, creature in ipairs(spectators) do
		if creature ~= player and not creature:isRemoved() and creature:getHealth() > 0 then
			if creature:isPlayer() and not creature:isInGhostMode() then
				local cpos = creature:getPosition()
				if cpos.z == pos.z then
					local cTile = Tile(cpos)
					if cTile and not cTile:hasFlag(TILESTATE_PROTECTIONZONE) then
						-- Skip if they are already in the same party
						if not (myParty and myParty:isMember(creature)) then
							-- Skip if we are already targeting them in PK
							if not (state.state == BOT_STATE.PK_ATTACK and state.pkTarget == creature:getId()) then
								rival = creature
								break
							end
						end
					end
				end
			end
		end
	end

	if not rival then return false end

	-- Rival found! Initiate NotJev dispute evaluation
	state.caveDisputeInFlight = true
	local myGuid = player:getGuid()
	local rivalGuid = rival:getGuid()
	local rivalName = rival:getName()
	local rivalLevel = rival:getLevel()
	local rivalIsPlayer = not (rival.isBotPlayer and rival:isBotPlayer())
	local script = state.huntScriptId and BotHuntData.scripts[state.huntScriptId]
	local caveName = script and script.name or "Cave"
	local arch = BotSystem.getBotArchetype(player, state)

	local payload = {
		bot_profile = {
			guid = myGuid,
			name = player:getName(),
			level = player:getLevel(),
			vocation = player:getVocation():getName(),
			personality = state.personality or 2,
			archetype_id = arch.id,
			archetype_name = arch.name
		},
		rival_name = rivalName,
		rival_level = rivalLevel,
		rival_is_player = rivalIsPlayer,
		cave_name = caveName
	}

	BotSystem.asyncNodePost("/api/decision/dispute", payload, function(res)
		state.caveDisputeInFlight = false
		local p = BotPlayers and BotPlayers[myGuid]
		local s = BotState and BotState[myGuid]
		if not p or p:isRemoved() or not s then return end

		local decision = tostring(res.decision or res.action or "SHARE"):upper()
		local speech = res.speech or ""
		local cooldown = tonumber(res.cooldown_seconds) or 900 -- 15 minutos padrão

		if speech and #speech > 0 then
			p:say(speech, TALKTYPE_SAY)
		end

		if decision == "PK" then
			logger.info(string.format("[CaveDispute] %s (lv%d) DECIDED TO PK %s (lv%d) in %s!",
				p:getName(), p:getLevel(), rivalName, rivalLevel, caveName))
			BotSystem.clearAllTasks(p, s)
			s.state = BOT_STATE.PK_ATTACK
			s.pkTarget = rivalGuid
			s.pkStartTime = os.time()
			s.lastAttackTime = 0
			s.lastCombatProgress = os.time()
			local targetCreature = Creature(rivalGuid)
			if targetCreature and not targetCreature:isRemoved() then
				p:setTarget(targetCreature)
			end
		elseif decision == "PARTY" then
			logger.info(string.format("[CaveDispute] %s (lv%d) decided to PARTY with %s (lv%d) in %s (cooldown 15m).",
				p:getName(), p:getLevel(), rivalName, rivalLevel, caveName))
			s.caveDisputeCooldownUntil = os.time() + cooldown
			local targetCreature = Player(rivalGuid)
			if targetCreature and not p:getParty() then
				pcall(function() p:addPartyMember(targetCreature) end)
			end
		elseif decision == "SHARE" then
			logger.info(string.format("[CaveDispute] %s (lv%d) decided to SHARE cave %s with %s (15m cooldown).",
				p:getName(), p:getLevel(), caveName, rivalName))
			-- Aplica o cooldown rígido de 15 minutos: continuam caçando seus waypoints
			s.caveDisputeCooldownUntil = os.time() + cooldown
		elseif decision == "LEAVE" then
			logger.info(string.format("[CaveDispute] %s (lv%d) decided to LEAVE cave %s to avoid %s.",
				p:getName(), p:getLevel(), caveName, rivalName))
			s.caveDisputeCooldownUntil = os.time() + 300
			if s.huntScriptId then
				BotHuntData.releaseHunt(s.huntScriptId, p:getGuid())
				s.huntScriptId = nil
			end
			BotSystem.tryStartHunt(p, s)
		end
	end, function()
		-- Fallback if service times out: apply 15m cooldown to avoid spamming
		state.caveDisputeInFlight = false
		state.caveDisputeCooldownUntil = os.time() + 900
	end)

	return false
end

-- ============================================================================
-- Vigilante: attack visible PKers (white skull or higher)
-- ============================================================================

function BotSystem.checkAttackPKer(player, state)
	-- Already in combat/PK — don't interrupt
	if state.state == BOT_STATE.COMBAT or state.state == BOT_STATE.FLEEING
		or state.state == BOT_STATE.PK_ATTACK then return end

	-- Throttle: only scan every 2 seconds
	local now = os.time()
	if state.lastPKerScanTime and (now - state.lastPKerScanTime) < 2 then return end
	state.lastPKerScanTime = now

	-- Don't attack within 60 seconds of respawning from death
	if state.lastDeathTime and now - state.lastDeathTime < 60 then return end

	-- Check own PZ status — don't attack from inside PZ
	local myTile = Tile(player:getPosition())
	if myTile and myTile:hasFlag(TILESTATE_PROTECTIONZONE) then return end

	local pos = player:getPosition()
	local spectators = Game.getSpectators(pos, false, true, 7, 7, 5, 5)
	if not spectators or #spectators == 0 then return end

	local botLevel = player:getLevel()

	-- Build set of currently visible PKers (skull >= 3, same z, not in PZ)
	local visiblePKerIds = {}
	local newPKers = {}  -- PKers we haven't rolled for yet
	for _, creature in ipairs(spectators) do
		if creature ~= player and not creature:isRemoved() and creature:getHealth() > 0 then
			-- Skip invisible/ghost mode (GOD/GM)
			if creature:isInGhostMode() then goto vigilante_continue end

			local skull = creature:getSkull()
			if skull and skull >= 3 then
				-- Skip admin/GM accounts
				local pp = Player(creature:getId())
				if pp then
					local group = pp:getGroup()
					if group and group:getAccess() then goto vigilante_continue end
				end

				local tTile = Tile(creature:getPosition())
				if tTile and not tTile:hasFlag(TILESTATE_PROTECTIONZONE) then
					local cpos = creature:getPosition()
					if cpos.z == pos.z then
						local cid = creature:getId()
						visiblePKerIds[cid] = true
						if not state.seenPKers[cid] then
							table.insert(newPKers, creature)
						else
							-- Already seen — update last visible timestamp
							state.seenPKers[cid] = os.time()
						end
					end
				end
			end
		end
		::vigilante_continue::
	end

	-- Clean up memory: only remove PKers who left screen AND 60 seconds have passed
	for cid, lastSeen in pairs(state.seenPKers) do
		if not visiblePKerIds[cid] then
			if os.time() - lastSeen >= 60 then
				state.seenPKers[cid] = nil
			end
		end
	end

	-- Roll 5% for each NEW PKer (ones we haven't seen before in this window)
	for _, pker in ipairs(newPKers) do
		local cid = pker:getId()
		local shouldRoll = true

		-- Level-based ignore: if bot outlevels PKer by 6x, don't bother attacking
		local pkerLevel = 0
		local pp = Player(cid)
		if pp then pkerLevel = pp:getLevel() end
		if pkerLevel > 0 and botLevel >= pkerLevel * 6 then
			-- Too weak to care about — remember and skip
			state.seenPKers[cid] = os.time()
			shouldRoll = false
		end

		if shouldRoll then
			if math.random(1, 20) == 1 then
				-- Attack this PKer
				state.state = BOT_STATE.COMBAT
				state.combatDecision = "fight"
				state.combatStartTime = os.time()
				state.attackerId = cid
				state.lastAttackerSeen = os.time()
				state.walkTarget = nil
				state.currentPOI = nil

				if math.random(1, 2) == 1 then
					BotSystem.sayRandom(player, state, "combat")
				end

				local targetName = pker:getName() or "unknown"
				logger.info("[Bot] " .. player:getName() .. " (lv" .. botLevel
					.. ") vigilante attacking PKer " .. targetName .. " (lv" .. pkerLevel .. ")")
				return
			else
				-- Remember: we decided NOT to attack this PKer (with timestamp)
				state.seenPKers[cid] = os.time()
			end
		end
	end
end

-- (Random PK handled by C++ BotEngine::checkRandomPK in bot_engine.cpp)

function BotSystem.doPKAttack(player, state)
	-- Use lastCombatProgress for timeout (updated each spell cast), not static pkStartTime
	local lastProgress = state.lastCombatProgress or state.pkStartTime
	if os.time() - lastProgress > BOT_CONFIG.PK_TIMEOUT then
		BotSystem.exitPK(player, state)
		return
	end

	local target = Creature(state.pkTarget)
	if not target or target:isRemoved() or target:getHealth() <= 0 then
		BotSystem.exitPK(player, state)
		return
	end

	local pos = player:getPosition()
	local tpos = target:getPosition()

	-- PZ safety: stop attacking if target reached protection zone
	local tTile = Tile(tpos)
	if tTile and tTile:hasFlag(TILESTATE_PROTECTIONZONE) then
		BotSystem.exitPK(player, state)
		return
	end

	-- PZ safety: stop if bot itself is in PZ (shouldn't happen with proper skull, but safety net)
	local myTile = Tile(pos)
	if myTile and myTile:hasFlag(TILESTATE_PROTECTIONZONE) then
		BotSystem.exitPK(player, state)
		return
	end

	-- Leash distance check (same z only — allow z-pursuit through stairs)
	if pos.z == tpos.z then
		local dist = math.max(math.abs(pos.x - tpos.x), math.abs(pos.y - tpos.y))
		if dist > 10 then
			BotSystem.exitPK(player, state)
			return
		end
	end

	-- Set target (server auto-attacks with weapon) + cast spell
	if player:getTarget() ~= target then
		player:setTarget(target)
	end
	BotSystem.doCastSpell(player, state, target)
	BotSystem.chaseTarget(player, state, target)  -- chaseTarget handles z-pursuit
end

function BotSystem.exitPK(player, state)
	local oldTarget = state.pkTarget
	state.pkTarget = nil
	state.pkStartTime = nil
	state.chaseLastTargetPos = nil
	state.targetLastSameZPos = nil
	state.walkTarget = nil
	state.currentPOI = nil
	state.pvpManaSpent = nil
	state.combatHpCheckTime = nil
	state.combatHpBaseline = nil
	state.combatStalemateCount = nil
	player:setTarget(nil)
	player:setFollowCreature(nil)

	-- Check if anyone is still attacking us — if so, enter COMBAT instead of IDLE
	-- This prevents the "ignore weak attacker" roll from immediately disengaging
	local pos = player:getPosition()
	local spectators = Game.getSpectators(pos, false, false, 7, 7, 5, 5)
	local nearbyAttacker = nil
	if spectators then
		for _, creature in ipairs(spectators) do
			if creature ~= player and not creature:isRemoved() and creature:getHealth() > 0
				and Player(creature:getId()) then
				local target = creature:getTarget()
				if target and target:getId() == player:getId() then
					nearbyAttacker = creature
					break
				end
			end
		end
	end

	if nearbyAttacker then
		-- Someone is still attacking us — enter COMBAT to fight back
		state.state = BOT_STATE.COMBAT
		state.combatDecision = "fight"
		state.combatStartTime = os.time()
		state.lastCombatProgress = os.time()
		state.attackerId = nearbyAttacker:getId()
		local cpos = player:getPosition()
		state.preCombatPos = { x = cpos.x, y = cpos.y, z = cpos.z }
		state.zBreadcrumbs = {}
		logger.info("[Bot] " .. player:getName() .. " PK ended, still under attack by "
			.. nearbyAttacker:getName() .. " — entering COMBAT")
	else
		state.state = BOT_STATE.IDLE
	end
end

-- ============================================================================
-- POI Selection: weighted, multi-city, with fallback
-- ============================================================================

function BotSystem.pickNextPOI(player, state)
	local town = player:getTown()
	if not town then return nil end
	local townId = town:getId()
	local walkZ = CITY_WALK_Z[townId] or town:getTemplePosition().z

	-- Build IDLE POI list dynamically: depot, depot_outside, boat, temple
	-- (Shops and NPCs excluded from IDLE rotation — only visited during hunts)
	local idlePois = {}

	-- Find depot and temple from CITY_POIS
	local pois = CITY_POIS[townId]
	local depotPoi = nil
	local templePoi = nil
	if pois then
		for _, poi in ipairs(pois) do
			if poi.type == "depot" and not depotPoi then
				depotPoi = poi
			elseif poi.type == "temple" and not templePoi then
				templePoi = poi
			end
		end
	end

	-- Temple POI (always available via town data)
	if templePoi then
		table.insert(idlePois, {
			name = templePoi.name,
			pos = Position(templePoi.pos.x, templePoi.pos.y, walkZ),
			type = "temple",
		})
	else
		local tp = town:getTemplePosition()
		table.insert(idlePois, {
			name = town:getName() .. " Temple",
			pos = Position(tp.x, tp.y, walkZ),
			type = "temple",
		})
	end

	-- Depot POI (inside)
	if depotPoi then
		table.insert(idlePois, {
			name = depotPoi.name,
			pos = Position(depotPoi.pos.x, depotPoi.pos.y, walkZ),
			type = "depot",
		})
		-- Depot outside variant (±3-5 tiles from depot)
		local ox = math.random(-5, 5)
		local oy = math.random(-5, 5)
		if math.abs(ox) < 3 then ox = ox > 0 and 3 or -3 end
		if math.abs(oy) < 3 then oy = oy > 0 and 3 or -3 end
		table.insert(idlePois, {
			name = depotPoi.name .. " (outside)",
			pos = Position(depotPoi.pos.x + ox, depotPoi.pos.y + oy, walkZ),
			type = "depot_outside",
		})
	end

	-- Boat POI (use walk z for accessibility — bot hangs out near the dock area)
	local boatPos = BOAT_POSITIONS[townId]
	if boatPos then
		table.insert(idlePois, {
			name = town:getName() .. " Boat",
			pos = Position(boatPos.x, boatPos.y, walkZ),
			type = "boat",
		})
	end

	if #idlePois == 0 then
		return BotSystem.generateFallbackPOI(player)
	end

	-- Build candidate list excluding recently visited (by POI name)
	local visitedNames = state.visitedPOIs or {}
	local isVisited = {}
	for _, name in ipairs(visitedNames) do
		isVisited[name] = true
	end

	local candidates = {}
	local totalWeight = 0
	for _, poi in ipairs(idlePois) do
		if not isVisited[poi.name] then
			local w = POI_TYPE_WEIGHTS[poi.type] or 10
			if w > 0 then
				table.insert(candidates, { poi = poi, weight = w })
				totalWeight = totalWeight + w
			end
		end
	end

	-- If all visited recently, reset
	if #candidates == 0 or totalWeight == 0 then
		state.visitedPOIs = {}
		candidates = {}
		totalWeight = 0
		for _, poi in ipairs(idlePois) do
			local w = POI_TYPE_WEIGHTS[poi.type] or 10
			if w > 0 then
				table.insert(candidates, { poi = poi, weight = w })
				totalWeight = totalWeight + w
			end
		end
	end

	if #candidates == 0 or totalWeight == 0 then
		return BotSystem.generateFallbackPOI(player)
	end

	-- Weighted random selection
	local roll = math.random(1, totalWeight)
	local cumulative = 0
	local pick = candidates[1]
	for _, c in ipairs(candidates) do
		cumulative = cumulative + c.weight
		if roll <= cumulative then
			pick = c
			break
		end
	end

	-- Track visited by name (keep last 3 — smaller pool now)
	table.insert(visitedNames, pick.poi.name)
	if #visitedNames > 3 then
		table.remove(visitedNames, 1)
	end
	state.visitedPOIs = visitedNames

	return pick.poi
end

function BotSystem.generateFallbackPOI(player)
	local town = player:getTown()
	if not town then return nil end
	local tp = town:getTemplePosition()
	local walkZ = CITY_WALK_Z[town:getId()] or tp.z
	return {
		name = town:getName() .. " Temple",
		pos = Position(tp.x, tp.y, walkZ),
		type = "temple",
	}
end

-- ============================================================================
-- Spell Learning & Selection
-- ============================================================================

-- Learn all attack + heal spells appropriate for bot's vocation
function BotSystem.learnAllSpells(player)
	local voc = player:getVocation()
	local baseVoc = voc and voc:getBaseId() or 4
	local count = 0

	local atkSpells = BOT_SPELLS[baseVoc]
	if atkSpells then
		for _, spell in ipairs(atkSpells) do
			player:learnSpell(spell.name)
			count = count + 1
		end
	end

	local healSpells = BOT_HEAL_SPELLS[baseVoc]
	if healSpells then
		for _, spell in ipairs(healSpells) do
			player:learnSpell(spell.name)
			count = count + 1
		end
	end

	-- Learn universal spells
	player:learnSpell("exura")
	player:learnSpell("exura vita")

	logger.info("[Bot] " .. player:getName() .. " learned " .. count .. " spells (voc=" .. baseVoc .. ")")
end

-- Throwing weapon item IDs that need stacking (paladin ammo)
local THROWING_WEAPON_IDS = {
	[3287] = true,   -- throwing star
	[3298] = true,   -- throwing knife
	[3302] = true,   -- snowball
	[7367] = true,   -- enchanted spear
	[7368] = true,   -- assassin star
	[7378] = true,   -- royal spear
	[11230] = true,  -- viper star
	[25757] = true,  -- prismatic bolt
	[25759] = true,  -- royal star
	[14251] = true,  -- hunting spear
}
local THROWING_WEAPON_COUNT = 100  -- Stack count (ammo never consumed for bots via C++ skip)

local FALLBACK_STARTER_LOADOUTS = {
	[1] = { slot_head = 3351, slot_armor = 3357, slot_legs = 3557, slot_feet = 3552, slot_right = 3074, slot_left = 3425 }, -- Sorcerer: Wand of Vortex + Plate Set + Dwarven Shield
	[2] = { slot_head = 3351, slot_armor = 3357, slot_legs = 3557, slot_feet = 3552, slot_right = 3066, slot_left = 3425 }, -- Druid: Snakebite Rod + Plate Set + Dwarven Shield
	[3] = { slot_head = 3351, slot_armor = 3357, slot_legs = 3557, slot_feet = 3552, slot_right = 7378, slot_left = 3425 }, -- Paladin: Royal Spear + Plate Set + Dwarven Shield
	[4] = { slot_head = 3351, slot_armor = 3357, slot_legs = 3557, slot_feet = 3552, slot_right = 3271, slot_left = 3425 }, -- Knight: Spike Sword + Plate Set + Dwarven Shield
}

-- Equip bot with best gear for their level and vocation.
-- Efficient: skips slots where the correct item is already equipped.
function BotSystem.equipBot(player)
	local level = math.min(player:getLevel(), 500)
	local voc = player:getVocation()
	local baseVoc = voc and voc:getBaseId() or 4

	-- Ensure bot always has a backpack equipped for loot
	if CONST_SLOT_BACKPACK and not player:getSlotItem(CONST_SLOT_BACKPACK) then
		pcall(function() player:setSlotItem(CONST_SLOT_BACKPACK, 2854, 1) end)
	end

	-- Ensure bot always carries essential exploration tools: machete (3308), rope (3003), shovel (3457)
	pcall(function()
		if not player:getItemCount(3308) or player:getItemCount(3308) == 0 then
			player:addItem(3308, 1, false)
		end
		if not player:getItemCount(3003) or player:getItemCount(3003) == 0 then
			player:addItem(3003, 1, false)
		end
		if not player:getItemCount(3457) or player:getItemCount(3457) == 0 then
			player:addItem(3457, 1, false)
		end
	end)

	local guid = player:getGuid()
	local state = BotState and BotState[guid]
	local personality = state and state.personality or ((guid % 5) + 1)
	local loadout = BotEquipmentData and BotEquipmentData.getLoadout and BotEquipmentData.getLoadout(level, baseVoc, personality)
	if not loadout then
		loadout = FALLBACK_STARTER_LOADOUTS[baseVoc] or FALLBACK_STARTER_LOADOUTS[4]
	end
	if not loadout then
		logger.warn("[Bot] " .. player:getName() .. " no equipment loadout for lv=" .. level .. " voc=" .. baseVoc)
		return
	end

	local slotMap = {
		{field = "slot_head",  slot = CONST_SLOT_HEAD,  name = "head"},
		{field = "slot_armor", slot = CONST_SLOT_ARMOR, name = "armor"},
		{field = "slot_legs",  slot = CONST_SLOT_LEGS,  name = "legs"},
		{field = "slot_feet",  slot = CONST_SLOT_FEET,  name = "feet"},
		{field = "slot_right", slot = CONST_SLOT_LEFT,  name = "weapon"},  -- DB slot_right = weapon -> left hand
		{field = "slot_left",  slot = CONST_SLOT_RIGHT, name = "shield"},  -- DB slot_left = shield -> right hand
	}

	local equipped = 0
	local updated = 0
	local failed = {}
	for _, s in ipairs(slotMap) do
		local itemId = loadout[s.field]
		if itemId and itemId > 0 then
			-- Check if already equipped correctly
			local current = player:getSlotItem(s.slot)
			local currentId = current and current:getId() or 0
			if currentId == itemId then
				equipped = equipped + 1
			else
				-- Need to equip or replace
				local count = THROWING_WEAPON_IDS[itemId] and THROWING_WEAPON_COUNT or 1
				local ok = player:setSlotItem(s.slot, itemId, count)
				if ok then
					equipped = equipped + 1
					updated = updated + 1
				else
					table.insert(failed, s.name .. "=" .. itemId)
				end
			end
		end
	end

	if #failed > 0 then
		logger.warn("[Bot] " .. player:getName() .. " equip FAILED for: " .. table.concat(failed, ", ")
			.. " (lv=" .. level .. " voc=" .. baseVoc .. ")")
	end
	if updated > 0 then
		logger.info("[Bot] " .. player:getName() .. " equipped " .. equipped .. "/6 items, " .. updated .. " updated"
			.. " (lv=" .. level .. " voc=" .. baseVoc .. ")")
	end
end

-- Select best available attack spell for the given target
-- Returns the spell table entry or nil
function BotSystem.selectAttackSpell(player, state, target)
	local voc = player:getVocation()
	local baseVoc = voc and voc:getBaseId() or 4
	local level = player:getLevel()
	local spells = BOT_SPELLS[baseVoc]
	if not spells then return nil end

	local pos = player:getPosition()
	local tpos = target:getPosition()
	local dist = math.max(math.abs(pos.x - tpos.x), math.abs(pos.y - tpos.y))
	local now = os.time()

	-- Determine if target is a player (for PvP-only spells like SD rune)
	local targetIsPlayer = Player(target:getId()) ~= nil
	-- For monsters: SD rune usable only if monster HP >= 5x bot's max HP AND not immune to death
	local targetIsStrongMonster = false
	if not targetIsPlayer then
		local mon = Monster(target:getId())
		if mon then
			local monHp = mon:getMaxHealth()
			local botHp = Player(player:getId()) and player:getMaxHealth() or 1
			if monHp >= botHp * 5 then
				-- Check death immunity via monster type element map
				-- getElementList() returns table[combatType] = absorbPercent
				local mtype = mon:getType()
				local elementMap = mtype and mtype:getElementList() or nil
				local deathAbsorb = elementMap and elementMap[COMBAT_DEATHDAMAGE] or 0
				if deathAbsorb < 100 then
					targetIsStrongMonster = true
				end
			end
		end
	end

	-- Collect all available spells (off cooldown, in range, level met)
	local available = {}
	for i = 1, #spells do
		local spell = spells[i]
		if level >= spell.level then
			-- pvpOnly spells (SD rune): only vs players or strong non-immune monsters
			if spell.pvpOnly and not targetIsPlayer and not targetIsStrongMonster then
				-- skip this spell
			else
				local cdKey = "spellCd_" .. spell.name
				if not state[cdKey] or now >= state[cdKey] then
					if spell.range == 0 or dist <= spell.range then
						available[#available + 1] = spell
					end
				end
			end
		end
	end

	if #available == 0 then return nil end

	-- Pick randomly from available spells
	return available[math.random(#available)]
end

-- ============================================================================
-- Combat: Attack and Healing
-- ============================================================================

-- Cast a spell on the current target.
-- Weapon auto-attacks are handled by the server via setAttackedCreature.
-- This function only handles spell casting: select a random available spell and cast it.
-- The spell system uses getAttackedCreature() for targeting automatically.
function BotSystem.doCastSpell(player, state, target)
	local now = os.time()
	if now - state.lastAttackTime < BOT_CONFIG.ATTACK_COOLDOWN then return end

	local pos = player:getPosition()
	local tpos = target:getPosition()
	local dist = math.max(math.abs(pos.x - tpos.x), math.abs(pos.y - tpos.y))

	-- Must be on same floor with line of sight for spells
	if pos.z ~= tpos.z then return end
	if not pos:isSightClear(tpos, true) then
		state.spellLOSFailCount = (state.spellLOSFailCount or 0) + 1
		BotSystem.combatLog(player, state, "HUNT-SPELL-BLOCKED: noLOS to " .. target:getName()
			.. " dist=" .. dist
			.. " at (" .. tpos.x .. "," .. tpos.y .. "," .. tpos.z .. ")"
			.. " from (" .. pos.x .. "," .. pos.y .. "," .. pos.z .. ")"
			.. " fails=" .. state.spellLOSFailCount)
		-- Still count as combat progress since weapon auto-attack may still work
		-- (server checks LOS independently for weapon attacks)
		state.lastCombatProgress = now
		return
	end

	state.spellLOSFailCount = 0

	-- Select a random available spell (level-gated, cooldown-aware, range-checked)
	local spell = BotSystem.selectAttackSpell(player, state, target)
	if not spell then
		-- No spell available but weapon auto-attack is running via setTarget
		state.lastCombatProgress = now
		return
	end

	-- Ensure mana for casting (PvP: mana budget is limited so bots eventually run dry and die)
	if player:getMana() < player:getMaxMana() * 0.3 then
		local targetIsPlayer = Player(target:getId()) ~= nil
		if targetIsPlayer then
			local maxMana = player:getMaxMana()
			local budget = maxMana * 2.5  -- 5 refills of ~50% each
			state.pvpManaSpent = state.pvpManaSpent or 0
			if state.pvpManaSpent < budget then
				player:addMana(maxMana)
				state.pvpManaSpent = state.pvpManaSpent + maxMana
			end
		else
			player:addMana(player:getMaxMana())
		end
	end

	-- For isRune spells (SD): skip castSpell (no actual spell to cast), apply damage directly
	local ok = false
	if spell.isRune then
		ok = true  -- rune always "succeeds"
		-- Visual: show projectile + effect
		if spell.effect then
			tpos:sendMagicEffect(spell.effect)
		end
	else
		-- Cast through real spell system — spell uses attackedCreature for targeting
		ok = player:castSpell(spell.name, target)
	end

	if ok then
		state.lastAttackTime = now
		state.lastCombatProgress = now
		state["spellCd_" .. spell.name] = now + spell.cd

		-- Standard spell combat handles monster damage via the spell system.
		-- For PvP (bot vs player/bot), spell damage is blocked by Tibia PvP rules,
		-- so apply damage directly using the addHealth PvP bypass (nullptr attacker).
		-- Also needed for isRune spells which have no real spell to cast.
		local targetPlayer = Player(target:getId())
		if targetPlayer or spell.isRune then
			local baseDmg = spell.baseDmg or 20
			local level = player:getLevel()
			local dmg = math.floor(baseDmg * (1 + level / 100) * (0.8 + math.random() * 0.4))
			target:addHealth(-dmg, spell.combatType or COMBAT_PHYSICALDAMAGE, player)
			BotSystem.combatLogForce(player, state, "SPELL-DMG: " .. spell.name
				.. " -" .. dmg .. "hp to " .. target:getName()
				.. " (base=" .. baseDmg .. " lv=" .. level .. ")"
				.. (spell.isRune and " [rune]" or " [pvp-bypass]"))
		end

		BotSystem.combatLog(player, state, "HUNT-SPELL: " .. spell.name
			.. " ok=true target=" .. target:getName() .. " dist=" .. dist)
	else
		-- Spell failed but weapon auto-attack still running
		state.lastCombatProgress = now
		state.lastAttackTime = now
		BotSystem.combatLog(player, state, "HUNT-SPELL: " .. spell.name
			.. " ok=false target=" .. target:getName() .. " dist=" .. dist)
	end
end

function BotSystem.doHealing(player, state)
	-- PvP mana budget exhausted — stop healing entirely (simulates running out of mana for heals)
	local inPvP = false
	if state.state == BOT_STATE.PK_ATTACK then
		inPvP = true
	elseif (state.state == BOT_STATE.COMBAT or state.state == BOT_STATE.FLEEING) and state.attackerId then
		inPvP = Player(state.attackerId) ~= nil
	end
	if inPvP and (state.pvpManaSpent or 0) >= (player:getMaxMana() * 2.5) then
		return  -- No mana left to heal — bot will die from damage
	end

	local hp = player:getHealth()
	local maxHp = player:getMaxHealth()
	if (hp / math.max(maxHp, 1)) * 100 > BOT_CONFIG.HEAL_THRESHOLD_PERCENT then
		return
	end

	local now = os.time()
	if now - state.lastHealTime < BOT_CONFIG.HEAL_COOLDOWN then return end

	-- Select best heal spell (level-gated, cooldown-aware)
	local voc = player:getVocation()
	local baseVoc = voc and voc:getBaseId() or 4
	local level = player:getLevel()
	local healSpells = BOT_HEAL_SPELLS[baseVoc]
	local bestHeal = nil

	if healSpells then
		for i = #healSpells, 1, -1 do
			local spell = healSpells[i]
			if level >= spell.level then
				local cdKey = "healCd_" .. spell.name
				if not state[cdKey] or now >= state[cdKey] then
					bestHeal = spell
					break
				end
			end
		end
	end

	if not bestHeal then
		bestHeal = {name = "exura", heal = 80, cd = 1}
	end

	state.lastHealTime = now
	state["healCd_" .. bestHeal.name] = now + bestHeal.cd

	-- Scale heal amount by level and magic level
	local magicLevel = player:getMagicLevel()
	local healAmount = bestHeal.heal + math.floor(level / 5 + magicLevel * 2)
	local pos = player:getPosition()

	player:say(bestHeal.name, TALKTYPE_MONSTER_SAY)
	pos:sendMagicEffect(CONST_ME_MAGIC_BLUE)
	player:addHealth(healAmount)
	-- PvP mana budget: track total mana added, stop when budget exhausted
	local inPvP = false
	if state.state == BOT_STATE.PK_ATTACK then
		inPvP = true
	elseif (state.state == BOT_STATE.COMBAT or state.state == BOT_STATE.FLEEING) and state.attackerId then
		inPvP = Player(state.attackerId) ~= nil
	end
	local manaRegen = math.floor(level * 2 + 50)
	if inPvP then
		local maxMana = player:getMaxMana()
		local budget = maxMana * 2.5  -- 5 refills of ~50% each
		state.pvpManaSpent = state.pvpManaSpent or 0
		if state.pvpManaSpent < budget then
			player:addMana(manaRegen)
			state.pvpManaSpent = state.pvpManaSpent + manaRegen
		end
		-- Once budget exhausted, no more mana regen — bot drains and dies
	else
		player:addMana(manaRegen)
	end
end

-- ============================================================================
-- Chat
-- ============================================================================

function BotSystem.sayRandom(player, state, category)
	local now = os.time()
	if now - state.lastChatTime < 60 then return end
	state.lastChatTime = now

	local phrases = BOT_CHAT[category] or BOT_CHAT.idle
	if #phrases > 0 then
		player:say(phrases[math.random(1, #phrases)], TALKTYPE_SAY)
	end
end

-- ============================================================================
-- Population Helpers
-- ============================================================================

function BotSystem.countActiveBots()
	local count = 0
	for _, active in pairs(BotActive) do
		if active then count = count + 1 end
	end
	return count
end

function BotSystem.getInactiveBots()
	local inactive = {}
	for guid, active in pairs(BotActive) do
		if not active and BotPlayers[guid] and not BotPlayers[guid]:isRemoved() then
			table.insert(inactive, guid)
		end
	end
	return inactive
end

-- ============================================================================
-- Hunting System
-- ============================================================================

-- Try to start a hunt: find eligible scripts, reserve one, begin travel
function BotSystem.tryStartHunt(player, state)
	-- Ensure bot's skills meet archetype criteria before hunting (Rusher skips, Cauteloso trains)
	if BotSystem.getSkillTargetInfo then
		local skillInfo = BotSystem.getSkillTargetInfo(player)
		if skillInfo and BotSystem.shouldBotTrain(player, state, skillInfo) then
			if BotSystem.startStatueTraining(player, state, false) then
				return true
			end
		end
	end

	local arch = BotSystem.getBotArchetype(player, state)
	local botData = {
		townId = player:getTown() and player:getTown():getId() or 8,
	}
	local eligible = BotHuntData.findHuntsForBot(player, botData, arch, state)
	if #eligible == 0 then
		return false
	end

	-- Pick from top candidates (prefer same-town hunts)
	local pick = nil
	-- Try same-town first
	for _, entry in ipairs(eligible) do
		if entry.script.town_id == botData.townId then
			pick = entry
			break
		end
	end
	-- Fallback to any eligible
	if not pick then
		pick = eligible[math.random(1, math.min(5, #eligible))]
	end

	-- Reserve the hunt (1-bot-per-spawn)
	local scriptId = pick.scriptId
	if not BotHuntData.reserveHunt(scriptId, player:getGuid()) then
		return false
	end

	-- Roll hunt duration
	local duration = math.random(BOT_CONFIG.HUNT_DURATION_MIN, BOT_CONFIG.HUNT_DURATION_MAX)

	-- Set up hunt state
	state.huntScriptId = scriptId
	state.huntTownId = pick.script.town_id
	state.huntStartTime = os.time()
	state.huntEndTime = os.time() + duration
	state.huntKillCount = 0
	state.huntMonsterTarget = nil
	state.huntWaypointSkipCount = 0
	state.huntLastPos = nil
	state.huntTargets = BotHuntData.getTargets(scriptId)

	-- If hunt is in a different town, travel there first
	if pick.script.town_id ~= botData.townId then
		-- Check if reachable
		local destinations = TRAVEL_DESTINATIONS[botData.townId]
		if destinations then
			local canReach = false
			for _, destId in ipairs(destinations) do
				if destId == pick.script.town_id then
					canReach = true
					break
				end
			end
			if not canReach then
				-- Can't reach this town directly — release and skip
				BotHuntData.releaseHunt(scriptId, player:getGuid())
				state.huntScriptId = nil
				return false
			end
		end
		-- Travel to hunt town via boat first, then begin hunt
		state.walkTarget = nil
		state.currentPOI = nil
		state.pendingHuntAfterTravel = true
		local destTownName = (pick.script.town_name or ("town " .. pick.script.town_id)):lower()
		BotSystem.castDebug(player, state, "HUNT START: traveling to " .. (pick.script.town_name or "?")
			.. " for " .. pick.script.name
			.. " (duration=" .. math.floor(duration / 60) .. "m)")
		logger.info("[Bot] " .. player:getName() .. " traveling to " .. (pick.script.town_name or "?")
			.. " for hunt: " .. pick.script.name
			.. " (duration=" .. math.floor(duration / 60) .. "m)")
		BotSystem.startCavebotTravel(player, state, pick.script.town_id, destTownName)
		return true
	end

	-- Same town: travel directly to spawn (skip pre-hunt city wandering)
	BotSystem.castDebug(player, state, "HUNT START: " .. pick.script.name
		.. " in " .. pick.script.town_name
		.. " (duration=" .. math.floor(duration / 60) .. "m"
		.. " targets=" .. #(state.huntTargets or {}) .. ")")
	BotSystem.beginHuntPhase(player, state, HUNT_PHASE.TRAVEL_TO)
	logger.info("[Bot] " .. player:getName() .. " starting hunt: " .. pick.script.name
		.. " in " .. pick.script.town_name
		.. " (duration=" .. math.floor(duration / 60) .. "m)")
	return true
end

-- Begin a hunt phase (travel_to, patrolling, leaving, resupplying)
-- Phase name lookup (hoisted out of tick loop)
local HUNT_PHASE_NAMES = {
	[HUNT_PHASE.PREPARING] = "PREPARING",
	[HUNT_PHASE.TRAVEL_TO] = "TRAVEL_TO",
	[HUNT_PHASE.PATROLLING] = "PATROLLING",
	[HUNT_PHASE.LEAVING] = "LEAVING",
	[HUNT_PHASE.RESUPPLYING] = "RESUPPLYING",
}

-- Resolve phase waypoints, automatically detecting and swapping inverted travel_to/hunt_patrol
-- in scripts (e.g. 1381-1384) where underground cave patrol was imported into travel_to.
function BotSystem.getResolvedHuntWaypoints(player, scriptId, phaseKey)
	local travelTo = BotHuntData.getPhaseWaypoints(scriptId, "travel_to") or {}
	local patrol = BotHuntData.getPhaseWaypoints(scriptId, "hunt_patrol") or {}

	local surfaceZ = BotSystem.getExpectedZ(player)
	local travelUnderground = 0
	for _, wp in ipairs(travelTo) do
		if wp.pos_z and wp.pos_z > surfaceZ then
			travelUnderground = travelUnderground + 1
		end
	end
	local patrolSurface = 0
	for _, wp in ipairs(patrol) do
		if wp.pos_z and wp.pos_z == surfaceZ then
			patrolSurface = patrolSurface + 1
		end
	end

	local isSwapped = (#travelTo >= 25 and travelUnderground / #travelTo >= 0.8
		and #patrol >= 5 and patrolSurface / #patrol >= 0.6)

	if isSwapped then
		if phaseKey == "travel_to" then
			local resolved = {}
			for i = 1, #patrol do
				resolved[#resolved + 1] = patrol[i]
			end
			-- If original travelTo started with the cave entrance hole on surfaceZ, append it
			if travelTo[1] and travelTo[1].pos_z == surfaceZ then
				resolved[#resolved + 1] = travelTo[1]
			end
			return resolved
		elseif phaseKey == "hunt_patrol" then
			local resolved = {}
			local startIdx = (travelTo[1] and travelTo[1].pos_z == surfaceZ) and 2 or 1
			for i = startIdx, #travelTo do
				resolved[#resolved + 1] = travelTo[i]
			end
			return resolved
		end
	end

	return BotHuntData.getPhaseWaypoints(scriptId, phaseKey)
end

-- Strip embedded city resupply loops (Depot -> Bank -> Depot -> Shop -> Depot)
-- and indoor/underground depot excursions from travel_to waypoints.
function BotSystem.sanitizeTravelWaypoints(player, wps)
	if not wps or #wps <= 3 then return wps end

	local surfaceZ = BotSystem.getExpectedZ(player)

	-- Pass 1: If the route goes into an indoor/underground city building (z ~= surfaceZ)
	-- and returns to surfaceZ at index k, strip the prefix before that return
	-- (keeping the surfaceZ entrance waypoint right before the excursion if nearby).
	local lastReturnIdx = nil
	for k = 2, #wps do
		if wps[k].pos_z == surfaceZ and wps[k - 1].pos_z and wps[k - 1].pos_z ~= surfaceZ then
			-- Verify this isn't emerging from an underground passage far from town
			local prevZPos = wps[k - 1]
			for m = k - 2, 1, -1 do
				if wps[m].pos_z == surfaceZ then
					if math.abs((wps[m].pos_x or 0) - (prevZPos.pos_x or 0)) <= 15
						and math.abs((wps[m].pos_y or 0) - (prevZPos.pos_y or 0)) <= 15 then
						lastReturnIdx = k
					end
					break
				end
			end
			if not lastReturnIdx and k <= 6 then
				lastReturnIdx = k
			end
		end
	end

	local stage1 = {}
	if lastReturnIdx then
		-- Find the surfaceZ entrance waypoint right before the last indoor excursion
		local entranceWp = nil
		local prevZPos = wps[lastReturnIdx - 1]
		for m = lastReturnIdx - 2, 1, -1 do
			if wps[m].pos_z == surfaceZ then
				if math.abs((wps[m].pos_x or 0) - (prevZPos.pos_x or 0)) <= 6
					and math.abs((wps[m].pos_y or 0) - (prevZPos.pos_y or 0)) <= 6 then
					entranceWp = wps[m]
				end
				break
			end
		end
		if entranceWp then
			stage1[#stage1 + 1] = entranceWp
		end
		for i = lastReturnIdx, #wps do
			stage1[#stage1 + 1] = wps[i]
		end
	else
		stage1 = wps
	end

	-- Pass 2: Eliminate self-intersecting surface loops (e.g. Depot -> Shop -> Depot)
	local cleaned = {}
	local i = 1
	while i <= #stage1 do
		local wp = stage1[i]
		local jumpTo = nil
		if wp and wp.pos_x and wp.pos_x > 0 then
			for j = #stage1 - 1, i + 2, -1 do
				local other = stage1[j]
				if other and other.pos_x and other.pos_x > 0 and other.pos_z == wp.pos_z then
					local dx = math.abs(wp.pos_x - other.pos_x)
					local dy = math.abs(wp.pos_y - other.pos_y)
					if dx <= 4 and dy <= 4 then
						jumpTo = j
						break
					end
				end
			end
		end
		if jumpTo then
			i = jumpTo
		end
		cleaned[#cleaned + 1] = stage1[i]
		i = i + 1
	end

	if #cleaned < #wps then
		logger.info("[Bot] " .. player:getName() .. " sanitized travel_to waypoints: "
			.. #wps .. " -> " .. #cleaned .. " (stripped city resupply loops)")
	end
	return cleaned
end

function BotSystem.beginHuntPhase(player, state, phase)
	-- Skip redundant pre-hunt PREPARING city loop; go straight to TRAVEL_TO
	if phase == HUNT_PHASE.PREPARING then
		phase = HUNT_PHASE.TRAVEL_TO
	end

	BotSystem.castDebug(player, state, "Hunt phase: " .. (HUNT_PHASE_NAMES[phase] or tostring(phase)))

	state.huntPhase = phase
	state.huntWaypointIdx = 0
	state.huntWaypointSkipCount = 0
	state.walkTarget = nil
	state.currentPOI = nil
	state.state = BOT_STATE.HUNTING

	if phase == HUNT_PHASE.TRAVEL_TO then
		local rawWps = BotSystem.getResolvedHuntWaypoints(player, state.huntScriptId, "travel_to")
		state.huntWaypoints = BotSystem.sanitizeTravelWaypoints(player, rawWps)
		if not state.huntWaypoints or #state.huntWaypoints == 0 then
			-- No travel_to phase, go straight to patrol
			BotSystem.beginHuntPhase(player, state, HUNT_PHASE.PATROLLING)
			return
		end
	elseif phase == HUNT_PHASE.PATROLLING then
		state.huntWaypoints = BotSystem.getResolvedHuntWaypoints(player, state.huntScriptId, "hunt_patrol")
		if not state.huntWaypoints or #state.huntWaypoints == 0 then
			-- No patrol waypoints, abort
			BotSystem.abortHunt(player, state, "no patrol waypoints")
			return
		end
		logger.info("[Bot] " .. player:getName() .. " entering PATROLLING phase ("
			.. #state.huntWaypoints .. " waypoints)")
	elseif phase == HUNT_PHASE.LEAVING then
		state.huntWaypoints = BotHuntData.getPhaseWaypoints(state.huntScriptId, "travel_from")
		if not state.huntWaypoints or #state.huntWaypoints == 0 then
			-- No travel_from, reverse sanitized travel_to
			local rawTravelTo = BotSystem.getResolvedHuntWaypoints(player, state.huntScriptId, "travel_to")
			local travelTo = BotSystem.sanitizeTravelWaypoints(player, rawTravelTo)
			if travelTo and #travelTo > 0 then
				state.huntWaypoints = {}
				for i = #travelTo, 1, -1 do
					state.huntWaypoints[#state.huntWaypoints + 1] = travelTo[i]
				end
			else
				-- No travel waypoints at all, just end the hunt
				BotSystem.beginHuntPhase(player, state, HUNT_PHASE.RESUPPLYING)
				return
			end
		end
	elseif phase == HUNT_PHASE.RESUPPLYING then
		state.huntWaypoints = nil
		state.resupplyStep = "bank"
		state.resupplyUntil = 0
		state.resupplyWalkTarget = nil
		state.resupplyRoute = nil
		state.routeIdx = nil
		state.routeStuckCount = nil
		state.resupplyStartTime = nil
		state.resupplyDepotTarget = nil
		state.resupplyLastPOI = nil
		-- Teleport back to town if far from city
		local town = player:getTown()
		if town then
			local templePos = town:getTemplePosition()
			local pos = player:getPosition()
			local dist = math.max(math.abs(pos.x - templePos.x), math.abs(pos.y - templePos.y))
			local expectedZ = BotSystem.getExpectedZ(player)
			if dist > 30 or pos.z ~= expectedZ then
				local tpPos = Position(templePos.x, templePos.y, expectedZ)
				player:teleportTo(tpPos)
				logger.info("[Bot] " .. player:getName() .. " teleported to town for resupply ("
					.. tpPos.x .. "," .. tpPos.y .. "," .. tpPos.z .. ")")
			end
		end
	end
end

-- Main hunting dispatch
function BotSystem.doHunting(player, state)
	-- Guard: if we're in HUNTING state but have no hunt phase AND no cavebot command,
	-- fall back to IDLE. This catches bots left in HUNTING after cavebot commands complete.
	if not state.huntPhase and not state.cavebotCommand then
		state.state = BOT_STATE.IDLE
		state.verboseLog = state.verboseLogAutoEnabled or false
		return
	end

	-- Safety timeout
	if state.huntStartTime and os.time() - state.huntStartTime > BOT_CONFIG.HUNT_SAFETY_TIMEOUT then
		BotSystem.castDebug(player, state, "HUNT safety timeout after " .. BOT_CONFIG.HUNT_SAFETY_TIMEOUT .. "s")
		BotSystem.abortHunt(player, state, "safety timeout (" .. BOT_CONFIG.HUNT_SAFETY_TIMEOUT .. "s)")
		return
	end

	-- Heal during hunts (throttled: only check every 5 ticks ~500ms)
	state.healCheckCooldown = (state.healCheckCooldown or 0) - 1
	if state.healCheckCooldown <= 0 then
		state.healCheckCooldown = 5
		BotSystem.doHealing(player, state)
	end
	-- Restore mana (bots have infinite mana) — only check every 10 ticks
	state.manaCheckCooldown = (state.manaCheckCooldown or 0) - 1
	if state.manaCheckCooldown <= 0 then
		state.manaCheckCooldown = 10
		if player:getMana() < player:getMaxMana() * 0.5 then
			player:addMana(player:getMaxMana())
		end
	end

	if state.huntPhase == HUNT_PHASE.PREPARING then
		BotSystem.doHuntResupply(player, state)
	elseif state.huntPhase == HUNT_PHASE.TRAVEL_TO then
		BotSystem.doHuntTravel(player, state, HUNT_PHASE.PATROLLING)
	elseif state.huntPhase == HUNT_PHASE.PATROLLING then
		BotSystem.doHuntPatrol(player, state)
	elseif state.huntPhase == HUNT_PHASE.LEAVING then
		BotSystem.doHuntTravel(player, state, nil) -- nil = go to resupply after
	elseif state.huntPhase == HUNT_PHASE.RESUPPLYING then
		BotSystem.doHuntResupply(player, state)
	end
end

-- Follow waypoints for travel_to or leaving phase
function BotSystem.doHuntTravel(player, state, nextPhase)
	-- If already engaged with a monster or being attacked on the way to/from cave, fight back!
	if state.huntMonsterTarget then
		if BotSystem.scanAndAttackHuntTarget(player, state) then
			return
		end
	else
		local pos = player:getPosition()
		local specs = Game.getSpectators(pos, false, false, 7, 7, 5, 5)
		if specs then
			for _, cr in ipairs(specs) do
				if cr:isMonster() and not cr:isRemoved() and cr:getHealth() > 0 then
					local t = cr:getTarget()
					if t and t:getId() == player:getId() and cr:getPosition().z == pos.z then
						state.huntScanCooldown = 0
						if BotSystem.scanAndAttackHuntTarget(player, state) then
							return
						end
						break
					end
				end
			end
		end
	end

	-- Loot any monster killed on the way
	if BotSystem.processPendingLoot(player, state) then
		return
	end

	if player:isWalking() then return end

	local wps = state.huntWaypoints
	if not wps or #wps == 0 then
		BotSystem.castDebug(player, state, "TRAVEL: no waypoints, advancing phase")
		if nextPhase then
			BotSystem.beginHuntPhase(player, state, nextPhase)
		else
			BotSystem.beginHuntPhase(player, state, HUNT_PHASE.RESUPPLYING)
		end
		return
	end

	-- Advance waypoint index
	local advanced = BotSystem.advanceHuntWaypoint(player, state)
	if advanced == "done" then
		-- Reached end of waypoints
		BotSystem.castDebug(player, state, "TRAVEL: all " .. #wps .. " waypoints done, advancing phase")
		if nextPhase then
			BotSystem.beginHuntPhase(player, state, nextPhase)
		else
			BotSystem.beginHuntPhase(player, state, HUNT_PHASE.RESUPPLYING)
		end
		return
	end

	-- Navigate to current waypoint
	local wp = wps[state.huntWaypointIdx]
	if wp and wp.pos_x and wp.pos_x > 0 then
		local pos = player:getPosition()
		local dist = math.max(math.abs(pos.x - wp.pos_x), math.abs(pos.y - wp.pos_y))
		BotSystem.castDebug(player, state, "TRAVEL: wp " .. state.huntWaypointIdx .. "/" .. #wps
			.. " (" .. wp.pos_x .. "," .. wp.pos_y .. "," .. wp.pos_z .. ")"
			.. " dist=" .. dist .. " type=" .. (wp.waypoint_type or "walk"))
	end
	BotSystem.navigateToHuntWaypoint(player, state)
end

-- Hunt patrol: walk waypoints + scan for monsters + attack
function BotSystem.doHuntPatrol(player, state)
	-- Occasional chat during hunting
	if math.random(1, BOT_CONFIG.CHAT_CHANCE * 2) == 1 then
		BotSystem.sayRandom(player, state, "hunting")
	end

	-- Check if hunt time expired
	if state.huntEndTime and os.time() >= state.huntEndTime then
		local remaining = state.huntEndTime - os.time()
		BotSystem.castDebug(player, state, "PATROL: hunt time expired, kills=" .. (state.huntKillCount or 0)
			.. " cycles=" .. (state.huntCycles or 0) .. ", leaving spawn")
		BotSystem.beginHuntPhase(player, state, HUNT_PHASE.LEAVING)
		return
	end

	-- ALWAYS scan for monsters — even while walking to a waypoint.
	-- This lets bots interrupt movement to chase a target that appears mid-walk.
	if BotSystem.scanAndAttackHuntTarget(player, state) then
		return -- busy fighting or chasing
	end

	-- Loot any recently killed monster before resuming patrol
	if BotSystem.processPendingLoot(player, state) then
		return
	end

	-- Check for cave encounter / dispute (PK, Party, Share, Leave with 15-min cooldown)
	BotSystem.checkCaveEncounter(player, state)

	-- Check waypoint arrival BEFORE navigating (handles proximity-based advancement)
	local advanced = BotSystem.advanceHuntWaypoint(player, state)
	if advanced == "done" then
		-- Loop back to start of patrol
		state.huntWaypointIdx = 0
		state.huntWaypointSkipCount = 0
		state.huntCycles = (state.huntCycles or 0) + 1
		BotSystem.castDebug(player, state, "PATROL: cycle " .. state.huntCycles .. " complete, looping back"
			.. " kills=" .. (state.huntKillCount or 0))
	end

	if player:isWalking() then return end

	-- Navigate to next waypoint
	local wps = state.huntWaypoints
	local idx = state.huntWaypointIdx
	if wps and idx and idx >= 1 and idx <= #wps then
		local wp = wps[idx]
		if wp and wp.pos_x and wp.pos_x > 0 then
			local pos = player:getPosition()
			local dist = math.max(math.abs(pos.x - wp.pos_x), math.abs(pos.y - wp.pos_y))
			BotSystem.castDebug(player, state, "PATROL: navigating to wp " .. idx .. "/" .. #wps
				.. " (" .. wp.pos_x .. "," .. wp.pos_y .. "," .. wp.pos_z .. ")"
				.. " dist=" .. dist .. " type=" .. (wp.waypoint_type or "walk"))
		end
	end
	BotSystem.navigateToHuntWaypoint(player, state)
end

-- Check arrival and advance to next waypoint. Returns "done" if past last, true if advanced, false if not.
function BotSystem.advanceHuntWaypoint(player, state)
	local wps = state.huntWaypoints
	if not wps or #wps == 0 then return "done" end

	local pos = player:getPosition()
	local idx = state.huntWaypointIdx

	-- If we haven't started yet, go to first waypoint
	if idx == 0 then
		state.huntWaypointIdx = 1
		BotSystem.castDebug(player, state, "ADVANCE: starting at wp 1/" .. #wps)
		return true
	end

	-- Check if we've arrived at current waypoint
	if idx <= #wps then
		local wp = wps[idx]
		if wp and wp.pos_x and wp.pos_x > 0 then
			local dx = math.abs(pos.x - wp.pos_x)
			local dy = math.abs(pos.y - wp.pos_y)
			local arrivalDist = BOT_CONFIG.HUNT_NODE_ARRIVAL_DIST

			-- Stand waypoints need near-exact position in patrol, close enough during travel
			if wp.waypoint_type == "stand" then
				if state.huntPhase == HUNT_PHASE.PATROLLING then
					arrivalDist = 0
				else
					arrivalDist = 1  -- close enough during travel phases
				end
			elseif wp.waypoint_type == "hole" or wp.waypoint_type == "shovel"
				or wp.waypoint_type == "rope" or wp.waypoint_type == "ladder" then
				arrivalDist = 1
			end

			-- Floor-change tiles or closed shovel holes can't be stood on, so relax arrival to dist=1
			if arrivalDist == 0 then
				local wpTile = Tile(Position(wp.pos_x, wp.pos_y, wp.pos_z))
				if wpTile and (wpTile:hasFlag(TILESTATE_FLOORCHANGE) or BotSystem.findClosedShovelHole(wpTile)) then
					arrivalDist = 1
				end
			end

			if dx <= arrivalDist and dy <= arrivalDist and pos.z == wp.pos_z then
				-- Arrived! Handle special waypoint actions
				BotSystem.handleHuntWaypointAction(player, state, wp)

				-- Refresh pos in case handleHuntWaypointAction changed our z-level
				pos = player:getPosition()

				-- Reset skip counter on successful arrival
				state.huntWaypointSkipCount = 0
				state.huntLastPos = { x = pos.x, y = pos.y, z = pos.z }

				-- Advance to next
				state.huntWaypointIdx = idx + 1
				BotSystem.castDebug(player, state, "ADVANCE: arrived wp " .. idx .. "/" .. #wps
					.. " (" .. wp.pos_x .. "," .. wp.pos_y .. "," .. wp.pos_z .. ")"
					.. " type=" .. (wp.waypoint_type or "walk"))
				if state.huntWaypointIdx > #wps then
					BotSystem.castDebug(player, state, "ADVANCE: all waypoints done")
					return "done"
				end
				return true
			end
		else
			-- Label/conditional waypoint — skip to next
			BotSystem.castDebug(player, state, "ADVANCE: skipping label/cond wp " .. idx)
			state.huntWaypointIdx = idx + 1
			if state.huntWaypointIdx > #wps then
				return "done"
			end
			return true
		end
	else
		return "done"
	end

	return false
end

-- Cut jungle grass, wild growth, reeds or spider webs using machete
function BotSystem.tryCutMacheteObstacle(player, targetPos)
	local tile = Tile(targetPos)
	if not tile then return false end
	local items = tile:getItems()
	if not items then return false end

	for _, item in ipairs(items) do
		local id = item:getId()
		-- Jungle grass (3696, 3702, 17153)
		if id == 3696 or id == 3702 or id == 17153 then
			item:transform(id == 17153 and 17151 or id - 1)
			item:decay()
			targetPos:sendMagicEffect(CONST_ME_POFF)
			return true
		-- Wild growth (2130, 3635, 30224)
		elseif id == 2130 or id == 3635 or id == 30224 then
			targetPos:sendMagicEffect(CONST_ME_POFF)
			item:remove()
			return true
		-- Swamp reeds (30623 -> 30624)
		elseif id == 30623 then
			item:transform(30624)
			item:decay()
			targetPos:sendMagicEffect(CONST_ME_POFF)
			return true
		-- Spider webs / cobwebs (3798, 3799, 3800)
		elseif id == 3798 or id == 3799 or id == 3800 then
			item:transform(id == 3800 and 3801 or id + 1)
			item:decay()
			targetPos:sendMagicEffect(CONST_ME_POFF)
			return true
		end
	end
	return false
end

-- Handle special waypoint actions (door, hole, shovel, rope, ladder, etc.)
function BotSystem.handleHuntWaypointAction(player, state, wp)
	local wtype = wp.waypoint_type

	if wtype == "door" then
		-- Try to open door at waypoint position
		local doorPos = Position(wp.pos_x, wp.pos_y, wp.pos_z)
		BotSystem.tryOpenDoors(player, doorPos)
	elseif wtype == "hole" or wtype == "shovel" then
		-- Open closed shovel hole if present and descend to z+1
		local holePos = Position(wp.pos_x, wp.pos_y, wp.pos_z)
		local holeTile = Tile(holePos)
		BotSystem.tryOpenShovelHole(holeTile)
		if player:getPosition().z == wp.pos_z then
			local destPos = Position(wp.pos_x, wp.pos_y, wp.pos_z + 1)
			player:teleportTo(destPos, true)
			BotSystem.castDebug(player, state, "ACTION: descended " .. wtype .. " at ("
				.. wp.pos_x .. "," .. wp.pos_y .. "," .. wp.pos_z .. ") -> z=" .. destPos.z)
		end
	elseif wtype == "rope" or wtype == "ladder" then
		-- Ascend to z-1 if the next waypoint (or next phase) is above us
		local wps = state.huntWaypoints
		local nextWp = wps and wps[(state.huntWaypointIdx or 0) + 1] or nil
		if player:getPosition().z == wp.pos_z and (not nextWp or (nextWp.pos_z and nextWp.pos_z < wp.pos_z)) then
			local fcPos = Position(wp.pos_x, wp.pos_y, wp.pos_z)
			local destPos = (wtype == "rope") and fcPos:moveUpstairs() or Position(wp.pos_x, wp.pos_y - 1, wp.pos_z - 1)
			player:teleportTo(destPos, true)
			BotSystem.castDebug(player, state, "ACTION: ascended " .. wtype .. " at ("
				.. wp.pos_x .. "," .. wp.pos_y .. "," .. wp.pos_z .. ") -> z=" .. destPos.z)
		end
	elseif wtype == "machete" then
		local mPos = Position(wp.pos_x, wp.pos_y, wp.pos_z)
		BotSystem.tryCutMacheteObstacle(player, mPos)
		for ox = -1, 1 do
			for oy = -1, 1 do
				if ox ~= 0 or oy ~= 0 then
					BotSystem.tryCutMacheteObstacle(player, Position(wp.pos_x + ox, wp.pos_y + oy, wp.pos_z))
				end
			end
		end
	end

	-- Pretend delay at supply points
	if wp.extra_data == "pretend_delay" then
		-- Say something at this supply point
		if math.random(1, 3) == 1 then
			BotSystem.sayRandom(player, state, "shop")
		end
	end
end

-- Navigate to the current hunt waypoint
-- Z-transitions are delegated to the floor-change state machine (handleFloorChange)
-- which runs over multiple ticks with retry logic, diagonal fix, and verification.
function BotSystem.navigateToHuntWaypoint(player, state)
	local wps = state.huntWaypoints
	if not wps then return end

	local idx = state.huntWaypointIdx
	if idx < 1 or idx > #wps then return end

	local wp = wps[idx]
	if not wp or not wp.pos_x or wp.pos_x == 0 then
		-- Skip nil/labels/conditionals
		state.huntWaypointIdx = idx + 1
		return
	end

	if player:isWalking() then return end

	local pos = player:getPosition()
	local targetPos = Position(wp.pos_x, wp.pos_y, wp.pos_z)

	-- Z-transition needed?
	if pos.z ~= targetPos.z then
		-- If floor change state machine is already running, let it finish
		if state.floorChangeState ~= FLOOR_CHANGE_STATE.NONE then
			return
		end

		local goDown = targetPos.z > pos.z
		BotSystem.castDebug(player, state, "NAV: z-transition needed at wp " .. idx
			.. " (z=" .. pos.z .. " -> z=" .. targetPos.z .. ", " .. (goDown and "DOWN" or "UP") .. ")")

		-- Build extra search centers (hunt-specific strategies)
		local extraCenters = {}
		-- Strategy 1: if previous waypoint was a rope/ladder/hole type, use its position
		-- (the imported script tells us exactly where the z-transition is)
		if idx > 1 then
			local prevWp = wps[idx - 1]
			if prevWp and prevWp.pos_x and prevWp.pos_x > 0 and prevWp.pos_z == pos.z then
				if prevWp.waypoint_type == "rope" or prevWp.waypoint_type == "ladder"
					or prevWp.waypoint_type == "hole" or prevWp.waypoint_type == "shovel" then
					table.insert(extraCenters, Position(prevWp.pos_x, prevWp.pos_y, pos.z))
					BotSystem.castDebug(player, state, "NAV: using " .. prevWp.waypoint_type
						.. " wp hint at (" .. prevWp.pos_x .. "," .. prevWp.pos_y .. "," .. pos.z .. ")")
				end
				-- Strategy 2: midpoint between previous waypoint and target
				local midX = math.floor((prevWp.pos_x + targetPos.x) / 2)
				local midY = math.floor((prevWp.pos_y + targetPos.y) / 2)
				table.insert(extraCenters, Position(midX, midY, pos.z))
			end
		end

		BotSystem.startFloorChange(state, goDown, targetPos,
			#extraCenters > 0 and extraCenters or nil, "hunt")
		return
	end

	-- If the waypoint is on a floor-change tile or closed shovel hole, A* can't path TO it.
	-- Instead, path to within 1 tile and let advanceHuntWaypoint (arrivalDist=1) advance.
	local targetTile = Tile(targetPos)
	local isHoleOrFC = targetTile and (targetTile:hasFlag(TILESTATE_FLOORCHANGE)
		or BotSystem.findClosedShovelHole(targetTile) ~= nil
		or wp.waypoint_type == "hole" or wp.waypoint_type == "shovel")
	if isHoleOrFC then
		local dist = math.max(math.abs(pos.x - targetPos.x), math.abs(pos.y - targetPos.y))
		if dist <= 1 then
			-- Already adjacent — arrival check will handle it
			BotSystem.castDebug(player, state, "NAV: adjacent to floor-change tile wp " .. idx .. ", waiting for arrival check")
			state.huntWaypointSkipCount = 0
			return
		end
		BotSystem.castDebug(player, state, "NAV: pathing near floor-change tile wp " .. idx .. " dist=" .. dist)
		local dirs = player:getPathTo(targetPos, 1, 1, true, false, BOT_CONFIG.PATH_MAX_DIST)
		if not dirs or type(dirs) ~= "table" or #dirs == 0 then
			dirs = player:getPathTo(targetPos, 1, 1, true, true, BOT_CONFIG.PATH_MAX_DIST)
		end
		if dirs and type(dirs) == "table" and #dirs > 0 then
			player:startAutoWalk(dirs)
			state.huntWaypointSkipCount = 0
			return
		end
		if dist > 4 and BotSystem.goTo(player, targetPos, state) then
			state.huntWaypointSkipCount = 0
			return
		end
		-- Can't path near the stairs — try opening doors then clear blocker or skip
		BotSystem.castDebug(player, state, "NAV: floor-change tile unreachable at wp " .. idx .. ", trying doors then skipping")
		BotSystem.tryOpenDoors(player, targetPos)
		if not BotSystem.clearPathBlocker(player, state, targetPos) then
			BotSystem.skipHuntWaypoint(player, state, "floor-change tile unreachable")
		end
		return
	end

	-- Same z, normal tile: pathfind to within arrival distance of the waypoint.
	-- Use maxDist matching arrival check (not goTo's maxDist=3, which causes
	-- oscillation when bot reaches dist=3 but arrival needs dist<=2).
	local arrivalDist = BOT_CONFIG.HUNT_NODE_ARRIVAL_DIST
	local maxDist = math.max(arrivalDist - 1, 0) -- path to 1 tile inside arrival zone
	local dist = math.max(math.abs(pos.x - targetPos.x), math.abs(pos.y - targetPos.y))

	-- Only use tight pathfinding when close; for long distances use goTo()'s chunked approach
	local ok = false
	if dist <= BOT_CONFIG.PATH_MAX_DIST then
		local dirs = player:getPathTo(targetPos, 0, maxDist, true, false, BOT_CONFIG.PATH_MAX_DIST)
		if not dirs or type(dirs) ~= "table" or #dirs == 0 then
			-- Retry without clearSight restriction
			dirs = player:getPathTo(targetPos, 0, maxDist, true, true, BOT_CONFIG.PATH_MAX_DIST)
		end
		if dirs and type(dirs) == "table" and #dirs > 0 then
			player:startAutoWalk(dirs)
			ok = true
		end
	else
		-- Far away — use chunked goTo for long-range navigation
		ok = BotSystem.goTo(player, targetPos)
	end

	if not ok then
		-- Try to open doors first
		BotSystem.tryOpenDoors(player, targetPos)
		local dirs = player:getPathTo(targetPos, 0, maxDist, true, false, BOT_CONFIG.PATH_MAX_DIST)
		if dirs and type(dirs) == "table" and #dirs > 0 then
			player:startAutoWalk(dirs)
			ok = true
		end
		if not ok then
			-- Try to clear blocking monsters before skipping
			BotSystem.castDebug(player, state, "NAV: path failed to wp " .. idx
				.. " (" .. targetPos.x .. "," .. targetPos.y .. "," .. targetPos.z .. ")"
				.. ", trying to clear blocker")
			if not BotSystem.clearPathBlocker(player, state, targetPos) then
				-- Skip to next waypoint (with delay)
				BotSystem.castDebug(player, state, "NAV: no blocker found, skipping wp " .. idx)
				BotSystem.skipHuntWaypoint(player, state, "path failed")
			end
		end
	else
		-- Successful pathfind — reset skip counter
		state.huntWaypointSkipCount = 0
	end
end

-- Clear any monster blocking the path toward a target position
-- Returns true if a blocker was found and attacked
function BotSystem.clearPathBlocker(player, state, targetPos)
	local pos = player:getPosition()
	local dx = targetPos.x - pos.x
	local dy = targetPos.y - pos.y
	local ndx = dx > 0 and 1 or (dx < 0 and -1 or 0)
	local ndy = dy > 0 and 1 or (dy < 0 and -1 or 0)

	-- Build ordered list of positions to check:
	-- 1) Tiles in direction of travel (up to 3 deep)
	-- 2) All 8 adjacent tiles (for when surrounded by monsters)
	local checked = {}
	local checkList = {}

	-- Direction tiles first (highest priority)
	if ndx ~= 0 or ndy ~= 0 then
		for step = 1, 3 do
			local cx, cy = pos.x + ndx * step, pos.y + ndy * step
			local key = cx .. "," .. cy
			if not checked[key] then
				checked[key] = true
				checkList[#checkList + 1] = Position(cx, cy, pos.z)
			end
		end
	end

	-- All 8 adjacent tiles (catches blockers from any direction)
	for ox = -1, 1 do
		for oy = -1, 1 do
			if ox ~= 0 or oy ~= 0 then
				local cx, cy = pos.x + ox, pos.y + oy
				local key = cx .. "," .. cy
				if not checked[key] then
					checked[key] = true
					checkList[#checkList + 1] = Position(cx, cy, pos.z)
				end
			end
		end
	end

	for _, checkPos in ipairs(checkList) do
		local tile = Tile(checkPos)
		if tile then
			-- Check if this tile contains a cuttable machete obstacle (jungle grass, wild growth, reeds, webs)
			if BotSystem.tryCutMacheteObstacle(player, checkPos) then
				BotSystem.castDebug(player, state, "ACTION: cut obstacle with machete at (" .. checkPos.x .. "," .. checkPos.y .. "," .. checkPos.z .. ")")
				return true
			end

			local creature = tile:getTopCreature()
			if creature and creature:isMonster() and creature:getHealth() > 0 then
				local cid = creature:getId()

				-- Check if we've been trying to clear this same blocker too long
				if state.blockerTarget == cid then
					state.blockerFailCount = (state.blockerFailCount or 0) + 1
					if state.blockerFailCount >= BOT_CONFIG.HUNT_BLOCKER_FAIL_LIMIT then
						BotSystem.combatLogForce(player, state, "HUNT-BLOCKER-GIVEUP: "
							.. creature:getName() .. " after " .. state.blockerFailCount .. " ticks")
						state.blockerTarget = nil
						state.blockerFailCount = 0
						return false -- give up, let caller skip waypoint
					end
				else
					state.blockerTarget = cid
					state.blockerFailCount = 1
				end

				-- Only attack if we have LOS
				if pos:isSightClear(checkPos, true) then
					BotSystem.doAttackCreature(player, state, creature)
					BotSystem.castDebug(player, state, "BLOCKER: attacking " .. creature:getName()
						.. " at (" .. checkPos.x .. "," .. checkPos.y .. "," .. checkPos.z .. ")"
						.. " attempt=" .. state.blockerFailCount)
					logger.info("[Bot:" .. player:getName() .. "] HUNTING clearing blocker "
						.. creature:getName() .. " at (" .. checkPos.x .. "," .. checkPos.y .. "," .. checkPos.z .. ")"
						.. " attempt=" .. state.blockerFailCount)
				else
					BotSystem.combatLog(player, state, "HUNT-BLOCKER-NOLOS: "
						.. creature:getName() .. " at (" .. checkPos.x .. "," .. checkPos.y .. "," .. checkPos.z .. ")")
				end
				return true
			end
		end
	end
	-- No blocker found — reset tracker
	state.blockerTarget = nil
	state.blockerFailCount = 0
	return false
end

-- Skip current waypoint and try the next one
function BotSystem.skipHuntWaypoint(player, state, reason)
	state.huntWaypointSkipCount = (state.huntWaypointSkipCount or 0) + 1
	BotSystem.castDebug(player, state, "SKIP: wp " .. (state.huntWaypointIdx or 0)
		.. " reason=" .. reason .. " skipCount=" .. state.huntWaypointSkipCount)

	-- Check if we've made real progress toward the target (not just oscillating)
	local pos = player:getPosition()
	local madeProgress = false
	if state.huntLastPos then
		-- Calculate distance to current waypoint target
		local wps = state.huntWaypoints
		local idx = state.huntWaypointIdx
		if wps and idx and idx >= 1 and idx <= #wps then
			local wp = wps[idx]
			if wp and wp.pos_x and wp.pos_x > 0 then
				local oldDist = math.max(math.abs(state.huntLastPos.x - wp.pos_x),
					math.abs(state.huntLastPos.y - wp.pos_y))
				local newDist = math.max(math.abs(pos.x - wp.pos_x),
					math.abs(pos.y - wp.pos_y))
				-- Only count as progress if we got at least 3 tiles closer
				madeProgress = (newDist < oldDist - 2)
				if madeProgress then
					BotSystem.castDebug(player, state, "SKIP: progress detected (oldDist=" .. oldDist .. " newDist=" .. newDist .. "), resetting skip count")
				end
			end
		end
	else
		madeProgress = true -- first time, give benefit of doubt
	end

	if madeProgress then
		state.huntWaypointSkipCount = 0
	end
	state.huntLastPos = { x = pos.x, y = pos.y, z = pos.z }

	if state.huntWaypointSkipCount >= BOT_CONFIG.HUNT_STUCK_THRESHOLD then
		BotSystem.castDebug(player, state, "SKIP: stuck threshold reached (" .. BOT_CONFIG.HUNT_STUCK_THRESHOLD .. "), aborting hunt")
		BotSystem.abortHunt(player, state, "stuck at waypoint " .. (state.huntWaypointIdx or 0)
			.. " (" .. reason .. ")")
		return
	end

	-- Skip to next waypoint
	local wps = state.huntWaypoints
	if wps and state.huntWaypointIdx < #wps then
		if reason == "z-transition failed" or reason == "z-mismatch" then
			-- Z-transition failed: skip immediately to next waypoint on our z-level.
			local startIdx = state.huntWaypointIdx
			while state.huntWaypointIdx < #wps do
				state.huntWaypointIdx = state.huntWaypointIdx + 1
				local nextWp = wps[state.huntWaypointIdx]
				if nextWp and nextWp.pos_z and nextWp.pos_z == pos.z then
					break
				end
			end
			local skipped = state.huntWaypointIdx - startIdx
			BotSystem.castDebug(player, state, "SKIP: z-skip " .. skipped .. " wps, now at wp "
				.. state.huntWaypointIdx .. " (z=" .. pos.z .. ")")
		else
			state.huntWaypointIdx = state.huntWaypointIdx + 1
			BotSystem.castDebug(player, state, "SKIP: advancing to wp " .. state.huntWaypointIdx .. "/" .. #wps)
		end
	else
		-- Past end of waypoints
		if state.huntPhase == HUNT_PHASE.PATROLLING then
			-- Loop back, reset skip counter per cycle
			state.huntWaypointIdx = 1
			state.huntCycles = (state.huntCycles or 0) + 1
			state.huntWaypointSkipCount = 0
			BotSystem.castDebug(player, state, "SKIP: end of patrol, looping (cycle " .. state.huntCycles
				.. " kills=" .. (state.huntKillCount or 0) .. ")")
			-- Abort if 3+ cycles with zero kills (patrol area unreachable or empty)
			if state.huntCycles >= 3 and (state.huntKillCount or 0) == 0 then
				BotSystem.castDebug(player, state, "SKIP: no kills after " .. state.huntCycles .. " cycles, aborting")
				BotSystem.abortHunt(player, state, "no kills after " .. state.huntCycles .. " patrol cycles")
				return
			end
		else
			-- For travel phases, consider it done
			BotSystem.castDebug(player, state, "SKIP: end of travel waypoints, advancing phase")
			if state.huntPhase == HUNT_PHASE.TRAVEL_TO then
				BotSystem.beginHuntPhase(player, state, HUNT_PHASE.PATROLLING)
			else
				BotSystem.beginHuntPhase(player, state, HUNT_PHASE.RESUPPLYING)
			end
		end
	end
end

-- Debug log helper: throttled to once per DEBUG_COMBAT_INTERVAL seconds per bot
function BotSystem.combatLog(player, state, msg)
	if not BOT_CONFIG.DEBUG_COMBAT then return end
	local now = os.time()
	if now - (state.lastCombatLogTime or 0) < BOT_CONFIG.DEBUG_COMBAT_INTERVAL then return end
	state.lastCombatLogTime = now
	if state and state.verboseLog and player then
		player:sendChannelMessage("", "[Bot] " .. msg, CAST_TALK_TYPE, CHANNEL_CAST)
	end
	logger.info("[Bot:" .. player:getName() .. "] " .. msg)
end

-- Force a combat log (bypasses throttle, for important one-time events)
function BotSystem.combatLogForce(player, state, msg)
	if not BOT_CONFIG.DEBUG_COMBAT then return end
	state.lastCombatLogTime = os.time()
	if state and state.verboseLog and player then
		player:sendChannelMessage("", "[Bot] " .. msg, CAST_TALK_TYPE, CHANNEL_CAST)
	end
	logger.info("[Bot:" .. player:getName() .. "] " .. msg)
end

-- Check if a monster is in the temporary ignore list
function BotSystem.isMonsterIgnored(state, creatureId)
	if not state.huntIgnoredMonsters then return false end
	local until_time = state.huntIgnoredMonsters[creatureId]
	if not until_time then return false end
	if os.time() >= until_time then
		state.huntIgnoredMonsters[creatureId] = nil
		return false
	end
	return true
end

-- Find a cardinal-aligned attack position for ranged vocations (mages/paladins).
-- Prefers tiles on the same axis (N/S/E/W) as the monster for clear LOS.
function BotSystem.findCardinalAttackPosition(player, monsterPos, range)
	local pos = player:getPosition()
	-- Try cardinal offsets at increasing distances (1..range), sorted by distance from player
	local candidates = {}
	for d = 1, range do
		local offsets = {
			Position(monsterPos.x, monsterPos.y - d, monsterPos.z), -- north
			Position(monsterPos.x, monsterPos.y + d, monsterPos.z), -- south
			Position(monsterPos.x - d, monsterPos.y, monsterPos.z), -- west
			Position(monsterPos.x + d, monsterPos.y, monsterPos.z), -- east
		}
		for _, tilePos in ipairs(offsets) do
			local tile = Tile(tilePos)
			-- Check tile exists, has ground, and no solid blocking
			if tile and tile:getGround() and not tile:hasFlag(TILESTATE_BLOCKSOLID) then
				local pdist = math.abs(pos.x - tilePos.x) + math.abs(pos.y - tilePos.y)
				candidates[#candidates + 1] = {pos = tilePos, dist = pdist}
			end
		end
	end
	-- Sort by distance from player (closest first)
	table.sort(candidates, function(a, b) return a.dist < b.dist end)
	-- Try pathfinding to each candidate
	for _, c in ipairs(candidates) do
		local dirs = player:getPathTo(c.pos, 0, 0, true, true, BOT_CONFIG.PATH_MAX_DIST)
		if dirs and type(dirs) == "table" and #dirs > 0 then
			return dirs
		end
	end
	return nil
end

-- Walk to and loot the corpse of the most recently killed monster
function BotSystem.processPendingLoot(player, state)
	local lootPos = state.pendingLootPos
	if not lootPos then return false end

	local pos = player:getPosition()
	if pos.z ~= lootPos.z then
		state.pendingLootPos = nil
		state.pendingLootMonsterName = nil
		state.pendingLootAttempts = nil
		return false
	end

	local dist = math.max(math.abs(pos.x - lootPos.x), math.abs(pos.y - lootPos.y))
	if dist > 8 or (state.pendingLootAttempts or 0) > 6 then
		state.pendingLootPos = nil
		state.pendingLootMonsterName = nil
		state.pendingLootAttempts = nil
		return false
	end

	if dist <= 1 then
		-- Adjacent to or standing on the corpse tile: search lootPos and immediate neighbors
		local searchPositions = { lootPos }
		for ox = -1, 1 do
			for oy = -1, 1 do
				if ox ~= 0 or oy ~= 0 then
					searchPositions[#searchPositions + 1] = Position(lootPos.x + ox, lootPos.y + oy, lootPos.z)
				end
			end
		end

		local foundCorpse = false
		for _, checkPos in ipairs(searchPositions) do
			local checkDist = math.max(math.abs(pos.x - checkPos.x), math.abs(pos.y - checkPos.y))
			if checkDist <= 1 then
				local tile = Tile(checkPos)
				local items = tile and tile:getItems()
				if items then
					for _, item in ipairs(items) do
						if item:isContainer() then
							local it = item:getType()
							if (it and it:isCorpse()) or item:getCorpseOwner() ~= 0 or item:getSize() > 0 then
								foundCorpse = true
								local inside = item:getItems(true)
								local lootedDesc = {}
								if inside and #inside > 0 then
									for i = #inside, 1, -1 do
										local sub = inside[i]
										if sub and not sub:isContainer() then
											local subId = sub:getId()
											local subCount = sub:getCount() or 1
											local subName = sub:getName() or ("item#" .. subId)
											if subId == 3031 then
												player:setBankBalance(player:getBankBalance() + subCount)
											elseif subId == 3035 then
												player:setBankBalance(player:getBankBalance() + subCount * 100)
											elseif subId == 3043 then
												player:setBankBalance(player:getBankBalance() + subCount * 10000)
											else
												pcall(function() player:addItem(subId, subCount, false) end)
											end
											lootedDesc[#lootedDesc + 1] = (subCount > 1 and (subCount .. "x ") or "") .. subName
											sub:remove()
										end
									end
								end
								local mName = state.pendingLootMonsterName or item:getName()
								if #lootedDesc > 0 then
									local lootStr = table.concat(lootedDesc, ", ")
									logger.info("[Bot:" .. player:getName() .. "] LOOTED: " .. lootStr .. " from " .. mName)
									BotSystem.castDebug(player, state, "LOOT: " .. lootStr .. " (" .. mName .. ")")
								else
									BotSystem.castDebug(player, state, "LOOT: empty corpse (" .. mName .. ")")
								end
								break
							end
						end
					end
				end
			end
			if foundCorpse then break end
		end

		state.pendingLootPos = nil
		state.pendingLootMonsterName = nil
		state.pendingLootAttempts = nil
		return false
	end

	-- Need to walk to the corpse (dist > 1)
	state.pendingLootAttempts = (state.pendingLootAttempts or 0) + 1
	if player:isWalking() then
		return true
	end

	local dirs = player:getPathTo(lootPos, 0, 1, true, true, BOT_CONFIG.PATH_MAX_DIST)
	if not dirs or type(dirs) ~= "table" or #dirs == 0 then
		dirs = player:getPathTo(lootPos, 0, 1, true, false, BOT_CONFIG.PATH_MAX_DIST)
	end
	if dirs and type(dirs) == "table" and #dirs > 0 then
		player:startAutoWalk(dirs)
		BotSystem.castDebug(player, state, "LOOT: walking to corpse at ("
			.. lootPos.x .. "," .. lootPos.y .. "," .. lootPos.z .. ") dist=" .. dist)
		return true
	end

	-- Unreachable corpse
	state.pendingLootPos = nil
	state.pendingLootMonsterName = nil
	state.pendingLootAttempts = nil
	return false
end

-- Scan for monsters and attack highest-priority target
-- Uses native targeting: setAttackedCreature (red box) -> server auto-attacks with weapon.
-- Chase mode is enabled in C++, so server handles follow/pathfinding for melee (knights).
-- Mages use manual cardinal positioning to maintain range and LOS.
function BotSystem.scanAndAttackHuntTarget(player, state)
	local pos = player:getPosition()
	local voc = player:getVocation()
	local baseVoc = voc and voc:getBaseId() or 4
	local name = player:getName()
	-- Vocation-aware attack range: mages keep distance, knights go melee
	local attackRange = 1
	if baseVoc == 1 or baseVoc == 2 then attackRange = 3
	elseif baseVoc == 3 then attackRange = 5 end

	-- Check if already fighting a monster
	if state.huntMonsterTarget then
		local monster = Creature(state.huntMonsterTarget)
		if monster and not monster:isRemoved() and monster:getHealth() > 0 then
			local mpos = monster:getPosition()
			state.huntMonsterLastPos = { x = mpos.x, y = mpos.y, z = mpos.z, name = monster:getName() }
			local dist = math.max(math.abs(pos.x - mpos.x), math.abs(pos.y - mpos.y))
			if dist <= BOT_CONFIG.HUNT_MONSTER_SCAN_RADIUS + 5 then
				-- Ensure target is set (server handles auto-attack with weapon)
				if player:getTarget() ~= monster then
					player:setTarget(monster)
				end
				local hasLOS = pos.z == mpos.z and pos:isSightClear(mpos, true)

				-- Periodically cast spells (spell system uses attackedCreature for targeting)
				BotSystem.doCastSpell(player, state, monster)

				-- Persistent LOS failure = give up on this target too
				-- (bot may be in range but separated by wall)
				if not hasLOS then
					state.huntLOSFailCount = (state.huntLOSFailCount or 0) + 1
					if state.huntLOSFailCount >= BOT_CONFIG.HUNT_CHASE_FAIL_LIMIT then
						state.huntChaseFailCount = BOT_CONFIG.HUNT_CHASE_FAIL_LIMIT
					end
				else
					state.huntLOSFailCount = 0
				end

				-- Chase logic depends on vocation
				if pos.z ~= mpos.z then
					BotSystem.huntChaseMonster(player, state, monster)
					state.huntChaseFailCount = 0
				elseif dist <= attackRange and hasLOS then
					-- In range with LOS — weapon auto-attacks + spells handle damage
					state.huntChaseFailCount = 0
					-- Mages: disable chase mode to hold position at range
					if (baseVoc == 1 or baseVoc == 2) and dist >= 2 then
						player:setChaseMode(false)
					end
				elseif not player:isWalking() then
					-- Need to close distance or fix LOS — manual pathfinding for ALL vocations
					-- (setChaseMode/setFollowCreature is unreliable for bot players)
					local dirs = nil
					if (baseVoc == 1 or baseVoc == 2) then
						-- Mages: try cardinal positioning first for ranged LOS
						player:setChaseMode(false)
						dirs = BotSystem.findCardinalAttackPosition(player, mpos, attackRange)
					end
					if not dirs then
						-- All vocations: pathfind toward monster
						dirs = player:getPathTo(mpos, 0, attackRange, true, true, BOT_CONFIG.PATH_MAX_DIST)
						if not dirs or type(dirs) ~= "table" or #dirs == 0 then
							dirs = player:getPathTo(mpos, 0, attackRange, true, false, BOT_CONFIG.PATH_MAX_DIST)
						end
					end
					if dirs and type(dirs) == "table" and #dirs > 0 then
						player:startAutoWalk(dirs)
						state.huntChaseFailCount = 0
					else
						state.huntChaseFailCount = (state.huntChaseFailCount or 0) + 1
					end

					-- Unreachable target timeout
					if (state.huntChaseFailCount or 0) >= BOT_CONFIG.HUNT_CHASE_FAIL_LIMIT then
						local mid = state.huntMonsterTarget
						BotSystem.combatLogForce(player, state, "HUNT-TARGET-TIMEOUT: giving up on "
							.. monster:getName() .. " after " .. state.huntChaseFailCount .. " fails"
							.. " dist=" .. dist .. " LOS=" .. tostring(hasLOS))
						player:setTarget(nil)
						state.huntMonsterTarget = nil
						state.huntMonsterLastPos = nil
						state.huntChaseFailCount = 0
						-- Add to temporary ignore list
						if not state.huntIgnoredMonsters then state.huntIgnoredMonsters = {} end
						state.huntIgnoredMonsters[mid] = os.time() + BOT_CONFIG.HUNT_IGNORE_DURATION
						return true -- stay in combat mode, try rescanning
					end
				end

				BotSystem.combatLog(player, state, "HUNT-COMBAT: " .. monster:getName()
					.. " dist=" .. dist .. " LOS=" .. tostring(hasLOS)
					.. " walking=" .. tostring(player:isWalking())
					.. " chaseFails=" .. (state.huntChaseFailCount or 0))
				return true
			end
		end
		-- Monster dead or gone — clear target, count kill, queue corpse loot, resume patrol
		BotSystem.combatLogForce(player, state, "HUNT-TARGET-CLEARED: monster dead/gone"
			.. " kills=" .. ((state.huntKillCount or 0) + 1))
		player:setTarget(nil)
		state.huntMonsterTarget = nil
		state.huntChaseFailCount = 0
		state.huntKillCount = (state.huntKillCount or 0) + 1
		if state.huntMonsterLastPos then
			state.pendingLootPos = Position(state.huntMonsterLastPos.x, state.huntMonsterLastPos.y, state.huntMonsterLastPos.z)
			state.pendingLootMonsterName = state.huntMonsterLastPos.name
			state.pendingLootAttempts = 0
			state.huntMonsterLastPos = nil
		end
		-- Re-enable chase mode for next target
		player:setChaseMode(true)
		if state.huntPhase == HUNT_PHASE.PATROLLING then
			BotSystem.findClosestForwardWaypoint(player, state)
		end
		state.huntScanCooldown = 0 -- immediately re-scan after kill
	end

	-- If a corpse from our just-killed monster is waiting to be looted, walk to and loot it first
	if state.pendingLootPos then
		if BotSystem.processPendingLoot(player, state) then
			return true
		end
	end

	-- Scan for monsters (throttled: only every 5 ticks (~500ms) when no target locked)
	-- Returns false during cooldown so navigation can proceed; cooldown resets to 0
	-- after a kill (see above) so we always re-scan immediately after killing a monster
	state.huntScanCooldown = (state.huntScanCooldown or 0) - 1
	if state.huntScanCooldown > 0 then return false end
	state.huntScanCooldown = 5

	local targets = state.huntTargets or {}

	local radius = BOT_CONFIG.HUNT_MONSTER_SCAN_RADIUS
	local spectators = Game.getSpectators(pos, false, false, radius, radius, radius, radius)
	if not spectators or #spectators == 0 then return false end

	-- Build target name lookup (handle comma-separated names like "Rotworm, Carrion Worm")
	local targetNames = {}
	for _, t in ipairs(targets) do
		local tname = t.monster_name
		if tname:find(",") then
			for part in tname:gmatch("[^,]+") do
				local trimmed = part:match("^%s*(.-)%s*$")
				if trimmed and #trimmed > 0 then
					targetNames[trimmed:lower()] = t
				end
			end
		else
			targetNames[tname:lower()] = t
		end
	end

	-- Collect ALL matching monsters (sorted by priority then distance)
	local candidates = {}

	-- Debug: periodic scan logging (every 60 ticks = ~60s)
	state.huntScanTick = (state.huntScanTick or 0) + 1
	local debugScan = (state.huntScanTick % 60 == 0)
	local debugMonsters = {}
	local debugMatchFails = {}

	for _, creature in ipairs(spectators) do
		if creature ~= player and not creature:isRemoved() and creature:getHealth() > 0 then
			local cid = creature:getId()
			if creature:isMonster() and not BotSystem.isMonsterIgnored(state, cid) then
				local cname = creature:getName():lower()
				local targetInfo = targetNames[cname]
				local isTargetingMe = creature:getTarget() and creature:getTarget():getId() == player:getId()
				if targetInfo or isTargetingMe then
					local cpos = creature:getPosition()
					if cpos.z == pos.z then
						local dist = math.max(math.abs(pos.x - cpos.x), math.abs(pos.y - cpos.y))
						candidates[#candidates + 1] = {
							creature = creature,
							priority = targetInfo and targetInfo.priority or (isTargetingMe and 2 or 1),
							dist = dist,
							pos = cpos,
						}
					elseif debugScan then
						debugMatchFails[#debugMatchFails + 1] = cname .. "(z=" .. cpos.z .. ")"
					end
				elseif debugScan then
					debugMonsters[cname] = (debugMonsters[cname] or 0) + 1
				end
			end
		end
	end

	-- Sort candidates: highest priority first, then closest
	table.sort(candidates, function(a, b)
		if a.priority ~= b.priority then return a.priority > b.priority end
		return a.dist < b.dist
	end)

	-- Debug log: what creatures are nearby that DON'T match targets
	if debugScan and #candidates == 0 then
		local nearbyStr = ""
		for cname, count in pairs(debugMonsters) do
			if nearbyStr ~= "" then nearbyStr = nearbyStr .. ", " end
			nearbyStr = nearbyStr .. cname .. "x" .. count
		end
		local failStr = ""
		for _, f in ipairs(debugMatchFails) do
			if failStr ~= "" then failStr = failStr .. ", " end
			failStr = failStr .. f
		end
		local targetStr = ""
		local tCount = 0
		for tname, _ in pairs(targetNames) do
			tCount = tCount + 1
			if tCount <= 3 then
				if targetStr ~= "" then targetStr = targetStr .. "," end
				targetStr = targetStr .. tname
			end
		end
		if tCount > 3 then targetStr = targetStr .. ",+" .. (tCount - 3) end
		logger.info("[Bot] " .. name .. " hunt-scan at ("
			.. pos.x .. "," .. pos.y .. "," .. pos.z .. ") spectators=" .. #spectators
			.. " nearby=[" .. nearbyStr .. "]"
			.. (failStr ~= "" and (" matchfail=[" .. failStr .. "]") or "")
			.. " seeking=[" .. targetStr .. "]"
			.. " kills=" .. (state.huntKillCount or 0)
			.. " cycle=" .. (state.huntCycles or 0)
			.. " wp=" .. (state.huntWaypointIdx or 0) .. "/" .. #(state.huntWaypoints or {}))
	end

	-- Try each candidate: validate reachability before committing
	for _, cand in ipairs(candidates) do
		local monster = cand.creature
		local mpos = cand.pos
		local dist = cand.dist
		local hasLOS = pos:isSightClear(mpos, true)

		-- Accept if: already in range with LOS, or pathfinding succeeds
		local reachable = false
		if dist <= attackRange and hasLOS then
			reachable = true
		elseif dist <= attackRange and not hasLOS then
			-- In range but no LOS — check if we can reposition
			if baseVoc == 1 or baseVoc == 2 then
				reachable = (BotSystem.findCardinalAttackPosition(player, mpos, attackRange) ~= nil)
			else
				-- Melee: chase mode will handle it
				reachable = true
			end
		else
			-- Out of range — for melee, chase mode handles it; for ranged, check path
			if baseVoc == 3 or baseVoc == 4 then
				reachable = true -- chase mode will get us there
			else
				local dirs = player:getPathTo(mpos, 0, attackRange, true, true, BOT_CONFIG.PATH_MAX_DIST)
				reachable = (dirs and type(dirs) == "table" and #dirs > 0)
			end
		end

		if reachable then
			-- Commit to this target
			state.huntMonsterTarget = monster:getId()
			state.huntMonsterLastPos = { x = mpos.x, y = mpos.y, z = mpos.z, name = monster:getName() }
			state.huntChaseFailCount = 0
			player:setTarget(monster)
			BotSystem.doCastSpell(player, state, monster)

			BotSystem.combatLogForce(player, state, "HUNT-TARGET: selected " .. monster:getName()
				.. " id=" .. monster:getId() .. " dist=" .. dist
				.. " LOS=" .. tostring(hasLOS) .. " voc=" .. baseVoc
				.. " at (" .. mpos.x .. "," .. mpos.y .. "," .. mpos.z .. ")")

			-- Start chase if needed
			if dist > attackRange and not player:isWalking() then
				if baseVoc == 1 or baseVoc == 2 then
					player:setChaseMode(false)
					local dirs = BotSystem.findCardinalAttackPosition(player, mpos, attackRange)
					if dirs then
						player:startAutoWalk(dirs)
					end
				else
					player:setChaseMode(true)
					local dirs = player:getPathTo(mpos, 0, attackRange, true, true, BOT_CONFIG.PATH_MAX_DIST)
					if not dirs or type(dirs) ~= "table" or #dirs == 0 then
						dirs = player:getPathTo(mpos, 0, attackRange, true, false, BOT_CONFIG.PATH_MAX_DIST)
					end
					if dirs and type(dirs) == "table" and #dirs > 0 then
						player:startAutoWalk(dirs)
					end
				end
			end
			return true
		end
	end

	return false
end

-- Chase a monster across z-levels during hunting (mirrors chaseTarget z-pursuit)
function BotSystem.huntChaseMonster(player, state, monster)
	local pos = player:getPosition()
	local tpos = monster:getPosition()
	if pos.z == tpos.z then return end

	local goDown = tpos.z > pos.z

	-- Collect transitions from multiple search centers
	local allTransitions = {}
	local seen = {}
	local function addFrom(center)
		local transitions = BotSystem.findZTransitions(center, 10, goDown)
		for _, entry in ipairs(transitions) do
			local key = entry.pos.x .. "," .. entry.pos.y .. "," .. entry.type
			if not seen[key] then
				seen[key] = true
				table.insert(allTransitions, entry)
			end
		end
	end
	addFrom(Position(pos.x, pos.y, pos.z))
	addFrom(Position(tpos.x, tpos.y, pos.z))

	-- Sort by distance from bot
	table.sort(allTransitions, function(a, b)
		local da = math.abs(pos.x - a.pos.x) + math.abs(pos.y - a.pos.y)
		local db = math.abs(pos.x - b.pos.x) + math.abs(pos.y - b.pos.y)
		return da < db
	end)

	if #allTransitions > 0 and not player:isWalking() then
		for _, entry in ipairs(allTransitions) do
			local fc = entry.pos
			local dist = math.max(math.abs(pos.x - fc.x), math.abs(pos.y - fc.y))

			if entry.type == "ladder" or entry.type == "sewer" or entry.type == "shovel" then
				local maxUseDist = (entry.type == "shovel") and 1 or 0
				if dist <= maxUseDist then
					local destPos = Position(fc.x, fc.y, fc.z)
					if entry.type == "ladder" then
						destPos.z = destPos.z - 1 -- ladder goes UP (z decreases)
						destPos.y = destPos.y - 1 -- offset north to land next to hole
					else
						if entry.type == "shovel" then
							BotSystem.tryOpenShovelHole(Tile(fc))
						end
						destPos.z = destPos.z + 1
					end
					player:teleportTo(destPos, true)
					return
				end
				local dirs = player:getPathTo(fc, 0, maxUseDist, true, false, BOT_CONFIG.PATH_MAX_DIST)
				if dirs and type(dirs) == "table" and #dirs > 0 then
					player:startAutoWalk(dirs)
					return
				end
			else
				if dist == 0 then return end -- on stairs, waiting for transition
				if dist == 1 then
					local stepDir = Position.getDirectionTo(pos, fc)
					if stepDir then
						player:startAutoWalk({stepDir})
						return
					end
				end
				local dirs = player:getPathTo(fc, 1, 1, true, false, BOT_CONFIG.PATH_MAX_DIST)
				if dirs and type(dirs) == "table" and #dirs > 0 then
					player:startAutoWalk(dirs)
					return
				end
			end
		end
	end
end

-- After killing a hunt target, only advance if we happened to walk right onto
-- the current waypoint or the immediately following 1-2 waypoints during combat.
-- Never scan the entire waypoint table (which caused jumps from wp 3 to wp 19 at cave entrances).
function BotSystem.findClosestForwardWaypoint(player, state)
	local wps = state.huntWaypoints
	if not wps or #wps == 0 then return end

	local pos = player:getPosition()
	local currentIdx = state.huntWaypointIdx or 1
	local bestIdx = currentIdx
	local bestDist = 9999

	local maxLookahead = math.min(currentIdx + 2, #wps - 1)
	for i = currentIdx, maxLookahead do
		local wp = wps[i]
		if wp and wp.pos_x and wp.pos_x > 0 and wp.pos_z == pos.z then
			local d = math.max(math.abs(pos.x - wp.pos_x), math.abs(pos.y - wp.pos_y))
			if d < bestDist then
				bestDist = d
				bestIdx = i
			end
		end
	end

	-- If bot was pulled far away (> 15 tiles) by combat or a previous skip,
	-- recover the closest reachable waypoint on our current z-level (within 15 sqm).
	if bestDist > 15 then
		local nearestIdx = nil
		local nearestDist = 9999
		for i = 1, #wps do
			local wp = wps[i]
			if wp and wp.pos_x and wp.pos_x > 0 and wp.pos_z == pos.z then
				local d = math.max(math.abs(pos.x - wp.pos_x), math.abs(pos.y - wp.pos_y))
				if d < nearestDist and d <= 15 then
					nearestDist = d
					nearestIdx = i
				end
			end
		end
		if nearestIdx then
			BotSystem.castDebug(player, state, "RESUME: stranded at dist=" .. bestDist .. ", recovered closest wp " .. nearestIdx .. " at dist=" .. nearestDist)
			state.huntWaypointIdx = nearestIdx
			return
		end
	end

	-- Only advance if we actually reached within 2 tiles of that nearby waypoint
	if bestDist <= 2 and bestIdx >= currentIdx and bestIdx < #wps then
		bestIdx = bestIdx + 1
	else
		bestIdx = currentIdx
	end

	if bestIdx ~= currentIdx then
		BotSystem.castDebug(player, state, "RESUME: after kill, wp " .. currentIdx .. " -> " .. bestIdx
			.. " (passed nearby wp at dist=" .. bestDist .. ")")
	else
		BotSystem.castDebug(player, state, "RESUME: staying at wp " .. currentIdx .. " (dist=" .. bestDist .. ")")
	end
	state.huntWaypointIdx = math.min(bestIdx, #wps)
end

-- Follow a city route waypoint by waypoint using state.routeIdx
-- Returns: "arrived" when at final waypoint, "walking" while in transit, "failed" if stuck
-- Uses a loop to advance through multiple arrived waypoints per tick (no 1s pauses)
function BotSystem.followCityRoute(player, state, routeWps)
	if not routeWps or #routeWps == 0 then return "failed" end

	if not state.routeIdx then state.routeIdx = 1 end
	if state.routeIdx > #routeWps then return "arrived" end

	-- If floor-change state machine is running, let it finish
	if state.floorChangeState ~= FLOOR_CHANGE_STATE.NONE then
		return "walking"
	end

	-- Check if a floor change just completed/failed — then continue processing below
	if state.floorChangeResult and state.floorChangeSource == "route" then
		local fcResult = state.floorChangeResult
		state.floorChangeResult = nil
		state.floorChangeSource = nil
		if fcResult == "completed" then
			BotSystem.castDebug(player, state, "Route wp " .. state.routeIdx .. "/" .. #routeWps
				.. ": z-transition OK, now at z=" .. player:getPosition().z)
			-- Fall through to waypoint loop below (no return "walking")
		else
			BotSystem.castDebug(player, state, "Route wp " .. state.routeIdx .. "/" .. #routeWps
				.. ": z-transition FAILED, skipping waypoint")
			state.routeIdx = state.routeIdx + 1
			state.routeStuckCount = 0
			if state.routeIdx > #routeWps then return "arrived" end
			-- Fall through to process next waypoint immediately
		end
	end

	-- Loop: advance through all consecutive waypoints we've already reached
	-- This eliminates the 1-second-per-waypoint delay from single recursion
	local advancedCount = 0
	while state.routeIdx <= #routeWps and advancedCount < 20 do
		local wp = routeWps[state.routeIdx]
		local targetPos = Position(wp.pos_x, wp.pos_y, wp.pos_z)
		local pos = player:getPosition()
		local dist = math.max(math.abs(pos.x - targetPos.x), math.abs(pos.y - targetPos.y))

		-- Check if we've arrived at this waypoint
		if dist <= 2 and pos.z == targetPos.z then
			advancedCount = advancedCount + 1
			BotSystem.castDebug(player, state, "Route wp " .. state.routeIdx .. "/" .. #routeWps
				.. ": arrived at (" .. targetPos.x .. "," .. targetPos.y .. "," .. targetPos.z .. ")")

			-- Handle special waypoint types
			if wp.waypoint_type == "door" then
				BotSystem.tryOpenDoors(player, targetPos)
			end

			state.routeIdx = state.routeIdx + 1
			state.routeStuckCount = 0
			if state.routeIdx > #routeWps then
				BotSystem.castDebug(player, state, "Route: ARRIVED at destination")
				return "arrived"
			end
			-- Continue loop to check next waypoint immediately
		else
			-- Not arrived — break out and handle walk/z-transition below
			break
		end
	end

	-- If we advanced but there's more, process current target
	if state.routeIdx > #routeWps then return "arrived" end

	local wp = routeWps[state.routeIdx]
	local targetPos = Position(wp.pos_x, wp.pos_y, wp.pos_z)
	local pos = player:getPosition()

	-- Z-mismatch: use floor-change state machine (NOT teleport!)
	if pos.z ~= targetPos.z then
		local goDown = targetPos.z > pos.z
		BotSystem.castDebug(player, state, "Route wp " .. state.routeIdx .. "/" .. #routeWps
			.. ": z-transition " .. (goDown and "DOWN" or "UP") .. " (z=" .. pos.z .. "->" .. targetPos.z .. ")")
		BotSystem.startFloorChange(state, goDown, targetPos, nil, "route")
		return "walking"
	end

	-- Same z: walk to waypoint (only issue new walk if not already walking)
	if not player:isWalking() then
		-- For floor-change tile waypoints, path to 1 tile away (A* rejects FLOORCHANGE tiles)
		local targetTile = Tile(targetPos)
		local isFcTile = targetTile and targetTile:hasFlag(TILESTATE_FLOORCHANGE)
		local minDist, maxDist = 0, 2
		if isFcTile then minDist, maxDist = 1, 1 end

		local dirs = player:getPathTo(targetPos, minDist, maxDist, true, true, BOT_CONFIG.PATH_MAX_DIST)
		if dirs and type(dirs) == "table" and #dirs > 0 then
			player:startAutoWalk(dirs)
			state.routeStuckSince = nil
			state.routeStuckLogged = nil
		else
			-- Time-based stuck detection (works correctly with both fast and normal ticks)
			local now = os.time()
			if not state.routeStuckSince then
				state.routeStuckSince = now
			end
			local stuckSeconds = now - state.routeStuckSince
			-- Try to open doors in the direction of the target
			BotSystem.tryOpenDoors(player, targetPos)
			-- Try to clear path blockers (monsters)
			BotSystem.clearPathBlocker(player, state, targetPos)

			if stuckSeconds >= 5 and not state.routeStuckLogged then
				state.routeStuckLogged = true
				BotSystem.castDebug(player, state, "Route wp " .. state.routeIdx .. "/" .. #routeWps
					.. ": stuck at (" .. pos.x .. "," .. pos.y .. "," .. pos.z
					.. ") trying to reach (" .. targetPos.x .. "," .. targetPos.y .. "," .. targetPos.z .. ")")
			end

			-- After 15 seconds stuck, skip to next waypoint
			if stuckSeconds > 15 then
				BotSystem.castDebug(player, state, "Route wp " .. state.routeIdx .. "/" .. #routeWps
					.. ": stuck too long, skipping")
				state.routeIdx = state.routeIdx + 1
				state.routeStuckSince = nil
				state.routeStuckLogged = nil
				if state.routeIdx > #routeWps then return "arrived" end
			end
		end
	end

	return "walking"
end

function BotSystem.checkEquipmentUpgrade(player, state)
	if not player or player:isRemoved() then return end
	local curLevel = player:getLevel()
	local voc = player:getVocation()
	local baseVoc = voc and voc:getBaseId() or 4
	local personality = state and state.personality or 2
	local bracket = BotEquipmentData.getBracketForLevel and BotEquipmentData.getBracketForLevel(curLevel) or 8
	local vocStr = (baseVoc == 1 and "sorcerer") or (baseVoc == 2 and "druid") or (baseVoc == 3 and "paladin") or "knight"

	local slots = {
		{ name = "head",  slot = CONST_SLOT_HEAD },
		{ name = "armor", slot = CONST_SLOT_ARMOR },
		{ name = "legs",  slot = CONST_SLOT_LEGS },
		{ name = "feet",  slot = CONST_SLOT_FEET },
		{ name = "right", slot = CONST_SLOT_LEFT },  -- weapon
		{ name = "left",  slot = CONST_SLOT_RIGHT }, -- shield
	}

	for _, s in ipairs(slots) do
		local opt = BotEquipmentData.getOptionForSlot and BotEquipmentData.getOptionForSlot(bracket, vocStr, s.name, personality)
		if opt and opt.item_id then
			local curItem = player:getSlotItem(s.slot)
			local curId = curItem and curItem:getId() or 0
			if curId ~= opt.item_id then
				local price = opt.price or 1000
				local balance = player:getBankBalance()
				if balance >= price then
					player:setBankBalance(balance - price)
					player:setSlotItem(s.slot, opt.item_id, 1)
					logger.info(string.format("[Bot:%s] [UPGRADE-MARKET] Comprou %s por %d gold no Market de Venebra e equipou no slot %s!",
						player:getName(), opt.name or "item", price, s.name))
				end
			end
		end
	end
end

function BotSystem.processDepotLootAndBank(player, state)
	if not player or player:isRemoved() then return end

	local backpack = player:getSlotItem(CONST_SLOT_BACKPACK)
	if not backpack then return end

	local depositedGold = 0
	local soldLootGold = 0
	local itemsSold = 0

	-- 1. Depósito de Gold/Platinum/Crystal coins
	local itemsToRemove = {}
	local bpItems = backpack:getItems(true)
	if bpItems and #bpItems > 0 then
		for _, item in ipairs(bpItems) do
			local id = item:getId()
			local count = item:getCount() or 1
			if id == 3031 then -- gold coin
				depositedGold = depositedGold + count
				table.insert(itemsToRemove, item)
			elseif id == 3035 then -- platinum coin
				depositedGold = depositedGold + (count * 100)
				table.insert(itemsToRemove, item)
			elseif id == 3043 then -- crystal coin
				depositedGold = depositedGold + (count * 10000)
				table.insert(itemsToRemove, item)
			end
		end
	end

	for _, it in ipairs(itemsToRemove) do
		pcall(function() it:remove() end)
	end

	if depositedGold > 0 then
		player:setBankBalance(player:getBankBalance() + depositedGold)
		logger.info(string.format("[Bot:%s] [DEPOT] Depositou %d gold físico no banco.", player:getName(), depositedGold))
	end

	-- 2. Venda Instantânea de Loot/Creature Products pelo preço de mercado de Venebra
	local lootSold = {}
	local bpItemsRemaining = backpack:getItems(true)
	if bpItemsRemaining and #bpItemsRemaining > 0 then
		for _, item in ipairs(bpItemsRemaining) do
			local id = item:getId()
			local count = item:getCount() or 1
			if id ~= 3003 and id ~= 3457 and id ~= 5710 and id ~= 268 and id ~= 266 and id ~= 7590 and id ~= 7591 and not item:isContainer() then
				local res = db.storeQuery(string.format("SELECT buy_offer, day_avg_sell, npc_buy FROM tibia_market_items WHERE item_id = %d LIMIT 1", id))
				if res then
					local bOff = Result.getNumber(res, "buy_offer")
					local dAvg = Result.getNumber(res, "day_avg_sell")
					local npcB = Result.getNumber(res, "npc_buy")
					Result.free(res)
					local unitPrice = (bOff > 0 and bOff) or (dAvg > 0 and dAvg) or (npcB > 0 and npcB) or 0
					if unitPrice > 0 then
						local totalVal = unitPrice * count
						soldLootGold = soldLootGold + totalVal
						itemsSold = itemsSold + count
						table.insert(lootSold, item)
					end
				end
			end
		end
	end

	for _, it in ipairs(lootSold) do
		pcall(function() it:remove() end)
	end

	if soldLootGold > 0 then
		player:setBankBalance(player:getBankBalance() + soldLootGold)
		logger.info(string.format("[Bot:%s] [MARKET-VENEBRA] Vendeu %d itens de loot por %d gold no Market de Venebra.", player:getName(), itemsSold, soldLootGold))
	end

	-- 3. Upgrade de Equipamento a cada 3 níveis utilizando o saldo bancário
	local curLevel = player:getLevel()
	state.lastUpgradeLevel = state.lastUpgradeLevel or 0
	if (curLevel % 3 == 0) or (curLevel - state.lastUpgradeLevel >= 3) then
		BotSystem.checkEquipmentUpgrade(player, state)
		state.lastUpgradeLevel = curLevel
	end
end

function BotSystem.doHuntResupply(player, state)
	-- Resupply timeout: 5 minutes max total for entire resupply/prepare phase
	if not state.resupplyStartTime then
		state.resupplyStartTime = os.time()
	end
	if os.time() - state.resupplyStartTime > 300 then
		BotSystem.castDebug(player, state, "RESUPPLY: timeout (300s), phase=" .. (state.huntPhase or "?"))
		if state.huntPhase == HUNT_PHASE.PREPARING then
			-- Timeout during prep — skip to travel_to anyway
			logger.info("[Bot] " .. player:getName() .. " prepare timeout, heading to spawn")
			BotSystem.beginHuntPhase(player, state, HUNT_PHASE.TRAVEL_TO)
		else
			BotSystem.endHunt(player, state)
		end
		return
	end

	local step = state.resupplyStep

	-- Sub-state: walking to depot locker (after route arrival at depot)
	if state.resupplyDepotTarget then
		local pos = player:getPosition()
		local dp = state.resupplyDepotTarget
		local dist = math.max(math.abs(pos.x - dp.x), math.abs(pos.y - dp.y))
		if dist <= 1 and pos.z == dp.z then
			-- Adjacent to depot locker — processar ouro, venda de loot de Venebra e upgrade
			BotSystem.processDepotLootAndBank(player, state)
			if math.random(1, 2) == 1 then
				BotSystem.sayRandom(player, state, "depot")
			end
			state.resupplyDepotTarget = nil
			state.resupplyUntil = os.time() + math.random(
				BOT_CONFIG.HUNT_RESUPPLY_DEPOT_MIN, BOT_CONFIG.HUNT_RESUPPLY_DEPOT_MAX)
			local waitSec = state.resupplyUntil - os.time()
			BotSystem.castDebug(player, state, "RESUPPLY: at depot locker (" .. dp.x .. "," .. dp.y .. "), waiting " .. waitSec .. "s")
			return
		end
		-- Not adjacent yet — walk toward it
		if not player:isWalking() then
			local foundPath = false
			local adjacentOffsets = {{0,-1},{0,1},{-1,0},{1,0},{-1,-1},{1,-1},{-1,1},{1,1}}
			for _, off in ipairs(adjacentOffsets) do
				local adjPos = Position(dp.x + off[1], dp.y + off[2], dp.z)
				local adjTile = Tile(adjPos)
				if adjTile and adjTile:isWalkable() then
					local dirs = player:getPathTo(adjPos, 0, 0, true, true, BOT_CONFIG.PATH_MAX_DIST)
					if dirs and type(dirs) == "table" and #dirs > 0 then
						player:startAutoWalk(dirs)
						foundPath = true
						break
					end
				end
			end
			if not foundPath then
				local newLocker = BotSystem.findReachableDepotLocker(player, state)
				if newLocker and (newLocker.x ~= dp.x or newLocker.y ~= dp.y) then
					state.resupplyDepotTarget = newLocker
				else
					-- No reachable locker — just wait here
					state.resupplyDepotTarget = nil
					state.resupplyUntil = os.time() + math.random(
						BOT_CONFIG.HUNT_RESUPPLY_DEPOT_MIN, BOT_CONFIG.HUNT_RESUPPLY_DEPOT_MAX)
				end
			end
		end
		return
	end

	-- Check if current step delay is still running
	if state.resupplyUntil > 0 and os.time() < state.resupplyUntil then
		-- Show wait timer every ~5 seconds
		local remaining = state.resupplyUntil - os.time()
		if not state.lastResupplyWaitLog or os.time() - state.lastResupplyWaitLog >= 5 then
			state.lastResupplyWaitLog = os.time()
			BotSystem.castDebug(player, state, "RESUPPLY: waiting at " .. (step or "?")
				.. " (" .. remaining .. "s remaining)")
		end
		return -- still waiting
	end

	local townId = state.huntTownId or (player:getTown() and player:getTown():getId() or 8)

	-- Helper: find route from bot's current position to a destination POI
	local function findRouteToDestination(destPOI)
		local pos = player:getPosition()
		local srcPOI = state.resupplyLastPOI
		if not srcPOI then
			srcPOI = BotHuntData.detectNearestPOI(townId, pos)
		end
		if not srcPOI then return nil end
		local route = BotHuntData.findRoute(townId, srcPOI, destPOI)
		return route
	end

	if step == "bank" then
		-- Bank is only visited during post-hunt RESUPPLYING, not during PREPARING
		if state.huntPhase == HUNT_PHASE.PREPARING then
			BotSystem.castDebug(player, state, "RESUPPLY: skipping bank (PREPARING phase), -> depot")
			state.resupplyStep = "depot"
			state.resupplyUntil = 0
			return
		end
		if state.resupplyUntil == 0 then
			if not state.resupplyRoute then
				BotSystem.castDebug(player, state, "RESUPPLY: finding route to bank")
				state.resupplyRoute = findRouteToDestination("bank")
				state.routeIdx = nil
			end
			if state.resupplyRoute then
				local result = BotSystem.followCityRoute(player, state, state.resupplyRoute)
				if result == "arrived" then
					state.resupplyLastPOI = "bank"
					if math.random(1, 2) == 1 then
						player:say("hi", TALKTYPE_SAY)
					end
					state.resupplyUntil = os.time() + math.random(
						BOT_CONFIG.HUNT_RESUPPLY_BANK_MIN, BOT_CONFIG.HUNT_RESUPPLY_BANK_MAX)
					BotSystem.castDebug(player, state, "RESUPPLY: arrived at bank, waiting "
						.. (state.resupplyUntil - os.time()) .. "s")
				elseif result == "failed" then
					state.resupplyStep = "depot"
					state.resupplyUntil = 0
					state.resupplyRoute = nil
					state.routeIdx = nil
				end
				return
			end
			-- No bank route, skip to depot
			state.resupplyStep = "depot"
			state.resupplyUntil = 0
			return
		end
		-- Bank delay done, move to depot
		BotSystem.castDebug(player, state, "RESUPPLY: bank done, -> depot")
		state.resupplyStep = "depot"
		state.resupplyUntil = 0
		state.resupplyRoute = nil
		state.routeIdx = nil

	elseif step == "depot" then
		if state.resupplyUntil == 0 then
			if not state.resupplyRoute then
				BotSystem.castDebug(player, state, "RESUPPLY: finding route to depot")
				state.resupplyRoute = findRouteToDestination("depot")
				state.routeIdx = nil
			end
			if state.resupplyRoute then
				local result = BotSystem.followCityRoute(player, state, state.resupplyRoute)
				if result == "arrived" then
					state.resupplyLastPOI = "depot"
					-- Find and walk to a depot locker (like navigate depot does)
					local lockerPos = BotSystem.findReachableDepotLocker(player, state)
					if lockerPos then
						local pos = player:getPosition()
						local dist = math.max(math.abs(pos.x - lockerPos.x), math.abs(pos.y - lockerPos.y))
						if dist <= 1 and pos.z == lockerPos.z then
							-- Already adjacent — processar ouro, venda de loot de Venebra e upgrade
							BotSystem.processDepotLootAndBank(player, state)
							if math.random(1, 2) == 1 then
								BotSystem.sayRandom(player, state, "depot")
							end
							state.resupplyUntil = os.time() + math.random(
								BOT_CONFIG.HUNT_RESUPPLY_DEPOT_MIN, BOT_CONFIG.HUNT_RESUPPLY_DEPOT_MAX)
							BotSystem.castDebug(player, state, "RESUPPLY: at depot locker, waiting "
								.. (state.resupplyUntil - os.time()) .. "s")
						else
							-- Walk to the locker
							BotSystem.castDebug(player, state, "RESUPPLY: walking to depot locker at ("
								.. lockerPos.x .. "," .. lockerPos.y .. "," .. lockerPos.z .. ") dist=" .. dist)
							state.resupplyDepotTarget = lockerPos
						end
					else
						-- No locker found — just wait at current position
						BotSystem.processDepotLootAndBank(player, state)
						state.resupplyUntil = os.time() + math.random(
							BOT_CONFIG.HUNT_RESUPPLY_DEPOT_MIN, BOT_CONFIG.HUNT_RESUPPLY_DEPOT_MAX)
					end
					state.resupplyRoute = nil
					state.routeIdx = nil
				elseif result == "failed" then
					state.resupplyStep = "shop"
					state.resupplyUntil = 0
					state.resupplyRoute = nil
					state.routeIdx = nil
				end
				return
			end
			state.resupplyStep = "shop"
			state.resupplyUntil = 0
			return
		end
		-- Depot delay done, move to shop
		BotSystem.castDebug(player, state, "RESUPPLY: depot done, -> shop")
		state.resupplyStep = "shop"
		state.resupplyUntil = 0
		state.resupplyRoute = nil
		state.routeIdx = nil

	elseif step == "shop" then
		if state.resupplyUntil == 0 then
			if not state.resupplyRoute then
				BotSystem.castDebug(player, state, "RESUPPLY: finding route to shop (potions/runes/ammo)")
				state.resupplyRoute = findRouteToDestination("potions")
					or findRouteToDestination("runes")
					or findRouteToDestination("ammo")
				state.routeIdx = nil
			end
			if state.resupplyRoute then
				local result = BotSystem.followCityRoute(player, state, state.resupplyRoute)
				if result == "arrived" then
					state.resupplyLastPOI = "potions"
					if math.random(1, 2) == 1 then
						player:say("hi", TALKTYPE_SAY)
					end
					state.resupplyUntil = os.time() + math.random(
						BOT_CONFIG.HUNT_RESUPPLY_SHOP_MIN, BOT_CONFIG.HUNT_RESUPPLY_SHOP_MAX)
					BotSystem.castDebug(player, state, "RESUPPLY: arrived at shop, waiting "
						.. (state.resupplyUntil - os.time()) .. "s")
				elseif result == "failed" then
					state.resupplyStep = "done"
					state.resupplyUntil = 0
					state.resupplyRoute = nil
					state.routeIdx = nil
				end
				return
			end
			state.resupplyStep = "done"
			state.resupplyUntil = 0
			return
		end
		BotSystem.castDebug(player, state, "RESUPPLY: shop done, -> done")
		state.resupplyStep = "done"
		state.resupplyUntil = 0
		state.resupplyRoute = nil
		state.routeIdx = nil

	elseif step == "done" then
		if state.huntPhase == HUNT_PHASE.PREPARING then
			-- Preparation complete — now head to the spawn
			BotSystem.castDebug(player, state, "RESUPPLY: preparation complete, heading to spawn")
			logger.info("[Bot] " .. player:getName() .. " preparation done, heading to spawn")
			BotSystem.beginHuntPhase(player, state, HUNT_PHASE.TRAVEL_TO)
		elseif state.huntPhase == HUNT_PHASE.RESUPPLYING then
			-- Post-hunt resupply done — re-roll for another hunt or end
			BotSystem.castDebug(player, state, "RESUPPLY: post-hunt resupply done, re-rolling")
			BotSystem.finishResupplyAndReroll(player, state)
		else
			BotSystem.castDebug(player, state, "RESUPPLY: done, ending hunt")
			BotSystem.endHunt(player, state)
		end
	end
end

-- After post-hunt resupply, decide whether to hunt again or go idle
function BotSystem.finishResupplyAndReroll(player, state)
	local scriptId = state.huntScriptId
	local kills = state.huntKillCount or 0
	local scriptName = "?"
	if scriptId and BotHuntData.scripts[scriptId] then
		scriptName = BotHuntData.scripts[scriptId].name
	end

	-- Release the current hunt reservation
	if scriptId then
		BotHuntData.releaseHunt(scriptId, player:getGuid())
	end

	BotSystem.castDebug(player, state, "REROLL: resupply done (hunt: " .. scriptName
		.. " kills=" .. kills .. "), rolling for next hunt")
	logger.info("[Bot] " .. player:getName() .. " resupply done (hunt: " .. scriptName
		.. " kills=" .. kills .. "), rolling for next hunt")

	-- Roll for another hunt (same chance as normal idle roll)
	-- If successful, the bot stays in the hunt city and hunts again
	if math.random(1, BOT_CONFIG.HUNT_CHANCE_PER_TICK) <= 3 then
		-- Clear old hunt state but keep position
		local oldTownId = state.huntTownId
		player:setTarget(nil)
		state.huntScriptId = nil
		state.huntPhase = nil
		state.huntWaypoints = nil
		state.huntWaypointIdx = 0
		state.huntTargets = nil
		state.huntStartTime = nil
		state.huntEndTime = nil
		state.huntKillCount = 0
		state.huntMonsterTarget = nil
		state.huntWaypointSkipCount = 0
		state.huntLastPos = nil
		state.resupplyStep = nil
		state.resupplyUntil = 0
		state.resupplyWalkTarget = nil
		state.resupplyRoute = nil
		state.routeIdx = nil
		state.routeStuckCount = nil
		state.resupplyDepotTarget = nil
		state.resupplyDepotWaitUntil = nil
		state.resupplyLastPOI = nil
		state.walkTarget = nil
		state.currentPOI = nil
		state.state = BOT_STATE.IDLE

		-- Try to start a new hunt (prefer same town since we're already here)
		if BotSystem.tryStartHunt(player, state) then
			logger.info("[Bot] " .. player:getName() .. " re-hunting after resupply!")
			return
		end
	end

	-- No re-hunt — end normally
	BotSystem.endHunt(player, state)
end

-- Cleanly end a hunt (success)
function BotSystem.endHunt(player, state)
	-- Clear native target
	player:setTarget(nil)
	local scriptId = state.huntScriptId
	local kills = state.huntKillCount or 0
	local duration = state.huntStartTime and (os.time() - state.huntStartTime) or 0
	local scriptName = "?"
	if scriptId and BotHuntData.scripts[scriptId] then
		scriptName = BotHuntData.scripts[scriptId].name
	end

	BotSystem.castDebug(player, state, "HUNT END: " .. scriptName
		.. " kills=" .. kills
		.. " duration=" .. math.floor(duration / 60) .. "m")
	logger.info("[Bot] " .. player:getName() .. " finished hunt: " .. scriptName
		.. " kills=" .. kills
		.. " duration=" .. math.floor(duration / 60) .. "m")

	-- Release reservation
	if scriptId then
		BotHuntData.releaseHunt(scriptId, player:getGuid())
	end

	-- Set cooldown
	local cooldown = math.random(BOT_CONFIG.HUNT_COOLDOWN_MIN, BOT_CONFIG.HUNT_COOLDOWN_MAX)
	state.huntCooldownUntil = os.time() + cooldown

	-- Clear all hunt state
	state.huntScriptId = nil
	state.huntPhase = nil
	state.huntWaypoints = nil
	state.huntWaypointIdx = 0
	state.huntTargets = nil
	state.huntStartTime = nil
	state.huntEndTime = nil
	state.huntKillCount = 0
	state.huntMonsterTarget = nil
	state.huntWaypointSkipCount = 0
	state.huntLastPos = nil
	state.huntTownId = nil
	state.resupplyStep = nil
	state.resupplyUntil = 0
	state.resupplyWalkTarget = nil
	state.resupplyRoute = nil
	state.routeIdx = nil
	state.routeStuckCount = nil
	state.resupplyDepotTarget = nil
	state.resupplyDepotWaitUntil = nil
	state.resupplyLastPOI = nil
	state.walkTarget = nil
	state.currentPOI = nil

	-- Teleport home if far from town
	local town = player:getTown()
	if town then
		local pos = player:getPosition()
		local templePos = town:getTemplePosition()
		local expectedZ = BotSystem.getExpectedZ(player)
		local dist = math.max(math.abs(pos.x - templePos.x), math.abs(pos.y - templePos.y))
		if pos.z ~= expectedZ or dist > 50 then
			local spawnPos = BotSystem.getSpawnPosition(player)
			player:teleportTo(spawnPos)
		end
	end

	-- Return to idle
	state.state = BOT_STATE.IDLE
end

-- Abort a hunt (stuck, timeout, error)
function BotSystem.abortHunt(player, state, reason)
	-- Clear native target
	player:setTarget(nil)
	local scriptId = state.huntScriptId
	local scriptName = "?"
	if scriptId and BotHuntData.scripts[scriptId] then
		scriptName = BotHuntData.scripts[scriptId].name
	end

	BotSystem.castDebug(player, state, "ABORT: " .. scriptName
		.. " reason=" .. (reason or "unknown")
		.. " kills=" .. (state.huntKillCount or 0)
		.. " phase=" .. (state.huntPhase or "?"))
	logger.warn("[Bot] " .. player:getName() .. " ABORTING hunt: " .. scriptName
		.. " reason=" .. (reason or "unknown")
		.. " kills=" .. (state.huntKillCount or 0)
		.. " phase=" .. (state.huntPhase or "?"))

	-- Release reservation
	if scriptId then
		BotHuntData.releaseHunt(scriptId, player:getGuid())
	end

	-- Teleport home if far from town or on wrong z-level
	local pos = player:getPosition()
	local town = player:getTown()
	local expectedZ = BotSystem.getExpectedZ(player)
	if town then
		local templePos = town:getTemplePosition()
		local dist = math.max(math.abs(pos.x - templePos.x), math.abs(pos.y - templePos.y))
		if pos.z ~= expectedZ or dist > 50 then
			local spawnPos = BotSystem.getSpawnPosition(player)
			player:teleportTo(spawnPos)
			logger.info("[Bot] " .. player:getName() .. " teleported home from ("
				.. pos.x .. "," .. pos.y .. "," .. pos.z .. ") dist=" .. dist)
		end
	end

	-- Set cooldown (shorter than normal — allow retrying sooner)
	state.huntCooldownUntil = os.time() + math.random(300, 600)

	-- Clear all hunt state
	state.huntScriptId = nil
	state.huntPhase = nil
	state.huntWaypoints = nil
	state.huntWaypointIdx = 0
	state.huntTargets = nil
	state.huntStartTime = nil
	state.huntEndTime = nil
	state.huntKillCount = 0
	state.huntMonsterTarget = nil
	state.huntWaypointSkipCount = 0
	state.huntLastPos = nil
	state.huntTownId = nil
	state.resupplyStep = nil
	state.resupplyUntil = 0
	state.resupplyWalkTarget = nil
	state.resupplyRoute = nil
	state.routeIdx = nil
	state.routeStuckCount = nil
	state.resupplyDepotTarget = nil
	state.resupplyDepotWaitUntil = nil
	state.resupplyLastPOI = nil
	state.walkTarget = nil
	state.currentPOI = nil

	state.state = BOT_STATE.IDLE
end

-- ============================================================================
-- Party System: /party command support
-- ============================================================================

-- Find leader's current combat target (monster being fought nearby)
function BotSystem.findLeaderCombatTarget(leader)
	local leaderPos = leader:getPosition()
	local spectators = Game.getSpectators(leaderPos, false, false, 7, 7, 7, 7)
	for _, creature in ipairs(spectators) do
		if creature:isMonster() and creature:getHealth() > 0 then
			-- Check if this monster is attacking the leader or being attacked
			local target = creature:getTarget()
			if target and target:getId() == leader:getId() then
				return creature
			end
		end
	end
	return nil
end

-- Party follow AI: follow leader, attack their target, heal party members
function BotSystem.doPartyFollow(player, state)
	local leaderGuid = state.partyLeader
	if not leaderGuid then
		BotSystem.exitParty(player, state)
		return
	end

	local leader = Player(leaderGuid)
	if not leader then
		BotSystem.exitParty(player, state)
		return
	end

	-- Check party still exists
	local party = player:getParty()
	if not party then
		BotSystem.exitParty(player, state)
		return
	end

	local pos = player:getPosition()
	local leaderPos = leader:getPosition()

	-- Self heal (always)
	BotSystem.doHealing(player, state)

	-- Mana restore
	if player:getMana() < player:getMaxMana() * 0.5 then
		player:addMana(player:getMaxMana())
	end

	-- Party healing (druid only)
	BotSystem.doPartyHealing(player, state, party)

	-- Attack leader's target
	local leaderTarget = leader:getTarget()
	if not leaderTarget or leaderTarget:getHealth() <= 0 then
		leaderTarget = BotSystem.findLeaderCombatTarget(leader)
	end

	local chasing = false
	if leaderTarget and leaderTarget:getHealth() > 0 then
		-- Set target (server auto-attacks with weapon) + cast spell
		if player:getTarget() ~= leaderTarget then
			player:setTarget(leaderTarget)
		end
		BotSystem.doCastSpell(player, state, leaderTarget)
		-- Actively chase the target if not in range
		local tpos = leaderTarget:getPosition()
		if pos.z == tpos.z then
			local voc = player:getVocation()
			local baseVoc = voc and voc:getBaseId() or 4
			local attackRange = 1
			if baseVoc == 1 or baseVoc == 2 then attackRange = 3
			elseif baseVoc == 3 then attackRange = 5 end
			local tdist = math.max(math.abs(pos.x - tpos.x), math.abs(pos.y - tpos.y))
			if tdist > attackRange and not player:isWalking() then
				local dirs = player:getPathTo(tpos, 0, attackRange, true, true, BOT_CONFIG.PATH_MAX_DIST)
				if dirs and type(dirs) == "table" and #dirs > 0 then
					player:startAutoWalk(dirs)
					chasing = true
				end
			elseif tdist <= attackRange then
				chasing = true -- in range, no need to follow leader
			end
		end
	end

	-- Follow leader (only if not chasing a target)
	if not chasing then
		if pos.z ~= leaderPos.z then
			BotSystem.chaseTarget(player, state, leader)
		else
			local dist = math.max(math.abs(pos.x - leaderPos.x), math.abs(pos.y - leaderPos.y))
			if dist > 2 and not player:isWalking() then
				local dirs = player:getPathTo(leaderPos, 0, 1, true, true, BOT_CONFIG.PATH_MAX_DIST)
				if dirs and type(dirs) == "table" and #dirs > 0 then
					player:startAutoWalk(dirs)
				elseif dist > 15 then
					-- Too far, teleport near leader
					player:teleportTo(leaderPos, true)
				end
			end
		end
	end
end

-- Druid party healing: heal party members with exura sio
function BotSystem.doPartyHealing(player, state, party)
	local voc = player:getVocation()
	local baseVoc = voc and voc:getBaseId() or 4
	if baseVoc ~= 2 then return end -- Only druids heal others

	local now = os.time()
	if state.lastPartyHealTime and now - state.lastPartyHealTime < 1 then return end

	local members = party:getMembers()
	local leader = party:getLeader()
	if leader then table.insert(members, leader) end

	for _, member in ipairs(members) do
		if member:getId() ~= player:getId() then
			local hp = member:getHealth()
			local maxHp = member:getMaxHealth()
			if (hp / math.max(maxHp, 1)) * 100 < 70 then
				local mpos = member:getPosition()
				local pos = player:getPosition()
				local dist = math.max(math.abs(pos.x - mpos.x), math.abs(pos.y - mpos.y))
				if dist <= 7 and pos.z == mpos.z then
					state.lastPartyHealTime = now
					player:say("exura sio \"" .. member:getName(), TALKTYPE_MONSTER_SAY)
					local magicLevel = player:getMagicLevel()
					local healAmount = math.floor(player:getLevel() / 5 + magicLevel * 4) + 100
					member:addHealth(healAmount)
					mpos:sendMagicEffect(CONST_ME_MAGIC_BLUE)
					return -- heal 1 per tick
				end
			end
		end
	end
end

-- Exit party mode: return bot to normal behavior
function BotSystem.exitParty(player, state)
	local party = player:getParty()
	if party then
		party:removeMember(player)
	end

	state.partyLeader = nil
	state.lastPartyHealTime = nil
	state.state = BOT_STATE.IDLE

	-- Teleport home
	local town = player:getTown()
	if town then
		local spawnPos = BotSystem.getSpawnPosition(player)
		player:teleportTo(spawnPos)
	end

	logger.info("[Bot] " .. player:getName() .. " left party, returning to IDLE")
end

-- ============================================================================
-- Node.js Brain Integration (bot-decision-service :3001)
-- - Autonomous Macro-Decisions (/api/decision/macro)
-- - Reactive Player/GOD Chat & Conditional Obedience (/api/decision/chat)
-- - 5-Turn Bot <-> Bot Dialogues (/api/decision/dialogue)
-- ============================================================================

local NODE_SERVICE_URL = "http://127.0.0.1:3001"
local _nodeReqSeq = 0
local _lastGlobalDialogueTime = 0
local _lastSpeakerBroadcastHandled = {} -- [speakerGuid] = timestamp (anti-crowd dedupe)

local function jsonEscape(str)
	str = tostring(str or "")
	str = str:gsub("\\", "\\\\")
	str = str:gsub('"', '\\"')
	str = str:gsub("\n", "\\n")
	str = str:gsub("\r", "\\r")
	str = str:gsub("\t", "\\t")
	return str
end

local function encodeJson(val)
	local t = type(val)
	if t == "nil" then
		return "null"
	elseif t == "boolean" then
		return val and "true" or "false"
	elseif t == "number" then
		return tostring(val)
	elseif t == "string" then
		return '"' .. jsonEscape(val) .. '"'
	elseif t == "table" then
		local isArray = (#val > 0)
		if isArray then
			local parts = {}
			for i = 1, #val do
				parts[#parts + 1] = encodeJson(val[i])
			end
			return "[" .. table.concat(parts, ",") .. "]"
		else
			local parts = {}
			for k, v in pairs(val) do
				parts[#parts + 1] = '"' .. jsonEscape(k) .. '":' .. encodeJson(v)
			end
			return "{" .. table.concat(parts, ",") .. "}"
		end
	end
	return "null"
end

-- Lightweight recursive JSON decoder for Node.js responses
local function decodeJson(str)
	if type(str) ~= "string" or str == "" then return nil end
	local pos = 1
	local len = #str

	local function skipWs()
		while pos <= len do
			local c = str:sub(pos, pos)
			if c == " " or c == "\t" or c == "\n" or c == "\r" then
				pos = pos + 1
			else
				break
			end
		end
	end

	local parseValue

	local function parseString()
		pos = pos + 1 -- skip opening quote
		local out = {}
		while pos <= len do
			local c = str:sub(pos, pos)
			if c == '"' then
				pos = pos + 1
				return table.concat(out)
			elseif c == "\\" then
				pos = pos + 1
				local esc = str:sub(pos, pos)
				if esc == "n" then out[#out + 1] = "\n"
				elseif esc == "r" then out[#out + 1] = "\r"
				elseif esc == "t" then out[#out + 1] = "\t"
				else out[#out + 1] = esc end
				pos = pos + 1
			else
				out[#out + 1] = c
				pos = pos + 1
			end
		end
		return table.concat(out)
	end

	local function parseObject()
		pos = pos + 1 -- skip '{'
		local obj = {}
		skipWs()
		if str:sub(pos, pos) == "}" then
			pos = pos + 1
			return obj
		end
		while pos <= len do
			skipWs()
			if str:sub(pos, pos) ~= '"' then break end
			local key = parseString()
			skipWs()
			if str:sub(pos, pos) == ":" then pos = pos + 1 end
			skipWs()
			obj[key] = parseValue()
			skipWs()
			local sep = str:sub(pos, pos)
			if sep == "," then
				pos = pos + 1
			elseif sep == "}" then
				pos = pos + 1
				break
			else
				break
			end
		end
		return obj
	end

	local function parseArray()
		pos = pos + 1 -- skip '['
		local arr = {}
		skipWs()
		if str:sub(pos, pos) == "]" then
			pos = pos + 1
			return arr
		end
		while pos <= len do
			skipWs()
			arr[#arr + 1] = parseValue()
			skipWs()
			local sep = str:sub(pos, pos)
			if sep == "," then
				pos = pos + 1
			elseif sep == "]" then
				pos = pos + 1
				break
			else
				break
			end
		end
		return arr
	end

	parseValue = function()
		skipWs()
		local c = str:sub(pos, pos)
		if c == '"' then
			return parseString()
		elseif c == "{" then
			return parseObject()
		elseif c == "[" then
			return parseArray()
		elseif str:sub(pos, pos + 3) == "true" then
			pos = pos + 4
			return true
		elseif str:sub(pos, pos + 4) == "false" then
			pos = pos + 5
			return false
		elseif str:sub(pos, pos + 3) == "null" then
			pos = pos + 4
			return nil
		else
			local numStr = str:match("^[%-]?%d+%.?%d*", pos)
			if numStr and #numStr > 0 then
				pos = pos + #numStr
				return tonumber(numStr)
			end
			pos = pos + 1
			return nil
		end
	end

	local ok, res = pcall(parseValue)
	return ok and res or nil
end

-- Non-blocking HTTP POST to Node.js service using /tmp RAM files + addEvent polling
function BotSystem.asyncNodePost(endpoint, payloadTable, callback, fallbackCallback)
	_nodeReqSeq = (_nodeReqSeq % 100000) + 1
	local reqId = tostring(os.time()) .. "_" .. tostring(_nodeReqSeq)
	local reqFile = "/tmp/bot_req_" .. reqId .. ".json"
	local resFile = "/tmp/bot_res_" .. reqId .. ".json"

	local wf = io.open(reqFile, "w")
	if not wf then
		if fallbackCallback then pcall(fallbackCallback) end
		return
	end
	wf:write(encodeJson(payloadTable))
	wf:close()

	local cmd = string.format(
		"curl -s -m 4 -X POST '%s%s' -H 'Content-Type: application/json' --data-binary @'%s' -o '%s' 2>/dev/null &",
		NODE_SERVICE_URL, endpoint, reqFile, resFile
	)
	os.execute(cmd)

	local attempts = 0
	local function pollResponse()
		attempts = attempts + 1
		local rf = io.open(resFile, "r")
		if rf then
			local content = rf:read("*a")
			rf:close()
			if content and #content > 2 and content:match("}%s*$") then
				os.remove(reqFile)
				os.remove(resFile)
				local parsed = decodeJson(content)
				if parsed and callback then
					pcall(callback, parsed)
				end
				return
			end
		end
		if attempts < 10 then
			addEvent(pollResponse, 350)
		else
			os.remove(reqFile)
			os.remove(resFile)
			if fallbackCallback then
				pcall(fallbackCallback)
			end
		end
	end

	addEvent(pollResponse, 350)
end

-- Execute a macro intent returned by Node.js (either autonomous or from chat obedience)
function BotSystem.executeMacroIntent(player, state, intent, speech, targetPlayer)
	if not player or player:isRemoved() or not state then return end

	if speech and type(speech) == "string" and #speech > 0 then
		player:say(speech, TALKTYPE_SAY)
	end

	intent = tostring(intent or "NONE"):upper()
	if intent == "NONE" or intent == "" then
		return
	end

	logger.info(string.format("[BotMacro] %s executing intent=%s", player:getName(), intent))

	if intent == "HUNT" then
		state.followPlayerGuid = nil
		state.huntCooldownUntil = 0
		if state.state ~= BOT_STATE.HUNTING then
			if not BotSystem.tryStartHunt(player, state) then
				logger.info("[BotMacro] " .. player:getName() .. " wanted to HUNT, no eligible spawn free right now")
			end
		end
	elseif intent == "RESTOCK" or intent == "DEPOT" then
		state.followPlayerGuid = nil
		if state.state == BOT_STATE.HUNTING then
			BotSystem.beginHuntPhase(player, state, HUNT_PHASE.LEAVING)
		else
			local town = player:getTown()
			local pois = town and CITY_POIS[town:getId()]
			if pois then
				for _, p in ipairs(pois) do
					if p.type == "depot" then
						state.currentPOI = p
						state.walkTarget = p.pos
						state.state = BOT_STATE.IDLE
						break
					end
				end
			end
		end
	elseif intent == "TRAIN" then
		state.followPlayerGuid = nil
		BotSystem.startStatueTraining(player, state, true)
	elseif intent == "SOCIAL" or intent == "REST" then
		state.followPlayerGuid = nil
		local town = player:getTown()
		local pois = town and CITY_POIS[town:getId()]
		if pois and #pois > 0 then
			local targetType = (intent == "REST") and "temple" or "depot"
			for _, p in ipairs(pois) do
				if p.type == targetType then
					state.currentPOI = p
					state.walkTarget = p.pos
					state.state = BOT_STATE.IDLE
					break
				end
			end
		end
	elseif intent == "FOLLOW" then
		if targetPlayer and not targetPlayer:isRemoved() then
			BotSystem.clearAllTasks(player, state)
			state.state = BOT_STATE.IDLE
			state.followPlayerGuid = targetPlayer:getGuid()
			logger.info("[BotMacro] " .. player:getName() .. " is now following " .. targetPlayer:getName())
		end
	elseif intent == "INVITE_PARTY" then
		if targetPlayer and not targetPlayer:isRemoved() then
			BotSystem.clearAllTasks(player, state)
			state.partyLeader = targetPlayer:getGuid()
			state.state = BOT_STATE.PARTY
			logger.info("[BotMacro] " .. player:getName() .. " entered PARTY mode with " .. targetPlayer:getName())
		end
	elseif intent == "STOP" then
		state.followPlayerGuid = nil
		BotSystem.clearAllTasks(player, state)
		if player.stopWalk then player:stopWalk() end
		state.state = BOT_STATE.IDLE
		logger.info("[BotMacro] " .. player:getName() .. " stopped all tasks")
	end
end

-- Autonomous Macro-Decision: Bot asks Node.js (:3001) what to do for itself
function BotSystem.requestNodeMacroDecision(player, state)
	if not player or player:isRemoved() or not state then return end
	if state.state == BOT_STATE.HUNTING or state.state == BOT_STATE.TRAINING
		or state.state == BOT_STATE.COMBAT or state.state == BOT_STATE.PARTY then
		return
	end

	local guid = player:getGuid()
	local town = player:getTown()
	local voc = player:getVocation()
	local personality = state.personality or ((guid % 5) + 1)
	state.personality = personality

	local arch = BotSystem.getBotArchetype(player, state)
	local townName = town and town:getName() or "Thais"
	local vocName = voc and voc:getName() or "Knight"
	local hpPct = math.floor((player:getHealth() / math.max(1, player:getMaxHealth())) * 100)
	local manaPct = math.floor((player:getMana() / math.max(1, player:getMaxMana())) * 100)
	local capFree = math.floor(player:getFreeCapacity() / 100)
	local skillInfo = BotSystem.getSkillTargetInfo and BotSystem.getSkillTargetInfo(player) or {}

	local payload = {
		guid = guid,
		name = player:getName(),
		level = player:getLevel(),
		vocation = vocName,
		hpPct = hpPct,
		manaPct = manaPct,
		capFree = capFree,
		town = townName,
		currentState = tostring(state.state),
		personality = personality,
		archetype_id = arch.id,
		archetype_name = arch.name,
		risk_tolerance = arch.riskTolerance,
		bot_profile = {
			guid = guid,
			name = player:getName(),
			level = player:getLevel(),
			vocation = vocName,
			city = townName,
			personality = personality,
			archetype_id = arch.id,
			archetype_name = arch.name,
			archetype_title = arch.title,
			risk_tolerance = arch.riskTolerance,
			level_offset = arch.levelOffset,
			recent_deaths = state.recentDeathsInCave or 0,
			revenge_hunt_id = state.revengeHuntId or nil,
			skills = {
				sword = player:getSkillLevel(SKILL_SWORD),
				axe = player:getSkillLevel(SKILL_AXE),
				club = player:getSkillLevel(SKILL_CLUB),
				dist = player:getSkillLevel(SKILL_DISTANCE),
				shield = player:getSkillLevel(SKILL_SHIELD),
				ml = player:getMagicLevel(),
				primary_label = skillInfo.skillLabel or "skill",
				primary_level = skillInfo.currentSkill or 10,
				target_level = skillInfo.targetSkill or 45,
				target_shield = skillInfo.targetShield or 40,
				needs_training = skillInfo.needsTraining and true or false,
				should_train = BotSystem.shouldBotTrain(player, state, skillInfo),
			},
		},
		bot_status = {
			hp = hpPct,
			mana = manaPct,
			cap = capFree,
			potions = 20,
			stamina_hours = 42,
			gold = 1000,
		},
	}

	BotSystem.asyncNodePost("/api/decision/macro", payload, function(res)
		local p = BotPlayers and BotPlayers[guid]
		local s = BotState and BotState[guid]
		if not p or p:isRemoved() or not s then return end
		if s.state == BOT_STATE.HUNTING or s.state == BOT_STATE.TRAINING or s.state == BOT_STATE.COMBAT then return end

		local decision = res.macro_action or res.decision or "HUNT"
		local reason = res.reasoning or res.reason or "autonomous routine"
		logger.info(string.format("[BotMacro] %s autonomous decision: %s (%s) [source=%s]",
			p:getName(), tostring(decision), tostring(reason), tostring(res.source)))
		BotSystem.executeMacroIntent(p, s, decision, res.suggested_speech, nil)
	end, function()
		-- Fallback nativo Lua executado se o Node.js estiver offline ou sofrer timeout
		local p = BotPlayers and BotPlayers[guid]
		local s = BotState and BotState[guid]
		if not p or p:isRemoved() or not s then return end
		if s.state == BOT_STATE.HUNTING or s.state == BOT_STATE.TRAINING or s.state == BOT_STATE.COMBAT then return end
		logger.warn(string.format("[BotMacroFallback] Node.js offline, executando decisão nativa Lua para %s", p:getName()))
		BotSystem.tryStartHunt(p, s)
	end)
end

-- Reactive Hearing: Called from C++ Player::onCreatureSay when a real player/GOD speaks
function BotSystem.onBotHear(bot, speaker, speakType, text)
	if not bot or bot:isRemoved() or not speaker or speaker:isRemoved() then return end
	if not text or #text == 0 then return end

	-- Ignore talkaction commands starting with ! or /
	local trimmed = text:gsub("^%s+", "")
	local firstChar = trimmed:sub(1, 1)
	if firstChar == "!" or firstChar == "/" then return end

	-- Ignore NPC/Monster/Bot speakers to prevent infinite loops
	if speaker.isBotPlayer and speaker:isBotPlayer() then return end
	if speaker:getName():sub(1, 4) == "Bot " then return end

	local botGuid = bot:getGuid()
	local state = BotState and BotState[botGuid]
	if not state or not BotActive[botGuid] then return end

	local botPos = bot:getPosition()
	local spkPos = speaker:getPosition()
	local isPrivate = (speakType == TALKTYPE_PRIVATE_FROM or speakType == TALKTYPE_PRIVATE_TO)

	if not isPrivate then
		if botPos.z ~= spkPos.z then return end
		local dist = math.max(math.abs(botPos.x - spkPos.x), math.abs(botPos.y - spkPos.y))
		if dist > 8 then return end

		-- Check if the speaker addressed a specific bot by name
		local lowText = text:lower()
		local myFullName = bot:getName():lower()
		local myShortName = myFullName:gsub("^bot%s+", "")
		local mentionedMe = lowText:find(myFullName, 1, true) or (#myShortName >= 3 and lowText:find(myShortName, 1, true))

		-- Check if speaker mentioned ANY online bot's name
		local mentionedAnyBot = false
		for g, otherBot in pairs(BotPlayers or {}) do
			if otherBot and not otherBot:isRemoved() and BotActive[g] then
				local oname = otherBot:getName():lower()
				local oshort = oname:gsub("^bot%s+", "")
				if lowText:find(oname, 1, true) or (#oshort >= 3 and lowText:find(oshort, 1, true)) then
					mentionedAnyBot = true
					break
				end
			end
		end

		if mentionedAnyBot and not mentionedMe then
			return -- Speaker addressed a different bot specifically
		end

		if not mentionedMe then
			-- General message ("oi", "alguem quer ir hunt?"): only 1 nearby bot within 5 SQMs replies
			if dist > 5 then return end
			local now = os.time()
			local spkGuid = speaker:getGuid()
			if _lastSpeakerBroadcastHandled[spkGuid] and (now - _lastSpeakerBroadcastHandled[spkGuid]) < 2 then
				return
			end
			_lastSpeakerBroadcastHandled[spkGuid] = now
		end
	end

	-- Per-bot chat cooldown (3s)
	local now = os.time()
	if state.lastHeardReplyTime and (now - state.lastHeardReplyTime) < 3 then
		return
	end
	state.lastHeardReplyTime = now

	-- Detect if speaker is GOD / Admin
	local isGod = false
	pcall(function()
		if speaker:getAccountType() >= ACCOUNT_TYPE_GOD then isGod = true end
		local grp = speaker:getGroup()
		if grp and (grp:getId() >= 4 or grp:getAccess()) then isGod = true end
		if speaker:getName():lower():sub(1, 3) == "god" then isGod = true end
	end)

	local personality = state.personality or ((botGuid % 5) + 1)
	state.personality = personality
	local town = bot:getTown()
	local voc = bot:getVocation()
	local townName = town and town:getName() or "Thais"
	local vocName = voc and voc:getName() or "Knight"
	local skillInfo = BotSystem.getSkillTargetInfo and BotSystem.getSkillTargetInfo(bot) or {}

	if not state.chatHistory then state.chatHistory = {} end
	table.insert(state.chatHistory, speaker:getName() .. ": " .. text)
	while #state.chatHistory > 6 do
		table.remove(state.chatHistory, 1)
	end
	local historyStr = table.concat(state.chatHistory, " | ")

	local arch = BotSystem.getBotArchetype(bot, state)
	local spkGuid = speaker:getGuid()
	local payload = {
		guid = botGuid,
		name = bot:getName(),
		level = bot:getLevel(),
		vocation = vocName,
		town = townName,
		currentState = tostring(state.state),
		personality = personality,
		archetype_id = arch.id,
		archetype_name = arch.name,
		risk_tolerance = arch.riskTolerance,
		speakerName = speaker:getName(),
		speakerLevel = speaker:getLevel(),
		isGod = isGod,
		text = text,
		recent_history = historyStr,
		bot_profile = {
			guid = botGuid,
			name = bot:getName(),
			level = bot:getLevel(),
			vocation = vocName,
			city = townName,
			personality = personality,
			archetype_id = arch.id,
			archetype_name = arch.name,
			archetype_title = arch.title,
			risk_tolerance = arch.riskTolerance,
			level_offset = arch.levelOffset,
			recent_deaths = state.recentDeathsInCave or 0,
			revenge_hunt_id = state.revengeHuntId or nil,
			skills = {
				sword = bot:getSkillLevel(SKILL_SWORD),
				axe = bot:getSkillLevel(SKILL_AXE),
				club = bot:getSkillLevel(SKILL_CLUB),
				dist = bot:getSkillLevel(SKILL_DISTANCE),
				shield = bot:getSkillLevel(SKILL_SHIELD),
				ml = bot:getMagicLevel(),
				primary_label = skillInfo.skillLabel or "skill",
				primary_level = skillInfo.currentSkill or 10,
				target_level = skillInfo.targetSkill or 45,
				target_shield = skillInfo.targetShield or 40,
				needs_training = skillInfo.needsTraining and true or false,
				should_train = BotSystem.shouldBotTrain(bot, state, skillInfo),
			},
		},
		speaker_name = speaker:getName(),
		message = text,
		channel = isPrivate and "Private" or "Default",
		speaker_is_god = isGod,
		bot_state = tostring(state.state),
	}

	logger.info(string.format("[BotChat] %s heard %s (isGod=%s): \"%s\"",
		bot:getName(), speaker:getName(), tostring(isGod), text))

	BotSystem.asyncNodePost("/api/decision/chat", payload, function(res)
		local b = BotPlayers and BotPlayers[botGuid]
		local s = BotState and BotState[botGuid]
		local spk = Player(spkGuid)
		if not b or b:isRemoved() or not s then return end

		local replyText = res.speech or res.reply_text
		if replyText and BotSystem.formatChatText then
			replyText = BotSystem.formatChatText(replyText)
		end
		local actionIntent = tostring(res.action_intent or "NONE"):upper()
		local obey = isGod or (res.obey_command == true)

		if replyText and #replyText > 0 then
			if not s.chatHistory then s.chatHistory = {} end
			table.insert(s.chatHistory, b:getName() .. ": " .. replyText)
			while #s.chatHistory > 6 do
				table.remove(s.chatHistory, 1)
			end
		end

		logger.info(string.format("[BotChat] %s -> %s (isGod=%s, obey=%s, intent=%s, src=%s): \"%s\"",
			b:getName(),
			spk and spk:getName() or "?",
			tostring(isGod),
			tostring(obey),
			actionIntent,
			tostring(res.source),
			tostring(replyText)))

		-- Natural typing delay (800ms - 1600ms)
		addEvent(function()
			local b2 = BotPlayers and BotPlayers[botGuid]
			local s2 = BotState and BotState[botGuid]
			local spk2 = Player(spkGuid)
			if not b2 or b2:isRemoved() or not s2 then return end

			if replyText and #replyText > 0 then
				b2:say(replyText, TALKTYPE_SAY)
			end
			if obey and actionIntent ~= "NONE" then
				BotSystem.executeMacroIntent(b2, s2, actionIntent, nil, spk2)
			end
		end, math.random(800, 1600))
	end)
end

-- 5-Turn Bot <-> Bot Conversation (token-safe: only when a human player is within 15 SQMs)
function BotSystem.tryBotToBotDialogue(player, state)
	if not player or player:isRemoved() or not state then return end
	local now = os.time()

	-- Global rate limit (45s) and per-bot cooldown (180s)
	if (now - _lastGlobalDialogueTime) < (BOT_CONFIG.DIALOGUE_GLOBAL_COOLDOWN or 45) then return end
	if state.lastBotDialogueTime and (now - state.lastBotDialogueTime) < (BOT_CONFIG.DIALOGUE_COOLDOWN or 180) then return end
	if state.inBotDialogue then return end

	local pos = player:getPosition()
	local myGuid = player:getGuid()

	-- Token guard: only trigger when a real human player is within 15 SQMs
	local humanNearby = false
	for _, p in ipairs(Game.getPlayers()) do
		local isBot = (p.isBotPlayer and p:isBotPlayer()) or (p:getName():sub(1, 4) == "Bot ")
		if not isBot and not p:isRemoved() then
			local ppos = p:getPosition()
			if math.abs(ppos.x - pos.x) <= 15 and math.abs(ppos.y - pos.y) <= 15 and ppos.z == pos.z then
				humanNearby = true
				break
			end
		end
	end
	if not humanNearby then return end

	-- Find a partner bot within 5 SQMs on the same floor
	local partner = nil
	local partnerState = nil
	for g, other in pairs(BotPlayers or {}) do
		if g ~= myGuid and other and not other:isRemoved() and BotActive[g] then
			local os_state = BotState and BotState[g]
			if os_state and (os_state.state == BOT_STATE.IDLE or os_state.state == BOT_STATE.DWELLING)
				and not os_state.inBotDialogue
				and (now - (os_state.lastBotDialogueTime or 0)) >= (BOT_CONFIG.DIALOGUE_COOLDOWN or 180) then
				local opos = other:getPosition()
				if opos.z == pos.z and math.max(math.abs(opos.x - pos.x), math.abs(opos.y - pos.y)) <= 5 then
					partner = other
					partnerState = os_state
					break
				end
			end
		end
	end

	if not partner or not partnerState then return end

	-- Lock both bots and set cooldowns immediately to prevent duplicate triggers
	_lastGlobalDialogueTime = now
	state.lastBotDialogueTime = now
	partnerState.lastBotDialogueTime = now
	state.inBotDialogue = true
	partnerState.inBotDialogue = true

	local guidA = myGuid
	local guidB = partner:getGuid()
	local town = player:getTown()
	local townName = town and town:getName() or "Thais"

	local infoA = {
		guid = guidA,
		name = player:getName(),
		level = player:getLevel(),
		vocation = player:getVocation() and player:getVocation():getName() or "Knight",
		town = townName,
		city = townName,
		personality = state.personality or ((guidA % 5) + 1),
	}
	local infoB = {
		guid = guidB,
		name = partner:getName(),
		level = partner:getLevel(),
		vocation = partner:getVocation() and partner:getVocation():getName() or "Paladin",
		town = townName,
		city = townName,
		personality = partnerState.personality or ((guidB % 5) + 1),
	}

	local payload = {
		botA = infoA,
		botB = infoB,
		bot_a = infoA,
		bot_b = infoB,
		location_name = townName .. " Depot",
		maxTurns = 5,
		max_turns = 5,
	}

	logger.info(string.format("[BotDialogue] Starting up to 5-turn dialogue between %s and %s",
		player:getName(), partner:getName()))

	BotSystem.asyncNodePost("/api/decision/dialogue", payload, function(res)
		local turns = res and res.turns
		if type(turns) ~= "table" or #turns == 0 then
			if BotState[guidA] then BotState[guidA].inBotDialogue = false end
			if BotState[guidB] then BotState[guidB].inBotDialogue = false end
			return
		end

		local maxTurns = math.min(5, #turns)
		for i = 1, maxTurns do
			local turn = turns[i]
			addEvent(function()
				local pA = BotPlayers and BotPlayers[guidA]
				local pB = BotPlayers and BotPlayers[guidB]
				if pA and not pA:isRemoved() and pB and not pB:isRemoved() then
					local posA = pA:getPosition()
					local posB = pB:getPosition()
					if posA.z == posB.z and math.max(math.abs(posA.x - posB.x), math.abs(posA.y - posB.y)) <= 7 then
						local spkStr = tostring(turn.speaker or "")
						local isB = (spkStr == "B") or (spkStr:lower() == pB:getName():lower()) or ((i % 2) == 0 and spkStr == "")
						local speakerBot = isB and pB or pA
						local speechText = turn.speech or turn.text
						if speechText and #speechText > 0 then
							speakerBot:say(speechText, TALKTYPE_SAY)
							logger.info(string.format("[BotDialogue] Turn %d/%d %s: \"%s\"",
								i, maxTurns, speakerBot:getName(), speechText))
						end
					end
				end
				if i == maxTurns then
					if BotState[guidA] then BotState[guidA].inBotDialogue = false end
					if BotState[guidB] then BotState[guidB].inBotDialogue = false end
				end
			end, i * 3200)
		end
	end)
end

logger.info("[BotSystem] Bot system library loaded (Node.js macro AI, GOD/player chat obedience, 5-turn bot dialogue, trap-safe nav)")

