--[[
  The Spotify Contract
  Guild price checks for World of Warcraft Forever.

  Author:   Jeff Wilton (ThatJeffGuy on GitHub)
  In game:  Joe Roegan, Horde
  Project:  https://github.com/ThatJeffGuy/The-Spotify-Contract-Mod
  Version:  1.0.0
  License:  MIT
]]

local ADDON = ...
local TRIGGER = "?"
local PREFIX = "TSC1"
local CHUNK = 240
local SEND_INTERVAL = 1.0
local HOUSES = { "H", "N" }
local NEUTRAL_ZONES = { [1434] = true, [1446] = true, [1452] = true }

local db
local me, meShort
local sentMessages = {}
local pendingAnswers = {}
local sending
local queue = {}
local peers = {}
local online
local incoming = {}
local guildSentAt = {}
local stats = { sent = 0, sentBytes = 0, recv = 0, recvBytes = 0, ignored = 0 }

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function b36(n)
	n = math.floor(tonumber(n) or 0)
	if n <= 0 then return "0" end
	local s = ""
	while n > 0 do
		local d = n % 36
		s = B36:sub(d + 1, d + 1) .. s
		n = math.floor(n / 36)
	end
	return s
end
local function unb36(s) return tonumber(s or "", 36) end

local function fullName(name)
	return (tostring(name):gsub("%-", " "))
end

local function chatName(name)
	return (tostring(name):gsub(" ", "-"))
end

local function isMe(name)
	return name == me or name == meShort
end

local function ago(t)
	local d = math.max(0, time() - t)
	if d < 3600 then return ("%dm ago"):format(math.floor(d / 60)) end
	if d < 86400 then return ("%dh ago"):format(math.floor(d / 3600)) end
	return ("%dd ago"):format(math.floor(d / 86400))
end

local function hash(s)
	local h = 5381
	for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
	return b36(h)
end

local function whisper(msg, player)

	sentMessages[msg] = true
	sentMessages[(msg:gsub("||", "|"))] = true

	if ChatThrottleLib then
		ChatThrottleLib:SendChatMessage("ALERT", "TheSpotifyContract", msg, "WHISPER", nil, player)
	else
		(C_ChatInfo.SendChatMessage or SendChatMessage)(msg, "WHISPER", nil, player)
	end
end

local function addonSend(msg, prio, target)
	if not IsInGuild() then return end
	local channel, dest = "GUILD", nil
	if target then channel, dest = "WHISPER", chatName(target) end
	stats.sent, stats.sentBytes = stats.sent + 1, stats.sentBytes + #msg
	if ChatThrottleLib then
		ChatThrottleLib:SendAddonMessage(prio or "BULK", PREFIX, msg, channel, dest)
	else
		C_ChatInfo.SendAddonMessage(PREFIX, msg, channel, dest)
	end
end

local function hasAuctioneer()
	return AucAdvanced and AucAdvanced.API and AucAdvanced.Scan and AucAdvanced.Const
end

local function factionName()
	return (UnitFactionGroup and UnitFactionGroup("player")) or "Faction"
end

local function houseName(h)
	return h == "N" and "Neutral" or factionName()
end

local function currentHouse()
	local R = AucAdvanced and AucAdvanced.Resources
	if R and R.IsNeutralZone ~= nil then return R.IsNeutralZone and "N" or "H" end
	if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetMapInfo) then return nil end
	local id = C_Map.GetBestMapForUnit("player")
	while id do
		if NEUTRAL_ZONES[id] then return "N" end
		local info = C_Map.GetMapInfo(id)
		if not info then break end
		if info.mapType and info.mapType <= 3 then return "H" end
		id = info.parentMapID
	end
	return id and "H" or nil
end

local function inCombat()
	return (InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and UnitAffectingCombat("player"))
end

local function eligible()
	return IsResting() and not inCombat()
end

local function peerEligible(name)
	local p = peers[name]
	if not (p and p.ok) then return false end
	if online and not online[name] then return false end
	return true
end

local function anyPeerEligible()
	for name in pairs(peers) do
		if peerEligible(name) then return true end
	end
	return false
