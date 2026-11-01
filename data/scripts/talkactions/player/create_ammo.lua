-- TalkAction: /create_ammo [ammo name] [count]
-- Available for all players (normal group)
-- Debits the total cost directly from the player's bank balance.

local AMMO_CATALOG = {
	["arrow"] = { id = 3447, buy = 3 },
	["arrows"] = { id = 3447, buy = 3 },
	["simple arrow"] = { id = 21470, buy = 2 },
	["simple arrows"] = { id = 21470, buy = 2 },
	["bolt"] = { id = 3446, buy = 4 },
	["bolts"] = { id = 3446, buy = 4 },
	["sniper arrow"] = { id = 7364, buy = 5 },
	["sniper arrows"] = { id = 7364, buy = 5 },
	["piercing bolt"] = { id = 7363, buy = 5 },
	["piercing bolts"] = { id = 7363, buy = 5 },
	["earth arrow"] = { id = 774, buy = 5 },
	["earth arrows"] = { id = 774, buy = 5 },
	["flaming arrow"] = { id = 763, buy = 5 },
	["flaming arrows"] = { id = 763, buy = 5 },
	["flash arrow"] = { id = 761, buy = 5 },
	["flash arrows"] = { id = 761, buy = 5 },
	["shiver arrow"] = { id = 762, buy = 5 },
	["shiver arrows"] = { id = 762, buy = 5 },
	["poison arrow"] = { id = 3448, buy = 5 },
	["poison arrows"] = { id = 3448, buy = 5 },
	["burst arrow"] = { id = 3449, buy = 10 },
	["burst arrows"] = { id = 3449, buy = 10 },
	["power bolt"] = { id = 3450, buy = 7 },
	["power bolts"] = { id = 3450, buy = 7 },
	["onyx arrow"] = { id = 7365, buy = 7 },
	["onyx arrows"] = { id = 7365, buy = 7 },
	["tarsal arrow"] = { id = 14251, buy = 6 },
	["tarsal arrows"] = { id = 14251, buy = 6 },
	["vortex bolt"] = { id = 14252, buy = 6 },
	["vortex bolts"] = { id = 14252, buy = 6 },
	["drill bolt"] = { id = 16142, buy = 12 },
	["drill bolts"] = { id = 16142, buy = 12 },
	["envenomed arrow"] = { id = 16143, buy = 12 },
	["envenomed arrows"] = { id = 16143, buy = 12 },
	["crystalline arrow"] = { id = 15793, buy = 20 },
	["crystalline arrows"] = { id = 15793, buy = 20 },
	["crystal bolt"] = { id = 15792, buy = 20 },
	["crystal bolts"] = { id = 15792, buy = 20 },
	["prismatic bolt"] = { id = 16141, buy = 20 },
	["prismatic bolts"] = { id = 16141, buy = 20 },
	["spectral bolt"] = { id = 35902, buy = 70 },
	["spectral bolts"] = { id = 35902, buy = 70 },
	["diamond arrow"] = { id = 35901, buy = 130 },
	["diamond arrows"] = { id = 35901, buy = 130 },
	["infernal bolt"] = { id = 6528, buy = 150 },
	["infernal bolts"] = { id = 6528, buy = 150 },
	["spear"] = { id = 3277, buy = 5 },
	["spears"] = { id = 3277, buy = 5 },
	["hunting spear"] = { id = 3347, buy = 25 },
	["hunting spears"] = { id = 3347, buy = 25 },
	["enchanted spear"] = { id = 7367, buy = 30 },
	["enchanted spears"] = { id = 7367, buy = 30 },
	["throwing star"] = { id = 3287, buy = 42 },
	["throwing stars"] = { id = 3287, buy = 42 },
	["assassin star"] = { id = 7368, buy = 100 },
	["assassin stars"] = { id = 7368, buy = 100 },
	["royal star"] = { id = 25759, buy = 110 },
	["royal stars"] = { id = 25759, buy = 110 },
	["small stone"] = { id = 1781, buy = 10 },
	["small stones"] = { id = 1781, buy = 10 },
	["snowball"] = { id = 2992, buy = 5 },
	["snowballs"] = { id = 2992, buy = 5 },
}

