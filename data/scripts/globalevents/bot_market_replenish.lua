-- ============================================================================
-- Bot Market Replenisher - Infinite Liquidity & Scarcity Eliminator
-- ============================================================================
-- Ensures 100% catalog availability for both SELL and BUY offers:
-- 1. Continuously tops up GOD offers (player_id = 7) whose amount drops below 1000 back to 65535.
-- 2. Restores any fully-depleted offers (deleted when amount == 0) from bot_market_item_prices.
-- 3. Clears GOD inbox / depot periodically to prevent capacity exhaustion when players sell items.
-- 4. CRITICAL: Strictly restricts operations to player_id = 7, guaranteeing real player offers
--    and escrowed items are never deleted, corrupted, or destroyed.
-- ============================================================================

local REPLENISH_INTERVAL_MS = 60000 -- Run every 60 seconds
local GOD_PLAYER_ID = 7
local MAX_STOCK = 65535
local DEPLETED_THRESHOLD = 1000

local botMarketReplenish = GlobalEvent("BotMarketReplenish")

function botMarketReplenish.onThink(interval)
	if BOT_CONFIG and BOT_CONFIG.MASTER_DISABLE then return true end

	-- 1. Top-up depleted GOD offers (both BUY and SELL)
	db.asyncQuery(string.format([[
		UPDATE `market_offers` 
		SET `amount` = %d, `created` = UNIX_TIMESTAMP() 
		WHERE `player_id` = %d AND `amount` < %d
	]], MAX_STOCK, GOD_PLAYER_ID, DEPLETED_THRESHOLD))

	-- 2. Clean GOD inbox and depot items so players can always sell items to GOD without inbox space errors
	db.asyncQuery(string.format("DELETE FROM `player_inboxitems` WHERE `player_id` = %d", GOD_PLAYER_ID))
	db.asyncQuery(string.format("DELETE FROM `player_depotitems` WHERE `player_id` = %d", GOD_PLAYER_ID))

	-- Preço de referência (garante cobertura 100%, inclusive itens com market_max = 0):
	-- market_max -> média de compra -> média de venda -> npc_buy -> npc_sell -> base 100.
	-- As médias reais vêm de tibia_market_items via JOIN por canary_item_id.
	local REF_PRICE = [[COALESCE(
			NULLIF(p.market_max, 0),
			NULLIF(t.day_avg_buy, 0), NULLIF(t.month_avg_buy, 0),
			NULLIF(t.day_avg_sell, 0), NULLIF(t.month_avg_sell, 0),
			NULLIF(p.npc_buy, 0), NULLIF(p.npc_sell, 0),
			100
		)]]

	-- 3. Garante uma oferta de SELL (player COMPRA) para todo item marketável e visível no Market.
	-- Sem LIMIT: cobre o catálogo inteiro por ciclo (INSERT..SELECT indexado por player_id,sale,itemtype).
	db.asyncQuery(string.format([[
		INSERT INTO `market_offers` (`player_id`, `sale`, `itemtype`, `amount`, `created`, `anonymous`, `price`, `tier`)
		SELECT %d, 1, p.item_id, %d, UNIX_TIMESTAMP(), 1, GREATEST(1, FLOOR(%s)), 0
		FROM `bot_market_item_prices` p
		LEFT JOIN `tibia_market_items` t ON t.canary_item_id = p.item_id
		WHERE p.marketable = 1 AND p.category IS NOT NULL AND p.category <> ''
		AND p.item_id NOT IN (
			SELECT `itemtype` FROM `market_offers` WHERE `player_id` = %d AND `sale` = 1
		)
	]], GOD_PLAYER_ID, MAX_STOCK, REF_PRICE, GOD_PLAYER_ID))

	-- 4. Garante uma oferta de BUY (player VENDE) para o mesmo conjunto -> sempre as duas pontas.
	-- Preço = 80% da referência (abaixo do sell -> sem arbitragem).
	db.asyncQuery(string.format([[
		INSERT INTO `market_offers` (`player_id`, `sale`, `itemtype`, `amount`, `created`, `anonymous`, `price`, `tier`)
		SELECT %d, 0, p.item_id, %d, UNIX_TIMESTAMP(), 1, GREATEST(1, FLOOR(%s * 0.80)), 0
		FROM `bot_market_item_prices` p
		LEFT JOIN `tibia_market_items` t ON t.canary_item_id = p.item_id
		WHERE p.marketable = 1 AND p.category IS NOT NULL AND p.category <> ''
		AND p.item_id NOT IN (
			SELECT `itemtype` FROM `market_offers` WHERE `player_id` = %d AND `sale` = 0
		)
	]], GOD_PLAYER_ID, MAX_STOCK, REF_PRICE, GOD_PLAYER_ID))

	return true
end

function botMarketReplenish.onStartup()
	addEvent(function()
		db.asyncQuery(string.format([[
			UPDATE `market_offers` 
			SET `amount` = %d, `created` = UNIX_TIMESTAMP() 
			WHERE `player_id` = %d AND `amount` < %d
		]], MAX_STOCK, GOD_PLAYER_ID, MAX_STOCK))
		logger.info("[BotMarketReplenish] Initial startup stock top-up completed (all offers set to 65535).")
	end, 5000)
	return true
end

botMarketReplenish:interval(REPLENISH_INTERVAL_MS)
botMarketReplenish:register()
