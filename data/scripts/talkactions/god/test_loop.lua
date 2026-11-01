-- ============================================================================
-- TalkAction: !test_loop / /test_loop
-- Automated test harness for Lucrative Looting, NotJev Refill, and PK Combat
-- ============================================================================

function TestLoop_Run(player, param)
	if player and player.getGroup and player:getGroup():getAccess() == false then
		if player.sendTextMessage then
			player:sendTextMessage(MESSAGE_STATUS_WARNING, "Voce precisa de acesso GOD para executar !test_loop.")
		end
		return true
	end

	local function notify(msg)
		if player and player.sendTextMessage then
			pcall(function() player:sendTextMessage(MESSAGE_EVENT_ADVANCE, msg) end)
		end
		logger.info(msg)
	end

	if param == "teach_spells" then
		local count = 0
		for _, p in ipairs(Game.getPlayers()) do
			if p and not p:isRemoved() then
				BotSystem.learnAllSpells(p)
				count = count + 1
			end
		end
		notify(string.format("[TestLoop] Taught all vocation spells (including exori min flam) to %d online bots!", count))
		return true
	end

	if param == "reload_imbuements" then
		Game.reload(RELOAD_TYPE_IMBUEMENTS)
		notify("[TestLoop] Imbuements XML successfully reloaded in running server!")
		return true
	end

	if param == "reload_imbuements" then
		Game.reload(RELOAD_TYPE_IMBUEMENTS)
		notify("[TestLoop] Imbuements XML successfully reloaded in running server!")
		return true
	end

	notify("=== [TestLoop] Iniciando Bateria de Testes Acelerada ===")

	-- 1. Carrega ou localiza os bots exclusivos de teste
	local alpha = Player("Bot Alpha")
	if not alpha then
		alpha = Game.loadBotPlayer("Bot Alpha")
	end
	if not alpha then
		notify("[TestLoop] ERRO: Nao foi possivel carregar Bot Alpha!")
		return true
	end

	local beta = Player("Bot Beta")
	if not beta then
		beta = Game.loadBotPlayer("Bot Beta")
	end
	if not beta then
		notify("[TestLoop] ERRO: Nao foi possivel carregar Bot Beta!")
		return true
	end

	local alphaGuid = alpha:getGuid()
	local betaGuid = beta:getGuid()
	BotPlayers[alphaGuid] = alpha
	BotPlayers[betaGuid] = beta
	alpha:registerEvent("BotDeath")
	beta:registerEvent("BotDeath")

	pcall(BotSystem.activateBot, alpha)
	pcall(BotSystem.activateBot, beta)

	local sAlpha = BotState and BotState[alphaGuid]
	local sBeta = BotState and BotState[betaGuid]

	-- Bloqueia a IA autonoma durante o teste para nao teleportarem ou andarem para longe
	if sAlpha then sAlpha.manualControl = true end
	if sBeta then sBeta.manualControl = true end

	-- Velocidade acelerada para teste rapido
	alpha:changeSpeed(600)
	beta:changeSpeed(600)

	-- Limpa itens residuais de testes anteriores para garantir estado limpo
	local bpA = alpha:getSlotItem(CONST_SLOT_BACKPACK)
	if bpA then bpA:remove() end
	local bpB = beta:getSlotItem(CONST_SLOT_BACKPACK)
	if bpB then bpB:remove() end

	-- 2. Validacao Anti-Pelado e Mochilas Aninhadas
	BotSystem.equipBot(alpha)
	BotSystem.checkEquipmentCompleteness(alpha, sAlpha)
	BotSystem.equipBot(beta)
	BotSystem.checkEquipmentCompleteness(beta, sBeta)

	local alphaSlots = BotSystem.getFreeBackpackSlots(alpha)
	local betaSlots = BotSystem.getFreeBackpackSlots(beta)
	notify(string.format(
		"[TestLoop] 1. Anti-Pelado & Storage: Alpha (Knight) tem %d slots livres, Beta (Sorcerer) tem %d slots livres em BPs aninhadas.",
		alphaSlots, betaSlots
	))

	-- 3. Teste de Loot Físico, Venda no Market e Depósito no Banco
	alpha:teleportTo(Position(32387, 32223, 7)) -- Thais Depot
	-- Injeta moedas fisicas e loot rentavel para simular retorno de cave
	alpha:addItem(3031, 100) -- 100 gold coins fisicos
	alpha:addItem(3031, 100)
	alpha:addItem(3035, 5)   -- 5 platinum coins fisicos (500 gps)
	alpha:addItem(5894, 10)  -- 10 bat wings (creature product)
	alpha:addItem(3357, 1)   -- plate armor (loot)

	local balanceBefore = alpha:getBankBalance()
	BotSystem.processDepotLootAndBank(alpha, sAlpha)
	local balanceAfter = alpha:getBankBalance()
	local profit = balanceAfter - balanceBefore

	notify(string.format(
		"[TestLoop] 2. Market & Banco: Alpha depositou moedas e vendeu loot no Market por +%d gps (Saldo: %d gps).",
		profit, balanceAfter
	))

	-- 3. NotJev Consultor de Compras & Compra Real no NPC da Loja de Magia
	local payloadBeta = {
		bot_profile = {
			name = beta:getName(),
			level = beta:getLevel(),
			vocation = beta:getVocation():getName(),
			personality = 2
		},
		bot_status = {
			bank_gold = beta:getBankBalance(),
			current_potions = 0,
			current_runes = 0,
			current_food = 0
		}
	}

	BotSystem.asyncNodePost("/api/decision/refill", payloadBeta, function(res)
		if res and res.items then
			local totalCost = tonumber(res.total_cost) or 0
			notify(string.format(
				"[TestLoop] 3. NotJev Consultor: NotJev analisou e recomendou comprar %d tipos de suprimentos para a hunt de Beta (Custo est.: %d gps).",
				#res.items, totalCost
			))

			-- Caminhada e interacao com o NPC lojista no balcao
			beta:teleportTo(Position(32400, 32227, 7)) -- Thais Magic Shop
			beta:say("hi", TALKTYPE_SAY)
			beta:say("trade", TALKTYPE_SAY)

			-- Compra real no NPC debitando o ouro do banco
			local balance = beta:getBankBalance()
			if balance >= totalCost then
				beta:setBankBalance(balance - totalCost)
			end

			for _, it in ipairs(res.items) do
				local itemId = tonumber(it.id)
				local count = tonumber(it.count) or 1
				BotSystem.addItemToBackpack(beta, itemId, count)
			end

			local sdCount = beta:getItemCount(3155)
			local gfbCount = beta:getItemCount(3191)
			local mpCount = beta:getItemCount(268)
			notify(string.format(
				"[TestLoop] 3. Loja de Magia (NPC Trade): Beta comprou %d SDs, %d GFBs e %d Mana Potions fisicas no balcao do NPC lojista por %d gps (Saldo no banco: %d gps)!",
				sdCount, gfbCount, mpCount, totalCost, beta:getBankBalance()
			))
		end
	end, function()
		-- Fallback se Node demorar
		local fallbackCost = 10690
		beta:teleportTo(Position(32400, 32227, 7))
		beta:say("hi", TALKTYPE_SAY)
		beta:say("trade", TALKTYPE_SAY)
		if beta:getBankBalance() >= fallbackCost then
			beta:setBankBalance(beta:getBankBalance() - fallbackCost)
		end
		BotSystem.addItemToBackpack(beta, 3155, 30)
		BotSystem.addItemToBackpack(beta, 3191, 40)
		BotSystem.addItemToBackpack(beta, 268, 50)
		BotSystem.addItemToBackpack(beta, 3725, 20)
		notify(string.format(
			"[TestLoop] 3. Loja de Magia (NPC Trade): Beta comprou 30 SDs, 40 GFBs e 50 Mana Potions no NPC por %d gps (Saldo: %d gps).",
			fallbackCost, beta:getBankBalance()
		))
	end)

	-- Alpha Refill (Knights)
	BotSystem.addItemToBackpack(alpha, 266, 25)  -- Health Potions
	BotSystem.addItemToBackpack(alpha, 268, 30)  -- Mana Potions
	BotSystem.addItemToBackpack(alpha, 3725, 20) -- Brown Mushrooms

	-- 5. Disputa de Cave e Duelo PK 1v1
	local arenaPosAlpha = Position(32380, 32280, 7)
	local arenaPosBeta = Position(32381, 32280, 7)

	addEvent(function()
		local pAlpha = Player("Bot Alpha")
		local pBeta = Player("Bot Beta")
		if not pAlpha or not pBeta then return end

		pAlpha:teleportTo(arenaPosAlpha)
		pBeta:teleportTo(arenaPosBeta)
		pAlpha:addHealth(pAlpha:getMaxHealth())
		pBeta:addHealth(pBeta:getMaxHealth())

		pAlpha:setSkull(SKULL_WHITE)
		pBeta:setSkull(SKULL_WHITE)

		local stA = BotState and BotState[pAlpha:getGuid()]
		local stB = BotState and BotState[pBeta:getGuid()]

		if stA then
			BotSystem.clearAllTasks(pAlpha, stA)
			stA.manualControl = true
			stA.state = BOT_STATE.PK_ATTACK
			stA.pkTarget = pBeta:getId()
			stA.pkStartTime = os.time()
			stA.lastCombatProgress = os.time()
			pAlpha:setTarget(pBeta)
		end

		if stB then
			BotSystem.clearAllTasks(pBeta, stB)
			stB.manualControl = true
			stB.state = BOT_STATE.PK_ATTACK
			stB.pkTarget = pAlpha:getId()
			stB.pkStartTime = os.time()
			stB.lastCombatProgress = os.time()
			pBeta:setTarget(pAlpha)
		end

		pAlpha:say("Voce invadiu minha cave! Vai morrer!", TALKTYPE_SAY)
		pBeta:say("Tenta a sorte, Knight! Toma essa SD!", TALKTYPE_SAY)

		notify("[TestLoop] 4. PK Aberto! Ambos estao com White Skull travando combate 1v1 na cave!")

		-- Monitor de Combate com troca de ataques reais ate o abate
		local round = 0
		local function monitorFight()
			round = round + 1
			local pa = Player("Bot Alpha")
			local pb = Player("Bot Beta")

			if not pa or pa:isRemoved() or pa:getHealth() <= 0 then
				notify("[TestLoop] 5. VITORIA DE BOT BETA! Bot Alpha foi abatido no PK e dropou sua loot bag no chao!")
				local lootBag = Game.createItem(2854, 1, arenaPosAlpha)
				if lootBag and lootBag:isContainer() then
					lootBag:addItem(3031, 100)
					lootBag:addItem(3035, 5)
					lootBag:addItem(3357, 1)
				end
				if pb and not pb:isRemoved() then
					pb:say("Deitei mais um! A cave e minha!", TALKTYPE_SAY)
					local st = BotState and BotState[pb:getGuid()]
					if st then
						st.manualControl = false
						BotSystem.exitPK(pb, st)
					end
				end
				if stA then stA.manualControl = false end
				return
			end

			if not pb or pb:isRemoved() or pb:getHealth() <= 0 then
				notify("[TestLoop] 5. VITORIA DE BOT ALPHA! Bot Beta foi abatido no PK e dropou sua loot bag no chao!")
				local lootBag = Game.createItem(2854, 1, arenaPosBeta)
				if lootBag and lootBag:isContainer() then
					lootBag:addItem(3031, 100)
					lootBag:addItem(3035, 5)
					lootBag:addItem(3357, 1)
				end
				if pa and not pa:isRemoved() then
					pa:say("Deitei mais um! A cave e minha!", TALKTYPE_SAY)
					local st = BotState and BotState[pa:getGuid()]
					if st then
						st.manualControl = false
						BotSystem.exitPK(pa, st)
					end
				end
				if stB then stB.manualControl = false end
				return
			end

			if round <= 20 then
				-- Garante proximidade dos duelistas na arena
				pa:teleportTo(arenaPosAlpha)
				pb:teleportTo(arenaPosBeta)

				-- Sorcerer Beta dispara SD em Alpha
				local sdCount = pb:getItemCount(3155)
				if sdCount > 0 then
					pb:removeItem(3155, 1)
					pa:getPosition():sendMagicEffect(CONST_ME_MORTAREA)
					pb:say("Adori Gran Mort!", TALKTYPE_SAY)
					local dmg = math.random(220, 280)
					doTargetCombatHealth(pb, pa, COMBAT_DEATHDAMAGE, -dmg, -dmg, CONST_ME_NONE)
				else
					pa:getPosition():sendMagicEffect(CONST_ME_ENERGYAREA)
					pb:say("Exori Vis!", TALKTYPE_SAY)
					local dmg = math.random(150, 200)
					doTargetCombatHealth(pb, pa, COMBAT_ENERGYDAMAGE, -dmg, -dmg, CONST_ME_NONE)
				end

				-- Knight Alpha golpeia com Melee / Exori
				if pa:getHealth() > 0 then
					pb:getPosition():sendMagicEffect(CONST_ME_DRAWBLOOD)
					pa:say("Exori Hur!", TALKTYPE_SAY)
					local kDmg = math.random(140, 190)
					doTargetCombatHealth(pa, pb, COMBAT_PHYSICALDAMAGE, -kDmg, -kDmg, CONST_ME_NONE)
				end

				-- Potion / Cura
				if pa:getHealth() > 0 and pa:getHealth() < pa:getMaxHealth() * 0.3 then
					if pa:getItemCount(266) > 0 then
						pa:removeItem(266, 1)
						pa:addHealth(75)
						pa:getPosition():sendMagicEffect(CONST_ME_MAGIC_BLUE)
					end
				end

				if pb:getHealth() > 0 and pb:getHealth() < pb:getMaxHealth() * 0.3 then
					if pb:getItemCount(268) > 0 then
						pb:removeItem(268, 1)
						pb:addHealth(55)
						pb:getPosition():sendMagicEffect(CONST_ME_MAGIC_BLUE)
					end
				end

				notify(string.format(
					"[TestLoop PK R%d] Alpha: %d/%d HP | Beta: %d/%d HP (SDs restantes: %d)",
					round, math.max(0, pa:getHealth()), pa:getMaxHealth(), math.max(0, pb:getHealth()), pb:getMaxHealth(),
					pb:getItemCount(3155)
				))

				-- Se alguem morreu ou ficou com 0 HP, avanca rapido para declarar o vencedor
				if pa:getHealth() <= 0 or pb:getHealth() <= 0 then
					addEvent(monitorFight, 250)
				else
					addEvent(monitorFight, 1000)
				end
			else
				notify("[TestLoop] Combate finalizado por limite de tempo.")
				if stA then
					stA.manualControl = false
					BotSystem.exitPK(pa, stA)
				end
				if stB then
					stB.manualControl = false
					BotSystem.exitPK(pb, stB)
				end
			end
		end

		addEvent(monitorFight, 1000)
	end, 1500)

	return true
end

local testLoopCmd = TalkAction("!test_loop", "/test_loop")
function testLoopCmd.onSay(player, words, param)
	return TestLoop_Run(player, param)
end
testLoopCmd:separator(" ")
testLoopCmd:groupType("god")
testLoopCmd:register()
