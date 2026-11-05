-- TalkAction: /create_rune [rune name] [amount]
-- Available for all players (normal group). Same scheme as /create_ammo:
-- the total cost is debited from the player's bank balance.
-- `amount` = number of rune items; each one comes with its default charges.

local MAX_AMOUNT = 100 -- one backpack worth; each rune is a separate item

-- Price per rune item (gold), based on the usual NPC rune prices.
local RUNE_CATALOG = {
	["light magic missile"] = { id = 3174, buy = 4 },
	["heavy magic missile"] = { id = 3198, buy = 12 },
	["intense healing"] = { id = 3152, buy = 95 },
	["ultimate healing"] = { id = 3160, buy = 175 },
	["sudden death"] = { id = 3155, buy = 162 },
	["sd"] = { id = 3155, buy = 162 },
	["uh"] = { id = 3160, buy = 175 },
	["ih"] = { id = 3152, buy = 95 },
	["hmm"] = { id = 3198, buy = 12 },
	["lmm"] = { id = 3174, buy = 4 },
	["great fireball"] = { id = 3191, buy = 57 },
	["gfb"] = { id = 3191, buy = 57 },
	["explosion"] = { id = 3200, buy = 31 },
	["fire bomb"] = { id = 3192, buy = 147 },
	["poison bomb"] = { id = 3173, buy = 85 },
	["energy bomb"] = { id = 3149, buy = 203 },
	["soulfire"] = { id = 3195, buy = 46 },
	["fireball"] = { id = 3189, buy = 30 },
	["icicle"] = { id = 3158, buy = 30 },
	["avalanche"] = { id = 3161, buy = 57 },
	["stone shower"] = { id = 3175, buy = 37 },
	["thunderstorm"] = { id = 3202, buy = 52 },
	["stalagmite"] = { id = 3179, buy = 12 },
	["holy missile"] = { id = 3182, buy = 16 },
	["magic wall"] = { id = 3180, buy = 116 },
	["mw"] = { id = 3180, buy = 116 },
	["wild growth"] = { id = 3156, buy = 160 },
	["wg"] = { id = 3156, buy = 160 },
	["destroy field"] = { id = 3148, buy = 15 },
	["convince creature"] = { id = 3177, buy = 80 },
	["chameleon"] = { id = 3178, buy = 210 },
	["animate dead"] = { id = 3203, buy = 375 },
	["cure poison"] = { id = 3153, buy = 65 },
	["energy field"] = { id = 3164, buy = 38 },
	["fire field"] = { id = 3188, buy = 28 },
	["poison field"] = { id = 3172, buy = 21 },
	["energy wall"] = { id = 3166, buy = 85 },
	["fire wall"] = { id = 3190, buy = 61 },
	["poison wall"] = { id = 3176, buy = 52 },
}

local FALLBACK_PRICE = 100 -- runes not in the catalog (resolved by id / item name)

local USAGE = "Usage: /create_rune <rune_name> [amount]\n"
	.. "Examples:\n/create_rune sudden death 50\n/create_rune ultimate healing 30\n/create_rune sd 100\n/create_rune magic wall 10\n"
	.. "Total cost will be debited from your bank balance."

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parseArguments(param)
	local trimmed = trim(param)
	if trimmed == "" then
		return nil, nil
	end

	-- Comma format: "sudden death, 50"
	if trimmed:find(",") then
		local parts = trimmed:split(",")
		return trim(parts[1]), tonumber(trim(parts[2] or "")) or 1
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
	return table.concat(tokens, " "), 1
end

local function resolveRune(cleanName)
	local entry = RUNE_CATALOG[cleanName]
	if entry then
		return ItemType(entry.id), entry.buy
	end

	local asNum = tonumber(cleanName)
	local itemType = asNum and ItemType(asNum) or ItemType(cleanName)
	if not itemType or itemType:getId() == 0 then
		itemType = ItemType(cleanName .. " rune") -- "sudden death" -> "sudden death rune"
	end
	return itemType, FALLBACK_PRICE
end

local function onSayCreateRune(player, words, param)
	local rawName, count = parseArguments(param)
	if not rawName then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, USAGE)
		return true
	end

	count = math.max(1, math.min(math.floor(count), MAX_AMOUNT))

	local itemType, unitPrice = resolveRune(rawName:lower())
	if not itemType or itemType:getId() == 0 then
		player:sendCancelMessage(string.format("Rune '%s' not found. Type '/create_rune' to see usage.", rawName))
		return true
	end
	if itemType:getType() ~= ITEM_TYPE_RUNE then
		player:sendCancelMessage(string.format("Item '%s' is not a rune.", itemType:getName()))
		return true
	end

	local totalCost = unitPrice * count
	local balance = player:getBankBalance() or 0
	if balance < totalCost then
		player:sendCancelMessage(string.format("You do not have enough gold in your bank balance (%d gp needed, current balance: %d gp).", totalCost, balance))
		return true
	end

	-- Create first, debit only if the runes were actually delivered.
	local charges = math.max(1, itemType:getCharges())
	local result = player:addItem(itemType:getId(), count, true, charges)
	if not result then
		return true -- addItem already told the player why (no room / capacity)
	end

	player:setBankBalance(balance - totalCost)
	player:getPosition():sendMagicEffect(CONST_ME_MAGIC_GREEN)
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("Purchased %d %s (%d charges each) for %d gold (debited from bank). Remaining balance: %d gold.", count, itemType:getName(), charges, totalCost, player:getBankBalance()))
	return true
end

local createRune = TalkAction("/create_rune", "!create_rune")
createRune.onSay = onSayCreateRune
createRune:separator(" ")
createRune:groupType("normal")
createRune:register()
