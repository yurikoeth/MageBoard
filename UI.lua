-- MageBoard: UI (Find a Mage / My Services)

local ADDON, ns = ...
local UI = {}
ns.UI = UI

local W, H     = 500, 600
local ROW_H    = 72
local REQ_ROWS = 5

local function ClassHex(class)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class or ""]
    return (c and c.colorStr) or "ffffffff"
end

local function Label(parent, template, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    if text then fs:SetText(text) end
    return fs
end

local function Button(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w or 80, h or 22)
    b:SetText(text)
    return b
end

local function Check(parent, text, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb.label = Label(cb, "GameFontHighlight", text)
    cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    cb:SetScript("OnClick", function(self) onClick(self:GetChecked()) end)
    return cb
end

local function OpenTell(name)
    local short = ns.Short(name)
    if ChatFrame_SendTell then
        ChatFrame_SendTell(short)
    elseif ChatFrameUtil and ChatFrameUtil.SendTell then
        ChatFrameUtil.SendTell(short)
    end
end

local function ParsePrice(txt)
    txt = strtrim(txt or "")
    if txt == "" then return -1 end
    local n = tonumber(txt)
    if not n or n < 0 or n > 99999 then return nil end
    return math.floor(n * 10000 + 0.5)
end

local function PriceText(c)
    if not c or c < 0 then return "" end
    return ("%g"):format(c / 10000)
end

local function Ago(t)
    local s = math.floor(GetTime() - t)
    if s < 60 then return s .. "s ago" end
    return math.floor(s / 60) .. "m ago"
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
function UI:Build()
    if self.frame then return end

    local f = CreateFrame("Frame", "MageBoardFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(W, H)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(s)
        s:StopMovingOrSizing()
        local point, _, rel, x, y = s:GetPoint()
        ns.db.pos = { point, rel, x, y }
    end)
    local pos = ns.db.pos
    if pos then
        f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        f:SetPoint("CENTER")
    end
    f:Hide()
    tinsert(UISpecialFrames, "MageBoardFrame")
    f:SetScript("OnShow", function() UI:Refresh() end)

    local title = Label(f, "GameFontHighlight", "MageBoard")
    title:SetPoint("TOP", 0, -5)

    -- Tabs
    local tabFind = Button(f, "Find a Mage", 140, 24)
    tabFind:SetPoint("TOPLEFT", 14, -30)
    local tabMine = Button(f, "My Services", 140, 24)
    tabMine:SetPoint("LEFT", tabFind, "RIGHT", 6, 0)
    tabFind:SetScript("OnClick", function() UI:SetTab("find") end)
    tabMine:SetScript("OnClick", function() UI:SetTab("mine") end)
    f.tabFind, f.tabMine = tabFind, tabMine

    f.find = CreateFrame("Frame", nil, f)
    f.find:SetPoint("TOPLEFT", 12, -62)
    f.find:SetPoint("BOTTOMRIGHT", -12, 10)

    f.mine = CreateFrame("Frame", nil, f)
    f.mine:SetPoint("TOPLEFT", 12, -62)
    f.mine:SetPoint("BOTTOMRIGHT", -12, 10)

    self.frame = f
    self:BuildFind(f.find)
    self:BuildMine(f.mine)
    self:SetTab("find")
    C_Timer.NewTicker(5, function() UI:Refresh() end) -- keeps "Xm ago" fresh
end

function UI:SetTab(tab)
    local f = self.frame
    self.tab = tab
    f.find:SetShown(tab == "find")
    f.mine:SetShown(tab == "mine")
    f.tabFind:SetEnabled(tab ~= "find")
    f.tabMine:SetEnabled(tab ~= "mine")
    if tab == "find" then ns:Query() end
    self:Refresh()
end

function UI:Show(tab)
    self:Build()
    self.frame:Show()
    self:SetTab(tab or self.tab or "find")
end

function UI:Toggle()
    self:Build()
    if self.frame:IsShown() then self.frame:Hide() else self:Show() end
end

---------------------------------------------------------------------------
-- Find a Mage
---------------------------------------------------------------------------
function UI:BuildFind(p)
    p.count = Label(p, "GameFontNormal")
    p.count:SetPoint("TOPLEFT", 4, -4)

    local refresh = Button(p, "Refresh", 80, 22)
    refresh:SetPoint("TOPRIGHT", -2, 0)
    refresh:SetScript("OnClick", function()
        ns:JoinChannel()
        ns:Query()
    end)

    p.hideBusy = Check(p, "Hide busy", function(v)
        ns.db.hideBusy = v
        UI:Refresh()
    end)
    p.hideBusy:SetPoint("RIGHT", refresh, "LEFT", -70, 0)

    local scroll = CreateFrame("ScrollFrame", nil, p, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -30)
    scroll:SetPoint("BOTTOMRIGHT", -26, 0)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(W - 60, 1)
    scroll:SetScrollChild(content)
    p.scroll, p.content, p.rows = scroll, content, {}

    p.empty = Label(p, "GameFontDisable",
        "No mages listed right now.\n\nMages appear here when they open for business\nwith MageBoard. Hit Refresh to ask again.")
    p.empty:SetPoint("CENTER", 0, 20)
    p.empty:SetJustifyH("CENTER")
end

local function ShowRequestMenu(btn, prov)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        ns.Print("Menu API unavailable on this client.")
        return
    end
    MenuUtil.CreateContextMenu(btn, function(_, root)
        root:CreateTitle("Request from " .. ns.Short(prov.name))
        local o = ns.outgoing[prov.name]
        for _, s in ipairs(ns.SERVICES) do
            local price = prov.services[s.key]
            if price then
                root:CreateButton(s.label .. "  -  " .. ns.FormatPrice(price), function()
                    ns:RequestService(prov.name, s.key)
                end)
            end
        end
        if o then
            root:CreateDivider()
            root:CreateButton("|cffff6060Cancel my request|r", function() ns:CancelRequest(prov.name) end)
        end
    end)
end

function UI:GetFindRow(i)
    local p = self.frame.find
    local row = p.rows[i]
    if row then return row end

    row = CreateFrame("Frame", nil, p.content)
    row:SetSize(W - 60, ROW_H - 4)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.04 or 0.08)

    row.name = Label(row, "GameFontNormal")
    row.name:SetPoint("TOPLEFT", 6, -5)

    row.state = Label(row, "GameFontNormalSmall")
    row.state:SetPoint("LEFT", row.name, "RIGHT", 8, 0)

    row.zone = Label(row, "GameFontHighlightSmall")
    row.zone:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)

    row.svc = Label(row, "GameFontHighlightSmall")
    row.svc:SetPoint("TOPLEFT", row.zone, "BOTTOMLEFT", 0, -3)
    row.svc:SetWidth(W - 190)
    row.svc:SetJustifyH("LEFT")
    row.svc:SetMaxLines(1)

    row.note = Label(row, "GameFontDisableSmall")
    row.note:SetPoint("TOPLEFT", row.svc, "BOTTOMLEFT", 0, -3)
    row.note:SetWidth(W - 190)
    row.note:SetJustifyH("LEFT")
    row.note:SetMaxLines(1)

    row.request = Button(row, "Request", 80, 22)
    row.request:SetPoint("TOPRIGHT", -6, -6)
    row.request:SetScript("OnClick", function(btn) ShowRequestMenu(btn, row.prov) end)

    row.whisper = Button(row, "Whisper", 80, 22)
    row.whisper:SetPoint("TOPRIGHT", row.request, "BOTTOMRIGHT", 0, -4)
    row.whisper:SetScript("OnClick", function() OpenTell(row.prov.name) end)

    p.rows[i] = row
    return row
