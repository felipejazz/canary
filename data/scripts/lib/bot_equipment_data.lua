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

function BotEquipmentData.getLoadout(level, baseVoc, personality)
	local bracket = BotEquipmentData.getBracketForLevel(level)
	local vocStr = VOC_NAME_BY_ID[baseVoc or 4] or "knight"
	personality = personality or 2

	local headOpt  = BotEquipmentData.getOptionForSlot(bracket, vocStr, "head", personality)
	local armorOpt = BotEquipmentData.getOptionForSlot(bracket, vocStr, "armor", personality)
	local legsOpt  = BotEquipmentData.getOptionForSlot(bracket, vocStr, "legs", personality)
	local feetOpt  = BotEquipmentData.getOptionForSlot(bracket, vocStr, "feet", personality)
	local rightOpt = BotEquipmentData.getOptionForSlot(bracket, vocStr, "right", personality)
	local leftOpt  = BotEquipmentData.getOptionForSlot(bracket, vocStr, "left", personality)

	return {
		slot_head  = headOpt and headOpt.item_id or 3351,
		slot_armor = armorOpt and armorOpt.item_id or 3357,
		slot_legs  = legsOpt and legsOpt.item_id or 3557,
		slot_feet  = feetOpt and feetOpt.item_id or 3552,
		slot_right = rightOpt and rightOpt.item_id or 7773,
		slot_left  = leftOpt and leftOpt.item_id or 3425
	}
end

-- Fallback imediato se loadAll ainda não rodou no boot
if not BotEquipmentData.options or next(BotEquipmentData.options) == nil then
	BotEquipmentData.loadAll()
end
