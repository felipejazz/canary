-- ============================================================================
-- Bot Dispute Session Engine (singleton)
-- Autoridade única da disputa de cave: nasce no encontro físico, matricula os
-- envolvidos (bots automático; players confirmam "ciente" por modal), conduz
-- rounds em ordem fixa (dono do território -> nível desc), resolve por
-- SHARE / LEAVE / FFA, rastreia vivo/morto e persiste tudo pro dashboard.
--
-- Depende (em runtime, nunca no load) de: BotSystem, BotPolitics, BotState,
-- BotPlayers, BotHuntData. Este arquivo carrega ANTES de bot_system.lua
-- (ordem alfabética), portanto só referencia esses globais dentro de funções.
-- ============================================================================

BotDispute = BotDispute or {}
BotDispute.sessions = BotDispute.sessions or {}        -- [caveKey] = session
BotDispute.byParticipant = BotDispute.byParticipant or {} -- [guid] = caveKey
BotDispute.pendingModal = BotDispute.pendingModal or {}   -- [guid] = { caveKey, kind }
BotDispute._seq = BotDispute._seq or 0

BotDispute.CONFIG = {
	MAX_ROUNDS = 2,          -- rodadas sem acordo -> combate
	ACK_TIMEOUT = 20,        -- s para o humano confirmar "ciente"
	TURN_TIMEOUT = 25,       -- s para o humano agir no turno dele
	BOT_TURN_DELAY = 1400,   -- ms entre turnos de bot (ritmo legível)
	SESSION_TTL = 300,       -- s: teto duro de vida da sessão
	JOIN_RADIUS = 7,         -- precisa estar fisicamente perto p/ entrar
	CHANNEL_ID = 0x4B,       -- canal dedicado de disputa (0x4A/0x4B livres)
	MODAL_ID = 43120,        -- id da modal window de disputa
	MODAL_EVENT = "BotDisputeModal",
}

-- Decisões possíveis de um participante no seu turno
BotDispute.DECISION = {
	STAY = "STAY",    -- fica e disputa (vai pro combate se ninguém ceder)
	FIGHT = "FIGHT",  -- força a luta já
	SHARE = "SHARE",  -- dividir a cave / party
	LEAVE = "LEAVE",  -- sai e procura outra cave
}

-- ---------------------------------------------------------------------------
-- Util
-- ---------------------------------------------------------------------------
local function now() return os.time() end

local function isBotCreature(creature)
	return creature and creature.isBotPlayer and creature:isBotPlayer()
end

function BotDispute.getCaveKey(scriptId)
	return "cave:" .. tostring(scriptId or "unknown")
end

-- Posta uma linha da disputa: canal dedicado p/ quem o tem aberto + say local
-- (fallback imersivo, visível a todos por perto, nunca perde a fala).
function BotDispute.post(session, speaker, text)
	if not text or #text == 0 then return end
	if speaker and not speaker:isRemoved() then
		speaker:say(text, TALKTYPE_SAY)
	end
	for _, part in ipairs(session.participants) do
		local p = Player(part.guid)
		if p and not p:isRemoved() then
			pcall(function()
				p:sendChannelMessage(speaker and speaker:getName() or "Disputa",
					text, TALKTYPE_CHANNEL_Y, BotDispute.CONFIG.CHANNEL_ID)
			end)
		end
	end
	table.insert(session.history, {
		round = session.round, actor = speaker and speaker:getName() or "SYSTEM",
		action = "SAY", speech = text, ts = now()
	})
end

-- ---------------------------------------------------------------------------
-- Persistência (dashboard). Best-effort: nunca derruba a lógica.
-- ---------------------------------------------------------------------------
local function jsonParticipants(session)
	local parts = {}
	for _, p in ipairs(session.participants) do
		parts[#parts + 1] = string.format(
			'{"guid":%d,"name":"%s","isBot":%s,"isOwner":%s,"level":%d,"archetype":%d,"ack":%s,"life":"%s","decision":"%s"}',
			p.guid, (p.name or ""):gsub('"', ''), tostring(p.isBot), tostring(p.isOwner),
			p.level or 0, p.archetype or 0, tostring(p.ack), p.life or "ALIVE", p.decision or "")
	end
	return "[" .. table.concat(parts, ",") .. "]"
