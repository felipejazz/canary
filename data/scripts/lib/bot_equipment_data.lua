-- Bot Equipment Data Loader (Venebra-Local Integration)
-- Loads multi-option equipment matrix from MariaDB (bot_equipment table)
-- Selects optimal gear based on bot personality (1-5), level and vocation.

BotEquipmentData = {
	options = {}, -- [level_bracket][vocation][slot] = list of 4 options
	loadouts = {}, -- cached default loadout per bracket/voc
}

local VOC_NAME_BY_ID = {
	[1] = "sorcerer",
	[2] = "druid",
	[3] = "paladin",
	[4] = "knight",
	[5] = "sorcerer",
	[6] = "druid",
	[7] = "paladin",
	[8] = "knight"
}

-- Personality preference tag rankings
local PERSONALITY_PREFERENCES = {
	[1] = { "defensive", "balanced", "budget", "speed", "offensive", "brawler" }, -- Cauteloso
	[2] = { "offensive", "brawler", "speed", "balanced", "defensive", "budget" }, -- Arrojado / Rusher
	[3] = { "budget", "balanced", "speed", "defensive", "offensive", "brawler" },    -- Mercenário
	[4] = { "brawler", "offensive", "defensive", "balanced", "budget", "speed" },    -- Gladiador
	[5] = { "speed", "balanced", "defensive", "budget", "offensive", "brawler" }     -- Explorador
}

function BotEquipmentData.loadAll()
	local startTime = os.clock()
	BotEquipmentData.options = {}
	BotEquipmentData.loadouts = {}

	local resultId = db.storeQuery(
		"SELECT `level_bracket`, `vocation`, `slot`, `option_rank`, `item_id`, " ..
		"`item_name`, `price`, `personality_tag` FROM `bot_equipment` ORDER BY `level_bracket` ASC, `option_rank` ASC"
	)
	if not resultId then
		logger.warn("[BotEquipmentData] No equipment data found in bot_equipment table")
		return
	end

	local count = 0
	repeat
		local bracket = Result.getNumber(resultId, "level_bracket")
		local voc = Result.getString(resultId, "vocation"):lower()
		local slot = Result.getString(resultId, "slot"):lower()
		local rank = Result.getNumber(resultId, "option_rank")
		local itemId = Result.getNumber(resultId, "item_id")
		local itemName = Result.getString(resultId, "item_name")
		local price = Result.getNumber(resultId, "price")
		local tag = Result.getString(resultId, "personality_tag"):lower()

		if not BotEquipmentData.options[bracket] then
			BotEquipmentData.options[bracket] = {}
		end
		if not BotEquipmentData.options[bracket][voc] then
			BotEquipmentData.options[bracket][voc] = {}
		end
		if not BotEquipmentData.options[bracket][voc][slot] then
			BotEquipmentData.options[bracket][voc][slot] = {}
		end

		table.insert(BotEquipmentData.options[bracket][voc][slot], {
			item_id = itemId,
			name = itemName,
			price = price,
			tag = tag,
			rank = rank
		})
		count = count + 1
	until not Result.next(resultId)
	Result.free(resultId)

	local elapsed = math.floor((os.clock() - startTime) * 1000)
	logger.info("[BotEquipmentData] Loaded " .. count .. " equipment options from Venebra dataset (" .. elapsed .. "ms)")
end

function BotEquipmentData.getBracketForLevel(level)
	local brackets = { 100, 50, 20, 8 }
	for _, b in ipairs(brackets) do
		if (level or 8) >= b then
			return b
		end
	end
	return 8
end

function BotEquipmentData.getOptionForSlot(bracket, vocStr, slot, personality)
	local opts = BotEquipmentData.options[bracket]
		and BotEquipmentData.options[bracket][vocStr]
		and BotEquipmentData.options[bracket][vocStr][slot]

	if not opts or #opts == 0 then return nil end

	local prefs = PERSONALITY_PREFERENCES[personality or 2] or PERSONALITY_PREFERENCES[2]
	for _, prefTag in ipairs(prefs) do
		for _, opt in ipairs(opts) do
			if opt.tag == prefTag then
				return opt
			end
		end
	end
	return opts[1]
end

-- Melhor item do slot (rank1 = premium), ignorando personalidade.
function BotEquipmentData.getBestOptionForSlot(bracket, vocStr, slot)
	local opts = BotEquipmentData.options[bracket]
		and BotEquipmentData.options[bracket][vocStr]
		and BotEquipmentData.options[bracket][vocStr][slot]
	if not opts or #opts == 0 then return nil end
	return opts[1] -- ordenado por option_rank ASC no loadAll -> rank1 é o premium
