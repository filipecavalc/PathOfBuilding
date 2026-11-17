local McpProtocol = LoadModule("Modules/McpProtocol")
local dkjson = require("dkjson")

local PORT = 49290
local TOKEN = "0123456789abcdef0123456789abcdef"

local protocol

local function frameFuncKeys()
	local keys = { }
	for key in pairs(main.onFrameFuncs) do
		if key:match("^McpTrade") then
			table.insert(keys, key)
		end
	end
	return keys
end

-- Calls a tool, running its trade search frames until it answers.
local function callTool(name, args, allowError)
	local response
	protocol:HandleHttp({
		method = "POST",
		path = "/mcp",
		version = "1.1",
		headers = {
			host = "127.0.0.1:" .. PORT,
			authorization = "Bearer " .. TOKEN,
			["content-type"] = "application/json",
		},
		body = McpProtocol.Encode({ jsonrpc = "2.0", id = 1, method = "tools/call", params = { name = name, arguments = args or McpProtocol.Object() } }),
	}, function(r)
		response = r
	end)
	for _ = 1, 50 do
		if response then
			break
		end
		for _, key in ipairs(frameFuncKeys()) do
			main.onFrameFuncs[key]()
		end
	end
	assert.is_truthy(response, "no response")
	assert.are.equals(200, response.status)
	local body = McpProtocol.Decode(response.body)
	assert.is_nil(body.error)
	if body.result.isError and not allowError then
		error(name .. " failed: " .. tostring(body.result.content[1].text), 2)
	end
	return body.result.structuredContent, body.result
end

local function toolError(name, args)
	local _, result = callTool(name, args, true)
	assert.is_true(result.isError, "expected an error from " .. name)
	return result.content[1].text
end

local HELMET = "Rarity: RARE\nTest Hat\nIron Hat\nQuality: 0\n+80 to maximum Life\n"

-- A listing as the trade site's fetch API returns it.
local function listing(id, name, typeLine, mods, amount, currency, priceType, whisper)
	return {
		id = id,
		item = { rarity = "Rare", name = name, typeLine = typeLine, ilvl = 80, explicitMods = { { description = mods[1] } }, pseudoMods = { "Sum: 42" } },
		listing = { price = { amount = amount, currency = currency, type = priceType }, whisper = whisper, account = { name = "seller" .. id } },
	}
end