end

function BotDispute.persist(session)
	if not db or not db.asyncQuery then return end
	local parts = jsonParticipants(session):gsub("'", "")
	pcall(function()
		db.asyncQuery(string.format([[
			INSERT INTO `bot_dispute_sessions`
				(`session_key`, `cave_id`, `status`, `rounds`, `outcome`, `winner_guid`, `participants`, `created_at`, `resolved_at`)
			VALUES (%d, %s, %s, %d, %s, %s, '%s', FROM_UNIXTIME(%d), %s)
			ON DUPLICATE KEY UPDATE
				`status`=VALUES(`status`), `rounds`=VALUES(`rounds`), `outcome`=VALUES(`outcome`),
				`winner_guid`=VALUES(`winner_guid`), `participants`=VALUES(`participants`), `resolved_at`=VALUES(`resolved_at`)
		]],
			session.id,
			db.escapeString(session.cave_id or ""),
			db.escapeString(session.status),
			session.round or 0,
			db.escapeString(session.outcome or ""),
			session.winner_guid and tostring(session.winner_guid) or "NULL",
			parts,
			session.created_at,
			session.resolved_at and ("FROM_UNIXTIME(" .. session.resolved_at .. ")") or "NULL"
		))
	end)
end

function BotDispute.persistEvent(session, actorName, action, speech)
	if not db or not db.asyncQuery then return end
	pcall(function()
		db.asyncQuery(string.format([[
			INSERT INTO `bot_dispute_events` (`session_key`, `round`, `actor`, `action`, `speech`, `ts`)
			VALUES (%d, %d, %s, %s, %s, NOW())
		]], session.id, session.round or 0,
			db.escapeString(actorName or "SYSTEM"), db.escapeString(action or ""),
			db.escapeString(speech or "")))
	end)
end

-- ---------------------------------------------------------------------------
-- Participantes
-- ---------------------------------------------------------------------------
local function findPart(session, guid)
	for _, p in ipairs(session.participants) do
		if p.guid == guid then return p end
	end
	return nil
end

