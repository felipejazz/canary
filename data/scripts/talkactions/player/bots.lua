local botsTalkaction = TalkAction("!bots")

function botsTalkaction.onSay(player, words, param)
	param = (param or ""):gsub("^%s*(.-)%s*$", "%1")
	local lowerParam = param:lower()

	if lowerParam == "iniciar" or lowerParam == "start" then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "[Bots] Ativando cluster de bots e carregando IA DeepSeek...")
		os.execute("curl -s -X POST http://127.0.0.1:8085/api/bots/start > /dev/null 2>&1 &")

		local count = 0
		for _, p in ipairs(Game.getPlayers()) do
			if p:isBotPlayer() then
				BotSystem.activateBot(p)
				count = count + 1
			end
		end
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("[Bots] %d bots foram ativados com sucesso e estao patrulhando o mundo!", count))
		return true

	elseif lowerParam == "parar" or lowerParam == "stop" then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "[Bots] Pausando o cluster de bots...")
		os.execute("curl -s -X POST http://127.0.0.1:8085/api/bots/stop > /dev/null 2>&1 &")

		local count = 0
		for _, p in ipairs(Game.getPlayers()) do
			if p:isBotPlayer() then
				BotSystem.deactivateBot(p)
				count = count + 1
			end
		end
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("[Bots] %d bots pausados com sucesso.", count))
		return true

	elseif lowerParam == "reset soft" or lowerParam == "reset" then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "[Bots] Soft Reset disparado! Retornando todos os bots aos seus templos natais...")
		os.execute('curl -s -X POST http://127.0.0.1:8085/api/bots/reset -H "Content-Type: application/json" -d \'{"mode":"soft"}\' > /dev/null 2>&1 &')

		local count = 0
		for _, p in ipairs(Game.getPlayers()) do
			if p:isBotPlayer() then
				local town = p:getTown()
				if town then
					p:teleportTo(town:getTemplePosition())
				end
				p:addHealth(p:getMaxHealth())
				p:addMana(p:getMaxMana())
				local guid = p:getGuid()
				if BotState and BotState[guid] then
					BotState[guid].state = BOT_STATE.IDLE
					BotState[guid].walkTarget = nil
				end
				count = count + 1
			end
		end
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("[Bots] Soft Reset concluido: %d bots retornaram aos seus templos com vida e mana cheias!", count))
		return true

	elseif lowerParam == "reset hard" then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "[Bots] Hard Reset disparado! Zerando memoria, banco de dados, reservas, itens e reiniciando todos os bots no Nivel 8...")
		os.execute('curl -s -X POST http://127.0.0.1:8085/api/bots/reset -H "Content-Type: application/json" -d \'{"mode":"hard"}\' > /dev/null 2>&1 &')

		local count = 0
		if BotSystem and BotSystem.hardResetAllBots then
			count = BotSystem.hardResetAllBots(player)
		end
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("[Bots] Hard Reset concluido: %d bots foram zerados para o Nivel 8 (skills 10, ML 0) como em um reboot limpo do servidor!", count))
		return true

	elseif lowerParam == "train" or lowerParam == "treinar" then
		local count = 0
		for _, p in ipairs(Game.getPlayers()) do
			if p:isBotPlayer() and not p:isRemoved() then
				local guid = p:getGuid()
				local st = BotState and BotState[guid]
				if st and BotSystem.startStatueTraining(p, st, true) then
					count = count + 1
				end
			end
		end
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("[Bots] %d bots enviados para treinar nas estatuas de treino offline!", count))
		return true

	elseif lowerParam:sub(1, 4) == "add " then
		local rawArgs = param:sub(5)
		local parts = {}
		for part in rawArgs:gmatch("[^,]+") do
			table.insert(parts, part:gsub("^%s*(.-)%s*$", "%1"))
		end
		local name = parts[1] or "NovoBot"
		local voc = (parts[2] or "knight"):lower()
		local lvl = tonumber(parts[3]) or 8
		local city = (parts[4] or "thais"):lower()

		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("[Bots] Adicionando bot %s (%s lvl %d em %s)...", name, voc, lvl, city))
		local jsonPayload = string.format('{"name":"%s","vocation":"%s","level":%d,"city":"%s"}', name, voc, lvl, city)
		os.execute(string.format("curl -s -X POST http://127.0.0.1:8085/api/bots/add -H 'Content-Type: application/json' -d '%s' > /dev/null 2>&1 &", jsonPayload))
		return true

	elseif lowerParam:sub(1, 7) == "remove " then
		local name = param:sub(8):gsub("^%s*(.-)%s*$", "%1")
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("[Bots] Removendo bot %s...", name))
		local jsonPayload = string.format('{"name":"%s"}', name)
		os.execute(string.format("curl -s -X POST http://127.0.0.1:8085/api/bots/remove -H 'Content-Type: application/json' -d '%s' > /dev/null 2>&1 &", jsonPayload))
		return true

	elseif lowerParam == "status" then
		local onlineBots = 0
		for _, p in ipairs(Game.getPlayers()) do
			if p:isBotPlayer() then
				onlineBots = onlineBots + 1
			end
		end
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("[Bots] Cluster ativo com DeepSeek IA e FSM. Bots online: %d/75. Painel Web: http://localhost:8085", onlineBots))
		return true

	else
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Comandos: !bots start | !bots stop | !bots reset soft | !bots reset hard | !bots train | !talk <Bot>, <Mensagem> | !bots add <Nome>, <Voc>, <Lvl>, <Cidade> | !bots remove <Nome> | !bots status")
		return true
	end