end

function UI:RefreshFind()
    local p = self.frame.find
    local list = ns:SortedProviders()
    p.hideBusy:SetChecked(ns.db.hideBusy)
    p.count:SetText(("%d mage%s online"):format(#list, #list == 1 and "" or "s"))
    p.empty:SetShown(#list == 0)

    local myZone = GetZoneText()
    for i, prov in ipairs(list) do
        local row = self:GetFindRow(i)
        row.prov = prov
        row:Show()

        row.name:SetText(("|c%s%s|r  |cffaaaaaa%d|r"):format(ClassHex(prov.class), ns.Short(prov.name), prov.level or 0))

        local o = ns.outgoing[prov.name]
        if o and o.state == "accepted" then
            row.state:SetText("|cff40ff40Accepted - watch for invite|r")
        elseif o then
            row.state:SetText("|cffffd100Request pending...|r")
        elseif prov.status == "busy" then
            row.state:SetText("|cffff9933Busy|r")
        else
            row.state:SetText("|cff40ff40Open|r")
        end

        local zone = prov.zone or "?"
        if prov.subzone and prov.subzone ~= "" then zone = zone .. " - " .. prov.subzone end
        if prov.zone == myZone then zone = "|cff40ff40" .. zone .. "|r" end
        row.zone:SetText(zone)

        local parts = {}
        for _, s in ipairs(ns.SERVICES) do
            local price = prov.services and prov.services[s.key]
            if price then parts[#parts + 1] = s.short .. " " .. ns.FormatPrice(price) end
        end
        row.svc:SetText(#parts > 0 and table.concat(parts, "   ") or "|cff888888No services listed|r")
        row.note:SetText(prov.note or "")
        row.request:SetEnabled(#parts > 0)
    end
    for i = #list + 1, #p.rows do p.rows[i]:Hide() end
    p.content:SetHeight(math.max(1, #list * ROW_H))
end

---------------------------------------------------------------------------
-- My Services
---------------------------------------------------------------------------
function UI:BuildMine(p)
    p.open = Check(p, "Open for business (list me on the board)", function(v) ns:SetOpen(v) end)
    p.open:SetPoint("TOPLEFT", 0, 0)

    p.busy = Check(p, "Busy (stay listed, shown as busy)", function(v) ns:SetBusy(v) end)
    p.busy:SetPoint("TOPLEFT", p.open, "BOTTOMLEFT", 0, -2)

    p.invite = Check(p, "Auto-invite on accept", function(v) ns.db.inviteOnAccept = v end)
    p.invite:SetPoint("LEFT", p.busy.label, "RIGHT", 24, 0)

    p.warn = Label(p, "GameFontRedSmall")
    p.warn:SetPoint("TOPLEFT", p.busy, "BOTTOMLEFT", 4, -4)

    local hdrSvc = Label(p, "GameFontNormalSmall", "Service")
    hdrSvc:SetPoint("TOPLEFT", p.busy, "BOTTOMLEFT", 4, -22)
    local hdrPrice = Label(p, "GameFontNormalSmall", "Price in gold  |cff888888(blank = tips, 0 = free)|r")
    hdrPrice:SetPoint("TOPLEFT", hdrSvc, "TOPLEFT", 230, 0)

    p.svcRows = {}
    local anchor = hdrSvc
    for i, s in ipairs(ns.SERVICES) do
        local row = CreateFrame("Frame", nil, p)
        row:SetSize(W - 40, 22)
        row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", i == 1 and -4 or 0, i == 1 and -4 or 0)

        row.cb = Check(row, s.label, function(v)
            ns.cdb.services[s.key].on = v
            ns:QueueBroadcast()
        end)
        row.cb:SetPoint("LEFT", 0, 0)

        row.box = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        row.box:SetSize(60, 20)
        row.box:SetAutoFocus(false)
        row.box:SetMaxLetters(8)
        row.box:SetPoint("LEFT", 240, 0)
        row.box:SetScript("OnTextChanged", function(box, user)
            if not user then return end
            local c = ParsePrice(box:GetText())
            if c then
                ns.cdb.services[s.key].price = c
                row.preview:SetText(ns.FormatPrice(c))
                ns:QueueBroadcast()
            else
                row.preview:SetText("|cffff6060?|r")
            end
        end)
        row.box:SetScript("OnEnterPressed", row.box.ClearFocus)
        row.box:SetScript("OnEscapePressed", row.box.ClearFocus)

        row.preview = Label(row, "GameFontHighlightSmall")
        row.preview:SetPoint("LEFT", row.box, "RIGHT", 8, 0)

        row.known = Label(row, "GameFontDisableSmall")
        row.known:SetPoint("LEFT", row.preview, "RIGHT", 10, 0)

        row.svc = s
        p.svcRows[i] = row
        anchor = row
    end

    local noteLbl = Label(p, "GameFontNormalSmall", "Note shown to players (where to meet, bulk deals, etc.)")
    noteLbl:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 4, -10)
    p.note = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
    p.note:SetSize(W - 50, 20)
    p.note:SetAutoFocus(false)
    p.note:SetMaxLetters(120)
    p.note:SetPoint("TOPLEFT", noteLbl, "BOTTOMLEFT", 6, -4)
    p.note:SetScript("OnTextChanged", function(box, user)
        if not user then return end
        ns.cdb.note = ns.Clean(box:GetText(), 120)
        ns:QueueBroadcast()
    end)
    p.note:SetScript("OnEnterPressed", p.note.ClearFocus)
    p.note:SetScript("OnEscapePressed", p.note.ClearFocus)

    p.reqHdr = Label(p, "GameFontNormal")
    p.reqHdr:SetPoint("TOPLEFT", p.note, "BOTTOMLEFT", -6, -14)

    p.reqEmpty = Label(p, "GameFontDisableSmall")
    p.reqEmpty:SetPoint("TOPLEFT", p.reqHdr, "BOTTOMLEFT", 0, -8)

    p.reqRows = {}
    for i = 1, REQ_ROWS do
        local r = CreateFrame("Frame", nil, p)
        r:SetSize(W - 40, 24)
        r:SetPoint("TOPLEFT", p.reqHdr, "BOTTOMLEFT", 0, -6 - (i - 1) * 26)

        r.bg = r:CreateTexture(nil, "BACKGROUND")
        r.bg:SetAllPoints()
        r.bg:SetColorTexture(1, 1, 1, 0.06)

        r.text = Label(r, "GameFontHighlightSmall")
        r.text:SetPoint("LEFT", 6, 0)
        r.text:SetWidth(240)
        r.text:SetJustifyH("LEFT")
        r.text:SetMaxLines(1)

        r.whisper = Button(r, "Tell", 46, 20)
        r.whisper:SetPoint("RIGHT", -2, 0)
        r.whisper:SetScript("OnClick", function() OpenTell(r.req.sender) end)

        r.decline = Button(r, "Decline", 64, 20)
        r.decline:SetPoint("RIGHT", r.whisper, "LEFT", -4, 0)
        r.decline:SetScript("OnClick", function()
            if r.req.state == "accepted" then ns:RemoveRequest(r.req) else ns:DeclineRequest(r.req) end
        end)

        r.accept = Button(r, "Accept", 64, 20)
        r.accept:SetPoint("RIGHT", r.decline, "LEFT", -4, 0)
        r.accept:SetScript("OnClick", function() ns:AcceptRequest(r.req) end)

        p.reqRows[i] = r
    end
end

function UI:RefreshMine()
    local p = self.frame.mine
    local c = ns.cdb

    p.open:SetChecked(c.open)
    p.busy:SetChecked(c.busy)
    p.busy:SetEnabled(c.open)
    p.invite:SetChecked(ns.db.inviteOnAccept)

    local _, class = UnitClass("player")
    p.warn:SetText(class ~= "MAGE" and "You're not a mage. You can still list services if you have them." or "")

    for _, row in ipairs(p.svcRows) do
        local e = c.services[row.svc.key]
        row.cb:SetChecked(e.on)
        if not row.box:HasFocus() then row.box:SetText(PriceText(e.price)) end
        row.preview:SetText(ns.FormatPrice(e.price))
        row.known:SetText(ns.KnowsService(row.svc) and "" or "(not learned)")
    end
    if not p.note:HasFocus() then p.note:SetText(c.note or "") end

    local n = #ns.requests
    p.reqHdr:SetText(n > REQ_ROWS and ("Incoming requests (%d, showing first %d)"):format(n, REQ_ROWS)
        or ("Incoming requests (%d)"):format(n))
    p.reqEmpty:SetText(c.open and (n == 0 and "No requests yet. You'll hear a ready-check sound when one comes in." or "")
        or "Open for business to start receiving requests.")
    p.reqEmpty:SetShown(n == 0)

    for i, r in ipairs(p.reqRows) do
        local req = ns.requests[i]
        if req then
            r.req = req
            local s = ns.SERVICE_BY_KEY[req.key]
            local price = c.services[req.key] and c.services[req.key].price
            local tag = req.state == "accepted" and "|cff40ff40[accepted]|r " or ""
            r.text:SetText(("%s|cffffd100%s|r - %s (%s) |cff888888%s|r")
                :format(tag, ns.Short(req.sender), s.short, ns.PlainPrice(price), Ago(req.time)))
            r.accept:SetShown(req.state ~= "accepted")
            r.decline:SetText(req.state == "accepted" and "Done" or "Decline")
            r:Show()
        else
            r:Hide()
        end
    end
end

function UI:Refresh()
    if not (self.frame and self.frame:IsShown()) then return end
    if self.tab == "mine" then self:RefreshMine() else self:RefreshFind() end
end