local function aliveActive(session)
	-- vivos que ainda não saíram
	local list = {}
	for _, p in ipairs(session.participants) do
		if p.life == "ALIVE" and p.decision ~= BotDispute.DECISION.LEAVE then
			list[#list + 1] = p
		end
	end
	return list
end

function BotDispute.isPlayerInFight(guid)
	local caveKey = BotDispute.byParticipant[guid]
	if not caveKey then return false, nil end
	local session = BotDispute.sessions[caveKey]
	if not session or session.status ~= "ACTIVE" then return false, nil end
	return session.outcome == "FIGHT", session
end

function BotDispute.getRivalTarget(guid)
	local caveKey = BotDispute.byParticipant[guid]
	if not caveKey then return nil end
	local session = BotDispute.sessions[caveKey]
	if not session or session.status ~= "ACTIVE" then return nil end
	for _, part in ipairs(session.participants) do
		if part.guid ~= guid and part.life == "ALIVE" and part.decision ~= BotDispute.DECISION.LEAVE then
			local p = Player(part.guid)
			if p and not p:isRemoved() and p:getHealth() > 0 then
				return p
			end
		end
	end
	return nil
end

function BotDispute.addParticipant(session, player, state)
	local guid = player:getGuid()
	if findPart(session, guid) then return end
	local isBot = isBotCreature(player)
	local arch = (BotSystem and BotSystem.getBotArchetype and isBot) and BotSystem.getBotArchetype(player, state) or { id = 0 }
	local ownerGuild = nil
	if BotPolitics and BotPolitics.getTerritoryOwner then
		ownerGuild = BotPolitics.getTerritoryOwner(session.cave_id)
	end
	local pGuild = player:getGuild()
	local isOwner = (ownerGuild and pGuild and ownerGuild.id == pGuild:getId()) or false
	local part = {
		guid = guid,
		name = player:getName(),
		isBot = isBot,
		isOwner = isOwner,
		level = player:getLevel(),
		archetype = arch.id or 0,
		ack = isBot,                 -- bots já estão cientes
		life = "ALIVE",
		decision = nil,
		joinedAt = now(),
	}
	table.insert(session.participants, part)
	BotDispute.byParticipant[guid] = BotDispute.getCaveKey(session.scriptId)

	if not isBot then
		BotDispute.sendAckModal(session, player)
	end
end

-- ---------------------------------------------------------------------------
-- Criação / ingresso
-- ---------------------------------------------------------------------------
function BotDispute.openOrJoin(scriptId, player, state, rival, rivalState)
	if not player or player:isRemoved() then return nil end
	local caveKey = BotDispute.getCaveKey(scriptId)
	local session = BotDispute.sessions[caveKey]

	if not session then
		BotDispute._seq = BotDispute._seq + 1
		local script = BotHuntData and BotHuntData.scripts and BotHuntData.scripts[scriptId]
		session = {
			id = (now() % 1000000) * 1000 + (BotDispute._seq % 1000),
			cave_id = (script and script.name) or tostring(scriptId),
			scriptId = scriptId,
			status = "PENDING",
			participants = {},
			round = 0,
			max_rounds = BotDispute.CONFIG.MAX_ROUNDS,
			turn_index = 0,
			turn_started = nil,
			awaiting_human = nil,   -- guid do humano cujo turno aguarda resposta
			history = {},
			outcome = nil,
			winner_guid = nil,
			created_at = now(),
			resolved_at = nil,
		}
		BotDispute.sessions[caveKey] = session
	end

	if session.status == "RESOLVED" or session.status == "ABORTED" then
		return nil
	end

	BotDispute.addParticipant(session, player, state)
	if rival and not rival:isRemoved() then
		BotDispute.addParticipant(session, rival, rivalState)
	end

	BotDispute.persist(session)
	return session
end

-- ---------------------------------------------------------------------------
-- Modais (interação do humano por opções pré-determinadas)
-- ---------------------------------------------------------------------------
function BotDispute.sendAckModal(session, player)
	local w = ModalWindow(BotDispute.CONFIG.MODAL_ID, "Disputa de Cave",
		string.format("Voce foi puxado para uma disputa pela cave '%s'. Deseja participar?", session.cave_id))
	w:addButton(1, "Ciente / Participar")
	w:addButton(0, "Ignorar")
	w:setDefaultEnterButton(1)
	w:setDefaultEscapeButton(0)
	BotDispute.pendingModal[player:getGuid()] = { caveKey = session.cave_id and BotDispute.getCaveKey(session.scriptId), kind = "ACK" }
	pcall(function()
		player:registerEvent(BotDispute.CONFIG.MODAL_EVENT)
		w:sendToPlayer(player)
	end)
end

function BotDispute.sendTurnModal(session, player)
	local w = ModalWindow(BotDispute.CONFIG.MODAL_ID, "Sua vez - Disputa de Cave",
		string.format("Round %d/%d na cave '%s'. O que voce faz?", session.round, session.max_rounds, session.cave_id))
	w:addButton(1, "Ficar e lutar")
	w:addButton(2, "Dividir a cave")
	w:addButton(3, "Sair e procurar outra")
	w:setDefaultEnterButton(1)
	w:setDefaultEscapeButton(3)
	BotDispute.pendingModal[player:getGuid()] = { caveKey = BotDispute.getCaveKey(session.scriptId), kind = "TURN" }
	pcall(function()
		player:registerEvent(BotDispute.CONFIG.MODAL_EVENT)
		w:sendToPlayer(player)
	end)
end

-- Chamado pelo creaturescript onModalWindow
function BotDispute.onModalResponse(player, modalId, buttonId)
	if modalId ~= BotDispute.CONFIG.MODAL_ID then return end
	local guid = player:getGuid()
	local pending = BotDispute.pendingModal[guid]
	if not pending then return end
	BotDispute.pendingModal[guid] = nil

	local session = BotDispute.sessions[pending.caveKey]
	if not session then return end
	local part = findPart(session, guid)
	if not part or part.life == "DEAD" then return end

	if pending.kind == "ACK" then
		if buttonId == 1 then
			part.ack = true
			BotDispute.post(session, player, "Estou ciente. Vamos resolver isso.")
		else
			-- ignorou o convite: tratado como "fica e disputa", mas não trava a engine
			part.ack = true
			part.decision = BotDispute.DECISION.STAY
		end
		return
	end

	if pending.kind == "TURN" then
		local d = (buttonId == 2 and BotDispute.DECISION.SHARE)
			or (buttonId == 3 and BotDispute.DECISION.LEAVE)
			or BotDispute.DECISION.STAY
		local speech = (d == BotDispute.DECISION.SHARE and "Da pra dividir o respawn, numa boa.")
			or (d == BotDispute.DECISION.LEAVE and "De boa, procuro outra cave.")
			or "Eu fico. Resolve no osso se quiser."
		BotDispute.applyDecision(session, part, d, speech, player)
		session.awaiting_human = nil
		BotDispute.advanceTurn(session)
	end
end

-- ---------------------------------------------------------------------------
-- Rounds
-- ---------------------------------------------------------------------------
function BotDispute.computeOrder(session)
	-- dono do território primeiro, depois nível desc
	local order = {}
	for _, p in ipairs(session.participants) do order[#order + 1] = p end
	table.sort(order, function(a, b)
		if a.isOwner ~= b.isOwner then return a.isOwner end
		return (a.level or 0) > (b.level or 0)
	end)
	session.order = order
end

function BotDispute.start(session)
	if session.status ~= "PENDING" then return end
	session.status = "ACTIVE"
	session.round = 1
	session.turn_index = 0
	BotDispute.computeOrder(session)
	BotDispute.persist(session)
	BotDispute.advanceTurn(session)
end

function BotDispute.advanceTurn(session)
	if session.status ~= "ACTIVE" then return end
	-- resolve antes de dar a próxima vez
	if BotDispute.checkResolution(session) then return end

	session.turn_index = session.turn_index + 1
	if session.turn_index > #session.order then
		-- fim da volta
		session.round = session.round + 1
		if session.round > session.max_rounds then
			BotDispute.beginCombat(session, "rounds esgotados sem acordo")
			return
		end
		session.turn_index = 1
	end

	local part = session.order[session.turn_index]
	if not part or part.life == "DEAD" or part.decision == BotDispute.DECISION.LEAVE then
		return BotDispute.advanceTurn(session) -- pula quem saiu/morreu
	end

	local p = Player(part.guid)
	if not p or p:isRemoved() then
		part.life = "DEAD" -- sumiu do jogo
		return BotDispute.advanceTurn(session)
	end

	if part.isBot then
		BotDispute.takeBotTurn(session, part, p)
	else
		session.awaiting_human = part.guid
		session.turn_started = now()
		BotDispute.sendTurnModal(session, p)
		BotDispute.post(session, nil, string.format("E a vez de %s decidir...", part.name))
	end
end

function BotDispute.takeBotTurn(session, part, player)
	local state = BotState and BotState[part.guid]
	if not state or not BotSystem or not BotSystem.asyncNodePost then
		-- sem brain: default conservador por arquétipo
		local d = (part.archetype >= 4) and BotDispute.DECISION.STAY or BotDispute.DECISION.SHARE
		BotDispute.applyDecision(session, part, d, "", player)
		addEvent(function() BotDispute.advanceTurn(session) end, BotDispute.CONFIG.BOT_TURN_DELAY)
		return
	end

	-- monta roster resumido p/ contexto do brain
	local others = {}
	for _, o in ipairs(session.participants) do
		if o.guid ~= part.guid and o.life == "ALIVE" then
			others[#others + 1] = string.format("%s(lv%d%s)", o.name, o.level or 0, o.isOwner and ",dono" or "")
		end
	end

	local payload = {
		bot_profile = {
			guid = part.guid, name = part.name, level = part.level,
			vocation = player:getVocation() and player:getVocation():getName() or "Knight",
			personality = state.personality or 2,
			archetype_id = part.archetype,
		},
		cave_name = session.cave_id,
		trigger_event = "Sessao de disputa (round " .. session.round .. ")",
		session = {
			round = session.round, max_rounds = session.max_rounds,
			is_owner = part.isOwner, participants = others, count = #session.participants,
		},
		-- compat com o endpoint atual:
		rival_name = session.order and session.order[1] and session.order[1].name or "",
		rival_is_player = false,
	}

	BotSystem.asyncNodePost("/api/decision/dispute", payload, function(res)
		local p = Player(part.guid)
		if not p or p:isRemoved() or session.status ~= "ACTIVE" then return end
		local decision = tostring(res and (res.decision or res.action) or "SHARE"):upper()
		local map = {
			PK = BotDispute.DECISION.FIGHT, FIGHT = BotDispute.DECISION.FIGHT,
			PARTY = BotDispute.DECISION.SHARE, SHARE = BotDispute.DECISION.SHARE,
			LEAVE = BotDispute.DECISION.LEAVE, IGNORE = BotDispute.DECISION.STAY,
		}
		local d = map[decision] or BotDispute.DECISION.STAY
		BotDispute.applyDecision(session, part, d, res and res.speech or "", p)
		addEvent(function() BotDispute.advanceTurn(session) end, BotDispute.CONFIG.BOT_TURN_DELAY)
	end)
end

function BotDispute.applyDecision(session, part, decision, speech, player)
	part.decision = decision
	if speech and #speech > 0 and player and not player:isRemoved() then
		BotDispute.post(session, player, speech)
	end
	table.insert(session.history, { round = session.round, actor = part.name, action = decision, speech = speech or "", ts = now() })
	BotDispute.persistEvent(session, part.name, decision, speech)

	-- FIGHT = quer luta já -> colapsa em combate FFA
	if decision == BotDispute.DECISION.FIGHT then
		BotDispute.beginCombat(session, part.name .. " partiu pra cima")
	elseif decision == BotDispute.DECISION.LEAVE then
		BotDispute.makeLeave(session, part)
	end
	BotDispute.persist(session)
end

function BotDispute.makeLeave(session, part)
	part.decision = BotDispute.DECISION.LEAVE
	local p = Player(part.guid)
	local state = BotState and BotState[part.guid]
	if p and state and part.isBot and BotSystem then
		-- re-roteia o bot pra outra cave (reusa o fluxo de hunt existente)
		if state.huntScriptId and BotHuntData and BotHuntData.releaseHunt then
			BotHuntData.releaseHunt(state.huntScriptId, part.guid)
			state.huntScriptId = nil
		end
		state.caveDisputeCooldownUntil = now() + 600
		if BotSystem.clearAllTasks then BotSystem.clearAllTasks(p, state) end
		state.state = BOT_STATE.IDLE
	end
end

-- ---------------------------------------------------------------------------
-- Resolução & Combate (FFA: todos contra todos)
-- ---------------------------------------------------------------------------
function BotDispute.checkResolution(session)
	if session.status ~= "ACTIVE" then return true end
	local active = aliveActive(session)

	-- 1) sobra só 1 (os demais saíram) -> ele fica
	if #active <= 1 then
		BotDispute.resolve(session, (#active == 1) and "SOLE_SURVIVOR" or "LEFT",
			active[1] and active[1].guid or nil)
		return true
	end

	-- 2) consenso de SHARE entre todos os ativos -> dividem a cave
	local allShare = true
	for _, p in ipairs(active) do
		if p.decision ~= BotDispute.DECISION.SHARE then allShare = false; break end
	end
	if allShare then
		BotDispute.beginShare(session)
		return true
	end

	return false
end

function BotDispute.pickFfaTarget(session, part, player)
	-- rival vivo mais próximo; desempate pelo mais forte
	local best, bestScore
	local ppos = player:getPosition()
	for _, o in ipairs(session.participants) do
		if o.guid ~= part.guid and o.life == "ALIVE" and o.decision ~= BotDispute.DECISION.LEAVE then
			local op = Player(o.guid)
			if op and not op:isRemoved() then
				local opos = op:getPosition()
				local dist = (opos.z == ppos.z) and math.max(math.abs(opos.x - ppos.x), math.abs(opos.y - ppos.y)) or 50
				local score = dist * 1000 - (o.level or 0) -- menor = melhor alvo (perto e forte)
				if not bestScore or score < bestScore then bestScore = score; best = op end
			end
		end
	end
	return best
end

function BotDispute.beginCombat(session, reason)
	if session.status ~= "ACTIVE" then return end
	session.outcome = "FIGHT"
	session.combat_started = now()
	BotDispute.post(session, nil, "A conversa acabou! " .. (reason or ""))
	for _, part in ipairs(session.participants) do
		if part.life == "ALIVE" and part.decision ~= BotDispute.DECISION.LEAVE and part.decision ~= BotDispute.DECISION.SHARE then
			local p = Player(part.guid)
			if p and not p:isRemoved() and part.isBot then
				local target = BotDispute.pickFfaTarget(session, part, p)
				local state = BotState and BotState[part.guid]
				if target and state then
					-- Cancela rotas e alvos de monstros sem apagar a posse/id da cave em disputa
					state.walkTarget = nil
					state.currentPOI = nil
					state.huntMonsterTarget = nil
					state.pendingLootPos = nil
					state.cavebotCommand = nil
					state.state = BOT_STATE.PK_ATTACK
					state.pkTarget = target:getId()
					state.pkStartTime = now()
					state.lastAttackTime = 0
					state.lastCombatProgress = now()
					p:setTarget(target)
				end
			end
		end
	end
	BotDispute.persist(session)
	-- a resolução final vem por BotDispute.notifyDeath / tick
end

function BotDispute.beginShare(session)
	BotDispute.post(session, nil, "Acordo fechado: vamos dividir o respawn.")
	-- party entre os participantes ativos (reusa negociação de party existente)
	local active = aliveActive(session)
	local leader = nil
	for _, part in ipairs(active) do
		local p = Player(part.guid)
		if p and not p:isRemoved() then
			if not leader then
				leader = p
			else
				pcall(function()
					local party = leader:getParty() or Party(leader)
					if party then party:addInvite(p) end
				end)
			end
		end
	end
	BotDispute.resolve(session, "SHARE", nil)
end

function BotDispute.resolve(session, outcome, winnerGuid)
	if session.status == "RESOLVED" then return end
	session.status = "RESOLVED"
	session.outcome = outcome
	session.winner_guid = winnerGuid
	session.resolved_at = now()

	local caveName = session.cave_id or (BotHuntData and BotHuntData.scripts and BotHuntData.scripts[session.scriptId] and BotHuntData.scripts[session.scriptId].name) or "Cave"
	local loserName = "um rival"
	local loserPart = nil
	for _, part in ipairs(session.participants or {}) do
		if part.guid ~= winnerGuid then
			loserName = part.name or loserName
			loserPart = part
			break
		end
	end

	-- Se houver um vencedor de combate, ele reivindica o spawn e o servidor inteiro é notificado
	if outcome == "FIGHT" and winnerGuid then
		local wp = Player(winnerGuid)
		local ws = BotState and BotState[winnerGuid]
		if wp and not wp:isRemoved() then
			-- Anúncio do vencedor no local
			wp:say("Esse respawn agora e meu!", TALKTYPE_SAY)

			-- Anúncio global para o servidor inteiro
			if Game and Game.broadcastMessage then
				local msg = ""
				if loserPart and loserPart.fledToPz then
					msg = string.format("[Disputa de Cave] %s fugiu da batalha! %s reivindicou o controle total do spawn de %s!", loserName, wp:getName(), caveName)
				else
					msg = string.format("[Disputa de Cave] %s derrotou %s em combate mortal e reivindicou o spawn de %s!", wp:getName(), loserName, caveName)
				end
				logger.info(msg)
				pcall(function() Game.broadcastMessage(msg, MESSAGE_EVENT_ADVANCE) end)
			end

			-- Reivindica ocupação no BotHuntData
			if BotHuntData and BotHuntData.reserveHunt and session.scriptId then
				BotHuntData.reserveHunt(session.scriptId, winnerGuid)
			end

			-- Registra conquista de território na política
			if BotPolitics and BotPolitics.recordCaveActivity and session.scriptId then
				pcall(function() BotPolitics.recordCaveActivity(session.scriptId, wp) end)
			end

			-- O vencedor retoma caçada no spawn conquistado
			if ws and wp.isBotPlayer and wp:isBotPlayer() then
				ws.state = BOT_STATE.HUNTING
				ws.huntPhase = HUNT_PHASE.PATROLLING
				ws.huntScriptId = session.scriptId
				ws.pkTarget = nil
				ws.pkStartTime = nil
				ws.huntMonsterTarget = nil
				ws.caveDisputeCooldownUntil = now() + 900 -- 15 minutos de proteção de spawn
			end
			wp:setTarget(nil)
		end
	end

	BotDispute.post(session, nil, "Disputa encerrada (" .. outcome .. ").")

	-- Reseta o estado dos bots participantes para que não continuem em PK_ATTACK
	for _, part in ipairs(session.participants or {}) do
		local p = Player(part.guid)
		local state = BotState and BotState[part.guid]
		if p and not p:isRemoved() and state and part.isBot then
			if part.guid ~= winnerGuid and state.state == BOT_STATE.PK_ATTACK then
				if BotSystem and BotSystem.exitPK then
					BotSystem.exitPK(p, state)
				else
					state.state = BOT_STATE.IDLE
					state.pkTarget = nil
				end
			end
			-- Se for combate finalizado com vencedor, quem perdeu desocupa a cave
			if outcome == "FIGHT" and winnerGuid and part.guid ~= winnerGuid then
				BotDispute.makeLeave(session, part)
			end
		end
	end

	BotDispute.persist(session)
	BotDispute.cleanup(session)
end

function BotDispute.cleanup(session)
	local key = BotDispute.getCaveKey(session.scriptId)
	for _, p in ipairs(session.participants) do
		if BotDispute.byParticipant[p.guid] == key then
			BotDispute.byParticipant[p.guid] = nil
		end
		BotDispute.pendingModal[p.guid] = nil
	end
	BotDispute.sessions[BotDispute.getCaveKey(session.scriptId)] = nil
end

-- Marca morte de um participante (chamado de onBotDeath / onDeath de player)
function BotDispute.notifyDeath(guid, killerGuid)
	local caveKey = BotDispute.byParticipant[guid]
	if not caveKey then return end
	local session = BotDispute.sessions[caveKey]
	if not session then return end
	local part = findPart(session, guid)
	if not part then return end
	part.life = "DEAD"
	part.diedAt = now()
	table.insert(session.history, { round = session.round, actor = part.name, action = "DIED", speech = "", ts = now() })
	BotDispute.persistEvent(session, part.name, "DIED", "")

	-- vencedor = último vivo que não saiu
	local alive = aliveActive(session)
	if session.outcome == "FIGHT" and #alive <= 1 then
		BotDispute.resolve(session, "FIGHT", alive[1] and alive[1].guid or killerGuid)
	else
		BotDispute.persist(session)
	end
end

-- ---------------------------------------------------------------------------
-- Tick: dirige acks pendentes, timeout de turno do humano e TTL/limpeza.
-- Chamado pelo globalevent bot_dispute_poller (~1s).
-- ---------------------------------------------------------------------------
function BotDispute.tick()
	local t = now()
	for caveKey, session in pairs(BotDispute.sessions) do
		-- Sweep de mortes (bots e humanos): marca DEAD quem caiu/sumiu
		if session.status == "ACTIVE" then
			for _, part in ipairs(session.participants) do
				if part.life == "ALIVE" then
					local pp = Player(part.guid)
					if not pp or pp:isRemoved() or pp:getHealth() <= 0 then
						BotDispute.notifyDeath(part.guid, nil)
					end
				end
			end

			-- Stalemate breaker em combate FFA: se a luta durar mais de 45 segundos sem mortes,
			-- o participante com maior nível vence o território e os outros recuam pacificamente.
			if session.outcome == "FIGHT" and session.combat_started and (t - session.combat_started) > 45 then
				local alive = aliveActive(session)
				if #alive > 1 then
					table.sort(alive, function(a, b) return (a.level or 0) > (b.level or 0) end)
					local winner = alive[1]
					local loser = alive[2]
					local lp = Player(loser.guid)
					if lp and not lp:isRemoved() then
						lp:say("Voce e muito forte, a cave e sua!", TALKTYPE_SAY)
					end
					BotDispute.post(session, lp, "Stalemate quebrado por nivel: " .. winner.name .. " (lv " .. (winner.level or 0) .. ") venceu.")
					BotDispute.resolve(session, "FIGHT", winner.guid)
				elseif #alive == 1 then
					BotDispute.resolve(session, "FIGHT", alive[1].guid)
				else
					BotDispute.resolve(session, "ABORTED", nil)
				end
			end
		end
		-- TTL duro
		if (t - session.created_at) > BotDispute.CONFIG.SESSION_TTL then
			session.status = "ACTIVE" -- garante que resolve limpa
			BotDispute.resolve(session, session.outcome or "ABORTED", session.winner_guid)
		elseif session.status == "PENDING" then
			-- todos os humanos deram ack? ou estourou o ACK_TIMEOUT?
			local ready = true
			for _, p in ipairs(session.participants) do
				if not p.ack then ready = false; break end
			end
			if ready or (t - session.created_at) >= BotDispute.CONFIG.ACK_TIMEOUT then
				-- humanos que não confirmaram: "fica e disputa"
				for _, p in ipairs(session.participants) do
					if not p.ack then p.ack = true; p.decision = BotDispute.DECISION.STAY end
				end
				if #session.participants >= 2 then
					BotDispute.start(session)
				else
					BotDispute.resolve(session, "ABORTED", nil)
				end
			end
		elseif session.status == "ACTIVE" and session.awaiting_human then
			-- timeout do turno do humano -> default STAY
			if session.turn_started and (t - session.turn_started) >= BotDispute.CONFIG.TURN_TIMEOUT then
				local part = findPart(session, session.awaiting_human)
				local p = Player(session.awaiting_human)
				BotDispute.pendingModal[session.awaiting_human] = nil
				session.awaiting_human = nil
				if part then
					BotDispute.applyDecision(session, part, BotDispute.DECISION.STAY, "", p)
					BotDispute.advanceTurn(session)
				end
			end
		end
	end
end

logger = logger or {}
if logger.info then logger.info("[BotDispute] Dispute session engine loaded.") end