end

botsTalkaction:separator(" ")
botsTalkaction:groupType("normal")
botsTalkaction:register()

-- ============================================================================
-- TalkAction para dialogo com Bots usando IA DeepSeek (!talk ou !bot)
-- Exemplo: !talk Nadia, onde estamos caçando?
-- ============================================================================
local talkBotTalkaction = TalkAction("!talk", "!bot", "!pilot", "!auto")

function talkBotTalkaction.onSay(player, words, param)
	param = (param or ""):gsub("^%s*(.-)%s*$", "%1")
	local lowerParam = param:lower()

	-- Autopilot toggle for logged-in bot player
	if player:isBotPlayer() and (lowerParam == "on" or lowerParam == "off" or lowerParam == "status" or lowerParam == "ligar" or lowerParam == "desligar") then
		local guid = player:getGuid()
		local state = BotState and BotState[guid]
		if not state then
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "[Piloto Automatico] Estado do bot nao encontrado.")
			return true
		end
		if lowerParam == "off" or lowerParam == "desligar" then
			state.manualControl = true
			BotSystem.clearAllTasks(player, state)
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "[Piloto Automatico] IA pausada com sucesso. Voce assumiu o controle manual do personagem!")
			return true
		elseif lowerParam == "on" or lowerParam == "ligar" then
			state.manualControl = false
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "[Piloto Automatico] IA ativada! O bot continuara sua rotina autonoma agora.")
			return true
		elseif lowerParam == "status" then
			local arch = BotSystem.getBotArchetype and BotSystem.getBotArchetype(player, state)
			local archName = arch and arch.name or "Padrao"
			local risk = arch and arch.riskTolerance or 2
			local pilotState = state.manualControl and "PAUSADO (Controle Manual)" or "ATIVO (Piloto Automatico)"
			local cave = state.huntScriptId and BotHuntData.scripts[state.huntScriptId] and BotHuntData.scripts[state.huntScriptId].name or "Nenhuma"
			player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("[Piloto Automatico] Status: %s | Arquetipo: %s (Risco: %d/5) | Cave: %s", pilotState, archName, risk, cave))
			return true
		end
	end

	-- Autopilot toggle for third-party / admin targeting a bot
	local targetBotName, toggleCmd = param:match("^([^,]+)%s*,%s*(%a+)$")
	if not targetBotName or not toggleCmd then
		targetBotName, toggleCmd = param:match("^(%S+)%s+(%a+)$")
	end
	if targetBotName and (toggleCmd:lower() == "on" or toggleCmd:lower() == "off" or toggleCmd:lower() == "status") then
		local targetBot = Player(targetBotName) or Player("Bot " .. targetBotName)
		if targetBot and targetBot:isBotPlayer() then
			local tGuid = targetBot:getGuid()
			local tState = BotState and BotState[tGuid]
			if tState then
				if toggleCmd:lower() == "off" then
					tState.manualControl = true
					BotSystem.clearAllTasks(targetBot, tState)
					player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("[Piloto Automatico] IA pausada para %s. Modo manual ativado.", targetBot:getName()))
				elseif toggleCmd:lower() == "on" then
					tState.manualControl = false
					player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("[Piloto Automatico] IA reativada para %s.", targetBot:getName()))
				else
					local pilotState = tState.manualControl and "PAUSADO (Manual)" or "ATIVO (Autonomo)"
					player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("[Piloto Automatico] %s: %s", targetBot:getName(), pilotState))
				end
				return true
			end
		end
	end

	if param == "" then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Uso: !bot on | !bot off | !bot status | !talk <NomeDoBot>, <Mensagem>")
		return true
	end

	local botName, msg = param:match("^([^,]+)%s*,%s*(.+)$")
	if not botName or not msg then
		botName, msg = param:match("^(%S+)%s+(.+)$")
	end

	if not botName or not msg then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, "Uso: !talk <NomeDoBot>, <Mensagem>  (Ex: !talk Nadia, onde vamos cacar?)")
		return true
	end

	botName = botName:gsub("^%s*(.-)%s*$", "%1")
	msg = msg:gsub("^%s*(.-)%s*$", "%1")

	local targetBot = Player(botName) or Creature(botName)
	if not targetBot then
		targetBot = Player("Bot " .. botName) or Creature("Bot " .. botName)
	end

	if not targetBot then
		player:sendTextMessage(MESSAGE_EVENT_ADVANCE, string.format("[Chat IA] Bot '%s' nao foi encontrado ou esta offline.", botName))
		return true
	end

	local realBotName = targetBot:getName()
	local vocName = "Knight"
	if targetBot:getVocation() then
		vocName = targetBot:getVocation():getName()
	end
	local lvl = targetBot:getLevel()

	player:sendTextMessage(MESSAGE_HOTKEY_PRESSED, string.format("[%s -> %s]: %s", player:getName(), realBotName, msg))

	local safeMsg = msg:gsub('"', '\\"'):gsub("'", "\\'")
	local safeSpeaker = player:getName():gsub('"', '\\"')
	local safeBot = realBotName:gsub('"', '\\"')
	local payload = string.format('{"message":"%s","bot_name":"%s","speaker_name":"%s","vocation":"%s","level":%d}',
		safeMsg, safeBot, safeSpeaker, vocName, lvl)

	local cmd = string.format("curl -s -m 5 -X POST http://127.0.0.1:8085/api/command/interaction -H 'Content-Type: application/json' -d '%s'", payload)
	local handle = io.popen(cmd)
	local rawResponse = handle:read("*a")
	handle:close()

	local speech = nil
	local action = "NONE"
	if rawResponse and rawResponse ~= "" then
		speech = rawResponse:match('"speech"%s*:%s*"([^"]+)"')
		action = rawResponse:match('"action"%s*:%s*"([^"]+)"') or "NONE"
	end

	if not speech or speech == "" then
		speech = string.format("Opa %s! To focado na hunt aqui, bora la!", player:getName())
	end

	speech = speech:gsub("\\n", " "):gsub('\\"', '"')
	targetBot:say(speech, TALKTYPE_SAY)

	if action == "FOLLOW" or msg:lower():find("segue") or msg:lower():find("follow") then
		local dest = player:getPosition():getClosestFreePosition(targetBot, 1) or player:getPosition()
		targetBot:teleportTo(dest)
	end

	return true
end

talkBotTalkaction:separator(" ")
talkBotTalkaction:groupType("normal")
talkBotTalkaction:register()
