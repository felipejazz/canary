-- ============================================================================
-- Canary Talkaction: !spells / /spells / !magias / /magias
-- Displays all TibiaData catalog spells for the player's vocation.
-- Supports filters: !spells attack | !spells healing | !spells support | !spells <lvl>
-- ============================================================================

local spellsAction = TalkAction("!spells", "/spells", "!magias", "/magias")

function spellsAction.onSay(player, words, param)
	if not BOT_TIBIADATA_SPELLS then
		pcall(function() dofile("data/scripts/lib/bot_spell_table.lua") end)
	end

	local voc = player:getVocation()
	if not voc then
		return true
	end

	local baseVocId = voc:getBaseId()
	local vocName = voc:getName()
	local playerLevel = player:getLevel()

	local spellCatalog = BOT_TIBIADATA_SPELLS and BOT_TIBIADATA_SPELLS[baseVocId]
	if not spellCatalog or #spellCatalog == 0 then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Nenhuma magia encontrada para a sua vocação.")
		return true
	end

	local filter = param and param:lower():trim() or ""
	local filteredSpells = {}

	for _, sp in ipairs(spellCatalog) do
		local match = true
		if filter == "attack" or filter == "ataque" then
			match = (sp.group == "attack")
		elseif filter == "healing" or filter == "cura" then
			match = (sp.group == "healing")
		elseif filter == "support" or filter == "suporte" then
			match = (sp.group == "support")
		elseif filter == "rune" or filter == "runa" or filter == "runes" then
			match = sp.isRune
		elseif filter == "learned" or filter == "aprendidas" or filter == "my" then
			match = (sp.level <= playerLevel)
		elseif tonumber(filter) then
			local maxLvl = tonumber(filter)
			match = (sp.level <= maxLvl)
		end

		if match then
			table.insert(filteredSpells, sp)
		end
	end

	table.sort(filteredSpells, function(a, b)
		if a.level ~= b.level then
			return a.level < b.level
		end
		return a.name < b.name
	end)

	local lines = {}
	table.insert(lines, "==================================================")
	table.insert(lines, string.format("   MAGIAS: %s (Seu Level: %d)", vocName:upper(), playerLevel))
	table.insert(lines, "==================================================")
	table.insert(lines, "Dica: Use !spells [attack|healing|support|my|<lvl>]")
	table.insert(lines, "Ou pressione Ctrl+S para abrir a janela de magias do OTClient.")
	table.insert(lines, "--------------------------------------------------")

	local countLearned = 0
	for _, sp in ipairs(filteredSpells) do
		local status = (playerLevel >= sp.level) and "[OK]" or string.format("[Lvl %d]", sp.level)
		if playerLevel >= sp.level then
			countLearned = countLearned + 1
		end
		local line = string.format("%-8s | %-18s | Mana: %-4d | %s (%s)",
			status,
			sp.formula ~= "" and sp.formula or "(Rune)",
			sp.mana,
			sp.name,
			sp.group:upper()
		)
		table.insert(lines, line)
	end

	table.insert(lines, "--------------------------------------------------")
	table.insert(lines, string.format("Total: %d magias exibidas (%d disponíveis para seu level)", #filteredSpells, countLearned))
	table.insert(lines, "==================================================")

	local text = table.concat(lines, "\n")
	player:showTextDialog(1950, text)
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("Lista de magias aberta (%d magias). Pressione Ctrl+S para o console de magias.", #filteredSpells))
	return true
end

spellsAction:separator(" ")
spellsAction:groupType("normal")
spellsAction:register()
