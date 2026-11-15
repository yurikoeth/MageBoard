-- MageBoard: a marketplace for mage services (WoW: Forever)
-- Core: data, saved variables, addon-message protocol, slash commands.

local ADDON, ns = ...
_G.MageBoard = ns

ns.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "1.0.0"
ns.PREFIX  = "MageBoard"
ns.CHANNEL = "MageBoardSvc"

local PROTO        = "1"
local HEARTBEAT    = 90    -- seconds between provider broadcasts
local EXPIRE       = 270   -- drop a provider not heard from in this long
local REQUEST_TTL  = 600   -- drop stale requests
local REQ_COOLDOWN = 10    -- per-sender request spam guard

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
    { key = "wat", label = "Conjured Water",        short = "Water", spells = { 5504, 5505, 5506, 6127, 10138, 10139, 10140 } },
    { key = "fod", label = "Conjured Food",         short = "Food",  spells = { 587, 597, 990, 6129, 10144, 10145, 28612 } },
    { key = "ai",  label = "Arcane Intellect",      short = "Int",   spells = { 1459, 1460, 1461, 10156, 10157 } },
}
ns.SERVICE_BY_KEY = {}
for i, s in ipairs(ns.SERVICES) do
    s.order = i
    ns.SERVICE_BY_KEY[s.key] = s
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function Print(msg)
    print("|cff69ccf0MageBoard|r: " .. msg)
end
ns.Print = Print

local function IsSecret(v)
    return issecretvalue and issecretvalue(v) or false
end

local function Clean(s, maxLen)
    s = (tostring(s or ""):gsub("[|\r\n]", "/"))
    if maxLen and #s > maxLen then s = s:sub(1, maxLen) end
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

function ns:IsMe(sender)
    if sender == self.MyFullName() then return true end
    return self.Short(sender) == UnitName("player") and not sender:find("-", 1, true)
end

function ns.KnowsSpell(id)
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

