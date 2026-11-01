-- ============================================================================
-- Bot Politics Talkactions
-- Player commands to interact with bot guilds, territories, taxes and hunted list:
-- !guilds, !territorios, !taxa, !pagar, !hunted, !peace
-- ============================================================================

local politicsTalk = TalkAction("!guilds", "!territorios", "!territorio", "!caves", "!taxa", "!pagar", "!hunted", "!peace")

function politicsTalk.onSay(player, words, param)
	if not player or player:isRemoved() then return true end

	if not BotPolitics or not BotPolitics.loaded then
		if BotPolitics and BotPolitics.loadAll then
			BotPolitics.loadAll()
		end
	end

	local cmd = words:lower()
	param = (param or ""):gsub("^%s*(.-)%s*$", "%1")

	-- ------------------------------------------------------------------------
	-- 1. !guilds - Lista todas as guildas ativas e sua política
	-- ------------------------------------------------------------------------
	if cmd == "!guilds" then
		player:sendTextMessage(MESSAGE_STATUS_DEFAULT, "=== GUILDAS ATIVAS NO SERVIDOR ===")
		local count = 0
		for gId, g in pairs(BotPolitics.guilds or {}) do
			local alignDesc = (g.alignment == "DOMINANDO" and "Dominando [Hostil]")
				or (g.alignment == "COMMERCIAL" and "Comercial [Negociadora]")
				or "Neutra [Cooperativa]"
			local lPlayer = Player(g.ownerid)
			local lName = lPlayer and lPlayer:getName() or "Lider Offline"

			player:sendTextMessage(MESSAGE_STATUS_DEFAULT, string.format(
				"• %s (ID %d) | Alinhamento: %s | Membros: %d | Tesouro: %d gps | Lider: %s",
				g.name, gId, alignDesc, #(g.members or {}), g.treasury or 0, lName
			))
			count = count + 1
		end
		if count == 0 then
			player:sendTextMessage(MESSAGE_STATUS_DEFAULT, "Nenhuma guilda formada ate o momento.")
		end
		player:sendTextMessage(MESSAGE_STATUS_DEFAULT, "=================================")
		return true

	-- ------------------------------------------------------------------------
	-- 2. !territorios / !caves - Mostra as caves dominadas
	-- ------------------------------------------------------------------------
	elseif cmd == "!territorios" or cmd == "!territorio" or cmd == "!caves" then
		player:sendTextMessage(MESSAGE_STATUS_DEFAULT, "=== TERRITORIOS E CAVES DOMINADAS ===")
		local count = 0
		for caveId, t in pairs(BotPolitics.territories or {}) do
			if t.status == "ACTIVE" then
				local g = BotPolitics.guilds[t.guild_id]
				local gName = g and g.name or "Desconhecida"
				local gAlign = g and g.alignment or "NEUTRAL"
				local fee = g and BotPolitics.getCaveTaxFee(caveId, g) or 0
				local feeStr = fee > 0 and (fee .. " gps/hora") or "Isenta / Livre"

				player:sendTextMessage(MESSAGE_STATUS_DEFAULT, string.format(
					"• Cave: %s | Guilda: %s (%s) | Taxa: %s",
					caveId, gName, gAlign, feeStr
				))
				count = count + 1
			end
		end
		if count == 0 then
			player:sendTextMessage(MESSAGE_STATUS_DEFAULT, "Todas as caves estao livres e sem dominio de guildas.")
		end
		player:sendTextMessage(MESSAGE_STATUS_DEFAULT, "=====================================")
		return true

	-- ------------------------------------------------------------------------
	-- 3. !taxa - Mostra a taxa da cave onde o jogador esta ou status do passe
	-- ------------------------------------------------------------------------
	elseif cmd == "!taxa" then
		local pos = player:getPosition()
		-- Determine closest hunt script / cave
		local currentCave = nil
		if BotHuntData and BotHuntData.scripts then
			for _, script in pairs(BotHuntData.scripts) do
				local wps = BotHuntData.waypoints[script.id]
				if wps and wps.hunt_patrol and #wps.hunt_patrol > 0 then
					for _, wp in ipairs(wps.hunt_patrol) do
						local pPos = Position(wp.pos_x, wp.pos_y, wp.pos_z)
						if pPos and pos:getDistance(pPos) < 25 and pos.z == pPos.z then
							currentCave = script.name
							break
						end
					end
				end
				if currentCave then break end
			end
		end

		if not currentCave then
			player:sendTextMessage(MESSAGE_STATUS_DEFAULT, "[Taxa] Voce nao esta dentro do perimetro de uma cave reconhecida.")
			return true
		end

		local terr = BotPolitics.territories[currentCave]
		if not terr or terr.status ~= "ACTIVE" then
			player:sendTextMessage(MESSAGE_STATUS_DEFAULT, string.format("[Taxa] A cave '%s' e neutra e nao possui cobranca de taxa.", currentCave))
			return true
		end

		local g = BotPolitics.guilds[terr.guild_id]
		local pName = player:getName()
		local hasPass = BotPolitics.hasValidPass(currentCave, pName)

		if hasPass then
			local key = string.format("%s:%s", currentCave, pName:lower())
			local expTs = BotPolitics.passes[key] or os.time()
			local remSec = math.max(0, expTs - os.time())
			local remMin = math.floor(remSec / 60)
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("[Taxa] Voce possui PASSE ATIVO para '%s'! Tempo restante: %d minutos.", currentCave, remMin))
		else
			local fee = g and BotPolitics.getCaveTaxFee(currentCave, g) or 0
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format(
				"[Taxa] Cave '%s' dominada pela guilda '%s' (%s). Taxa: %d gps por 1 hora. Digite !pagar para regularizar.",
				currentCave, g and g.name or "Guilda", g and g.alignment or "", fee
			))
		end
		return true

	-- ------------------------------------------------------------------------
	-- 4. !pagar - Paga a taxa da cave atual
	-- ------------------------------------------------------------------------
	elseif cmd == "!pagar" then
		local pos = player:getPosition()
		local currentCave = nil

		-- First, check if player has a pending ultimatum
		local pName = player:getName():lower()
		for ultKey, ult in pairs(BotPolitics.activeUltimatums or {}) do
			if ultKey:find(":" .. pName) then
				currentCave = ult.caveName
				break
			end
		end

		-- If no ultimatum, find cave by proximity
		if not currentCave and BotHuntData and BotHuntData.scripts then
			for _, script in pairs(BotHuntData.scripts) do
				local wps = BotHuntData.waypoints[script.id]
				if wps and wps.hunt_patrol and #wps.hunt_patrol > 0 then
					for _, wp in ipairs(wps.hunt_patrol) do
						local pPos = Position(wp.pos_x, wp.pos_y, wp.pos_z)
						if pPos and pos:getDistance(pPos) < 30 and pos.z == pPos.z then
							currentCave = script.name
							break
						end
					end
				end
				if currentCave then break end
			end
		end

		if not currentCave then
			player:sendTextMessage(MESSAGE_STATUS_DEFAULT, "[Pagar] Voce precisa estar proximo ou dentro de uma cave dominada para pagar a taxa.")
			return true
		end

		local ok, fee, gName, expTs = BotPolitics.payCaveTax(player, currentCave)
		if ok then
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format(
				"[Pagar] Pagamento de %d gps realizado com sucesso para a guilda '%s'! Acesso livre a '%s' garantido ate %s.",
				fee, gName, currentCave, os.date("%H:%M:%S", expTs)
			))
		else
			player:sendTextMessage(MESSAGE_STATUS_DEFAULT, "[Pagar] " .. tostring(fee))
		end
		return true

	-- ------------------------------------------------------------------------
	-- 5. !hunted - Consulta quem marcou o jogador como hunted
	-- ------------------------------------------------------------------------
	elseif cmd == "!hunted" then
		local pName = player:getName()
		player:sendTextMessage(MESSAGE_STATUS_DEFAULT, "=== STATUS DE HUNTED ===")
		local count = 0
		for _, h in pairs(BotPolitics.hunted or {}) do
			if h.target_name:lower() == pName:lower() then
				local g = BotPolitics.guilds[h.guild_id]
				local gName = g and g.name or ("Guilda ID " .. h.guild_id)
				player:sendTextMessage(MESSAGE_STATUS_DEFAULT, string.format(
					"• HUNTED por '%s'! Motivo: %s | Multa de Paz: %d gps (!peace %s) | Expira em: %s",
					gName, h.reason, h.peace_fee, gName, h.expires_at
				))
				count = count + 1
			end
		end
		if count == 0 then
			player:sendTextMessage(MESSAGE_STATUS_DEFAULT, "Voce esta limpo! Nenhuma guilda possui hunted ativo contra voce.")
		end
		player:sendTextMessage(MESSAGE_STATUS_DEFAULT, "========================")
		return true

	-- ------------------------------------------------------------------------
	-- 6. !peace <guild> - Paga a multa de paz para remover hunted
	-- ------------------------------------------------------------------------
	elseif cmd == "!peace" then
		if param == "" then
			player:sendTextMessage(MESSAGE_STATUS_DEFAULT, "Uso: !peace <nome da guilda>")
			return true
		end

		local ok, fee, gName = BotPolitics.payPeaceFee(player, param)
		if not ok then
			player:sendTextMessage(MESSAGE_STATUS_DEFAULT, "[Peace] " .. tostring(fee))
		end
		return true
	end

	return true
end

politicsTalk:separator(" ")
politicsTalk:groupType("normal")
politicsTalk:register()
