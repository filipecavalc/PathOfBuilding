-- Path of Building
--
-- Module: MCP Pricing
-- Prices an item pasted from the game on the trade site: reads it, picks what drives its price,
-- builds a search for comparable items (with steps to loosen or tighten it), and summarises the
-- cheapest listings into a price range. Pure functions: the trade_price tool runs the requests.
--
local t_insert = table.insert
local t_sort = table.sort
local t_concat = table.concat
local m_floor = math.floor
local m_max = math.max
local m_min = math.min

local tradeHelpers = require("Classes.TradeHelpers")
local buySimilar = require("Classes.CompareBuySimilar")

local M = { }

M.MAX_SEARCHES = 3
M.MAX_FILTERS = 5
M.FETCH_COUNT = 20
M.FRESH_HOURS = 48
M.STALE_HOURS = 7 * 24
M.CHEAP_CHAOS = 5

-- Item classes priced by the bulk markets (poe.ninja, Currency Exchange) instead of the trade site.
local BULK_CLASS_PATTERNS = { "Currency", "Divination", "Gem", "Fragment", "^Maps$", "Incubator", "Tattoo", "Omen", "Memor", "Corpse" }

-- Trade site category by base type, then by sub type (which wins).
local CATEGORY_BY_TYPE = {
	Ring = "accessory.ring", Amulet = "accessory.amulet", Belt = "accessory.belt",
	Helmet = "armour.helmet", ["Body Armour"] = "armour.chest", Gloves = "armour.gloves", Boots = "armour.boots",
	Shield = "armour.shield", Quiver = "armour.quiver",
	Bow = "weapon.bow", Staff = "weapon.staff", Wand = "weapon.wand", Dagger = "weapon.dagger", Claw = "weapon.claw",
	Sceptre = "weapon.sceptre", ["Fishing Rod"] = "weapon.rod",
	["One Handed Sword"] = "weapon.onesword", ["One Handed Axe"] = "weapon.oneaxe", ["One Handed Mace"] = "weapon.onemace",
	["Two Handed Sword"] = "weapon.twosword", ["Two Handed Axe"] = "weapon.twoaxe", ["Two Handed Mace"] = "weapon.twomace",
	Flask = "flask", Jewel = "jewel.base",
}
local CATEGORY_BY_SUBTYPE = { ["Rune Dagger"] = "weapon.runedagger", Warstaff = "weapon.warstaff", Abyss = "jewel.abyss", Cluster = "jewel.cluster" }

-- Influence (the item field, as itemLib.influenceInfo names it) -> trade misc filter.
local INFLUENCE_FILTERS = {
	shaper = "shaper_item", elder = "elder_item", crusader = "crusader_item", eyrie = "redeemer_item",
	basilisk = "hunter_item", adjudicator = "warlord_item", cleansing = "searing_item", tangle = "tangled_item",
}
local INFLUENCE_NAMES = {
	shaper = "Shaper", elder = "Elder", crusader = "Crusader", eyrie = "Redeemer", basilisk = "Hunter",
	adjudicator = "Warlord", cleansing = "Searing Exarch", tangle = "Eater of Worlds",
}

-- Mods buyers pay for, by their text with numbers as "#". priority: 1 = most important.
-- Kept small on purpose: the life/resistance totals cover the common rares.
local VALUABLE = {
	["+# to Level of all Skill Gems"] = 1,
	["+# to Level of all Spell Skill Gems"] = 1,
	["+# to Level of all Minion Skill Gems"] = 1,
	["+# to Level of all Physical Spell Skill Gems"] = 1,
	["+# to Level of all Fire Spell Skill Gems"] = 1,
	["+# to Level of all Cold Spell Skill Gems"] = 1,
	["+# to Level of all Lightning Spell Skill Gems"] = 1,
	["+# to Level of all Chaos Spell Skill Gems"] = 1,
	["#% increased maximum Life"] = 1,
	["#% increased maximum Energy Shield"] = 1,
	["Gain #% of Physical Damage as Extra Fire Damage"] = 1,
	["Gain #% of Physical Damage as Extra Cold Damage"] = 1,
	["Gain #% of Physical Damage as Extra Lightning Damage"] = 1,
	["Gain #% of Physical Damage as Extra Chaos Damage"] = 1,
	["+# to Level of Socketed Gems"] = 2,
	["+#% to Global Critical Strike Multiplier"] = 2,
	["#% increased Spell Damage"] = 2,
	["#% increased Cast Speed"] = 2,
	["+#% to Damage over Time Multiplier"] = 2,
	["#% increased Energy Shield"] = 2,
	["+# to maximum Energy Shield"] = 2,
	["Adds # to # Fire Damage to Spells"] = 2,
	["Adds # to # Cold Damage to Spells"] = 2,
	["Adds # to # Lightning Damage to Spells"] = 2,
	["Adds # to # Chaos Damage to Spells"] = 2,
	["#% increased Global Critical Strike Chance"] = 3,
	["#% increased Attack Speed"] = 3,
	["Adds # to # Physical Damage to Attacks"] = 3,
	["Adds # to # Fire Damage to Attacks"] = 3,
	["Adds # to # Cold Damage to Attacks"] = 3,
	["Adds # to # Lightning Damage to Attacks"] = 3,
	["Adds # to # Chaos Damage to Attacks"] = 3,
	["#% increased Elemental Damage with Attack Skills"] = 3,
}

