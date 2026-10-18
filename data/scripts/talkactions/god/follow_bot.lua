-- Comando para GOD e Gamemaster seguir bots e players automaticamente em tempo real
-- Autor: Tibia Local

_G.ActiveGodFollowers = _G.ActiveGodFollowers or {}

local function findTargetCreature(query)
	if not query or query == "" then
		return nil
	end

	local cleanQuery = query:gsub("^%s*(.-)%s*$", "%1")
	local lower = cleanQuery:lower()

	-- 1. Direct Creature / Player lookup
	local target = Creature(cleanQuery) or Player(cleanQuery)
	if target then return target end

	-- 2. Lookup with "Bot " prefix if not present
	if not lower:find("^bot ") then
		target = Creature("Bot " .. cleanQuery) or Player("Bot " .. cleanQuery)
		if target then return target end
	end

	-- 3. Lookup without "Bot " prefix if present
	if lower:find("^bot ") then
		local noBot = cleanQuery:sub(5):gsub("^%s*(.-)%s*$", "%1")
		target = Creature(noBot) or Player(noBot)
		if target then return target end
	end

	-- 4. Search active players in Game.getPlayers()
	local allPlayers = Game.getPlayers()
	for _, p in ipairs(allPlayers) do
		local pName = p:getName()
		local pLower = pName:lower()
		if pLower == lower or pLower == ("bot " .. lower) or ("bot " .. pLower) == lower then
			return p
		end
		if pLower:sub(5) == lower or lower:sub(5) == pLower then
			return p
		end
	end

	-- 5. Search in _G.BotPlayers
	if _G.BotPlayers then
		for _, b in pairs(_G.BotPlayers) do
			if b and not b:isRemoved() then
				local bName = b:getName()
				local bLower = bName:lower()
				if bLower == lower or bLower == ("bot " .. lower) or ("bot " .. bLower) == lower or bLower:sub(5) == lower then
					return b
				end
			end
		end
	end

	-- 6. Partial match across Game.getPlayers()
	for _, p in ipairs(allPlayers) do
		local pLower = p:getName():lower()
		if pLower:find(lower, 1, true) then
			return p
		end
	end

	return nil
end

local function stepFollow(godGuid, targetName)
	local state = _G.ActiveGodFollowers[godGuid]
	if not state or not state.active or state.targetName ~= targetName then
		return
	end

	local godPlayer = Player(godGuid)
	if not godPlayer then
		_G.ActiveGodFollowers[godGuid] = nil
		return
	end

	local targetCreature = findTargetCreature(targetName)
	if not targetCreature then
		godPlayer:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("[Follow] '%s' deslogou ou não está mais visível no mundo. Rastreamento pausado.", targetName))
		_G.ActiveGodFollowers[godGuid] = nil
		return
	end

	local pGod = godPlayer:getPosition()
	local pTarget = targetCreature:getPosition()

	-- Teleporta se o bot mudar de andar (Z) ou se afastar mais de 2 tiles
	if pGod.z ~= pTarget.z or pGod:getDistanceBetween(pTarget) > 2 then
		local dest = godPlayer:getClosestFreePosition(pTarget, false)
		if not dest or dest.x == 0 then
			dest = pTarget
		end
		godPlayer:teleportTo(dest)
	end

	-- Agenda próximo passo em 500ms
	addEvent(stepFollow, 500, godGuid, targetName)
end

local followTalkaction = TalkAction("/follow", "/unfollow")

function followTalkaction.onSay(player, words, param)
	logCommand(player, words, param)

	local godGuid = player:getGuid()
	param = (param or ""):gsub("^%s*(.-)%s*$", "%1")
	local lowerParam = param:lower()

	-- Cancelar follow
	if words == "/unfollow" or lowerParam == "stop" or lowerParam == "parar" or lowerParam == "off" then
		if _G.ActiveGodFollowers[godGuid] then
			local prevTarget = _G.ActiveGodFollowers[godGuid].targetName
			_G.ActiveGodFollowers[godGuid] = nil
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("[Follow] Você parou de seguir '%s'.", prevTarget))
		else
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "[Follow] Você não está seguindo nenhum bot no momento.")
		end
		return true
	end

	-- Sem parâmetros: exibe status ou ajuda
	if param == "" then
		if _G.ActiveGodFollowers[godGuid] then
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("[Follow] Você está atualmente seguindo: '%s'. Digite /unfollow para parar.", _G.ActiveGodFollowers[godGuid].targetName))
		else
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Uso: /follow <NomeDoBot> | /follow stop | /unfollow")
		end
		return true
	end

	-- Busca pelo bot ou player
	local target = findTargetCreature(param)

	if not target then
		player:sendCancelMessage(string.format("Bot ou jogador '%s' não encontrado ou está offline.", param))
		return true
	end

	local targetName = target:getName()

	-- Ativa Ghost Mode automaticamente no GOD se ainda não estiver ativo
	if not player:isInGhostMode() then
		player:setGhostMode(true)
		player:sendTextMessage(MESSAGE_HOTKEY_PRESSED, "[Ghost Mode] Você está invisível para inspecionar o bot sem interferência de monstros.")
	end

	-- Registra no mapa global
	_G.ActiveGodFollowers[godGuid] = {
		targetName = targetName,
		active = true
	}

	-- Teleporta imediatamente para perto do bot
	local pTarget = target:getPosition()
	local dest = player:getClosestFreePosition(pTarget, false)
	if not dest or dest.x == 0 then
		dest = pTarget
	end
	player:teleportTo(dest)
	player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("[Follow] Agora seguindo '%s' em (%d, %d, %d). Subidas de escada e trocas de andar serão acompanhadas automaticamente. Digite /unfollow para sair.", targetName, pTarget.x, pTarget.y, pTarget.z))

	-- Inicia o ciclo suave a cada 500ms
	addEvent(stepFollow, 500, godGuid, targetName)
	return true
end

followTalkaction:separator(" ")
followTalkaction:groupType("gamemaster")
followTalkaction:register()