end

local function anyPeerCalm()
	for name, p in pairs(peers) do
		if not p.fight and (not online or online[name]) then return true end
	end
	return false
end

local function refreshRoster()
	if not (IsInGuild() and GetNumGuildMembers and GetGuildRosterInfo) then return end
	local n = GetNumGuildMembers()
	if not n or n == 0 then return end
	local set = {}
	for i = 1, n do
		local name, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
		if name and isOnline then set[fullName(name)] = true end
	end
	online = set
end

local categoryOf = {}
local function category(id)
	local c = categoryOf[id]
	if c == nil then
		local info = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
		local classID, subID
		if info then classID, subID = select(6, info(id)) end
		c = (classID and subID) and (classID .. ":" .. subID) or false
		categoryOf[id] = c
	end
	return c or nil
end

local function newHouse()
	return { items = {}, scans = {}, hist = {}, newest = 0, lastSent = 0 }
end

local HIST_DAYS = 3
local function dayKey(t) return date("%Y%m%d", t) end

local function recordDay(house, id, t, low, med)
	local v = (med and med > 0) and med or low
	if not v or v <= 0 then return end
	house.hist[id] = house.hist[id] or {}
	local d, cur = dayKey(t), house.hist[id][dayKey(t)]
	local isMed = med ~= nil and med > 0
	if not cur or (isMed and not cur.m) or (isMed == cur.m and t >= (cur.t or 0)) then
		house.hist[id][d] = { v = v, m = isMed, t = t }
	end
end

local function average3(house, id)
	local days = house.hist[id]
	if not days then return nil end
	local sum, n = 0, 0
	for i = 0, HIST_DAYS - 1 do
		local e = days[dayKey(time() - i * 86400)]
		if e then sum, n = sum + e.v, n + 1 end
	end
	return n > 0 and sum / n or nil
end

local function pruneHistory(house)
	local keep = {}
	for i = 0, HIST_DAYS - 1 do keep[dayKey(time() - i * 86400)] = true end
	for id, days in pairs(house.hist) do
		for d in pairs(days) do if not keep[d] then days[d] = nil end end
		if not next(days) then house.hist[id] = nil end
	end
end

local function initDB()
	TheSpotifyContractDB = TheSpotifyContractDB or {}
	db = TheSpotifyContractDB
	db.houses = db.houses or {}
	for _, h in ipairs(HOUSES) do
		local house = db.houses[h] or newHouse()
		db.houses[h] = house
		house.hist = house.hist or {}
		pruneHistory(house)
	end
	db.syncedUntil = db.syncedUntil or 0
end

local function newestAll()
	local n = 0
	for _, h in ipairs(HOUSES) do if db.houses[h].newest > n then n = db.houses[h].newest end end
	return n
end

local function merge(h, id, t, low, qty, n, by, med)
	local house = db.houses[h]
	if not (house and id and t and low and qty and n) then return end
	if t > time() + 3600 or qty < 0 or n < 0 or n > qty then return end
	local cur = house.items[id]
	if not cur or t > cur.t or (t == cur.t and by == cur.by) then
		house.items[id] = { t = t, low = low, qty = qty, n = n, by = by, med = (med and med > 0) and med or nil }
	end
	if qty > 0 then recordDay(house, id, t, low, med) end
	if t > house.newest then house.newest = t end
end

local function weightedMedian(listings)
	if #listings == 0 then return nil end
	table.sort(listings, function(a, b) return a[1] < b[1] end)
	local total = 0
	for _, l in ipairs(listings) do total = total + l[2] end
	local half, run = total / 2, 0
	for _, l in ipairs(listings) do
		run = run + l[2]
		if run >= half then return math.floor(l[1]) end
	end
end

local function encodeEntry(h, id)
	local house = db.houses[h]
	local it = house.items[id]
	return table.concat({ b36(id), b36(it.low), b36(it.qty), b36(it.n), b36(it.med or 0) }, ",")
end

