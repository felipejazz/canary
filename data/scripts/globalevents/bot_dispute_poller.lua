-- ============================================================================
-- Bot Dispute Poller — dirige a engine de sessão de disputa (~1s):
-- resolve acks pendentes, aplica timeout de turno do humano, TTL e limpeza.
-- ============================================================================

local disputePoller = GlobalEvent("BotDisputePoller")

function disputePoller.onThink(interval)
	if BotDispute and BotDispute.tick then
		local ok, err = pcall(BotDispute.tick)
		if not ok and logger and logger.error then
			logger.error("[BotDisputePoller] Error in dispute tick: " .. tostring(err))
		end
	end
	return true
end

disputePoller:interval(1000)
disputePoller:register()
