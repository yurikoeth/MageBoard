-- Mage Dash: a marketplace for mage services (WoW: Forever)
-- Core: data, saved variables, addon-message protocol, slash commands.

local ADDON, ns = ...
_G.MageDash = ns

ns.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "1.0.0"
-- The wire names keep the addon's original name on purpose: changing them
-- would cut off everyone still running an older version.
ns.PREFIX  = "MageBoard"
ns.CHANNEL = "MageBoardSvc"

local PROTO        = "1"
local HEARTBEAT    = 90    -- seconds between provider broadcasts
local EXPIRE       = 270   -- drop a provider not heard from in this long
local REQUEST_TTL  = 600   -- drop stale requests
local REQ_COOLDOWN = 10    -- per-sender request spam guard
local MAX_REQUESTS = 30    -- queue cap
local QUERY_GAP    = 5     -- min seconds between "who's online" queries

ns.providers = {}   -- [fullName] = provider record (what players see)
ns.requests  = {}   -- incoming requests (when you're the mage)
ns.outgoing  = {}   -- [mageFullName] = { key, time, state } (your requests as a player)

---------------------------------------------------------------------------
-- Services. Spell IDs are used only to auto-detect what you can offer;
-- every service can still be toggled by hand. Price is in copper:
--   -1 = tips / pay what you want, 0 = free, >0 = fixed rate.
---------------------------------------------------------------------------
ns.SERVICES = {
    { key = "pSW", label = "Portal: Stormwind",     short = "SW",    spells = { 10059 } },
    { key = "pIF", label = "Portal: Ironforge",     short = "IF",    spells = { 11416 } },
    { key = "pDN", label = "Portal: Darnassus",     short = "Darn",  spells = { 11419 } },
    { key = "pOG", label = "Portal: Orgrimmar",     short = "Org",   spells = { 11417 } },
    { key = "pUC", label = "Portal: Undercity",     short = "UC",    spells = { 11418 } },
    { key = "pTB", label = "Portal: Thunder Bluff", short = "TB",    spells = { 11420 } },
    -- Ranked services: { spellID, what it makes, level needed to use it }.
    -- A mage lists the highest rank they know; the player picks a rank they can use.
    { key = "wat", label = "Conjured Water", short = "Water", ranks = {
        { 5504,  "Conjured Water",            1 },
        { 5505,  "Conjured Fresh Water",      5 },
        { 5506,  "Conjured Purified Water",  15 },
        { 6127,  "Conjured Spring Water",    25 },
        { 10138, "Conjured Mineral Water",   35 },
        { 10139, "Conjured Sparkling Water", 45 },
        { 10140, "Conjured Crystal Water",   55 },
    } },
    { key = "fod", label = "Conjured Food", short = "Food", ranks = {
        { 587,   "Conjured Muffin",          1 },
        { 597,   "Conjured Bread",           5 },
        { 990,   "Conjured Rye",            15 },
        { 6129,  "Conjured Pumpernickel",   25 },
        { 10144, "Conjured Sourdough",      35 },
        { 10145, "Conjured Sweet Roll",     45 },
        { 28612, "Conjured Cinnamon Roll",  55 },
    } },
    { key = "ai", label = "Arcane Intellect", short = "Int", ranks = {
        { 1459,  nil,  1 },
        { 1460,  nil,  4 },
        { 1461,  nil, 18 },
        { 10156, nil, 32 },
        { 10157, nil, 46 },
    } },
    -- Warlock: the player is summoned to wherever the warlock is standing.
    { key = "sum", label = "Summon (Ritual of Summoning)", short = "Summon", spells = { 698 } },
}
for _, s in ipairs(ns.SERVICES) do
    if s.ranks then
        s.spells = {}
        for i, r in ipairs(s.ranks) do s.spells[i] = r[1] end
    end
end
ns.SERVICE_BY_KEY = {}
for i, s in ipairs(ns.SERVICES) do
    s.order = i
    ns.SERVICE_BY_KEY[s.key] = s
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function Print(msg)
    print("|cff69ccf0Mage Dash|r: " .. msg)
end
ns.Print = Print

local function IsSecret(v)
    return issecretvalue and issecretvalue(v) or false
end

local function Clean(s, maxLen)
    s = (tostring(s or ""):gsub("[|\r\n]", "/"))
    if maxLen and #s > maxLen then
        -- Never cut through a multi-byte character (zone names in Chinese, Korean, Russian...).
        local cut = maxLen
        while cut > 0 do
            local nxt = s:byte(cut + 1)
            if not nxt or nxt < 0x80 or nxt >= 0xC0 then break end
            cut = cut - 1
        end
        s = s:sub(1, cut)
    end
    return s
end
ns.Clean = Clean

local function Split(s)
    local t = {}
    for part in (s .. "|"):gmatch("(.-)|") do t[#t + 1] = part end
    return t
end

function ns.Short(name)
    return Ambiguate and Ambiguate(name, "none") or name
end

function ns.MyFullName()
    local n, r = UnitFullName("player")
    r = (r and r ~= "") and r or (GetNormalizedRealmName and GetNormalizedRealmName())
    if r and r ~= "" then return n .. "-" .. r end
    return n
end

function ns.MyRealm()
    local r = GetNormalizedRealmName and GetNormalizedRealmName()
    if not r or r == "" then r = select(2, UnitFullName("player")) end
    return r or ""
end

-- Each realm has its own board. A sender with no realm suffix is on ours.
function ns:SameRealm(sender)
    local realm = sender:match("^[^%-]+%-(.+)$")
    local mine = ns.MyRealm()
    return not realm or mine == "" or realm == mine
end

function ns:IsMe(sender)
    if sender == self.MyFullName() then return true end
    -- Ambiguate strips the realm only when it is our own realm, so a
    -- same-named player on another realm still keeps their suffix.
    return self.Short(sender) == UnitName("player")
end

function ns.KnowsSpellID(id)
    if IsPlayerSpell then
        local ok, known = pcall(IsPlayerSpell, id)
        if ok and known then return true end
    end
    if C_SpellBook and C_SpellBook.IsSpellKnown then
        local ok, known = pcall(C_SpellBook.IsSpellKnown, id)
        if ok and known then return true end
    end
    if IsSpellKnown then
        local ok, known = pcall(IsSpellKnown, id)
        if ok and known then return true end
    end
    return false
end

function ns.KnowsSpell(id)
    if ns.KnowsSpellID(id) then return true end
    -- Name lookups only resolve for spells in the player's own spellbook.
    if C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellInfo then
        local ok, name = pcall(C_Spell.GetSpellName, id)
        if ok and name and name ~= "" then
            local ok2, info = pcall(C_Spell.GetSpellInfo, name)
            if ok2 and info then return true end
        end
    end
    return false
end

function ns.KnowsService(svc)
    for _, id in ipairs(svc.spells or {}) do
        if ns.KnowsSpell(id) then return true end
    end
    return false
end

-- Highest rank of a ranked service this character knows (0 = unknown / unranked).
function ns.HighestRank(svc)
    if not svc.ranks then return 0 end
    for i = #svc.ranks, 1, -1 do
        if ns.KnowsSpellID(svc.ranks[i][1]) then return i end
    end
    return 0
end

-- "Rank 5: Conjured Mineral Water" / "Rank 3" / nil
function ns.RankText(svc, rank)
    local r = svc and svc.ranks and rank and svc.ranks[rank]
    if not r then return nil end
    return r[2] and ("Rank " .. rank .. ": " .. r[2]) or ("Rank " .. rank)
end

-- Highest rank (up to maxRank) usable at the given character level.
function ns.BestRankForLevel(svc, maxRank, level)
    for i = math.min(maxRank, #svc.ranks), 1, -1 do
        if svc.ranks[i][3] <= level then return i end
    end
    return 1
end

-- Can this character tick / advertise the service?
function ns.CanOffer(svc)
    return (ns.db and ns.db.allowUnlearned) or ns.KnowsService(svc)
end

-- Ticked AND castable: this is what actually gets listed.
function ns:Offers(key)
    local svc, e = self.SERVICE_BY_KEY[key], self.cdb.services[key]
    return (svc and e and e.on and ns.CanOffer(svc)) and true or false
end

local function CoinParts(c)
    return math.floor(c / 10000), math.floor((c % 10000) / 100), c % 100
end

function ns.FormatPrice(c)
    if c == nil or c < 0 then return "|cffffd100Tips|r" end
    if c == 0 then return "|cff40ff40Free|r" end
    local g, s, cp = CoinParts(c)
    local out = {}
    if g > 0 then out[#out + 1] = g .. "|cffffd700g|r" end
    if s > 0 then out[#out + 1] = s .. "|cffc7c7cfs|r" end
    if cp > 0 then out[#out + 1] = cp .. "|cffeda55fc|r" end
    return table.concat(out, " ")
end

function ns.PlainPrice(c)
    if c == nil or c < 0 then return "tips" end
    if c == 0 then return "free" end
    local g, s, cp = CoinParts(c)
    local out = {}
    if g > 0 then out[#out + 1] = g .. "g" end
    if s > 0 then out[#out + 1] = s .. "s" end
    if cp > 0 then out[#out + 1] = cp .. "c" end
    return table.concat(out, " ")
end

local function Alert()
    if ns.db and ns.db.sound and SOUNDKIT then
        PlaySound(SOUNDKIT.READY_CHECK or 8960, "Master")
    end
    if FlashClientIcon then FlashClientIcon() end
end

---------------------------------------------------------------------------
-- Saved variables
---------------------------------------------------------------------------
local function InitDB()
    MageDashDB = MageDashDB or {}
    local db = MageDashDB
    if db.sound == nil then db.sound = true end
    if db.autoOpen == nil then db.autoOpen = true end
    if db.inviteOnAccept == nil then db.inviteOnAccept = true end
    if db.hideBusy == nil then db.hideBusy = false end

    MageDashCharDB = MageDashCharDB or {}
    local c = MageDashCharDB
    c.services = c.services or {}
    for _, s in ipairs(ns.SERVICES) do
        if not c.services[s.key] then
            c.services[s.key] = { on = false, price = -1 }
        end
    end
    c.note = c.note or ""
    -- Never auto-list on login; the mage opens shop on purpose.
    c.open = false
    c.busy = false

    ns.db, ns.cdb = db, c
end

-- First login on a character: pre-tick the services it can actually cast.
local function AutoDetectServices()
    if ns.cdb.detected then return end
    local any = false
    for _, s in ipairs(ns.SERVICES) do
        if ns.KnowsService(s) then
            ns.cdb.services[s.key].on = true
            any = true
        end
    end
    -- Only lock in detection once spells are known (low-level alts retry later).
    if any then ns.cdb.detected = true end
end

---------------------------------------------------------------------------
-- Channel + messaging
---------------------------------------------------------------------------
function ns:GetChannel()
    local id = GetChannelName(self.CHANNEL)
    if id and id > 0 then return id end
    return nil
end

function ns:HideChannel()
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local cf = _G["ChatFrame" .. i]
        if cf then
            if ChatFrame_RemoveChannel then
                pcall(ChatFrame_RemoveChannel, cf, self.CHANNEL)
            elseif ChatFrameUtil and ChatFrameUtil.RemoveChannel then
                pcall(ChatFrameUtil.RemoveChannel, cf, self.CHANNEL)
            elseif cf.RemoveChannel then
                pcall(cf.RemoveChannel, cf, self.CHANNEL)
            end
        end
    end
end

function ns:JoinChannel()
    if self:GetChannel() then
        self:HideChannel()
        self:Query()
        return
    end
    local join = JoinTemporaryChannel or JoinChannelByName
    if join then pcall(join, self.CHANNEL) end
    C_Timer.After(2, function()
        self:HideChannel()
        self:Query()
        if self.cdb.open then self:Broadcast() end
    end)
end

function ns:Send(msg, chatType, target)
    if chatType == "CHANNEL" then
        target = self:GetChannel()
        if not target then return false end
    end
    local ok = pcall(C_ChatInfo.SendAddonMessage, self.PREFIX, msg, chatType, target)
    return ok
end

function ns:BuildHeartbeat()
    local parts = {}
    for _, s in ipairs(self.SERVICES) do
        local e = self.cdb.services[s.key]
        if self:Offers(s.key) then
            local rank = ns.HighestRank(s)
            parts[#parts + 1] = s.key .. "=" .. (e.price or -1) .. (rank > 0 and (":" .. rank) or "")
        end
    end
    local _, class = UnitClass("player")
    return table.concat({
        "H", PROTO,
        self.cdb.busy and "busy" or "open",
        UnitFactionGroup("player") or "?",
        class or "?",
        UnitLevel("player") or 0,
        Clean(GetZoneText(), 30),      -- kept short so the whole heartbeat
        Clean(GetSubZoneText(), 30),   -- always fits one 255-byte message
        table.concat(parts, ","),
    }, "|")
end

-- target = nil broadcasts to the channel; otherwise whispers one player.
function ns:Broadcast(target)
    if not self.cdb.open then return end
    local hb = self:BuildHeartbeat()
    local note = "N|" .. Clean(self.cdb.note, 200)
    if target then
        self:Send(hb, "WHISPER", target)
        self:Send(note, "WHISPER", target)
    else
        self:Send(hb, "CHANNEL")
        self:Send(note, "CHANNEL")
        self.lastBroadcast = GetTime()
    end
end

-- Coalesce rapid edits (typing a price) into one broadcast.
function ns:QueueBroadcast()
    if self.broadcastTimer then self.broadcastTimer:Cancel() end
    self.broadcastTimer = C_Timer.NewTimer(3, function()
        self.broadcastTimer = nil
        self:Broadcast()
    end)
end

function ns:Query()
    local now = GetTime()
    if now - (self.lastQuery or -QUERY_GAP) < QUERY_GAP then return end
    if self:Send("Q|" .. PROTO, "CHANNEL") then self.lastQuery = now end
end

---------------------------------------------------------------------------
-- Provider (mage) actions
---------------------------------------------------------------------------
function ns:SetOpen(open)
    open = not not open
    if self.cdb.open == open then return end
    self.cdb.open = open
    if open then
        self:JoinChannel()
        self:Broadcast()
        Print("You're |cff40ff40open for business|r. Players running Mage Dash can see your services.")
    else
        self:Send("X", "CHANNEL")
        wipe(self.requests)
        Print("You're |cffff6060closed|r and removed from the board.")
    end
    self:Refresh()
end

function ns:SetBusy(busy)
    self.cdb.busy = not not busy
    self:Broadcast()
    self:Refresh()
end

function ns:OnRequest(sender, key, note, faction, rank)
    local svc = self.SERVICE_BY_KEY[key or ""]
    if not svc then return end
    if faction and faction ~= "" and faction ~= (UnitFactionGroup("player") or "?") then
        self:Send("D|" .. key .. "|other faction", "WHISPER", sender)
        return
    end
    local entry = self.cdb.services[key]
    if not self.cdb.open or not self:Offers(key) then
        self:Send("D|" .. key .. "|unavailable", "WHISPER", sender)
        return
    end
    rank = tonumber(rank)
    local top = ns.HighestRank(svc)
    if not (rank and svc.ranks and rank >= 1 and rank <= #svc.ranks and (top == 0 or rank <= top)) then rank = nil end
    local now = GetTime()
    for _, r in ipairs(self.requests) do
        if r.sender == sender and r.key == key then
            if now - r.time < REQ_COOLDOWN then return end
            r.time, r.note, r.rank = now, note, rank
            self:Refresh()
            return
        end
    end
    if #self.requests >= MAX_REQUESTS then
        self:Send("D|" .. key .. "|queue full", "WHISPER", sender)
        return
    end
    table.insert(self.requests, { sender = sender, key = key, note = note or "", time = now, state = "new", rank = rank })
    Alert()
    local what = svc.label .. (rank and (" - " .. ns.RankText(svc, rank)) or "")
    Print(("|cffffd100%s|r wants |cff69ccf0%s|r (%s). /mage to respond.")
        :format(self.Short(sender), what, self.PlainPrice(entry.price)))
    if self.db.autoOpen and self.UI then self.UI:Show("mine") end
    self:Refresh()
end

function ns:AcceptRequest(req)
    local where = Clean(GetSubZoneText() ~= "" and GetSubZoneText() or GetZoneText(), 40)
    self:Send("A|" .. req.key .. "|" .. where, "WHISPER", req.sender)
    if self.db.inviteOnAccept then
        local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
        if invite then pcall(invite, req.sender) end
    end
    req.state = "accepted"
    self:Refresh()
end

function ns:DeclineRequest(req, reason)
    self:Send("D|" .. req.key .. "|" .. Clean(reason or "declined", 40), "WHISPER", req.sender)
    self:RemoveRequest(req)
end

function ns:RemoveRequest(req)
    for i, r in ipairs(self.requests) do
        if r == req then table.remove(self.requests, i) break end
    end
    self:Refresh()
end

---------------------------------------------------------------------------
-- Player (customer) actions
---------------------------------------------------------------------------
function ns:RequestService(mage, key, note, rank)
    local p, svc = self.providers[mage], self.SERVICE_BY_KEY[key]
    if not p or not svc then return end
    self:Send("R|" .. key .. "|" .. Clean(note or "", 80) .. "|" .. (UnitFactionGroup("player") or "?")
        .. "|" .. (rank or ""), "WHISPER", mage)
    self.outgoing[mage] = { key = key, time = GetTime(), state = "pending", rank = rank }
    local what = svc.label .. (rank and (" - " .. ns.RankText(svc, rank)) or "")
    Print(("Requested |cff69ccf0%s|r from |cffffd100%s|r (%s). Waiting for a reply...")
        :format(what, self.Short(mage), self.PlainPrice(p.services[key])))
    self:Refresh()
end

function ns:CancelRequest(mage)
    local o = self.outgoing[mage]
    if not o then return end
    self:Send("C|" .. o.key, "WHISPER", mage)
    self.outgoing[mage] = nil
    self:Refresh()
end

---------------------------------------------------------------------------
-- Incoming addon messages
---------------------------------------------------------------------------
function ns:OnAddonMessage(prefix, text, chatType, sender)
    if IsSecret(prefix) or IsSecret(text) or IsSecret(sender) then return end
    if prefix ~= self.PREFIX or type(text) ~= "string" or not sender then return end
    if self:IsMe(sender) then return end
    if not self:SameRealm(sender) then return end

    local f = Split(text)
    local cmd = f[1]
    -- Requests and replies are private: only honour them as whispers.
    if (cmd == "R" or cmd == "A" or cmd == "D" or cmd == "C") and chatType ~= "WHISPER" then return end

    if cmd == "H" then
        local svc, ranks = {}, {}
        for k, v, r in (f[9] or ""):gmatch("(%w+)=(%-?%d+):?(%d*)") do
            local def = self.SERVICE_BY_KEY[k]
            if def then
                svc[k] = tonumber(v)
                local n = tonumber(r)
                if n and def.ranks and n >= 1 and n <= #def.ranks then ranks[k] = n end
            end
        end
        if f[4] ~= (UnitFactionGroup("player") or "?") then
            self.providers[sender] = nil
            return
        end
        local p = self.providers[sender] or { name = sender }
        p.version  = f[2]
        p.status   = (f[3] == "busy") and "busy" or "open"
        p.faction  = f[4]
        p.class    = f[5]
        p.level    = tonumber(f[6]) or 0
        p.zone     = f[7] or ""
        p.subzone  = f[8] or ""
        p.services = svc
        p.ranks    = ranks
        p.seen     = GetTime()
        self.providers[sender] = p
        self:Refresh()

    elseif cmd == "N" then
        local p = self.providers[sender]
        if p then
            p.note = f[2] or ""
            self:Refresh()
        end

    elseif cmd == "X" then
        self.providers[sender] = nil
        self.outgoing[sender] = nil
        self:Refresh()

    elseif cmd == "Q" then
        if self.cdb.open then
            C_Timer.After(math.random() * 3, function() self:Broadcast(sender) end)
        end

    elseif cmd == "R" then
        self:OnRequest(sender, f[2], f[3], f[4], f[5])

    elseif cmd == "C" then
        for _, r in ipairs(self.requests) do
            if r.sender == sender and r.key == f[2] then
                self:RemoveRequest(r)
                Print(self.Short(sender) .. " cancelled their request.")
                break
            end
        end

    elseif cmd == "A" then
        local o = self.outgoing[sender]
        local svc = self.SERVICE_BY_KEY[f[2] or ""]
        if o and svc then
            o.state = "accepted"
            Alert()
            local where = (f[3] and f[3] ~= "") and (" They're at |cffffffff" .. f[3] .. "|r.") or ""
            Print(("|cff40ff40%s accepted|r your %s request. Watch for a group invite.%s")
                :format(self.Short(sender), svc.label, where))
            self:Refresh()
        end

    elseif cmd == "D" then
        local o = self.outgoing[sender]
        local svc = self.SERVICE_BY_KEY[f[2] or ""]
        if o and svc then
            self.outgoing[sender] = nil
            Print(("|cffff6060%s declined|r your %s request (%s).")
                :format(self.Short(sender), svc.label, f[3] or "declined"))
            self:Refresh()
        end
    end
end

---------------------------------------------------------------------------
-- Housekeeping
---------------------------------------------------------------------------
function ns:Prune()
    local now, changed = GetTime(), false
    for name, p in pairs(self.providers) do
        if not p.seen or now - p.seen > EXPIRE then
            self.providers[name] = nil
            changed = true
        end
    end
    for i = #self.requests, 1, -1 do
        if now - self.requests[i].time > REQUEST_TTL then
            table.remove(self.requests, i)
            changed = true
        end
    end
    for name, o in pairs(self.outgoing) do
        if now - o.time > REQUEST_TTL then
            self.outgoing[name] = nil
            changed = true
        end
    end
    if changed then self:Refresh() end
end

function ns:Refresh()
    if self.UI then self.UI:Refresh() end
end

-- Sorting for the Find Services list.
ns.SORTS = {
    { key = "near",  label = "Nearest (your zone first)" },
    { key = "cheap", label = "Cheapest" },
    { key = "rank",  label = "Highest rank" },
    { key = "level", label = "Highest level" },
    { key = "name",  label = "Name" },
}

-- Price ordering: free, then tips, then fixed prices low to high.
local function PriceScore(c)
    if c == nil then return 3, 0 end
    if c == 0 then return 0, 0 end
    if c < 0 then return 1, 0 end
    return 2, c
end

-- Best (lowest) price a provider offers, for one service or across all of them.
local function BestPrice(p, key)
    if key then return PriceScore(p.services and p.services[key]) end
    local bt, bc = 3, 0
    for _, c in pairs(p.services or {}) do
        local t, v = PriceScore(c)
        if t < bt or (t == bt and v < bc) then bt, bc = t, v end
    end
    return bt, bc
end

local function BestRank(p, key)
    if key then return (p.ranks and p.ranks[key]) or 0 end
    local best = 0
    for _, r in pairs(p.ranks or {}) do if r > best then best = r end end
    return best
end

-- Providers for the list: filtered by service, open before busy, then the chosen sort.
function ns:SortedProviders()
    local list, myZone = {}, GetZoneText()
    local filter = self.db.filterKey
    if filter and not self.SERVICE_BY_KEY[filter] then filter = nil end
    local mode = self.db.sortBy or "near"
    for _, p in pairs(self.providers) do
        if p.status and not (self.db.hideBusy and p.status == "busy")
            and (not filter or (p.services and p.services[filter] ~= nil)) then
            list[#list + 1] = p
        end
    end
    table.sort(list, function(a, b)
        if a.status ~= b.status then return a.status == "open" end
        if mode == "cheap" then
            local at, ac = BestPrice(a, filter)
            local bt, bc = BestPrice(b, filter)
            if at ~= bt then return at < bt end
            if ac ~= bc then return ac < bc end
        elseif mode == "rank" then
            local ar, br = BestRank(a, filter), BestRank(b, filter)
            if ar ~= br then return ar > br end
        elseif mode == "level" then
            local al, bl = a.level or 0, b.level or 0
            if al ~= bl then return al > bl end
        elseif mode == "near" then
            local az, bz = a.zone == myZone, b.zone == myZone
            if az ~= bz then return az end
        end
        return a.name < b.name
    end)
    return list
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("CHAT_MSG_ADDON")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:RegisterEvent("SPELLS_CHANGED")
ev:RegisterEvent("PLAYER_LOGOUT")

ev:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON then return end
        InitDB()
        C_ChatInfo.RegisterAddonMessagePrefix(ns.PREFIX)
        C_Timer.NewTicker(HEARTBEAT, function() ns:Broadcast() end)
        C_Timer.NewTicker(15, function() ns:Prune() end)

    elseif event == "PLAYER_ENTERING_WORLD" then
        local isLogin, isReload = ...
        if (isLogin or isReload) and C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("MageBoard") then
            Print("|cffff6060The old MageBoard addon is still installed.|r Mage Dash replaces it: delete the Interface\\AddOns\\MageBoard folder, or you'll get everything twice.")
        end
        if isLogin or isReload then
            -- Chat channels aren't ready instantly after login.
            C_Timer.After(6, function() ns:JoinChannel() end)
        end
        if ns.cdb then AutoDetectServices() end

    elseif event == "SPELLS_CHANGED" then
        if ns.cdb and not ns.cdb.detected then AutoDetectServices() end
        ns:Refresh() -- a newly learned portal becomes tickable

    elseif event == "CHAT_MSG_ADDON" then
        ns:OnAddonMessage(...)

    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if ns.cdb and ns.cdb.open and GetTime() - (ns.lastBroadcast or 0) > 10 then
            ns:Broadcast()
        end

    elseif event == "PLAYER_LOGOUT" then
        if ns.cdb and ns.cdb.open then ns:Send("X", "CHANNEL") end
    end
end)

---------------------------------------------------------------------------
-- Slash commands + addon compartment
---------------------------------------------------------------------------
SLASH_MAGEDASH1 = "/mage"
SLASH_MAGEDASH2 = "/magedash"
SLASH_MAGEDASH3 = "/mageboard" -- old name, kept so existing users aren't stranded
SLASH_MAGEDASH4 = "/mboard"
SlashCmdList.MAGEDASH = function(msg)
    msg = strtrim((msg or ""):lower())
    if msg == "" then
        ns.UI:Toggle()
    elseif msg == "open" then
        ns:SetOpen(true)
    elseif msg == "close" then
        ns:SetOpen(false)
    elseif msg == "busy" then
        ns:SetBusy(not ns.cdb.busy)
        Print(ns.cdb.busy and "Marked busy." or "Marked available.")
    elseif msg == "find" then
        ns:Query()
        ns.UI:Show("find")
    elseif msg == "unlock" then
        ns.db.allowUnlearned = not ns.db.allowUnlearned
        Print(ns.db.allowUnlearned and "Unlearned services can now be ticked (use this if a spell you know shows as not learned)."
            or "Only learned services can be ticked.")
        ns:QueueBroadcast()
        ns:Refresh()
    elseif msg == "sound" then
        ns.db.sound = not ns.db.sound
        Print("Request sound " .. (ns.db.sound and "on." or "off."))
    else
        Print("Commands:")
        print("  /mage  - show or hide the board")
        print("  /mage find  - refresh and browse who's offering services")
        print("  /mage open | close  - list or unlist yourself as a provider")
        print("  /mage busy  - toggle busy status")
        print("  /mage sound  - toggle the request alert sound")
        print("  /mage unlock  - allow ticking services shown as not learned")
    end
end

function MageDash_OnCompartmentClick()
    ns.UI:Toggle()
end

function MageDash_OnCompartmentEnter(_, button)
    GameTooltip:SetOwner(button or UIParent, "ANCHOR_LEFT")
    GameTooltip:AddLine("Mage Dash")
    local n = 0
    for _, p in pairs(ns.providers) do if p.status then n = n + 1 end end
    GameTooltip:AddLine(n .. " provider(s) online", 1, 1, 1)
    if ns.cdb and ns.cdb.open then
        GameTooltip:AddLine("You're open for business (" .. #ns.requests .. " request(s))", 0.25, 1, 0.25)
    end
    GameTooltip:Show()
end

function MageDash_OnCompartmentLeave()
    GameTooltip:Hide()
end
