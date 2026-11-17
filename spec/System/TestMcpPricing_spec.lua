local pricing = LoadModule("Modules/McpPricing")

local RING = [[Item Class: Rings
Rarity: Rare
Miracle Band
Two-Stone Ring
--------
Requirements:
Level: 60
--------
Item Level: 81
--------
{ Implicit Modifier — Elemental, Fire, Lightning, Resistance }
+14(12-16)% to Fire and Lightning Resistances
--------
{ Prefix Modifier "Rotund" (Tier: 2) — Life }
+94(85-99) to maximum Life
{ Prefix Modifier "Phased" (Tier: 2) — Defences, Evasion }
+148(121-150) to Evasion Rating
{ Suffix Modifier "of Exile" (Tier: 2) — Chaos, Resistance }
+30(26-30)% to Chaos Resistance
{ Suffix Modifier "of the Ranger" (Tier: 1) — Attack }
+461(351-480) to Accuracy Rating
{ Suffix Modifier "of the Lightning" (Tier: 2) — Elemental, Lightning, Resistance }
+44(42-45)% to Lightning Resistance
]]

local SHIELD = [[Item Class: Shields
Rarity: Rare
Vengeance Wing
Ezomyte Tower Shield
--------
Quality: +16% (augmented)
Chance to Block: 24%
Armour: 548 (augmented)
--------
Requirements:
Level: 64
Str: 159
--------
Sockets: W-W-R
--------
Item Level: 74
--------
{ Implicit Modifier — Life }
+34(30-40) to maximum Life
--------
{ Prefix Modifier "Vigorous" (Tier: 1) — Life }
+154(145-159) to maximum Life
{ Suffix Modifier "of the Phoenix" (Tier: 3) — Life }
Regenerate 95.3(64.1-96) Life per second
{ Suffix Modifier "of the Ice" (Tier: 2) — Elemental, Cold, Resistance }
+42(42-45)% to Cold Resistance
{ Suffix Modifier "of the Volcano" (Tier: 3) — Elemental, Fire, Resistance }
+37(36-41)% to Fire Resistance
]]

local SWORD = [[Item Class: Thrusting One Hand Swords
Rarity: Rare
Doom Needle
Jewelled Foil
--------
Thrusting One Hand Sword
Physical Damage: 120-221 (augmented)
Critical Strike Chance: 5.50%
Attacks per Second: 1.60
--------
Requirements:
Level: 68
Dex: 212
--------
Item Level: 84
--------
{ Implicit Modifier — Damage, Critical }
+25% to Global Critical Strike Multiplier
--------
{ Prefix Modifier "Merciless" (Tier: 1) — Damage, Physical, Attack }
172(170-179)% increased Physical Damage
{ Prefix Modifier "Gleaming" (Tier: 2) — Damage, Physical, Attack }
Adds 16(14-19) to 30(29-35) Physical Damage
{ Suffix Modifier "of Celebration" (Tier: 2) — Attack, Speed }
22(20-22)% increased Attack Speed
]]

local AMULET = [[Item Class: Amulets
Rarity: Unique
Astramentis
Onyx Amulet
--------
Requirements:
Level: 20
--------
Item Level: 84
--------
{ Implicit Modifier — Attribute }
+12(10-16) to all Attributes
--------
{ Unique Modifier — Attribute }
+98(80-100) to all Attributes
{ Unique Modifier — Physical, Attack }
-4 Physical Damage taken from Attacks
]]

local GEM = [[Item Class: Skill Gems
Rarity: Gem
Arc
--------
Lightning, Spell, Chaining
Level: 20 (Max)
Quality: +20% (augmented)
--------
Corrupted
]]

local function filterIds(query)
	local ids = { }
	for _, group in ipairs(query.stats) do
		for _, f in ipairs(group.filters) do
			ids[f.id] = f.value or true
		end
	end
	return ids
end