-- On jewels, the mods buyers pay for besides VALUABLE. Other good tiers only tighten a search.
local JEWEL_VALUABLE = {
	["#% increased Mana Reservation Efficiency of Skills"] = 3,
	["#% of Damage taken Recouped as Life"] = 3,
	["#% increased Damage over Time"] = 3,
	["+#% to Critical Strike Multiplier for Spells"] = 3,
	["+#% to Melee Critical Strike Multiplier"] = 3,
	["+#% to Critical Strike Multiplier with One Handed Melee Weapons"] = 3,
	["+#% to Critical Strike Multiplier with Two Handed Melee Weapons"] = 3,
	["Minions deal #% increased Damage"] = 3,
	["Minions have #% increased maximum Life"] = 3,
	["#% increased Attack and Cast Speed"] = 3,
	["#% increased Maximum Energy Shield"] = 3,
}

-- Small values drop too much when scaled (80% of 2 is 1): loosen only values at least this big.
local SCALE_MIN_VALUE = 20

-- Mods that rarely move the price: never a driver, never used to tighten a search.
local FILLER = {
	["+# to Accuracy Rating"] = true, ["+# to Evasion Rating"] = true, ["+# to Armour"] = true,
	["#% increased Light Radius"] = true, ["#% increased Rarity of Items found"] = true, ["+#% to Item Rarity"] = true,
	["Gain # Life per Enemy Killed"] = true, ["Gain # Mana per Enemy Killed"] = true, ["Gain # Life per Enemy Hit with Attacks"] = true,
	["+# Life gained for each Enemy hit by Attacks"] = true, ["#% increased Stun and Block Recovery"] = true,
	["#% reduced Attribute Requirements"] = true, ["+# to maximum Mana"] = true, ["#% increased Mana Regeneration Rate"] = true,
	["Regenerate # Mana per second"] = true, ["#% reduced Enemy Stun Threshold"] = true, ["#% increased Stun Duration on Enemies"] = true,
}

-- Lines the totals already cover (life, resistances, attributes, movement speed).
local function coveredByTotals(text)
	return text:match("^[%+%-]%d+%% to .- Resistances?$") or text:match("^%+%d+ to maximum Life$")
		or text:match("^%+%d+ to Strength") or text:match("^%+%d+ to Dexterity") or text:match("^%+%d+ to Intelligence")
		or text:match("^%+%d+ to all Attributes$") or text:match("^%d+%% increased Movement Speed$")
end

local function sanitise(text)
	return (text:gsub("\r\n", "\n"):gsub("\226\128\148", "-"):gsub("\226\128\147", "-"))
end

--- A mod line's value as the trade site compares it: the midpoint for "# to #", else the first number.
function M.lineValue(text)
	local low, high = text:match("(%-?%d+%.?%d*) to (%-?%d+%.?%d*)")
	if low and high then
		return (tonumber(low) + tonumber(high)) / 2
	end
	return tonumber(text:match("%-?%d+%.?%d*"))
end

--- The minimum to search for, a little under the item's own value.
function M.searchMin(value)
	if value >= 40 then
		return m_floor(value * 0.9)
	end
	return m_floor(value * 0.85)
end

-- The advanced copy (Ctrl+Alt+C) headers: tier, side and roll of each line, by the line's text.
local function readHeaders(text)
	local byText = { }
	local current
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		line = line:gsub("%s+$", "")
		local inner = line:match("^{ (.-) }$")
		if inner then
			local lower = inner:lower()
			current = {
				affix = inner:match('Modifier "(.-)"'),
				tier = tonumber(inner:match("%(Tier: (%d+)%)") or inner:match("%(Rank: (%d+)%)")),
				side = lower:match("prefix") and "prefix" or lower:match("suffix") and "suffix" or nil,
				kind = lower:match("implicit") and "implicit" or lower:match("crafted") and "crafted"
					or lower:match("fractured") and "fractured" or lower:match("unique") and "unique"
					or lower:match("enchant") and "enchant" or "explicit",
			}
		elseif line == "--------" or line == "" then
			current = nil
		elseif current and not line:match("^%(") then
			local rolls = { }
			local clean = line:gsub("(%-?%d+%.?%d*)%((%-?%d+%.?%d*)%-(%-?%d+%.?%d*)%)", function(v, lo, hi)
				v, lo, hi = tonumber(v), tonumber(lo), tonumber(hi)
				if v and lo and hi then
					t_insert(rolls, hi == lo and 1 or (v - lo) / (hi - lo))
				end
				return tostring(v and (v == m_floor(v) and m_floor(v) or v) or "")
			end)
			local roll
			if rolls[1] then
				roll = 0
				for _, r in ipairs(rolls) do
					roll = roll + r
				end
				roll = roll / #rolls
			end
			byText[(current.kind == "implicit" and "implicit|" or "mod|") .. clean] = { affix = current.affix, tier = current.tier, side = current.side, kind = current.kind, roll = roll }
		end
	end
	return byText
end