end

-- Lista de opções do slot em ordem de rank (melhor -> pior), para escolha por afford­abilidade.
function BotEquipmentData.getSlotOptions(bracket, vocStr, slot)
	return (BotEquipmentData.options[bracket]
		and BotEquipmentData.options[bracket][vocStr]
		and BotEquipmentData.options[bracket][vocStr][slot]) or {}
end

-- Regra de afford­abilidade (prioriza custo-do-item vs saldo):
--  1) se dá pra pagar o MELHOR (rank1) -> pega o melhor e IGNORA personalidade;
--  2) senão (dinheiro é restrição) -> melhor afford­ável na ordem da personalidade;
--  3) se nada couber -> o mais barato (slot nunca fica vazio).
function BotEquipmentData.pickAffordableOption(bracket, vocStr, slot, personality, bank)
	local opts = BotEquipmentData.getSlotOptions(bracket, vocStr, slot)
	if #opts == 0 then return nil end
	bank = bank or 0
	local best = opts[1]
	if best and (tonumber(best.price) or 0) <= bank then
		return best
	end
	local prefs = PERSONALITY_PREFERENCES[personality or 2] or PERSONALITY_PREFERENCES[2]
	for _, tag in ipairs(prefs) do
		for _, opt in ipairs(opts) do
			if opt.tag == tag and (tonumber(opt.price) or 0) <= bank then
				return opt
			end
		end
	end
	local cheapest = opts[1]
	for _, opt in ipairs(opts) do
		if (tonumber(opt.price) or 0) < (tonumber(cheapest.price) or 0) then cheapest = opt end
	end
	return cheapest
end

