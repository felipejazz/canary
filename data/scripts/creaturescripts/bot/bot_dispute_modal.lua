-- ============================================================================
-- Bot Dispute Modal — resposta das opções pré-determinadas da sessão de disputa.
-- Registrado no player via player:registerEvent("BotDisputeModal") quando a
-- engine envia a modal. Encaminha a escolha para BotDispute.onModalResponse.
-- ============================================================================

local botDisputeModal = CreatureEvent("BotDisputeModal")

function botDisputeModal.onModalWindow(player, modalWindowId, buttonId, choiceId)
	if BotDispute and BotDispute.onModalResponse then
		pcall(function() BotDispute.onModalResponse(player, modalWindowId, buttonId) end)
	end
	return true
end

botDisputeModal:register()
