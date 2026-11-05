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
-- Multiplicador de preço por tier (tier 0 = preço de referência). Ajuste aqui.
-- Cada item tem ofertas de VENDA em todos os tiers até o seu tier_cap (classificação do cliente).
-- LIMITE: o login manda UM pacote 0xCD (ProtocolGame::sendItemsPrice) com uma entrada por
-- (item, tier) que tenha oferta de COMPRA ativa (Game::loadItemsPrice), max ~65 KB. Com compras
-- em tier 1 e 2 ele estourou e o client fechava ao entrar. Por isso as COMPRAS do GOD param em
-- BUY_MAX_TIER (cabe ~58 KB); as VENDAS não entram no pacote e vão até o tier de cada item.
local TIER_PRICE_MULT = { [0] = 1, [1] = 2, [2] = 4, [3] = 8, [4] = 16 }
local BUY_MAX_TIER = 1

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

	-- Remove COMPRAS do GOD acima do tier suportado (ver LIMITE acima).
	db.asyncQuery(string.format("DELETE FROM `market_offers` WHERE `player_id` = %d AND `sale` = 0 AND `tier` > %d", GOD_PLAYER_ID, BUY_MAX_TIER))

	-- 3/4. Garante as DUAS pontas para todo item marketável do catálogo, em cada tier:
	--   SELL (sale=1, player COMPRA) pela referência x multiplicador do tier; BUY (sale=0,
	--   player VENDE) a 80% disso (abaixo do sell -> sem arbitragem).
	-- Tier 1/2 só existem para item com tier_cap >= tier (classificação do cliente, ver
	-- tools/sync_item_tier_cap.py). Sem LIMIT: cobre o catálogo inteiro por ciclo.
	-- Cada INSERT confere o resultado via callback: antes era fire-and-forget e uma falha
	-- deixava o catálogo sem cobertura sem nenhum rastro no log.
	local function ensureSide(sale, tier, priceExpr, label)
		db.asyncQuery(string.format([[
			INSERT INTO `market_offers` (`player_id`, `sale`, `itemtype`, `amount`, `created`, `anonymous`, `price`, `tier`)
			SELECT %d, %d, p.item_id, %d, UNIX_TIMESTAMP(), 1, GREATEST(1, FLOOR(%s)), %d
			FROM `bot_market_item_prices` p
			LEFT JOIN `tibia_market_items` t ON t.canary_item_id = p.item_id
			WHERE p.marketable = 1 AND p.category IS NOT NULL AND p.category <> '' AND p.tier_cap >= %d
			AND p.item_id NOT IN (
				SELECT `itemtype` FROM `market_offers` WHERE `player_id` = %d AND `sale` = %d AND `tier` = %d
			)
		]], GOD_PLAYER_ID, sale, MAX_STOCK, priceExpr, tier, tier, GOD_PLAYER_ID, sale, tier), function(success)
			if not success then
				logger.warn("[BotMarketReplenish] " .. label .. " tier " .. tier .. " coverage INSERT failed; retrying next cycle")
			end
		end)
	end
	for tier, mult in pairs(TIER_PRICE_MULT) do
		local price = REF_PRICE .. " * " .. mult
		ensureSide(1, tier, price, "SELL")
		if tier <= BUY_MAX_TIER then
			ensureSide(0, tier, price .. " * 0.80", "BUY")
		end
	end

	-- 5. Watchdog de cobertura: se sobrar item do catálogo sem alguma ponta depois dos
	-- INSERTs, avisa no log (a próxima rodada tenta de novo; o aviso expõe falha persistente).
	db.asyncStoreQuery(string.format([[
		SELECT
			SUM(p.item_id NOT IN (SELECT `itemtype` FROM `market_offers` WHERE `player_id` = %d AND `sale` = 1)) AS no_sell,
			SUM(p.item_id NOT IN (SELECT `itemtype` FROM `market_offers` WHERE `player_id` = %d AND `sale` = 0)) AS no_buy
		FROM `bot_market_item_prices` p
		WHERE p.marketable = 1 AND p.category IS NOT NULL AND p.category <> ''
	]], GOD_PLAYER_ID, GOD_PLAYER_ID), function(resultId)
		if not resultId then return end
		local noSell = Result.getNumber(resultId, "no_sell")
		local noBuy = Result.getNumber(resultId, "no_buy")
		Result.free(resultId)
		if noSell > 0 or noBuy > 0 then
			logger.warn(string.format("[BotMarketReplenish] coverage gap after refill: %d without SELL, %d without BUY", noSell, noBuy))
		end
	end)

	return true
end

-- Um GlobalEvent guarda UMA função e UM tipo: `onStartup` marca o tipo "startup" e
-- sobrescreve o callback (ver revscriptsys.lua GlobalEventNewIndex). Por isso o top-up
-- inicial é um evento separado; no mesmo objeto o onThink acima nunca chegava a rodar.
botMarketReplenish:interval(REPLENISH_INTERVAL_MS)
botMarketReplenish:register()

local botMarketReplenishStartup = GlobalEvent("BotMarketReplenishStartup")

function botMarketReplenishStartup.onStartup()
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

botMarketReplenishStartup:register()