function ns.KnowsService(svc)
    for _, id in ipairs(svc.spells or {}) do
        if ns.KnowsSpell(id) then return true end
    end
    return false
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
    MageBoardDB = MageBoardDB or {}
    local db = MageBoardDB
    if db.sound == nil then db.sound = true end
    if db.autoOpen == nil then db.autoOpen = true end
    if db.inviteOnAccept == nil then db.inviteOnAccept = true end
    if db.hideBusy == nil then db.hideBusy = false end

    MageBoardCharDB = MageBoardCharDB or {}
    local c = MageBoardCharDB
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
        if e.on then parts[#parts + 1] = s.key .. "=" .. (e.price or -1) end
    end
    local _, class = UnitClass("player")
    return table.concat({
        "H", PROTO,
        self.cdb.busy and "busy" or "open",
        UnitFactionGroup("player") or "?",
        class or "?",
        UnitLevel("player") or 0,
        Clean(GetZoneText(), 40),
        Clean(GetSubZoneText(), 40),
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
    self:Send("Q|" .. PROTO, "CHANNEL")
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
        Print("You're |cff40ff40open for business|r. Players running MageBoard can see your services.")
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

function ns:OnRequest(sender, key, note)
    local svc = self.SERVICE_BY_KEY[key or ""]
    if not svc then return end
    local entry = self.cdb.services[key]
    if not self.cdb.open or not entry or not entry.on then
        self:Send("D|" .. key .. "|unavailable", "WHISPER", sender)
        return
    end
    local now = GetTime()
    for _, r in ipairs(self.requests) do
        if r.sender == sender and r.key == key then
            if now - r.time < REQ_COOLDOWN then return end
            r.time, r.note = now, note
            self:Refresh()
            return
        end
    end
    table.insert(self.requests, { sender = sender, key = key, note = note or "", time = now, state = "new" })
    Alert()
    Print(("|cffffd100%s|r wants |cff69ccf0%s|r (%s). /mageboard to respond.")
        :format(self.Short(sender), svc.label, self.PlainPrice(entry.price)))
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
function ns:RequestService(mage, key, note)
    local p, svc = self.providers[mage], self.SERVICE_BY_KEY[key]
    if not p or not svc then return end
    self:Send("R|" .. key .. "|" .. Clean(note or "", 80), "WHISPER", mage)
    self.outgoing[mage] = { key = key, time = GetTime(), state = "pending" }
    Print(("Requested |cff69ccf0%s|r from |cffffd100%s|r (%s). Waiting for a reply...")
        :format(svc.label, self.Short(mage), self.PlainPrice(p.services[key])))
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
function ns:OnAddonMessage(prefix, text, _, sender)
    if prefix ~= self.PREFIX then return end
    if IsSecret(text) or IsSecret(sender) or not sender then return end
    if self:IsMe(sender) then return end

    local f = Split(text)
    local cmd = f[1]

    if cmd == "H" then
        local svc = {}
        for k, v in (f[9] or ""):gmatch("(%w+)=(%-?%d+)") do
            if self.SERVICE_BY_KEY[k] then svc[k] = tonumber(v) end
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
        p.seen     = GetTime()
        self.providers[sender] = p
        self:Refresh()

    elseif cmd == "N" then
        local p = self.providers[sender] or { name = sender, services = {} }
        p.note = f[2] or ""
        self.providers[sender] = p
        self:Refresh()

    elseif cmd == "X" then
        self.providers[sender] = nil
        self.outgoing[sender] = nil
        self:Refresh()

    elseif cmd == "Q" then
        if self.cdb.open then
            C_Timer.After(math.random() * 3, function() self:Broadcast(sender) end)
        end

    elseif cmd == "R" then
        self:OnRequest(sender, f[2], f[3])

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

-- Providers sorted: open before busy, your zone first, then by name.
function ns:SortedProviders()
    local list, myZone = {}, GetZoneText()
    for _, p in pairs(self.providers) do
        if p.status and not (self.db.hideBusy and p.status == "busy") then
            list[#list + 1] = p
        end
    end
    table.sort(list, function(a, b)
        if a.status ~= b.status then return a.status == "open" end
        local az, bz = a.zone == myZone, b.zone == myZone
        if az ~= bz then return az end
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
        if isLogin or isReload then
            -- Chat channels aren't ready instantly after login.
            C_Timer.After(6, function() ns:JoinChannel() end)
        end
        AutoDetectServices()

    elseif event == "SPELLS_CHANGED" then
        if ns.cdb and not ns.cdb.detected then AutoDetectServices() end

    elseif event == "CHAT_MSG_ADDON" then
        ns:OnAddonMessage(...)

    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if ns.cdb.open and GetTime() - (ns.lastBroadcast or 0) > 10 then
            ns:Broadcast()
        end

    elseif event == "PLAYER_LOGOUT" then
        if ns.cdb and ns.cdb.open then ns:Send("X", "CHANNEL") end
    end
end)

---------------------------------------------------------------------------
-- Slash commands + addon compartment
---------------------------------------------------------------------------
SLASH_MAGEBOARD1 = "/mageboard"
SLASH_MAGEBOARD2 = "/mboard"
SlashCmdList.MAGEBOARD = function(msg)
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
    elseif msg == "sound" then
        ns.db.sound = not ns.db.sound
        Print("Request sound " .. (ns.db.sound and "on." or "off."))
    else
        Print("Commands:")
        print("  /mageboard  - show or hide the board")
        print("  /mageboard find  - refresh and browse mages")
        print("  /mageboard open | close  - list or unlist yourself as a provider")
        print("  /mageboard busy  - toggle busy status")
        print("  /mageboard sound  - toggle the request alert sound")
    end
end

function MageBoard_OnCompartmentClick()
    ns.UI:Toggle()
end

function MageBoard_OnCompartmentEnter(_, button)
    GameTooltip:SetOwner(button or UIParent, "ANCHOR_LEFT")
    GameTooltip:AddLine("MageBoard")
    local n = 0
    for _, p in pairs(ns.providers) do if p.status then n = n + 1 end end
    GameTooltip:AddLine(n .. " mage(s) online", 1, 1, 1)
    if ns.cdb and ns.cdb.open then
        GameTooltip:AddLine("You're open for business (" .. #ns.requests .. " request(s))", 0.25, 1, 0.25)
    end
    GameTooltip:Show()
end

function MageBoard_OnCompartmentLeave()
    GameTooltip:Hide()
end
