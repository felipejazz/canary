-- ============================================================================
-- Talkaction: !test_hunts / !test_hunt / /test_hunts / /test_hunt
-- In-Game GOD/Gamemaster command to trigger and monitor hunt accessibility testing
-- Usage:
--   !test_hunts all               — test all enabled hunts
--   !test_hunts <id>              — test a specific hunt script ID
--   !test_hunts town <town_name>  — test all hunts for a specific town
--   !test_hunts parallel <N>      — test all hunts using N parallel testers (1-8)
--   !test_hunts stop              — stop active testing run
--   !test_hunts status            — show current testing status and progress
-- ============================================================================

local testHuntsCmd = TalkAction("!test_hunts", "/test_hunts", "!test_hunt", "/test_hunt")

function testHuntsCmd.onSay(player, words, param)
	-- Require God/GM access (group >= 3 or access flag)
	if player:getGroup():getAccess() == false then
		player:sendTextMessage(MESSAGE_STATUS, "Voce precisa de acesso GOD/Gamemaster para executar este comando.")
		return true
	end

	param = param and param:match("^%s*(.-)%s*$") or ""

	if param == "" or param == "help" then
		player:sendTextMessage(MESSAGE_STATUS, "=== Gerenciador de Testes de Hunts ===")
		player:sendTextMessage(MESSAGE_STATUS, "!test_hunts untested         - Testa apenas as hunts que ainda não foram testadas")
		player:sendTextMessage(MESSAGE_STATUS, "!test_hunts all              - Testa hunts pendentes em sequência (ou 'all force' para todas)")
		player:sendTextMessage(MESSAGE_STATUS, "!test_hunts <id>             - Testa uma hunt específica pelo ID")
		player:sendTextMessage(MESSAGE_STATUS, "!test_hunts town <cidade>    - Testa hunts de uma cidade")
		player:sendTextMessage(MESSAGE_STATUS, "!test_hunts parallel <N>     - Executa testes com N testers simultâneos (1 a 8)")
		player:sendTextMessage(MESSAGE_STATUS, "!test_hunts status           - Exibe progresso global e status atual")
		player:sendTextMessage(MESSAGE_STATUS, "!test_hunts reset            - Zera histórico de relatórios anteriores")
		player:sendTextMessage(MESSAGE_STATUS, "!test_hunts stop             - Interrompe a bateria de testes")
		return true
	end

	local lowerParam = param:lower()

	-- Status command
	if lowerParam == "status" then
		local statusText = HuntTester.getStatus()
		player:sendTextMessage(MESSAGE_STATUS, "[HuntTester Status]\n" .. statusText)
		return true
	end

	-- Reset command
	if lowerParam == "reset" then
		HuntTester.resetReports()
		player:sendTextMessage(MESSAGE_STATUS, "[HuntTester] Histórico de testes zerado com sucesso.")
		return true
	end

	-- Stop command
	if lowerParam == "stop" then
		HuntTester.stop()
		player:sendTextMessage(MESSAGE_STATUS, "[HuntTester] Comando de parada enviado com sucesso.")
		return true
	end

	-- Untested command: untested [workers]
	local untestedWorkers = param:match("^untested%s*(%d*)")
	if lowerParam == "untested" or (untestedWorkers and untestedWorkers ~= "") then
		local nWorkers = math.max(1, math.min(8, tonumber(untestedWorkers) or 1))
		local success = HuntTester.start({
			untestedOnly = true,
			workers = nWorkers,
			parallelExplicit = (nWorkers > 1)
		})
		if success then
			player:sendTextMessage(MESSAGE_STATUS, string.format("[HuntTester] Iniciando testes apenas de hunts não-testadas (%d workers)...", nWorkers))
		end
		return true
	end

	-- Failed command: failed [workers]
	local failedWorkers = param:match("^failed%s*(%d*)")
	if lowerParam == "failed" or (failedWorkers and failedWorkers ~= "") then
		local nWorkers = math.max(1, math.min(8, tonumber(failedWorkers) or 1))
		local success = HuntTester.start({
			failedOnly = true,
			workers = nWorkers,
			parallelExplicit = (nWorkers > 1)
		})
		if success then
			player:sendTextMessage(MESSAGE_STATUS, string.format("[HuntTester] Iniciando testes de re-validação das hunts que falharam (%d workers)...", nWorkers))
		end
		return true
	end

	-- Parallel command: parallel <N> [town]
	local parallelWorkers, restArgs = param:match("^parallel%s+(%d+)%s*(.*)")
	if parallelWorkers then
		local nWorkers = math.max(1, math.min(8, tonumber(parallelWorkers) or 1))
		local townArg = restArgs ~= "" and restArgs or nil
		local forceArg = false
		if townArg and townArg:lower():find("force") then
			forceArg = true
			townArg = townArg:lower():gsub("force", ""):match("^%s*(.-)%s*$")
			if townArg == "" then townArg = nil end
		end
		local success = HuntTester.start({
			workers = nWorkers,
			town = townArg,
			force = forceArg,
			parallelExplicit = true
		})
		if success then
			player:sendTextMessage(MESSAGE_STATUS, string.format(
				"[HuntTester] Bateria paralela iniciada com %d Testers!%s%s",
				nWorkers, townArg and (" (Filtro Cidade: " .. townArg .. ")") or "",
				forceArg and " [FORCE]" or " [Apenas Pendentes]"
			))
		end
		return true
	end

	-- Town command: town <cidade>
	local townMatch = param:match("^town%s+(.+)")
	if townMatch then
		local townName = townMatch:match("^%s*(.-)%s*$")
		local forceTown = false
		if townName:lower():find("force") then
			forceTown = true
			townName = townName:lower():gsub("force", ""):match("^%s*(.-)%s*$")
		end
		local success = HuntTester.start({
			town = townName,
			force = forceTown,
			workers = 1
		})
		if success then
			player:sendTextMessage(MESSAGE_STATUS, string.format("[HuntTester] Iniciando testes para a cidade '%s'...", townName))
		end
		return true
	end

	-- All command: all / all force
	if lowerParam == "all" or lowerParam == "all force" then
		local isForce = (lowerParam == "all force")
		local success = HuntTester.start({
			force = isForce,
			workers = 1
		})
		if success then
			player:sendTextMessage(MESSAGE_STATUS, string.format(
				"[HuntTester] Iniciando testes de todas as hunts em sequência (%s)...",
				isForce and "FORCE: re-testando todas" or "apenas pendentes"
			))
		end
		return true
	end

	-- Specific hunt by ID: <id> [force]
	local idStr, idRest = param:match("^(%d+)%s*(.*)")
	if idStr then
		local huntId = tonumber(idStr)
		local isForce = (idRest and idRest:lower():find("force")) and true or false
		local success = HuntTester.start({
			huntId = huntId,
			force = isForce,
			workers = 1
		})
		if success then
			player:sendTextMessage(MESSAGE_STATUS, string.format(
				"[HuntTester] Iniciando teste individual da Hunt #%d%s...",
				huntId, isForce and " [FORCE]" or ""
			))
		end
		return true
	end

	player:sendTextMessage(MESSAGE_STATUS, "Parametro invalido: '" .. param .. "'. Use '!test_hunts help' para ver instrucoes.")
	return true
end

testHuntsCmd:separator(" ")
testHuntsCmd:groupType("gamemaster")
testHuntsCmd:register()