local function sortRefs(refs)
	table.sort(refs, function(a, b)
		local x, y = db.houses[a[1]].items[a[2]], db.houses[b[1]].items[b[2]]
		if x.t ~= y.t then return x.t < y.t end
		if x.by ~= y.by then return x.by < y.by end
		if a[1] ~= b[1] then return a[1] < b[1] end
		return a[2] < b[2]
	end)
	return refs
end

local function sendQueueBusy()
	local bulk = ChatThrottleLib and ChatThrottleLib.Prio and ChatThrottleLib.Prio.BULK
	return bulk and bulk.Ring and bulk.Ring.pos
end

local function canMove(s)
	if s.kind == "F" then
		if inCombat() then return false, "you're in combat" end
		if not anyPeerCalm() then return false, "every other member is in combat or offline" end
	else
		if not eligible() then return false, "you're not resting, or in combat" end
		if s.target then
			if not peerEligible(s.target) then return false, s.target .. " isn't eligible" end
		elseif not anyPeerEligible() then
			return false, "no other eligible members online"
		end
	end
	if sendQueueBusy() then return false, "waiting for the send queue" end
	return true
end

local function nextChunk()
	if not sending then return end

	if not canMove(sending) then
		for i, other in ipairs(queue) do
			if canMove(other) then
				queue[i] = sending
				sending = other
				break
			end
		end
	end
	local s = sending
	if not canMove(s) then return end
	if s.pos > #s.refs then
		if s.complete and s.last then
			addonSend(("E|%s|%s|%s"):format(b36(s.last.t), s.last.by, s.last.h), "BULK", s.target)
		end
		sending = table.remove(queue, 1)
		return
	end

	local h0, id0 = s.refs[s.pos][1], s.refs[s.pos][2]
	local first = db.houses[h0].items[id0]
	local t, by = first.t, first.by
	if not s.last or t >= s.last.t then s.last = { t = t, by = by, h = h0 } end
	local parts, len = {}, 0
	while s.pos <= #s.refs do
		local h, id = s.refs[s.pos][1], s.refs[s.pos][2]
		local it = db.houses[h].items[id]
		if h ~= h0 or it.t ~= t or it.by ~= by then break end
		local e = encodeEntry(h, id)
		if len + #e + 1 > CHUNK - 12 - #by then break end
		parts[#parts + 1] = e
		len = len + #e + 1
		s.pos = s.pos + 1
		if not s.target then guildSentAt[h .. id] = time() end
	end
	addonSend(("%s|%s|%s|%s|%s"):format(s.kind or "D", b36(t), by, h0, table.concat(parts, ";")), "BULK", s.target)
end

local transferTicker

local function startTransfer(refs, label, complete, target, kind)
	if #refs == 0 or not IsInGuild() then return end
	local s = { refs = sortRefs(refs), pos = 1, label = label, complete = complete, target = target, kind = kind }
	if sending then queue[#queue + 1] = s else sending = s end
	transferTicker = transferTicker or C_Timer.NewTicker(SEND_INTERVAL, nextChunk)
end

local function auctioneerKey(h)
	local R = AucAdvanced.Resources
	return R and (h == "N" and R.ServerKeyNeutral or R.ServerKeyHome)
end

local building
local function shareAuctioneerHouse(h)
	local house = db.houses[h]
	local key = auctioneerKey(h)
	if not key then return false end
	local st = AucAdvanced.Scan.GetScanStats and AucAdvanced.Scan.GetScanStats(key)
	local t = st and st.LastScan
	if not t or t <= house.lastSent then return false end
	local SD = AucAdvanced.Modules and AucAdvanced.Modules.Util and AucAdvanced.Modules.Util.ScanData
	local scandata = SD and SD.GetScanData and SD.GetScanData(key)
	local image = scandata and scandata.image
	if not image then return false end

	building = h
	local C = AucAdvanced.Const
	local unseen = C.FLAG_UNSEEN or 0
	local sum, pos = {}, 1
	local ids = {}
	local ticker
	ticker = C_Timer.NewTicker(0.05, function()
		if inCombat() then return end

		if pos <= #image then
			local stop = math.min(#image, pos + 4999)
			for i = pos, stop do
				local a = image[i]
				local flag = a[C.FLAG] or 0
				if unseen == 0 or bit.band(flag, unseen) ~= unseen then
					local id, n = a[C.ITEMID], a[C.COUNT] or 1
					if id and n > 0 then
						local s = sum[id]
						if not s then
							s = { qty = 0, n = 0, list = {} }
							sum[id] = s
							ids[#ids + 1] = id
						end
						s.qty, s.n = s.qty + n, s.n + 1
						local each = (a[C.BUYOUT] or 0) / n
						if each > 0 then
							if not s.low or each < s.low then s.low = each end
							s.list[#s.list + 1] = { each, n }
						end
					end
				end
			end
			pos = stop + 1
			return
		end
		for _, id in ipairs(ids) do
			local s = sum[id]
			merge(h, id, t, math.floor(s.low or 0), s.qty, s.n, me, weightedMedian(s.list))
		end
		do
			ticker:Cancel()
			building = nil
			house.lastSent = t
			house.scans[me] = t
			local refs = {}
			for _, id in ipairs(ids) do refs[#refs + 1] = { h, id } end
			startTransfer(refs, ("Auctioneer %s AH scan"):format(houseName(h)), true)
		end
	end)
	return true
end

local function shareOwnScan()
	if building or not hasAuctioneer() or inCombat() then return end
	for _, h in ipairs(HOUSES) do
		if shareAuctioneerHouse(h) then return end
	end
end

local atrSigs
local atrPending

local function atrItemId(key)
	return tonumber(key) or tonumber(tostring(key):match("^g:(%d+)"))
end

local function atrFullSummary(h, t, raw)
	local sum = {}
	for _, row in ipairs(raw) do
		if row.itemKey and row.itemKey.itemID then
			local id, qty = row.itemKey.itemID, row.totalQuantity or 0
			if qty > 0 then
				local s = sum[id]
				if not s then s = { qty = 0, n = 0, list = {} } sum[id] = s end
				s.qty = s.qty + qty
				local low = row.minPrice or 0
				if low > 0 and (not s.low or low < s.low) then s.low = low end
			end
		end
		local info = row.replicateInfo
		local qty, buyout, id = info and info[3], info and info[10], info and info[17]
		if id and qty and qty > 0 then
			local s = sum[id]
			if not s then s = { qty = 0, n = 0, list = {} } sum[id] = s end
			s.qty, s.n = s.qty + qty, s.n + 1
			local each = (buyout or 0) / qty
			if each > 0 then
				if not s.low or each < s.low then s.low = each end
				s.list[#s.list + 1] = { each, qty }
			end
		end
	end
	local refs = {}
	for id, s in pairs(sum) do
		local med = weightedMedian(s.list)
		merge(h, id, t, math.floor(s.low or 0), s.qty, s.n, me, med)
		refs[#refs + 1] = { h, id }
	end
	return refs
end

local function shareAuctionator(full, raw)
	local A = Auctionator and Auctionator.Database
	local D = A and A.db
	local day0 = Auctionator and Auctionator.Constants and Auctionator.Constants.SCAN_DAY_0
	if type(D) ~= "table" or not day0 then return end
	local h = currentHouse()
	local day = tostring(math.floor((time() - day0) / 86400))
	local t = time()
	local agg, changed = {}, {}
	local first = atrSigs == nil
	atrSigs = atrSigs or {}
	for key, e in pairs(D) do
		local id = atrItemId(key)
		if id and type(e) == "table" and type(e.h) == "table" and (e.h[day] or (e.l and e.l[day])) then
			local qty = (e.a and e.a[day]) or 0
			local sig = (e.m or 0) .. ":" .. qty
			if not first and atrSigs[key] ~= sig then changed[id] = true end
			atrSigs[key] = sig
			local g = agg[id]
			if not g then g = { qty = 0 } agg[id] = g end
			if (e.m or 0) > 0 and (not g.low or e.m < g.low) then g.low = e.m end
			g.qty = g.qty + qty
		end
	end
	if not h then return end
	if full and type(raw) == "table" then
		db.houses[h].scans[me] = t
		startTransfer(atrFullSummary(h, t, raw), ("Auctionator %s AH scan"):format(houseName(h)), true)
		return
	end
	if first then return end
	local refs = {}
	for id in pairs(changed) do
		local g = agg[id]
		merge(h, id, t, math.floor(g.low or 0), g.qty, 0, me)
		refs[#refs + 1] = { h, id }
	end
	startTransfer(refs, ("Auctionator %s AH update"):format(houseName(h)), false)
end

local function hookAuctionator()
	if not (Auctionator and Auctionator.API and Auctionator.API.v1) then return end
	local bus = Auctionator.EventBus
	local fullEv = Auctionator.FullScan and Auctionator.FullScan.Events and Auctionator.FullScan.Events.ScanComplete
	local incEv = Auctionator.IncrementalScan and Auctionator.IncrementalScan.Events and Auctionator.IncrementalScan.Events.PricesProcessed
	local raw
	local function run()

		if inCombat() then C_Timer.After(5, run) return end
		local k, r = atrPending, raw
		atrPending, raw = nil, nil
		shareAuctionator(k == "full", r)
	end
	local function later(kind, data)

		if kind == "full" then raw = data end
		if atrPending == "full" then return end
		local wasPending = atrPending
		atrPending = kind
		if not wasPending then C_Timer.After(3, run) end
	end
	if bus and bus.Register and fullEv then
		bus:Register({ ReceiveEvent = function(_, _, data) later("full", data) end }, { fullEv })
		if incEv then bus:Register({ ReceiveEvent = function() later("update") end }, { incEv }) end

		local browseFull = Auctionator.IncrementalScan and Auctionator.IncrementalScan.Events
			and Auctionator.IncrementalScan.Events.ScanComplete
		if browseFull then bus:Register({ ReceiveEvent = function(_, _, data) later("full", data) end }, { browseFull }) end
	else
		pcall(Auctionator.API.v1.RegisterForDBUpdate, "TheSpotifyContract", function() later("update") end)
	end

	C_Timer.After(5, function() if not inCombat() and not atrSigs then shareAuctionator(false) end end)
end

local function refsNewerThan(since, cat)
	local refs = {}
	for _, h in ipairs(HOUSES) do
		for id, it in pairs(db.houses[h].items) do
			if it.t > since and (not cat or category(id) == cat) then refs[#refs + 1] = { h, id } end
		end
	end
	return refs
end

local serving = {}
local function onCatchUpRequest(requester, since)
	if serving[requester] or not eligible() or not peerEligible(requester) or newestAll() <= since then return end

	local snapshot = {}
	for _, r in ipairs(refsNewerThan(since)) do
		if db.houses[r[1]].items[r[2]].by ~= requester then snapshot[#snapshot + 1] = r end
	end
	if #snapshot == 0 then return end

	local asked = peers[requester] and peers[requester].okSince or time()
	local claim = {}
	serving[requester] = claim
	C_Timer.After(2 + math.random() * 4, function()
		if claim.cancelled or not eligible() then serving[requester] = nil return end
		claim.claimed = true
		addonSend(("C|%s|%s"):format(requester, b36(since)), "NORMAL")
		local function serve()
			if building then return C_Timer.After(5, serve) end
			serving[requester] = nil
			if claim.cancelled then return end

			local queued = {}
			for _, tr in ipairs({ sending, unpack(queue) }) do
				if tr and not tr.target then
					for i = tr.pos, #tr.refs do queued[tr.refs[i][1] .. tr.refs[i][2]] = true end
				end
			end
			local refs = {}
			for _, r in ipairs(snapshot) do
				local k = r[1] .. r[2]
				if not queued[k] and (guildSentAt[k] or 0) < asked then refs[#refs + 1] = r end
			end
			startTransfer(refs, "catch-up for " .. requester, true, requester)
		end
		C_Timer.After(1.5, serve)
	end)
end

local catOffers = {}
local function onCategoryRequest(key, id, since)
	if catOffers[key] or inCombat() then return end
	local cat = category(id)
	if not cat then return end
	local offers = {}
	catOffers[key] = offers
	local refs = refsNewerThan(since, cat)
	local ask, max = 0, 0
	for _, r in ipairs(refs) do
		local t = db.houses[r[1]].items[r[2]].t
		if t > max then max = t end
		if r[2] == id and t > ask then ask = t end
	end
	if #refs > 0 then
		C_Timer.After(0.05 + math.random() * 0.35, function()
			if inCombat() then return end
			offers[me] = { ask, max }
			addonSend(("KO|%s|%s|%s"):format(key, b36(ask), b36(max)), "ALERT")
		end)
	end
	C_Timer.After(1, function()
		catOffers[key] = nil
		local best, bo
		for name, o in pairs(offers) do
			if not bo or o[1] > bo[1] or (o[1] == bo[1] and (o[2] > bo[2] or (o[2] == bo[2] and name < best))) then
				best, bo = name, o
			end
		end
		if best ~= me or inCombat() then return end
		for _, h in ipairs(HOUSES) do
			local it = db.houses[h].items[id]
			if it and it.t > since then
				addonSend(("F|%s|%s|%s|%s"):format(b36(it.t), it.by, h, encodeEntry(h, id)), "ALERT")
			end
		end
		local rest = {}
		for _, r in ipairs(refs) do if r[2] ~= id then rest[#rest + 1] = r end end
		startTransfer(rest, "category " .. cat, false, nil, "F")
	end)
end

local function requestCatchUp()
	if not eligible() then return end
	addonSend("R|" .. b36(db.syncedUntil), "NORMAL")
end

local function mergeEntries(h, t, by, body)
	for e in (body or ""):gmatch("[^;]+") do
		local id, low, qty, n, med = strsplit(",", e)
		merge(h, unb36(id), t, unb36(low), unb36(qty), unb36(n), by, unb36(med))
	end
end

local function onAddonMessage(prefix, msg, channel, sender)
	if prefix ~= PREFIX or type(msg) ~= "string" then return end
	if channel ~= "GUILD" and channel ~= "WHISPER" then return end
	if issecretvalue and (issecretvalue(msg) or issecretvalue(sender)) then return end
	local from = fullName(sender)
	local kind, a, b, c, d = strsplit("|", msg, 5)

	if kind == "Q" then
		local p = pendingAnswers[a]
		if p and not isMe(from) then

			if not p.claimed or from < me then p.cancelled = true end
		end
		return
	end
	if isMe(from) then return end
	stats.recv, stats.recvBytes = stats.recv + 1, stats.recvBytes + #msg
	peers[from] = peers[from] or { ok = false }
	peers[from].t = time()

	if kind == "S" then
		if a == "1" and not peers[from].ok then peers[from].okSince = time() end
		peers[from].ok = a == "1"
		peers[from].fight = b == "1"
	elseif kind == "H" then
		C_Timer.After(1 + math.random() * 3, function()
			addonSend(("S|%s|%s"):format(eligible() and "1" or "0", inCombat() and "1" or "0"), "NORMAL")
		end)
	elseif kind == "D" then
		local t = unb36(a)
		if not t or not b or b == "" or not db.houses[c] then return end
		local key = c .. "|" .. b .. "|" .. a
		if not eligible() then

			stats.ignored = stats.ignored + 1
			incoming[key] = { ok = false }
			return
		end
		incoming[key] = incoming[key] or { ok = true }
		mergeEntries(c, t, b, d)
	elseif kind == "F" then
		local t = unb36(a)
		if not t or not b or b == "" or not db.houses[c] then return end
		if inCombat() then stats.ignored = stats.ignored + 1 return end
		mergeEntries(c, t, b, d)
	elseif kind == "E" then
		local t, house = unb36(a), db.houses[c]
		local key = (c or "") .. "|" .. (b or "") .. "|" .. (a or "")
		local inc = incoming[key]
		incoming[key] = nil

		if t and house and b and inc and inc.ok and eligible() and t <= time() + 3600 and t > (house.scans[b] or 0) then
			house.scans[b] = t
		end
	elseif kind == "R" then
		onCatchUpRequest(from, unb36(a) or 0)
	elseif kind == "C" then
		local claim = serving[a]
		if claim and (not claim.claimed or from < me) then claim.cancelled = true end
	elseif kind == "K" then
		local id = unb36(b)
		if a and id then onCategoryRequest(a, id, unb36(c) or 0) end
	elseif kind == "KO" then
		local offers = catOffers[a]
		if offers then offers[from] = { unb36(b) or 0, unb36(c) or 0 } end
	end
end

local function getItems(text)
	local items = {}
	for link in text:gmatch("|c[^|]+|Hitem:[^|]+|h%[.-%]|h|r") do
		items[#items + 1] = { link = link }
	end
	return items
end

local function bigCoins(money)
	money = math.floor(tonumber(money) or 0)
	local g, sv, c = math.floor(money / 10000), math.floor(money % 10000 / 100), money % 100
	local out = {}
	if g > 0 then out[#out + 1] = g .. "G" end
	if sv > 0 then out[#out + 1] = sv .. "S" end
	if c > 0 or #out == 0 then out[#out + 1] = c .. "C" end
	return table.concat(out, " ")
end

local function age(t)
	local m = math.floor(math.max(0, time() - t) / 60)
	if m < 120 then return m .. (m == 1 and " minute" or " minutes") end
	if m < 2880 then return math.floor(m / 60) .. " hours" end
	return math.floor(m / 1440) .. " days"
end

local function answer(link, player, h)
	local id = tonumber(link:match("|Hitem:(%d+)"))
	local house = db.houses[h]
	local label = h == "N" and "Neutral AH" or factionName()
	local avg = id and average3(house, id)
	local it = id and house.items[id]
	local parts = { link }
	parts[#parts + 1] = avg and ("%s: 3-day avg %s"):format(label, bigCoins(avg)) or (label .. ": no data yet")
	if it then
		local newest = 0
		for _, t in pairs(house.scans) do if t > newest then newest = t end end
		if it.t >= newest and it.qty > 0 and it.low > 0 then
			parts[#parts + 1] = ("Lowest %s (%d up)"):format(bigCoins(it.low), it.qty)
			parts[#parts + 1] = ("Data is %s old."):format(age(it.t))
		else
			parts[#parts + 1] = "None up now"
			parts[#parts + 1] = ("Data is %s old."):format(age(newest))
		end
	end

	whisper(table.concat(parts, " || "), player)
end

local function onGuildChat(text, player)
	if issecretvalue and (issecretvalue(text) or issecretvalue(player)) then return end
	if type(text) ~= "string" or type(player) ~= "string" then return end
	text = text:match("^%s*(.-)$")
	if text:sub(1, 1) ~= TRIGGER or not text:find("|Hitem:", 1, true) then return end

	local h = text:sub(2):lower():match("^%s*pvp") and "N" or "H"
	local items = getItems(text)
	if #items == 0 then return end

	local key = hash(player .. "\1" .. text)
	local p = {}
	pendingAnswers[key] = p
	local wait = eligible() and (0.2 + math.random() * 0.6) or (1.5 + math.random())
	C_Timer.After(wait, function()
		if p.cancelled then pendingAnswers[key] = nil return end
		p.claimed = true
		addonSend("Q|" .. key, "ALERT")
		C_Timer.After(0.7, function()
			pendingAnswers[key] = nil
			if p.cancelled then return end
			local function reply()
				for _, item in ipairs(items) do answer(item.link, player, h) end
			end
			if inCombat() or not anyPeerCalm() then return reply() end

			local asked = {}
			for i, item in ipairs(items) do
				local id = tonumber(item.link:match("|Hitem:(%d+)"))
				local cat = id and category(id)
				if cat and not asked[cat] then
					asked[cat] = true
					addonSend(("K|%s|%s|%s"):format(key .. i, b36(id), b36(db.syncedUntil)), "ALERT")

					onCategoryRequest(key .. i, id, db.syncedUntil)
				end
			end
			if next(asked) then C_Timer.After(2, reply) else reply() end
		end)
	end)
end

SLASH_THESPOTIFYCONTRACT1 = "/tsc"
SlashCmdList.THESPOTIFYCONTRACT = function()
	print("|cff33ff99The Spotify Contract|r")
	for _, h in ipairs(HOUSES) do
		local house = db.houses[h]
		local n = 0
		for _ in pairs(house.items) do n = n + 1 end
		print(("  %s AH: %d items, newest data %s"):format(houseName(h), n,
			house.newest > 0 and (date("%b %d %H:%M", house.newest) .. " (" .. ago(house.newest) .. ")") or "none"))
		for who, t in pairs(house.scans) do print(("    scanner %s: %s (%s)"):format(who, date("%b %d %H:%M", t), ago(t))) end
	end
	print("  you: " .. (eligible() and "eligible to sync" or (inCombat() and "in combat, not syncing" or "not resting, full sync off")))
	local ok = {}
	for name in pairs(peers) do if peerEligible(name) then ok[#ok + 1] = name end end
	table.sort(ok)
	print(("  eligible members: %s"):format(#ok > 0 and table.concat(ok, ", ") or "none"))
	if building then print(("  summarising your latest Auctioneer %s AH scan..."):format(houseName(building))) end
	if sending then
		local moving, why = canMove(sending)
		print(("  sending %s: %d/%d items%s"):format(sending.label, sending.pos - 1, #sending.refs,
			moving and "" or (" (paused: " .. why .. ")")))
		if #queue > 0 then print(("  %d more transfer(s) queued"):format(#queue)) end
	end
	print(("  this session: sent %d messages (%.1f KB), received %d (%.1f KB), skipped %d while not syncing"):format(
		stats.sent, stats.sentBytes / 1024, stats.recv, stats.recvBytes / 1024, stats.ignored))
end

local function hideSent(_, _, msg)
	if issecretvalue and issecretvalue(msg) then return end
	if sentMessages[msg] then
		sentMessages[msg] = nil
		sentMessages[(msg:gsub("||", "|"))] = nil
		return true
	end
end
local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
addFilter("CHAT_MSG_WHISPER_INFORM", hideSent)

local lastAnnounced, lastFight
local announceTimer
local function eligibilityChanged()
	if announceTimer then return end
	announceTimer = C_Timer.NewTimer(2, function()
		announceTimer = nil
		local now, fight = eligible() and true or false, inCombat() and true or false
		if now == lastAnnounced and fight == lastFight then return end
		local became = now and not lastAnnounced
		lastAnnounced, lastFight = now, fight
		addonSend(("S|%s|%s"):format(now and "1" or "0", fight and "1" or "0"), "NORMAL")
		if became then C_Timer.After(2, requestCatchUp) end
	end)
end

local function tickSynced()
	if not eligible() then return end
	local upTo = time()
	for key in pairs(incoming) do
		local t = unb36(key:match("|([^|]+)$"))
		if t and t - 1 < upTo then upTo = t - 1 end
	end
	if upTo > db.syncedUntil then db.syncedUntil = upTo end
end

local frame = CreateFrame("Frame")
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "CHAT_MSG_GUILD", "CHAT_MSG_ADDON",
	"PLAYER_UPDATE_RESTING", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "GUILD_ROSTER_UPDATE" }) do
	frame:RegisterEvent(e)
end
frame:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... == ADDON then initDB() end
	elseif event == "PLAYER_LOGIN" then
		local first, second = UnitFullName("player")
		meShort = first or UnitName("player")
		me = (second and second ~= "") and (meShort .. " " .. second) or meShort
		C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
		C_Timer.After(15, function()
			addonSend("H", "NORMAL")
			eligibilityChanged()
		end)
		C_Timer.NewTicker(30, tickSynced)
		C_Timer.NewTicker(60, function()
			if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
		end)
		C_Timer.NewTicker(15, shareOwnScan)
		hookAuctionator()
	elseif event == "PLAYER_UPDATE_RESTING" or event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
		if me then eligibilityChanged() end
	elseif event == "GUILD_ROSTER_UPDATE" then
		refreshRoster()
	elseif event == "CHAT_MSG_GUILD" then
		local text, player = ...
		onGuildChat(text, player)
	elseif event == "CHAT_MSG_ADDON" then
		onAddonMessage(...)
	end
end)
