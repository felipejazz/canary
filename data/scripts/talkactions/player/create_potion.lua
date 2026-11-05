-- TalkAction: /create_potion [potion name] [amount]
-- Available for all players (normal group). Same scheme as /create_ammo:
-- the total cost is debited from the player's bank balance.

local MAX_AMOUNT = 500

-- Price per potion (gold), based on the usual NPC potion prices.
local POTION_CATALOG = {
	["small health potion"] = { id = 7876, buy = 20 },
	["health potion"] = { id = 266, buy = 50 },
	["strong health potion"] = { id = 236, buy = 115 },
	["great health potion"] = { id = 239, buy = 190 },
	["ultimate health potion"] = { id = 7643, buy = 310 },
	["supreme health potion"] = { id = 23375, buy = 625 },
	["mana potion"] = { id = 268, buy = 50 },
	["strong mana potion"] = { id = 237, buy = 93 },
	["great mana potion"] = { id = 238, buy = 144 },
	["ultimate mana potion"] = { id = 23373, buy = 438 },
	["great spirit potion"] = { id = 7642, buy = 254 },
	["ultimate spirit potion"] = { id = 23374, buy = 438 },
	-- shortcuts
	["hp"] = { id = 266, buy = 50 },
	["shp"] = { id = 236, buy = 115 },
	["ghp"] = { id = 239, buy = 190 },
	["uhp"] = { id = 7643, buy = 310 },
	["mp"] = { id = 268, buy = 50 },
	["smp"] = { id = 237, buy = 93 },
	["gmp"] = { id = 238, buy = 144 },
	["ump"] = { id = 23373, buy = 438 },
	["gsp"] = { id = 7642, buy = 254 },
	["usp"] = { id = 23374, buy = 438 },
}

local USAGE = "Usage: /create_potion <potion_name> [amount]\n"
	.. "Examples:\n/create_potion great mana potion 100\n/create_potion ultimate health potion 50\n/create_potion gmp 200\n/create_potion uhp 50\n"
	.. "Shortcuts: hp shp ghp uhp supreme | mp smp gmp ump | gsp usp.\n"
	.. "Total cost will be debited from your bank balance."

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parseArguments(param)
	local trimmed = trim(param)
	if trimmed == "" then
		return nil, nil
	end

	if trimmed:find(",") then
		local parts = trimmed:split(",")
		return trim(parts[1]), tonumber(trim(parts[2] or "")) or 100
	end

	local tokens = {}
	for word in trimmed:gmatch("%S+") do
		table.insert(tokens, word)
	end

	local count = tonumber(tokens[#tokens])
	if count and #tokens > 1 then
		table.remove(tokens, #tokens)
		return table.concat(tokens, " "), count
	end
	return table.concat(tokens, " "), 100
end

local function onSayCreatePotion(player, words, param)
	local rawName, count = parseArguments(param)
	if not rawName then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, USAGE)
		return true
	end

	count = math.max(1, math.min(math.floor(count), MAX_AMOUNT))

	local entry = POTION_CATALOG[rawName:lower()]
	if not entry then
		player:sendCancelMessage(string.format("Potion '%s' not found. Type '/create_potion' to see usage.", rawName))
		return true
	end

	local itemType = ItemType(entry.id)
	local totalCost = entry.buy * count
	local balance = player:getBankBalance() or 0
	if balance < totalCost then
		player:sendCancelMessage(string.format("You do not have enough gold in your bank balance (%d gp needed, current balance: %d gp).", totalCost, balance))
		return true
	end

	-- Create first, debit only if the potions were actually delivered.
	if not player:addItem(entry.id, count) then
		return true -- addItem already told the player why (no room / capacity)
	end

	player:setBankBalance(balance - totalCost)
	player:getPosition():sendMagicEffect(CONST_ME_MAGIC_GREEN)
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("Purchased %d %s for %d gold (debited from bank). Remaining balance: %d gold.", count, itemType:getName(), totalCost, player:getBankBalance()))
	return true
end

local createPotion = TalkAction("/create_potion", "!create_potion")
createPotion.onSay = onSayCreatePotion
createPotion:separator(" ")
createPotion:groupType("normal")
createPotion:register()