-- Every mod line of the item, with its resolved text, kind and trade ids.
local function itemLines(item, headers)
	local out = { }
	local sources = {
		{ list = item.enchantModLines, kind = "enchant" },
		{ list = item.implicitModLines, kind = "implicit" },
		{ list = item.explicitModLines, kind = "explicit" },
	}
	for _, source in ipairs(sources) do
		for _, modLine in ipairs(source.list or { }) do
			if item:CheckModLineVariant(modLine) and not modLine.extra then
				local text = itemLib.applyRange(modLine.line:gsub("\n", " "), modLine.range, modLine.valueScalar)
				local kind = source.kind
				if kind == "explicit" then
					kind = modLine.crafted and "crafted" or modLine.fractured and "fractured" or "explicit"
				end
				local header = headers[(source.kind == "implicit" and "implicit|" or "mod|") .. text] or { }
				local roll = header.roll
				if not roll and modLine.range and item.rarity == "UNIQUE" then
					roll = modLine.range
				end
				t_insert(out, {
					text = text,
					template = tradeHelpers.modLineTemplate(text),
					kind = kind,
					tier = header.tier,
					side = header.side,
					affix = header.affix,
					roll = roll,
					value = M.lineValue(text),
					modLine = modLine,
				})
			end
		end
	end
	return out
end

local statText
local function tradeStatText()
	if not statText then
		statText = { }
		for _, category in ipairs(tradeHelpers.getTradeStats() or { }) do
			for _, entry in ipairs(category.entries or { }) do
				statText[entry.id] = entry.text
			end
		end
	end
	return statText
end

-- Trade ids for one line. Local stats (weapons, armour) and global ones share their text, so the
-- trade site lists both; keep the one that fits the item, or both when it is still unclear.
local function lineTradeIds(item, line, isGear)
	local sourceType = (line.kind == "crafted" or line.kind == "fractured") and line.kind or
		(line.kind == "unique" and "explicit") or line.kind
	local entries = buySimilar.addModEntries(item, { { list = { line.modLine }, type = sourceType } })
	local entry = entries[1]
	if not entry or not entry.tradeIds[1] then
		return nil
	end
	local ids = entry.tradeIds
	if #ids > 1 then
		local texts = tradeStatText()
		local want, other = { }, { }
		for _, id in ipairs(ids) do
			local isLocal = (texts[id] or ""):match("%(Local%)$") ~= nil
			t_insert(isLocal == isGear and want or other, id)
		end
		if want[1] then
			ids = want
		end
	end
	return { ids = ids, isOption = entry.isOption, optionValue = entry.isOption and entry.value or nil, invert = entry.invert }
end

-- The totals the trade site's pseudo filters use (life, resistances, attributes...).
local function totals(lines)
	local t = { life = 0, mana = 0, es = 0, fire = 0, cold = 0, lightning = 0, chaos = 0, str = 0, dex = 0, int = 0, ms = 0 }
	for _, line in ipairs(lines) do
		local text = line.text
		local v, what = text:match("^([%+%-]%d+)%% to (.-) Resistances?$")
		if v then
			v, what = tonumber(v), what:lower()
			if what == "all elemental" then
				t.fire, t.cold, t.lightning = t.fire + v, t.cold + v, t.lightning + v
			else
				for _, element in ipairs({ "fire", "cold", "lightning", "chaos" }) do
					if what:find(element, 1, true) then
						t[element] = t[element] + v
					end
				end
			end
		end
		v = tonumber(text:match("^%+(%d+) to maximum Life$"))
		if v then t.life = t.life + v end
		v = tonumber(text:match("^%+(%d+) to maximum Mana$"))
		if v then t.mana = t.mana + v end
		v = tonumber(text:match("^%+(%d+) to maximum Energy Shield$"))
		if v then t.es = t.es + v end
		v = tonumber(text:match("^(%d+)%% increased Movement Speed$"))
		if v then t.ms = t.ms + v end
		local amount, attrs = text:match("^%+(%d+) to (.+)$")
		if amount and (attrs == "all Attributes" or attrs:match("^Strength") or attrs:match("^Dexterity") or attrs:match("^Intelligence")) then
			amount = tonumber(amount)
			if attrs == "all Attributes" then
				t.str, t.dex, t.int = t.str + amount, t.dex + amount, t.int + amount
			else
				if attrs:find("Strength", 1, true) then t.str = t.str + amount end
				if attrs:find("Dexterity", 1, true) then t.dex = t.dex + amount end
				if attrs:find("Intelligence", 1, true) then t.int = t.int + amount end
			end
		end
	end
	t.ele = t.fire + t.cold + t.lightning
	return t
end

local function isBulkClass(itemClass)
	for _, pattern in ipairs(BULK_CLASS_PATTERNS) do
		if itemClass:match(pattern) then
			return true
		end
	end
end

