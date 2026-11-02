-- /botnormalize [force]
-- Varre os bots ONLINE e aplica a normalização base (saldo por level + BP só com shovel/machete/rope
-- + melhor set do level de graça). Sem 'force', só normaliza quem ainda não foi (flag de storage).
-- Com 'force', reaplica em todos (útil após mudar a tabela de saldo/set).

local botNormalize = TalkAction("/botnormalize")

function botNormalize.onSay(player, words, param)
	logCommand(player, words, param)

	if not BotSystem or not BotSystem.normalizeBot or not BotPlayers then
		player:sendTextMessage(MESSAGE_ADMINISTRATOR, "[botnormalize] BotSystem/BotPlayers indisponível.")
		return true
	end

	local force = (param and param:lower():find("force")) and true or false
	local online, done = 0, 0
	for _, bot in pairs(BotPlayers) do
		if bot and not bot:isRemoved() and bot.isBotPlayer and bot:isBotPlayer() then
			online = online + 1
			local ok = pcall(function() return BotSystem.normalizeBot(bot, force) end)
			if ok then done = done + 1 end
		end
	end

	player:sendTextMessage(MESSAGE_ADMINISTRATOR, string.format(
		"[botnormalize] %d bots online processados (%d ok)%s.", online, done, force and " [force]" or ""))
	logger.info(string.format("[botnormalize] %s acionou normalização: %d online, %d ok (force=%s)",
		player:getName(), online, done, tostring(force)))
	return true
end

botNormalize:separator(" ")
botNormalize:groupType("god")
botNormalize:register()