describe("MCP pricing", function()
	it("reads a rare ring and searches on its totals, not on filler", function()
		local desc = assert(pricing.describe(RING))
		assert.are.equals("price", desc.verdict)
		assert.are.equals("accessory.ring", desc.category)
		assert.are.equals(94, desc.totals.life)
		assert.are.equals(72, desc.totals.ele)
		assert.are.equals(30, desc.totals.chaos)
		assert.are.same({ prefixes = 1, suffixes = 0 }, desc.open)
		local plan = pricing.plan(desc)
		local first = pricing.firstSearch(plan)
		local ids = filterIds(first.query)
		assert.are.same({ min = 84 }, ids["pseudo.pseudo_total_life"])
		assert.are.same({ min = 64 }, ids["pseudo.pseudo_total_elemental_resistance"])
		assert.are.same({ min = 25 }, ids["pseudo.pseudo_total_chaos_resistance"])
		assert.is_nil(ids["explicit.stat_803737631"], "accuracy is filler")
		assert.are.equals("securable", first.query.status.option)
		assert.are.equals("accessory.ring", first.query.filters.type_filters.filters.category.option)
		assert.are.equals("nonunique", first.query.filters.type_filters.filters.rarity.option)
		assert.are.equals("false", first.query.filters.misc_filters.filters.corrupted.option)
	end)

	it("keeps the regeneration of a shield for tightening a search full of cheap ones", function()
		local desc = assert(pricing.describe(SHIELD))
		assert.are.equals("armour.shield", desc.category)
		assert.are.equals(188, desc.totals.life)
		assert.are.equals(79, desc.totals.ele)
		local plan = pricing.plan(desc)
		local first = pricing.firstSearch(plan)
		local summary = { median = 1 }
		local nextSearch = pricing.nextSearch(plan, first, 3455, summary, 1)
		assert.is_truthy(nextSearch, "should tighten")
		assert.is_truthy(nextSearch.step:find("Regenerate", 1, true))
		local ids = filterIds(nextSearch.query)
		assert.are.same({ min = 81 }, ids["explicit.stat_3325883026"])
	end)

	it("searches a physical weapon on its physical DPS, with local stats only", function()
		local desc = assert(pricing.describe(SWORD))
		assert.are.equals("weapon.onesword", desc.category)
		assert.is_true(desc.pdps > 0)
		local plan = pricing.plan(desc)
		local first = pricing.firstSearch(plan)
		local weapon = first.query.filters.weapon_filters
		assert.is_truthy(weapon and weapon.filters.pdps, "pdps filter")
		assert.are.equals(math.floor(desc.pdps * 0.9), weapon.filters.pdps.min)
		assert.is_nil(first.query.filters.misc_filters.filters.ilvl, "open affixes alone do not make a craft base")
		for _, t in ipairs(plan.tighten) do
			assert.is_falsy(t.label:match("Physical Damage") or t.label:match("Attack Speed"), "the DPS filter covers " .. t.label)
		end
		local texts = { }
		for _, category in ipairs(require("Data.TradeSiteStats")) do
			for _, entry in ipairs(category.entries) do
				texts[entry.id] = entry.text
			end
		end
		for id in pairs(filterIds(first.query)) do
			if (texts[id] or ""):match("Physical Damage") then
				assert.is_truthy(texts[id]:match("%(Local%)"), id .. " should be the local stat")
			end
		end
	end)

	it("searches a unique by name, then on its high rolls", function()
		local desc = assert(pricing.describe(AMULET))
		local plan = pricing.plan(desc)
		local first = pricing.firstSearch(plan)
		assert.are.equals("Astramentis", first.query.name)
		assert.are.equals("Onyx Amulet", first.query.type)
		assert.is_nil(first.query.filters.type_filters)
		assert.is_table(first.query.stats[1].filters)
		local nextSearch = pricing.nextSearch(plan, first, 40, { median = 100 }, 1)
		assert.is_truthy(nextSearch)
		local ids = filterIds(nextSearch.query)
		local found
		for _, value in pairs(ids) do
			if type(value) == "table" and value.min == 93 then
				found = true
			end
		end
		assert.is_true(found, "all attributes at 95% of 98")
	end)

	it("sends bulk items to the bulk markets", function()
		local desc = assert(pricing.describe(GEM))
		assert.are.equals("bulk", desc.verdict)
		assert.are.equals("Arc", desc.bulk.name)
		assert.are.equals(20, desc.bulk.gemLevel)
		assert.are.equals(20, desc.bulk.quality)
		assert.is_true(desc.bulk.corrupted)
	end)

	it("filters a Warlord craft base on its influence and item level", function()
		local warlord = RING:gsub("Item Level: 81\n", "Item Level: 86\n--------\nWarlord Item\n", 1)
		local desc = assert(pricing.describe(warlord))
		assert.are.same({ "adjudicator" }, desc.influences)
		local first = pricing.firstSearch(pricing.plan(desc))
		local misc = first.query.filters.misc_filters.filters
		assert.are.same({ option = "true" }, misc.warlord_item)
		assert.are.same({ min = 86 }, misc.ilvl)
	end)

	it("does not loosen a tightened search that found few listings", function()
		local plan = pricing.plan(assert(pricing.describe(SHIELD)))
		local first = pricing.firstSearch(plan)
		local tightened = pricing.nextSearch(plan, first, 3455, { median = 1 }, 1)
		assert.is_true(tightened.tightened)
		assert.is_nil(pricing.nextSearch(plan, tightened, 3, { median = 2 }, 2))
	end)

	it("refuses text that is not an item", function()
		local desc, message = pricing.describe("hello")
		assert.is_nil(desc)
		assert.is_truthy(message:find("Ctrl+Alt+C", 1, true))
	end)

	it("summarises listings: one per account, fresh first, outliers out of the quick sale", function()
		local now = os.time()
		local function l(amount, currency, account, hours)
			return pricing.parseListing({ id = account .. amount, listing = {
				price = { amount = amount, currency = currency, type = "~b/o" }, account = { name = account },
				indexed = os.date("!%Y-%m-%dT%H:%M:%SZ", now - hours * 3600) } }, now)
		end
		assert.is_nil(pricing.parseListing({ listing = { account = { name = "x" } } }, now))
		local listings = {
			l(10, "chaos", "low", 1), l(40, "chaos", "a", 1), l(45, "chaos", "b", 2), l(50, "chaos", "c", 3),
			l(55, "chaos", "d", 5), l(60, "chaos", "e", 6), l(60, "chaos", "e", 6), l(60, "chaos", "e", 7),
			l(65, "chaos", "f", 8), l(70, "chaos", "g", 9), l(0.5, "divine", "h", 10), l(1, "mirror", "i", 1),
		}
		assert.are.equals(1, math.floor(listings[1].hours + 0.5))
		local s = pricing.summarise(listings, { chaos = 1, divine = 160 }, 120, 0)
		assert.are.equals(1, s.skippedCurrencies.mirror)
		assert.are.same({ "e" }, s.walls)
		assert.are.equals(1, s.lowOutliers)
		assert.are.equals(45, s.quick)
		assert.is_true(s.fair >= 50 and s.fair <= 60)
		assert.is_true(s.ceiling >= s.fair)
		assert.are.equals(50, pricing.roundChaos(52))
		assert.are.equals(3, pricing.roundChaos(2.6))
		assert.is_true(pricing.isCheap({ total = 3455, fair = 1, p75 = 2 }))
		assert.is_false(pricing.isCheap({ total = 726, fair = 62, p75 = 70 }) or false)
	end)
end)