local function parseArguments(param)
	local trimmed = param:gsub("^%s+", ""):gsub("%s+$", "")
	if trimmed == "" then
		return nil, nil
	end

	-- Check comma format: "crystalline arrow, 100"
	if trimmed:find(",") then
		local parts = trimmed:split(",")
		local name = parts[1]:gsub("^%s+", ""):gsub("%s+$", "")
		local count = tonumber(parts[2]:gsub("^%s+", ""):gsub("%s+$", "")) or 100
		return name, count
	end

	-- Space-separated tokens: check if last token is a number
	local tokens = {}
	for word in trimmed:gmatch("%S+") do
		table.insert(tokens, word)
	end

	if #tokens == 1 then
		local num = tonumber(tokens[1])
		if num then
			return "arrow", num
		end
		return tokens[1], 100
	end

	local lastToken = tokens[#tokens]
	local count = tonumber(lastToken)
	if count then
		table.remove(tokens, #tokens)
		local name = table.concat(tokens, " ")
		return name, count
	end

	return table.concat(tokens, " "), 100
end

local function isAmmoOrMissile(itemType)
	if not itemType or itemType:getId() == 0 then
		return false
	end

	local weaponType = itemType:getWeaponType()
	if weaponType == WEAPON_AMMO or weaponType == WEAPON_MISSILE or weaponType == WEAPON_DISTANCE then
		return true
	end

	local ammoType = itemType:getAmmoType()
	if ammoType and ammoType > 0 then
		return true
	end

	if itemType:getSlotPosition() == CONST_SLOT_AMMO then
		return true
	end

	return false
end

local function onSayCreateAmmo(player, words, param)
	local rawName, count = parseArguments(param)
	if not rawName then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Usage: /create_ammo <ammo_name> [amount]\nExamples:\n/create_ammo arrow 100\n/create_ammo crystalline arrow 200\n/create_ammo diamond arrow 100\n/create_ammo spectral bolt 100\n/create_ammo assassin star 100\nTotal cost will be debited from your bank balance.")
		return true
	end

	-- Validate count
	count = math.max(1, math.min(count, 2000))

	local cleanName = rawName:lower():gsub("^%s+", ""):gsub("%s+$", "")
	local catalogEntry = AMMO_CATALOG[cleanName]
	local itemType
	local unitPrice = 0

	if catalogEntry then
		itemType = ItemType(catalogEntry.id)
		unitPrice = catalogEntry.buy
	else
		-- Try resolving by ID or direct name
		local asNum = tonumber(cleanName)
		if asNum then
			itemType = ItemType(asNum)
		else
			itemType = ItemType(cleanName)
		end

		if not itemType or itemType:getId() == 0 then
			player:sendCancelMessage(string.format("Ammunition '%s' not found. Type '/create_ammo' to see usage and common ammunition names.", rawName))
			return true
		end

		if not isAmmoOrMissile(itemType) then
			player:sendCancelMessage(string.format("Item '%s' is not an ammunition or throwable distance weapon.", itemType:getName()))
			return true
		end

		-- Fallback price for unlisted ammo
		unitPrice = 20
	end

	local totalCost = unitPrice * count
	local balance = player:getBankBalance() or 0

	if balance < totalCost then
		player:sendCancelMessage(string.format("You do not have enough gold in your bank balance (%d gp needed, current balance: %d gp).", totalCost, balance))
		return true
	end

	-- Deduct bank balance
	player:setBankBalance(balance - totalCost)

	-- Add items to player
	player:addItem(itemType:getId(), count)

	-- Send magic effect and confirmation message
	player:getPosition():sendMagicEffect(CONST_ME_MAGIC_GREEN)
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("Purchased %d %s for %d gold (debited from bank). Remaining balance: %d gold.", count, itemType:getName(), totalCost, player:getBankBalance()))

	return true
end

local createAmmoSlash = TalkAction("/create_ammo", "!create_ammo")
createAmmoSlash.onSay = onSayCreateAmmo
createAmmoSlash:separator(" ")
createAmmoSlash:groupType("normal")
createAmmoSlash:register()
