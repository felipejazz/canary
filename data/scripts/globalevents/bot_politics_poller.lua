-- ============================================================================
-- Bot Politics Poller
-- Periodic background evaluation (every 60 seconds) for:
-- 1. Forming dynamic guilds from high bot-to-bot friendships (affinity >= 30)
-- 2. Managing cave territory dominance and expiration of abandoned claims
-- 3. Synchronizing data with MariaDB
-- ============================================================================

local politicsPoller = GlobalEvent("BotPoliticsPoller")

function politicsPoller.onThink(interval)
	if BotPolitics and BotPolitics.onThinkPeriodic then
		local ok, err = pcall(BotPolitics.onThinkPeriodic)
		if not ok then
			logger.error("[BotPoliticsPoller] Error in periodic think: " .. tostring(err))
		end
	end
	return true
end

politicsPoller:interval(60000)
politicsPoller:register()