--- Read a pasted item. Returns a description, or nil and a message.
function M.describe(rawText)
	local text = sanitise(rawText)
	local itemClass = text:match("Item Class:%s*([^\n]+)")
	local rarityText = text:match("Rarity:%s*(%a+)")
	if itemClass then
		itemClass = itemClass:gsub("%s+$", "")
	end
	-- Normal and magic maps are bulk; rare maps too (their price follows the tier, not the mods).
	if itemClass and isBulkClass(itemClass) then
		local lines = { }
		for line in (text .. "\n"):gmatch("([^\n]*)\n") do
			t_insert(lines, (line:gsub("%s+$", "")))
		end
		local name = lines[3]
		if rarityText and (rarityText == "Rare" or rarityText == "Unique") and lines[4] and lines[4] ~= "--------" then
			name = rarityText == "Unique" and lines[3] or lines[4]
		end
		return {
			verdict = "bulk",
			class = itemClass,
			rarity = rarityText,
			bulk = {
				kind = itemClass,
				name = name,
				gemLevel = tonumber(text:match("\nLevel: (%d+)")),
				quality = tonumber(text:match("\nQuality: %+(%d+)%%")),
				mapTier = tonumber(text:match("\nMap Tier: (%d+)")),
				corrupted = text:match("\nCorrupted") ~= nil,
				stack = tonumber(text:match("\nStack Size: ([%d,]+)") and text:match("\nStack Size: ([%d,]+)"):gsub(",", "") or nil),
			},
		}
	end

	local ok, item = pcall(function()
		return new("Item"):Item(text)
	end)
	if not ok or not item or not item.base then
		return nil, "Path of Building could not read this item. Copy it in the game with Ctrl+Alt+C and paste the whole text."
	end
	local headers = readHeaders(text)
	local lines = itemLines(item, headers)
	local base = item.base
	local category = CATEGORY_BY_SUBTYPE[base.subType] or CATEGORY_BY_TYPE[base.type]
	local isWeapon = base.weapon ~= nil
	local isArmour = base.armour ~= nil
	local isGear = isWeapon or isArmour
	local influences = { }
	for key in pairs(INFLUENCE_FILTERS) do
		if item[key] then
			t_insert(influences, key)
		end
	end
	t_sort(influences)
	for _, line in ipairs(lines) do
		line.trade = lineTradeIds(item, line, isGear)
	end
	-- Count affixes by name: a hybrid mod has two lines but takes one slot.
	local prefixes, suffixes = 0, 0
	local seen = { }
	for _, line in ipairs(lines) do
		if line.side and line.affix and not seen[line.side .. line.affix] then
			seen[line.side .. line.affix] = true
			if line.side == "prefix" then prefixes = prefixes + 1 else suffixes = suffixes + 1 end
		end
	end
	local links = 0
	if item.sockets then
		local groups = { }
		for _, socket in ipairs(item.sockets) do
			groups[socket.group] = (groups[socket.group] or 0) + 1
		end
		for _, count in pairs(groups) do
			links = m_max(links, count)
		end
	end
	local weaponData = item.weaponData and item.weaponData[1]
	return {
		verdict = "price",
		item = item,
		class = itemClass or base.type,
		rarity = item.rarity,
		name = item.title or item.name,
		baseName = item.baseName,
		base = base,
		category = category,
		isWeapon = isWeapon,
		isArmour = isArmour,
		isGear = isGear,
		isJewel = base.type == "Jewel",
		isFlask = base.type == "Flask",
		isCluster = base.subType == "Cluster",
		ilvl = item.itemLevel,
		corrupted = item.corrupted or false,
		mirrored = item.mirrored or false,
		fractured = item.fractured or false,
		synthesised = item.synthesised or false,
		foulborn = item.foulborn or false,
		identified = not text:match("\nUnidentified"),
		influences = influences,
		links = links,
		advanced = item.advancedCopy or false,
		lines = lines,
		totals = totals(lines),
		open = item.rarity == "RARE" and item.advancedCopy and { prefixes = m_max(0, 3 - prefixes), suffixes = m_max(0, 3 - suffixes) } or nil,
		pdps = weaponData and weaponData.PhysicalDPS,
		edps = weaponData and weaponData.ElementalDPS,
		armour = item.armourData,
	}
end

-- A driver: one thing the search filters on.
local function statDriver(key, label, ids, value, priority, extra)
	local d = { key = key, label = label, ids = ids, value = value, min = M.searchMin(value), priority = priority }
	for k, v in pairs(extra or { }) do
		d[k] = v
	end
	return d
end