describe("MCP trade tools", function()
	local api, savedToken, savedDownload, requests

	before_each(function()
		main.mcpServer.token = TOKEN
		protocol = main.mcpServer:NewProtocol(PORT)
		build.abortSave = true
		while main.popups[1] do
			main:ClosePopup()
		end
		newBuild()
		api = main.api
		savedToken = api.authToken
		savedDownload = launch.DownloadPage
		requests = { }
		local listings = {
			listing("a", "Fine Hat", "Iron Hat", { "+90 to maximum Life" }, 2, "divine", "~price", "@seller hi"),
			listing("b", "Weak Hat", "Iron Hat", { "+50 to maximum Life" }, 1, "chaos", "~b/o"),
			listing("c", "Wrong Boots", "Rawhide Boots", { "+99 to maximum Life" }, 1, "chaos", "~b/o"),
		}
		-- The trade site: a search, then one fetch; the currency rates are not available.
		launch.DownloadPage = function(_, url, callback, params)
			table.insert(requests, { url = url, params = params })
			if url:find("api/trade/search/", 1, true) then
				callback({ header = "HTTP/1.1 200 OK", body = dkjson.encode({ id = "query1", total = 10, result = { "a", "b", "c" } }) })
			elseif url:find("api/trade/fetch/", 1, true) then
				callback({ header = "HTTP/1.1 200 OK", body = dkjson.encode({ result = listings }) })
			else
				callback(nil, "offline")
			end
		end
	end)

	after_each(function()
		api.authToken = savedToken
		launch.DownloadPage = savedDownload
		build.abortSave = true
		local popup = main.popups[1]
		while main.popups[1] do
			main:ClosePopup()
		end
		assert.is_nil(popup, popup and ("dialog left open: " .. tostring(popup.title)))
	end)

	it("needs Path of Building's Path of Exile login", function()
		api.authToken = nil
		local message = toolError("trade_search", { slot = "Helmet", league = "Standard" })
		assert.is_truthy(message:find("not logged in", 1, true))
		assert.are.equals(0, #requests)
	end)

	it("searches as the trader does and measures every listing on the build", function()
		api.authToken = "test-token"
		callTool("items_equip", { action = "equip", slot = "Helmet", item = HELMET })
		build:ResetModFlags()
		local result = callTool("trade_search", { slot = "Helmet", league = "Standard", pages = 1, weights = { { stat = "Life", weight = 1 } } })

		local search = requests[1]
		for _, request in ipairs(requests) do
			if request.url:find("api/trade/search/", 1, true) then
				search = request
			end
		end
		assert.are.equals("https://www.pathofexile.com/api/trade/search/Standard", search.url)
		local sent = dkjson.decode(search.params.body)
		assert.are.same({ ["statgroup.0"] = "desc" }, sent.sort)
		assert.are.equals("weight", sent.query.stats[1].type)
		assert.is_truthy(search.params.header:find("Bearer test-token", 1, true))

		-- The boots do not fit the slot; the better helmet comes first.
		assert.are.equals(2, result.found)
		assert.are.equals("Fine Hat, Iron Hat", result.listings[1].name)
		assert.are.equals("Weak Hat, Iron Hat", result.listings[2].name)
		assert.is_true(result.listings[1].statValue > result.listings[2].statValue)
		assert.are.same({ amount = 2, currency = "divine", type = "~price" }, result.listings[1].price)
		assert.are.equals("@seller hi", result.listings[1].whisper)
		assert.is_truthy(result.listings[2].listingUrl:find("^https://www%.pathofexile%.com/trade/search/Standard/"))
		assert.is_truthy(table.concat(result.listings[1].changes, "\n"):find("Life", 1, true))
		assert.is_truthy(result.listings[1].item:find("+90 to maximum Life", 1, true))
		assert.are.equals("https://www.pathofexile.com/trade/search/Standard/query1", result.searchUrl)
		assert.are.equals("stat_value", result.sortedBy)

		-- Nothing changed in the build, and the search left nothing running.
		assert.is_false(build.modFlag)
		assert.are.same({ }, frameFuncKeys())

		-- Without currency rates the price sort falls back to stat value, as the trader does.
		result = callTool("trade_search", { slot = "Helmet", league = "Standard", pages = 1, sort_by = "price" })
		assert.are.equals("stat_value", result.sortedBy)
		assert.is_truthy(result.notes[1]:find("Currency rates", 1, true))
	end)

	it("reports a search that finds nothing, and rejects links from elsewhere", function()
		api.authToken = "test-token"
		launch.DownloadPage = function(_, url, callback)
			if url:find("api/trade/search/", 1, true) then
				callback({ header = "HTTP/1.1 200 OK", body = dkjson.encode({ id = "none", total = 0, result = { } }) })
			else
				callback(nil, "offline")
			end
		end
		callTool("items_equip", { action = "equip", slot = "Helmet", item = HELMET })
		local message = toolError("trade_search", { slot = "Helmet", league = "Standard", max_price = 1 })
		assert.is_truthy(message:find("no listings", 1, true))
		assert.are.same({ }, frameFuncKeys())
		message = toolError("trade_search", { slot = "Helmet", url = "https://example.com/trade/search/Standard/abc" })
		assert.is_truthy(message:find("trade search link", 1, true))
	end)

	it("generates searches for the trader's unique rows", function()
		-- The unique jewels need an allocated jewel socket, as in the trader.
		local message = toolError("trade_query", { slot = "Megalomaniac" })
		assert.is_truthy(message:find("jewel socket", 1, true))
		local nearest
		for _, node in pairs(build.spec.nodes) do
			if node.type == "Socket" and not node.containJewelSocket and not node.expansionJewel and node.path
				and (not nearest or #node.path < #nearest.path) then
				nearest = node
			end
		end
		build.spec:AllocNode(nearest)
		build.buildFlag = true
		runCallback("OnFrame")
		build.itemsTab:UpdateSockets()
		local socketLabel = build.itemsTab.sockets[nearest.id].label

		local result = callTool("trade_query", { slot = "Megalomaniac", league = "Standard" })
		assert.are.equals("Megalomaniac", result.slot)
		assert.are.equals(socketLabel, result.measuredIn)
		assert.are.equals("Megalomaniac", result.query.name)
		assert.is_truthy(#result.weightedStats > 0)
		message = toolError("trade_query", { slot = "Megalomaniac", jewel_socket = "No Such Socket" })
		assert.is_truthy(message:find("jewel socket", 1, true))

		-- A Pearl's supports count only for gems in the ring, so PoB has nothing to weight here.
		message = toolError("trade_query", { slot = "Pearl of Tsoatha", ring_slot = "Ring 2" })
		assert.is_truthy(message:find("found no mods", 1, true))
		message = toolError("trade_query", { slot = "Pearl of Tsoatha", ring_slot = "Ring 3" })
		assert.is_truthy(message:find("ring slot", 1, true))
		message = toolError("trade_query", { slot = "Helmet", ring_slot = "Ring 1" })
		assert.is_truthy(message:find("unique rows", 1, true))
	end)
	describe("trade_price", function()
		local RING = table.concat({
			"Item Class: Rings", "Rarity: Rare", "Miracle Band", "Two-Stone Ring", "--------", "Item Level: 81", "--------",
			"{ Implicit Modifier — Elemental, Fire, Lightning, Resistance }", "+14(12-16)% to Fire and Lightning Resistances", "--------",
			"{ Prefix Modifier \"Rotund\" (Tier: 2) — Life }", "+94(85-99) to maximum Life",
			"{ Prefix Modifier \"Phased\" (Tier: 2) — Defences, Evasion }", "+148(121-150) to Evasion Rating",
			"{ Suffix Modifier \"of Exile\" (Tier: 2) — Chaos, Resistance }", "+30(26-30)% to Chaos Resistance",
			"{ Suffix Modifier \"of the Ranger\" (Tier: 1) — Attack }", "+461(351-480) to Accuracy Rating",
			"{ Suffix Modifier \"of the Lightning\" (Tier: 2) — Elemental, Lightning, Resistance }", "+44(42-45)% to Lightning Resistance",
		}, "\n")
		local totals, searchCount

		local function priced(id, amount, currency, account, hoursAgo)
			return {
				id = id,
				item = { rarity = "Rare", name = "Ring " .. id, typeLine = "Two-Stone Ring", ilvl = 80, explicitMods = { { description = "+90 to maximum Life" } } },
				listing = { price = { amount = amount, currency = currency, type = "~b/o" }, account = { name = account },
					indexed = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - hoursAgo * 3600) },
			}
		end

		before_each(function()
			totals = { 726 }
			searchCount = 0
			local fetched = { }
			for i = 1, 12 do
				table.insert(fetched, priced("l" .. i, 40 + i * 3, "chaos", "acc" .. i, i))
			end
			table.insert(fetched, priced("d", 0.5, "divine", "rich", 2))
			table.insert(fetched, { id = "noprice", item = { rarity = "Rare" }, listing = { account = { name = "x" } } })
			launch.DownloadPage = function(_, url, callback, params)
				table.insert(requests, { url = url, params = params })
				if url:find("api/trade/search/", 1, true) then
					searchCount = searchCount + 1
					local total = totals[math.min(searchCount, #totals)]
					local ids = { }
					for i = 1, math.min(total, #fetched) do
						ids[i] = fetched[i].id
					end
					callback({ header = "HTTP/1.1 200 OK", body = dkjson.encode({ id = "q" .. searchCount, total = total, result = ids }) })
				elseif url:find("api/trade/fetch/", 1, true) then
					local wanted = { }
					for id in url:match("fetch/([^?]+)"):gmatch("[^,]+") do
						wanted[id] = true
					end
					local out = { }
					for _, entry in ipairs(fetched) do
						if wanted[entry.id] then
							table.insert(out, entry)
						end
					end
					callback({ header = "HTTP/1.1 200 OK", body = dkjson.encode({ result = out }) })
				else
					callback(nil, "offline")
				end
			end
		end)

		local function searchBodies()
			local bodies = { }
			for _, request in ipairs(requests) do
				if request.url:find("api/trade/search/", 1, true) then
					table.insert(bodies, (dkjson.decode(request.params.body)))
				end
			end
			return bodies
		end

		local function statIds(query)
			local ids = { }
			for _, group in ipairs(query.stats) do
				for _, f in ipairs(group.filters) do
					ids[f.id] = f.value or true
				end
			end
			return ids
		end

		it("needs the login, except for bulk items and dry runs", function()
			api.authToken = nil
			local message = toolError("trade_price", { item = RING, league = "Covens" })
			assert.is_truthy(message:find("not logged in", 1, true))
			local result = callTool("trade_price", { item = "Item Class: Skill Gems\nRarity: Gem\nArc\n--------\nLevel: 20 (Max)\nQuality: +20% (augmented)\n" })
			assert.are.equals("bulk", result.verdict)
			assert.are.equals(20, result.bulk.gemLevel)
			result = callTool("trade_price", { item = RING, dry_run = true })
			assert.are.equals("accessory.ring", result.query.filters.type_filters.filters.category.option)
			assert.are.equals(0, #requests)
			message = toolError("trade_price", { item = "not an item" })
			assert.is_truthy(message:find("Ctrl+Alt+C", 1, true))
		end)

		it("prices a rare ring from Instant Buyout listings, without touching the build", function()
			api.authToken = "test-token"
			build:ResetModFlags()
			local result = callTool("trade_price", { item = RING, league = "Covens", chaos_per_divine = 160 })
			local bodies = searchBodies()
			assert.are.equals(1, #bodies)
			local sent = bodies[1]
			assert.are.same({ price = "asc" }, sent.sort)
			assert.are.equals("securable", sent.query.status.option)
			local ids = statIds(sent.query)
			assert.are.same({ min = 84 }, ids["pseudo.pseudo_total_life"])
			assert.are.same({ min = 64 }, ids["pseudo.pseudo_total_elemental_resistance"])
			assert.are.same({ min = 25 }, ids["pseudo.pseudo_total_chaos_resistance"])
			for _, request in ipairs(requests) do
				if request.url:find("api/trade/search/", 1, true) or request.url:find("api/trade/fetch/", 1, true) then
					assert.is_truthy(request.params.header:find("Bearer test-token", 1, true))
				end
			end
			assert.are.equals("price", result.verdict)
			assert.are.equals(726, result.market.total)
			assert.are.equals("https://www.pathofexile.com/trade/search/Covens/q1", result.searches[1].url)
			assert.are.equals("argument", result.rate.source)
			assert.is_true(result.price.quick.chaos <= result.price.fair.chaos)
			assert.is_true(result.price.fair.chaos <= result.price.ceiling.chaos)
			-- The divine listing counts at 80 chaos; the one without a price is left out.
			assert.are.equals(13, result.market.fetched)
			assert.is_true(#result.cheapest <= 8)
			assert.is_false(build.modFlag)
			assert.are.same({ }, frameFuncKeys())
		end)

		it("loosens a search that finds too little, at most three times", function()
			api.authToken = "test-token"
			totals = { 2, 30 }
			local result = callTool("trade_price", { item = RING, league = "Covens", chaos_per_divine = 160 })
			local bodies = searchBodies()
			assert.are.equals(2, #bodies)
			local firstIds, secondIds = statIds(bodies[1].query), statIds(bodies[2].query)
			assert.is_truthy(firstIds["pseudo.pseudo_total_chaos_resistance"])
			assert.is_nil(secondIds["pseudo.pseudo_total_chaos_resistance"])
			assert.is_truthy(result.searches[2].step:find("relaxed", 1, true))
			assert.are.equals(30, result.market.total)

			requests = { }
			searchCount = 0
			totals = { 0 }
			result = callTool("trade_price", { item = RING, league = "Covens", chaos_per_divine = 160 })
			assert.is_true(#searchBodies() <= 3)
			assert.are.equals("no_data", result.verdict)
			assert.are.same({ }, frameFuncKeys())
		end)
	end)
end)
