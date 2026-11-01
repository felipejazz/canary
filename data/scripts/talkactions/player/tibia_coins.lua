-- Talkaction para consulta e adição de Tibia Coins no chat do jogo
-- Comandos: !coins ou !tibiacoins (consulta) e !addcoins <quantidade> (recarga)

local tibiaCoins = TalkAction("!coins", "!tibiacoins")

function tibiaCoins.onSay(player, words, param)
	local normalCoins = player:getTibiaCoins() or 0
	local transferableCoins = player:getTransferableCoins() or 0

	player:sendTextMessage(
		MESSAGE_STATUS_CONSOLE_BLUE,
		string.format("🪙 Saldo da Conta: %s Tibia Coins (Store) | %s Transferíveis.", 
			Game.formatNumber(normalCoins) or tostring(normalCoins),
			Game.formatNumber(transferableCoins) or tostring(transferableCoins)
		)
	)
	return true
end

tibiaCoins:groupType("normal")
tibiaCoins:register()

local addCoins = TalkAction("!addcoins")

function addCoins.onSay(player, words, param)
	local amount = tonumber(param)
	if not amount or amount <= 0 then
		player:sendCancelMessage("Uso correto: !addcoins <quantidade>. Exemplo: !addcoins 1000")
		return true
	end

	if amount > 1000000 then
		player:sendCancelMessage("O limite máximo por recarga é de 1.000.000 Tibia Coins.")
		return true
	end

	player:addTibiaCoins(amount)

	-- Se o Gamestore sender estiver disponível, sincroniza a interface da Store aberta
	if sendStoreBalanceUpdating then
		sendStoreBalanceUpdating(player:getId(), true)
	end

	local newBalance = player:getTibiaCoins() or 0
	player:sendTextMessage(
		MESSAGE_EVENT_ADVANCE,
		string.format("✨ Sucesso! %s Tibia Coins adicionadas à sua conta. Saldo atual: %s TC.",
			Game.formatNumber(amount) or tostring(amount),
			Game.formatNumber(newBalance) or tostring(newBalance)
		)
	)
	return true
end

addCoins:groupType("normal")
addCoins:register()