--- What drives the price of a rare/magic item, most important first, and what can tighten the search.
function M.drivers(desc)
	local drivers, tighten = { }, { }
	local t = desc.totals
	local category = desc.category or ""
	local jewellery = category:match("^accessory") ~= nil
	local covered = { }

	if desc.isCluster then
		for _, line in ipairs(desc.lines) do
			if line.trade and (line.kind == "enchant" or line.trade.isOption) then
				local d = { key = line.template, label = line.text, ids = line.trade.ids, priority = line.kind == "enchant" and 1 or 2 }
				if line.trade.isOption then
					d.option = line.trade.optionValue
				else
					d.value, d.min = line.value, line.value
				end
				t_insert(drivers, d)
			end
		end
		return drivers, tighten
	end

	if desc.isFlask then
		for _, line in ipairs(desc.lines) do
			if line.kind == "explicit" and line.trade and line.value then
				t_insert(drivers, { key = line.template, label = line.text, ids = line.trade.ids, value = line.value, min = line.value, priority = 1 })
			end
		end
		return drivers, tighten
	end

	if not desc.isJewel then
		if t.life >= (jewellery and 50 or 70) then
			t_insert(drivers, statDriver("life", "+" .. t.life .. " total maximum Life", { "pseudo.pseudo_total_life" }, t.life, 1))
		end
		if t.ele >= 50 then
			t_insert(drivers, statDriver("ele_res", "+" .. t.ele .. "% total Elemental Resistance", { "pseudo.pseudo_total_elemental_resistance" }, t.ele, 2))
		end
		if t.chaos >= 15 then
			t_insert(drivers, statDriver("chaos_res", "+" .. t.chaos .. "% total Chaos Resistance", { "pseudo.pseudo_total_chaos_resistance" }, t.chaos, 3))
		end
		if category == "armour.boots" and t.ms >= 25 then
			t_insert(drivers, statDriver("movement", t.ms .. "% increased Movement Speed", { "pseudo.pseudo_increased_movement_speed" }, t.ms, 1, { min = t.ms }))
		end
		if jewellery and t.es >= 40 then
			t_insert(drivers, statDriver("es", "+" .. t.es .. " total maximum Energy Shield", { "pseudo.pseudo_total_energy_shield" }, t.es, 3))
		end
		local attrs = { { "str", "Strength", t.str }, { "dex", "Dexterity", t.dex }, { "int", "Intelligence", t.int } }
		t_sort(attrs, function(a, b) return a[3] > b[3] end)
		if attrs[1][3] >= 40 then
			t_insert(drivers, statDriver(attrs[1][1], "+" .. attrs[1][3] .. " total " .. attrs[1][2], { "pseudo.pseudo_total_" .. attrs[1][2]:lower() }, attrs[1][3], 5))
		end
	elseif desc.base.subType == "Abyss" and t.life >= 30 then
		t_insert(drivers, statDriver("life", "+" .. t.life .. " total maximum Life", { "pseudo.pseudo_total_life" }, t.life, 1))
	end
	for _, d in ipairs(drivers) do
		covered[d.key] = true
	end

	-- Weapons: the damage they deal, when their own mods add to it.
	if desc.isWeapon then
		local physMods, eleMods = false, false
		for _, line in ipairs(desc.lines) do
			if line.kind ~= "implicit" and line.text:match("Physical Damage$") and not line.text:match("to Attacks$") then
				physMods = true
			end
			if line.kind ~= "implicit" and line.text:match("^Adds .- (%a+) Damage$") and not line.text:match("Physical") then
				eleMods = true
			end
		end
		if physMods and (desc.pdps or 0) > 0 then
			t_insert(drivers, { key = "pdps", filter = "weapon", field = "pdps", value = desc.pdps, min = m_floor(desc.pdps * 0.9), priority = 1,
				label = string.format("%.1f physical DPS", desc.pdps) })
		end
		if eleMods and (desc.edps or 0) > 0 then
			t_insert(drivers, { key = "edps", filter = "weapon", field = "edps", value = desc.edps, min = m_floor(desc.edps * 0.9), priority = physMods and 2 or 1,
				label = string.format("%.1f elemental DPS", desc.edps) })
		end
	end

	-- Armour: its main defence, when its own mods raise it.
	if desc.isArmour and desc.armour and desc.category ~= "armour.quiver" then
		local localDefence = false
		for _, line in ipairs(desc.lines) do
			if line.kind ~= "implicit" and line.tier and line.tier <= 2 and line.trade and (line.text:match("increased Armour") or line.text:match("increased Evasion")
				or line.text:match("increased Energy Shield$") or line.text:match("^%+%d+ to Armour$") or line.text:match("^%+%d+ to Evasion Rating$")
				or line.text:match("^%+%d+ to maximum Energy Shield$")) then
				localDefence = true
			end
		end
		if localDefence then
			local best, field, label = 0
			for _, entry in ipairs({ { "Armour", "ar", "Armour" }, { "Evasion", "ev", "Evasion" }, { "EnergyShield", "es", "Energy Shield" } }) do
				local v = desc.armour[entry[1]] or 0
				if v > best then
					best, field, label = v, entry[2], entry[3]
				end
			end
			if best > 0 then
				t_insert(drivers, { key = "def_" .. field, filter = "armour", field = field, value = best, min = m_floor(best * 0.9), priority = 2,
					label = best .. " " .. label })
			end
		end
	end

	-- Mods a weapon's DPS or an armour's defence already reflect: never added on top of that driver.
	local hasWeaponDriver, hasDefenceDriver = false, false
	for _, d in ipairs(drivers) do
		hasWeaponDriver = hasWeaponDriver or d.filter == "weapon"
		hasDefenceDriver = hasDefenceDriver or d.filter == "armour"
	end
	local function reflected(text)
		if hasWeaponDriver and (text:match("Damage$") or text:match("increased Attack Speed$") or text:match("increased Critical Strike Chance$")) then
			return true
		end
		if hasDefenceDriver and (text:match("increased Armour") or text:match("increased Evasion") or text:match("increased Energy Shield$")
			or text:match("^%+%d+ to Armour$") or text:match("^%+%d+ to Evasion Rating$") or text:match("^%+%d+ to maximum Energy Shield$")) then
			return true
		end
	end

	-- Single mods: the valuable ones, and on jewels the best rolled ones.
	local candidates = { }
	for _, line in ipairs(desc.lines) do
		if line.trade and line.value and line.kind ~= "enchant" and not FILLER[line.template] and not coveredByTotals(line.text) then
			local priority = VALUABLE[line.template]
			local goodTier = not line.tier or line.tier <= 3
			if desc.isJewel and line.kind == "explicit" then
				priority = priority or JEWEL_VALUABLE[line.template]
			end
			if priority and goodTier and not (desc.isGear and line.template == "#% increased Attack Speed" and desc.isWeapon) then
				local min = desc.isJewel and m_max(line.value - 1, m_floor(line.value * 0.85)) or m_floor(line.value * 0.9)
				t_insert(candidates, { key = line.template, label = line.text, ids = line.trade.ids, invert = line.trade.invert,
					value = line.value, min = min, priority = priority + (line.kind == "implicit" and 2 or 0), tier = line.tier,
					kindPrefix = line.kind })
			elseif line.kind == "explicit" and line.tier and line.tier <= 3 and not reflected(line.text) then
				t_insert(tighten, { key = line.template, label = line.text, ids = line.trade.ids, invert = line.trade.invert,
					value = line.value, min = m_floor(line.value * 0.85), priority = 4, tier = line.tier })
			end
		end
	end
	t_sort(candidates, function(a, b)
		if a.priority ~= b.priority then return a.priority < b.priority end
		return (a.tier or 9) < (b.tier or 9)
	end)
	for _, c in ipairs(candidates) do
		t_insert(drivers, c)
	end
	t_sort(tighten, function(a, b) return (a.tier or 9) < (b.tier or 9) end)

	-- Nothing stands out: fall back on the best tiers it has.
	if not drivers[1] then
		local fallback = { }
		for _, line in ipairs(desc.lines) do
			if line.kind == "explicit" and line.trade and line.value and not FILLER[line.template] then
				t_insert(fallback, { key = line.template, label = line.text, ids = line.trade.ids, invert = line.trade.invert,
					value = line.value, min = M.searchMin(line.value), priority = 4, tier = line.tier, generic = true })
			end
		end
		t_sort(fallback, function(a, b) return (a.tier or 9) < (b.tier or 9) end)
		for i = 1, m_min(3, #fallback) do
			t_insert(drivers, fallback[i])
		end
		tighten = { }
	end

	-- Stable order: by priority, keeping the order found within a priority.
	for i, d in ipairs(drivers) do
		d.order = i
	end
	t_sort(drivers, function(a, b)
		if a.priority ~= b.priority then return a.priority < b.priority end
		return a.order < b.order
	end)
	return drivers, tighten
end

-- Unique items: lines whose roll is high enough to search for, best first.
function M.uniqueRolls(desc)
	local out = { }
	for _, line in ipairs(desc.lines) do
		if line.kind == "explicit" and line.roll and line.roll >= 0.7 and line.trade and line.value and not line.trade.isOption then
			t_insert(out, { key = line.template, label = line.text, ids = line.trade.ids, invert = line.trade.invert,
				value = line.value, min = m_floor(line.value * 0.95), priority = 1, roll = line.roll })
		end
	end
	t_sort(out, function(a, b) return a.roll > b.roll end)
	return { out[1], out[2] }
end

local function scaledMin(d, scale)
	if scale and d.min and d.value and d.value >= SCALE_MIN_VALUE then
		return m_min(d.min, m_floor(d.value * scale))
	end
	return d.min
end

local function filterFor(d, scale)
	local min = scaledMin(d, scale)
	if d.option ~= nil then
		return { value = { option = d.option } }
	end
	if d.invert and min then
		return { value = { max = -min } }
	end
	return min and { value = { min = min } } or { }
end

--- The trade search for a description and a list of drivers.
function M.buildQuery(desc, drivers, status, scale)
	local query = {
		status = { option = status or "securable" },
		stats = { { type = "and", filters = { } } },
	}
	local filters = { }
	local function misc()
		filters.misc_filters = filters.misc_filters or { filters = { } }
		return filters.misc_filters.filters
	end
	if desc.rarity == "UNIQUE" or desc.rarity == "RELIC" then
		local name = (desc.name or ""):gsub("^Foulborn%s+", "")
		query.name = name
		query.type = desc.baseName
		if desc.foulborn then
			misc().foulborn_item = { option = "true" }
		end
	elseif desc.isFlask then
		query.type = desc.baseName
	else
		filters.type_filters = { filters = { rarity = { option = "nonunique" } } }
		if desc.category then
			filters.type_filters.filters.category = { option = desc.category }
		else
			query.type = desc.baseName
		end
	end
	misc().corrupted = { option = desc.corrupted and "true" or "false" }
	if desc.links >= 5 then
		filters.socket_filters = { filters = { links = { min = desc.links } } }
	end
	for _, d in ipairs(drivers) do
		if d.filter == "weapon" or d.filter == "armour" then
			local group = d.filter .. "_filters"
			filters[group] = filters[group] or { filters = { } }
			filters[group].filters[d.field] = { min = scaledMin(d, scale) }
		elseif d.filter == "misc" then
			for k, v in pairs(d.misc) do
				misc()[k] = v
			end
		elseif d.ids then
			if #d.ids == 1 then
				local f = filterFor(d, scale)
				f.id = d.ids[1]
				t_insert(query.stats[1].filters, f)
			else
				local group = { type = "count", value = { min = 1 }, filters = { } }
				for _, id in ipairs(d.ids) do
					local f = filterFor(d, scale)
					f.id = id
					t_insert(group.filters, f)
				end
				t_insert(query.stats, group)
			end
		end
	end
	query.filters = filters
	return query
end

--- A craft base: its value is the base, item level and influence as much as its mods.
function M.craftBaseDriver(desc)
	if desc.rarity ~= "RARE" or desc.isJewel or desc.isFlask or not desc.ilvl then
		return nil
	end
	-- Only influence, fractured and synthesised make the base itself part of the price; open affixes alone
	-- do not (filtering on item level then just hides comparable items).
	if not (desc.influences[1] or desc.fractured or desc.synthesised) then
		return nil
	end
	local f = { ilvl = { min = m_min(desc.ilvl, 86) } }
	local names = { }
	for _, key in ipairs(desc.influences) do
		f[INFLUENCE_FILTERS[key]] = { option = "true" }
		t_insert(names, INFLUENCE_NAMES[key])
	end
	if desc.fractured then
		f.fractured_item = { option = "true" }
		t_insert(names, "fractured")
	end
	if desc.synthesised then
		f.synthesised_item = { option = "true" }
		t_insert(names, "synthesised")
	end
	t_insert(names, "item level " .. f.ilvl.min .. "+")
	return { key = "craft_base", filter = "misc", misc = f, priority = 2, label = t_concat(names, ", ") }
end

--- The searches to try, in order, for a description: { { step, drivers, query } , ... } generator state.
function M.plan(desc, args)
	args = args or { }
	local plan = { desc = desc, status = args.status or "securable" }
	if desc.rarity == "UNIQUE" or desc.rarity == "RELIC" then
		plan.unique = true
		plan.drivers = { }
		plan.rolls = M.uniqueRolls(desc)
		plan.tighten = { }
	else
		plan.drivers, plan.tighten = M.drivers(desc)
		local craft = M.craftBaseDriver(desc)
		if craft then
			t_insert(plan.drivers, 1, craft)
		end
	end
	if args.stats and args.stats[1] then
		plan.drivers = { }
		for _, s in ipairs(args.stats) do
			t_insert(plan.drivers, { key = s.id, label = s.id, ids = { s.id }, value = s.min or 0, min = s.min, priority = 1 })
		end
		plan.tighten = { }
	end
	if args.drop and args.drop[1] then
		local dropped = { }
		for _, k in ipairs(args.drop) do
			dropped[k] = true
		end
		local kept = { }
		for _, d in ipairs(plan.drivers) do
			local hit = dropped[d.key]
			for _, id in ipairs(d.ids or { }) do
				hit = hit or dropped[id]
			end
			if not hit then
				t_insert(kept, d)
			end
		end
		plan.drivers = kept
	end
	plan.active = { }
	for i = 1, m_min(M.MAX_FILTERS, #plan.drivers) do
		t_insert(plan.active, plan.drivers[i])
	end
	return plan
end

--- The first search.
function M.firstSearch(plan)
	return { step = "exact", drivers = plan.active, query = M.buildQuery(plan.desc, plan.active, plan.status) }
end

--- The next search after one that found `total` listings whose cheapest summary is `summary`; nil to stop.
function M.nextSearch(plan, previous, total, summary, searchesDone)
	if searchesDone >= M.MAX_SEARCHES then
		return nil
	end
	local desc = plan.desc
	if plan.unique then
		if previous.step == "exact" and total >= 5 and plan.rolls[1] then
			return { step = "tightened: high rolls", drivers = plan.rolls, query = M.buildQuery(desc, plan.rolls, plan.status) }
		end
		return nil
	end
	local active = previous.drivers
	if total < 8 and not previous.tightened and #active > 1 then
		if previous.step == "exact" then
			local kept = { }
			for i = 1, #active - 1 do
				kept[i] = active[i]
			end
			return { step = "relaxed: dropped " .. active[#active].label, drivers = kept, query = M.buildQuery(desc, kept, plan.status) }
		elseif total < 5 then
			-- The two main filters, the big values at 80%. Skip it when that is the search just made.
			local kept = { active[1], active[2] }
			local lowers = false
			for _, d in ipairs(kept) do
				lowers = lowers or scaledMin(d, 0.8) ~= d.min
			end
			if #active > 2 or lowers then
				return { step = "relaxed: two main filters" .. (lowers and ", big values at 80%" or ""), drivers = kept,
					query = M.buildQuery(desc, kept, plan.status, 0.8), scaled = true }
			end
		end
		return nil
	end
	if previous.step == "exact" and total >= 200 and summary and summary.median and summary.median <= 10 and plan.tighten[1] then
		local more = { }
		for i, d in ipairs(active) do
			more[i] = d
		end
		t_insert(more, plan.tighten[1])
		return { step = "tightened: +" .. plan.tighten[1].label, drivers = more, query = M.buildQuery(desc, more, plan.status), tightened = true }
	end
	return nil
end

--- ISO 8601 UTC ("2026-11-17T21:02:21Z") -> epoch seconds.
function M.isoToEpoch(iso)
	local y, mo, d, h, mi, s = tostring(iso or ""):match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
	if not y then
		return nil
	end
	local now = os.time()
	local offset = now - os.time(os.date("!*t", now))
	return os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s), isdst = false }) + offset
end

--- One listing from the fetch API, compact. nil when it has no price.
function M.parseListing(entry, now)
	local listing = entry and entry.listing
	if not listing or not listing.price or not listing.price.amount then
		return nil
	end
	local epoch = M.isoToEpoch(listing.indexed)
	return {
		amount = tonumber(listing.price.amount),
		currency = listing.price.currency,
		priceType = listing.price.type,
		account = listing.account and listing.account.name or "?",
		hours = epoch and m_max(0, (now - epoch) / 3600) or nil,
		id = entry.id,
	}
end

local function percentile(sorted, p)
	if not sorted[1] then
		return nil
	end
	local k = (#sorted - 1) * p + 1
	local lo = m_floor(k)
	local hi = m_min(lo + 1, #sorted)
	return sorted[lo] + (sorted[hi] - sorted[lo]) * (k - lo)
end

--- Round a chaos price the way people list it.
function M.roundChaos(value)
	if not value then return nil end
	if value >= 50 then
		return m_floor(value / 5 + 0.5) * 5
	end
	return m_max(1, m_floor(value + 0.5))
end

--- Summarise listings into a price range. rates: currency -> chaos (nil entries are skipped).
function M.summarise(listings, rates, total, relaxed)
	local priced, skipped = { }, { }
	for _, l in ipairs(listings) do
		local rate = rates[l.currency]
		if rate then
			l.chaos = l.amount * rate
			t_insert(priced, l)
		else
			skipped[l.currency] = (skipped[l.currency] or 0) + 1
		end
	end
	t_sort(priced, function(a, b) return a.chaos < b.chaos end)
	local perAccount, accounts = { }, 0
	for _, l in ipairs(priced) do
		if not perAccount[l.account] then
			accounts = accounts + 1
			perAccount[l.account] = 0
		end
		perAccount[l.account] = perAccount[l.account] + 1
	end
	local walls = { }
	for account, count in pairs(perAccount) do
		if count >= 3 then
			t_insert(walls, account)
		end
	end
	t_sort(walls)
	-- One listing per account: the cheapest.
	local unique, seen = { }, { }
	for _, l in ipairs(priced) do
		if not seen[l.account] then
			seen[l.account] = true
			t_insert(unique, l)
		end
	end
	local fresh, stale = 0, 0
	local freshList = { }
	for _, l in ipairs(unique) do
		if l.hours and l.hours <= M.FRESH_HOURS then
			fresh = fresh + 1
			t_insert(freshList, l)
		elseif l.hours and l.hours > M.STALE_HOURS then
			stale = stale + 1
		end
	end
	local useFresh = fresh >= 5
	local pool = useFresh and freshList or unique
	local values = { }
	for _, l in ipairs(pool) do
		t_insert(values, l.chaos)
	end
	local out = {
		total = total, fetched = #listings, priced = #priced, accounts = accounts, fresh = fresh, stale = stale,
		walls = walls, usedFreshOnly = useFresh, skippedCurrencies = next(skipped) and skipped or nil,
	}
	if not values[1] then
		return out
	end
	local p25 = percentile(values, 0.25)
	local valid, outliers = { }, 0
	for _, v in ipairs(values) do
		if #values >= 4 and v < 0.5 * p25 then
			outliers = outliers + 1
		else
			t_insert(valid, v)
		end
	end
	out.lowOutliers = outliers
	out.min = values[1]
	out.p25 = p25
	local cheapest10 = { }
	for i = 1, m_min(10, #valid) do
		cheapest10[i] = valid[i]
	end
	out.median = percentile(cheapest10, 0.5)
	out.p75 = percentile(valid, 0.75)
	local quick = #valid >= 4 and valid[2] or valid[1]
	local fair = out.median
	local ceiling = (total and total <= M.FETCH_COUNT) and percentile(values, 0.75) or out.p75
	out.quick, out.fair, out.ceiling = quick, fair, m_max(ceiling or fair, fair)

	-- Confidence.
	local why = { }
	local spread = (out.p25 and out.p25 > 0) and (out.p75 / out.p25) or 99
	local level
	if (total or 0) >= 30 and #valid >= 10 and fresh >= 5 and spread <= 2.5 and (relaxed or 0) <= 1 then
		level = "high"
	elseif (total or 0) >= 8 and #valid >= 5 and spread <= 4 then
		level = "medium"
	else
		level = "low"
	end
	if (total or 0) < 8 then t_insert(why, "few comparable listings (" .. tostring(total) .. ")") end
	if spread > 2.5 then t_insert(why, string.format("prices spread widely (p75/p25 = %.1f)", spread)) end
	if fresh < 5 then t_insert(why, "few listings from the last 48 hours (" .. fresh .. ")") end
	if stale > 0 then t_insert(why, stale .. " cheap listing(s) older than a week, maybe unsold") end
	if walls[1] then t_insert(why, #walls .. " account(s) with 3+ listings counted once") end
	if outliers > 0 then t_insert(why, outliers .. " listing(s) under half the p25 left out of the quick sale") end
	if (relaxed or 0) > 0 then t_insert(why, "search loosened " .. relaxed .. " time(s)") end
	out.confidence, out.why = level, why
	return out
end

--- Is this an item worth only a few chaos, judged on the summary of a broad search?
function M.isCheap(summary)
	return (summary.total or 0) >= 50 and summary.fair and summary.fair <= M.CHEAP_CHAOS
		and summary.p75 and summary.p75 <= M.CHEAP_CHAOS * 2
end

--- Compact item description for the tool's output.
function M.itemSummary(desc)
	return {
		name = desc.name, base = desc.baseName, class = desc.class, rarity = desc.rarity, ilvl = desc.ilvl,
		corrupted = desc.corrupted, fractured = desc.fractured or nil, synthesised = desc.synthesised or nil,
		influences = desc.influences[1] and desc.influences or nil, links = desc.links > 0 and desc.links or nil,
		open = desc.open, advancedCopy = desc.advanced,
	}
end

--- Drivers for the tool's output.
function M.driverSummary(drivers, active)
	local used = { }
	for _, d in ipairs(active or { }) do
		used[d] = true
	end
	local out = { }
	for _, d in ipairs(drivers) do
		local filter
		if d.filter == "weapon" or d.filter == "armour" then
			filter = d.field .. ">=" .. d.min
		elseif d.filter == "misc" then
			filter = "misc"
		elseif d.option ~= nil then
			filter = (d.ids[1] or "?") .. "=" .. tostring(d.option)
		elseif d.ids then
			filter = t_concat(d.ids, "|") .. (d.min and (">=" .. d.min) or "")
		end
		t_insert(out, { key = d.key, text = d.label, tier = d.tier, filter = filter, used = used[d] or false })
	end
	return out
end

return M