-- Lista ORDENADA de candidatos p/ um slot, para o chamador tentar equipar em ordem até um funcionar
-- (ex.: rank1 pode ser incompatível com a vocação — knight legs p/ druid — então cai p/ o próximo).
--  forceBest: ordem de rank (melhor primeiro).
--  afford­ável (rank1 cabe no saldo): afford­áveis em ordem de rank, depois o resto (fallback).
--  dinheiro restrito: ordem de personalidade entre afford­áveis, depois o resto (mais barato primeiro).
function BotEquipmentData.getOrderedCandidates(bracket, vocStr, slot, personality, bank, forceBest)
	local opts = BotEquipmentData.getSlotOptions(bracket, vocStr, slot)
	local list, seen = {}, {}
	local function push(o) if o and o.item_id and o.item_id > 0 and not seen[o] then seen[o] = true; list[#list + 1] = o end end
	if #opts == 0 then return list end

	if forceBest then
		for _, o in ipairs(opts) do push(o) end
		return list
	end

	bank = bank or 0
	local best = opts[1]
	if best and (tonumber(best.price) or 0) <= bank then
		for _, o in ipairs(opts) do if (tonumber(o.price) or 0) <= bank then push(o) end end
		for _, o in ipairs(opts) do push(o) end
	else
		local prefs = PERSONALITY_PREFERENCES[personality or 2] or PERSONALITY_PREFERENCES[2]
		for _, tag in ipairs(prefs) do
			for _, o in ipairs(opts) do
				if o.tag == tag and (tonumber(o.price) or 0) <= bank then push(o) end
			end
		end
		local rem = {}
		for _, o in ipairs(opts) do rem[#rem + 1] = o end
		table.sort(rem, function(a, b) return (tonumber(a.price) or 0) < (tonumber(b.price) or 0) end)
		for _, o in ipairs(rem) do push(o) end
	end
	return list
end

-- Loadout usando sempre o melhor item (rank1) por slot, mantendo as regras especiais de
-- arma de knight (por skill) e kit de paladino (archer/spearman).
function BotEquipmentData.getBestLoadout(level, baseVoc, player, personality)
	return BotEquipmentData.getLoadout(level, baseVoc, personality or 2, player, function(bracket, vocStr, slot)
		return BotEquipmentData.getBestOptionForSlot(bracket, vocStr, slot)
	end)
end

function BotEquipmentData.getLoadout(level, baseVoc, personality, player, selector)
	local bracket = BotEquipmentData.getBracketForLevel(level)
	local vocStr = VOC_NAME_BY_ID[baseVoc or 4] or "knight"
	personality = personality or 2
	-- selector(bracket, vocStr, slot) escolhe a opção do slot; default = por personalidade
	selector = selector or function(b, v, s)
		return BotEquipmentData.getOptionForSlot(b, v, s, personality)
	end

	local headOpt  = selector(bracket, vocStr, "head")
	local armorOpt = selector(bracket, vocStr, "armor")
	local legsOpt  = selector(bracket, vocStr, "legs")
	local feetOpt  = selector(bracket, vocStr, "feet")
	local rightOpt = selector(bracket, vocStr, "right")
	local leftOpt  = selector(bracket, vocStr, "left")
	local ammoOpt  = 0

	-- Knight Weapon Selection: strictly match character's highest trained skill
	if baseVoc == 4 and player then
		local sw = player.getSkillLevel and player:getSkillLevel(SKILL_SWORD) or 10
		local ax = player.getSkillLevel and player:getSkillLevel(SKILL_AXE) or 10
		local cl = player.getSkillLevel and player:getSkillLevel(SKILL_CLUB) or 10

		if sw >= ax and sw >= cl then
			-- Sword
			if bracket >= 100 then rightOpt = { item_id = 7390 } -- The Justice Seeker
			elseif bracket >= 50 then rightOpt = { item_id = 7383 } -- Relic Sword
			elseif bracket >= 20 then rightOpt = { item_id = 7385 } -- Crimson Sword
			else rightOpt = { item_id = 7774 } -- Jagged Sword
			end
		elseif ax >= sw and ax >= cl then
			-- Axe
			if bracket >= 100 then rightOpt = { item_id = 7434 } -- Royal Axe
			elseif bracket >= 50 then rightOpt = { item_id = 7389 } -- Heroic Axe
			elseif bracket >= 20 then rightOpt = { item_id = 7380 } -- Headchopper
			else rightOpt = { item_id = 7773 } -- Steel Axe
			end
		else
			-- Club
			if bracket >= 100 then rightOpt = { item_id = 7429 } -- Blessed Sceptre
			elseif bracket >= 50 then rightOpt = { item_id = 7415 } -- Cranial Basher
			elseif bracket >= 20 then rightOpt = { item_id = 7386 } -- Shadow Sceptre
			else rightOpt = { item_id = 3327 } -- Daramian Mace
			end
		end
	end

	-- Paladin Archetype Kits
	if baseVoc == 3 then
		local isArcher = (personality == 2 or personality == 4) -- 2: Arrojado/Rusher, 4: Gladiador
		if isArcher then
			-- Archer: Bow/Crossbow + Quiver (required for distance shooting in Canary)
			if bracket >= 100 then
				rightOpt = { item_id = 8854 }   -- Warsinger Bow
				leftOpt  = { item_id = 35848 }  -- Blue Quiver
				ammoOpt  = 15793                -- Crystalline Arrow
			elseif bracket >= 50 then
				rightOpt = { item_id = 8027 }   -- Composite Hornbow
				leftOpt  = { item_id = 35848 }  -- Blue Quiver
				ammoOpt  = 7365                 -- Onyx Arrow
			elseif bracket >= 20 then
				rightOpt = { item_id = 3350 }   -- Bow
				leftOpt  = { item_id = 35562 }  -- Quiver
				ammoOpt  = 7364                 -- Sniper Arrow
			else
				rightOpt = { item_id = 3350 }   -- Bow
				leftOpt  = { item_id = 35562 }  -- Quiver
				ammoOpt  = 3447                 -- Arrow
			end
		else
			-- Spearman: Throwing weapon + Shield
			ammoOpt = 0
			if bracket >= 100 then
				rightOpt = { item_id = 7368 }   -- Assassin Star
				leftOpt  = { item_id = 3414 }   -- Mastermind Shield
			elseif bracket >= 50 then
				rightOpt = { item_id = 7378 }   -- Royal Spear
				leftOpt  = { item_id = 3420 }   -- Demon Shield
			elseif bracket >= 20 then
				rightOpt = { item_id = (level >= 25 and 7378 or 14251) } -- Royal Spear (25+) / Hunting Spear
				leftOpt  = { item_id = 3415 }   -- Guardian Shield
			else
				rightOpt = { item_id = 3277 }   -- Spear
				leftOpt  = { item_id = 3425 }   -- Dwarven Shield
			end
		end
	end

	return {
		slot_head  = headOpt and headOpt.item_id or 3351,
		slot_armor = armorOpt and armorOpt.item_id or 3357,
		slot_legs  = legsOpt and legsOpt.item_id or 3557,
		slot_feet  = feetOpt and feetOpt.item_id or 3552,
		slot_right = rightOpt and rightOpt.item_id or 7773,
		slot_left  = leftOpt and leftOpt.item_id or 3425,
		slot_ammo  = ammoOpt or 0
	}
end

-- Fallback imediato se loadAll ainda não rodou no boot
if not BotEquipmentData.options or next(BotEquipmentData.options) == nil then
	BotEquipmentData.loadAll()
end
