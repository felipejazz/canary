local playerSave = TalkAction("!save")

-- Cooldown de 30 segundos por jogador para evitar sobrecarga de I/O por spam
local SAVE_COOLDOWN_SECONDS = 30
local STORAGE_SAVE_COOLDOWN = 65540

function playerSave.onSay(player, words, param)
	local currentTime = os.time()
	local lastSave = player:getStorageValue(STORAGE_SAVE_COOLDOWN)
	if lastSave > 0 and (currentTime - lastSave) < SAVE_COOLDOWN_SECONDS then
		local remaining = SAVE_COOLDOWN_SECONDS - (currentTime - lastSave)
		player:sendCancelMessage(string.format("Aguarde %d segundo(s) antes de salvar o jogo novamente.", remaining))
		return false
	end

	-- Salva o personagem do jogador imediatamente
	player:save()
	player:setStorageValue(STORAGE_SAVE_COOLDOWN, currentTime)

	-- Salva o servidor globalmente
	saveServer()
	if SaveHirelings then
		pcall(SaveHirelings)
	end

	-- Feedback visual e no chat
	player:getPosition():sendMagicEffect(CONST_ME_MAGIC_BLUE)
	player:sendTextMessage(MESSAGE_LOOK, "Seu personagem e o servidor foram salvos com sucesso!")
	return true
end

playerSave:separator(" ")
playerSave:groupType("normal")
playerSave:register()
