-- ============================================================================
-- Bot Market Funding -- baseline survival balance check at server startup
-- ============================================================================
-- Bots do NOT receive infinite gold (no 100kkk injection).
-- Instead, this startup task ensures every bot has at least the minimum
-- baseline gold for their level bracket, so bots that went bankrupt can
-- afford basic potions to hunt, while bots that profited keep their real wealth.
-- ============================================================================

local function getLevelMinimumBalance(level)
	if level >= 200 then
		return 150000
	elseif level >= 130 then
		return 80000
	elseif level >= 100 then
		return 45000
	elseif level >= 80 then
		return 25000
	elseif level >= 50 then
		return 12000
	elseif level >= 20 then
		return 3500
	else
		return 1000
	end
end

local FUNDING_DELAY_MS = 30000

local botMarketFunding = GlobalEvent("BotMarketFunding")

function botMarketFunding.onStartup()
	addEvent(function()
		local toppedUp = 0
		for _, player in pairs(BotPlayers or {}) do
			if player and not player:isRemoved() then
				local curBal = player:getBankBalance() or 0
				local minBal = getLevelMinimumBalance(player:getLevel())
				if curBal < minBal then
					player:setBankBalance(minBal)
					toppedUp = toppedUp + 1
				end
			end
		end

		logger.info(string.format(
			"[BotMarketFunding] Baseline survival check complete: %d bots topped up to level minimums (no infinite gold).",
			toppedUp
		))
	end, FUNDING_DELAY_MS)

	return true
end

botMarketFunding:register()
