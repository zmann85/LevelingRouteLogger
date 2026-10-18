-- LevelRouteLogger: records quest/route data while you level, for building leveling routes.
-- Data is written to WTF\Account\<ACCOUNT>\SavedVariables\LevelRouteLogger.lua on /reload or logout.
-- Quiet by default: no popups, no chat spam. Settings: minimap button or /lrl.
--
-- Entry format (one string per event, fields separated by "~"):
--   epoch ~ level ~ xp ~ TYPE ~ uiMapID ~ x ~ y ~ field1 ~ field2 ...
-- x/y are map percentages (0-100), the usual guide coordinate format.
-- tools/log_to_route.py (Itinerary) turns a run into an Itinerary route: quests, objectives with their kill
-- and loot areas, trainers, flight paths and flights, hearthstone, vendors, grinding and your notes.
--
-- Types: LOGIN LOGOUT Z (zone) P (position) A (accept) T (turn in) QD/QC (quest dialog/complete) QI (quest
-- info) O (objective) QDONE QR (removed) G (gossip) GS (gossip option picked) TR (trainer, with its kind)
-- TRB (trainer buy) L (learned) V (vendor) VC (vendor closed: money, sold, repaired) BUY FM (flight master)
-- FPNEW (flight path learned) FLY LAND BINDQ BIND (hearth set) C (cast: items, objects, hearth - not your own
-- spells) QU (quest item used, also in combat) U (item use from the bags) E (emote) LOOT LO (loot source)
-- GN (gathered node) CRAFT X (kill XP) XD (XP delta) LV D SPIRIT (spirit healer) RES LW/EW (loading screen:
-- leaving / entering the world, with the instance) GRP PROF SK SKNEW S (system) TP (time played) N (note)
-- PAUSE RESUME SAVE
-- 3.1: one run per character (its GUID): a new character under an old name starts a run of its own.

local ADDON = ...
local SEP = "~"
local BREADCRUMB_INTERVAL = 5     -- seconds between position samples
local BREADCRUMB_MIN_DIST = 0.6   -- map-% distance before a new sample is logged

-- Chat output: main chat tab plus a tab named "wsp" (if you have one)
local EXTRA_TAB = "wsp"
local function chatOut(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local msg = table.concat(parts, " ")
    local main = DEFAULT_CHAT_FRAME
    main:AddMessage(msg)
    local getInfo = FCF_GetChatWindowInfo or GetChatWindowInfo
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local cf = _G["ChatFrame" .. i]
        local name = getInfo and getInfo(i)
        if (not name or name == "") and _G["ChatFrame" .. i .. "Tab"] then name = _G["ChatFrame" .. i .. "Tab"]:GetText() end
        if cf and cf ~= main and name and name:lower() == EXTRA_TAB then cf:AddMessage(msg) end
    end
end
local print = chatOut

local f = CreateFrame("Frame")
local run            -- current run table
local paused = false
local lastNpc = { name = "", id = "", kind = "" }
local questSnap = {} -- [questID] = objective snapshot string
local questSeen = {} -- [questID] = true once its log info has been recorded
local lastCrumb = { m = 0, x = -100, y = -100 }
local mobIds = {}     -- [mob name] = npc id, learned from targeting
local lastXP, lastXPMax, lastLevel -- for language-independent XP deltas
local lastGroup = -1  -- last logged group size
local lastBind        -- hearthstone location, to log where you set it
local onTaxi = false  -- to log where a flight lands

---------------------------------------------------------------- helpers
local function isSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) or false
end

local function clean(v)
    if v == nil then return "" end
    if isSecret(v) then return "?" end
    v = tostring(v)
    v = v:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1")
    v = v:gsub("[~|\r\n]", " ")
    return v
end

local function pos()
    local m = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local x, y = 0, 0
    if m then
        local p = C_Map.GetPlayerMapPosition(m, "player")
        if p then x, y = p:GetXY() end
    end
    return m or 0, (x or 0) * 100, (y or 0) * 100
end

local function log(kind, ...)
    if not run or paused then return end
    local m, x, y = pos()
    local parts = {
        time(), UnitLevel("player") or 0, UnitXP("player") or 0, kind,
        m, string.format("%.2f", x), string.format("%.2f", y),
    }
    for i = 1, select("#", ...) do
        parts[#parts + 1] = clean((select(i, ...)))
    end
    local e = run.entries
    e[#e + 1] = table.concat(parts, SEP)
    if kind ~= "P" then lastCrumb.m, lastCrumb.x, lastCrumb.y = m, x, y end
end

local function unitInfo(unit)
    local name = UnitName(unit)
    local guid = UnitGUID(unit)
    if isSecret(name) then name = nil end
    if isSecret(guid) then guid = nil end
    local kind, id = "", ""
    if guid then
        local k, _, _, _, _, nid = strsplit("-", guid)
        kind, id = k or "", nid or ""
    end
    return name or "", id, kind
end

local function cacheNpc()
    local name, id, kind = unitInfo("npc")
    if name == "" then name, id, kind = unitInfo("target") end
    lastNpc.name, lastNpc.id, lastNpc.kind = name, id, kind
    return name, id, kind
end

local function spellName(id)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) or "" end
    return GetSpellInfo and GetSpellInfo(id) or ""
end

local function itemIdFromLink(link)
    return link and link:match("item:(%d+)") or ""
end

---------------------------------------------------------------- quest log scanning
local function iterateQuestLog(fn)
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
        local n = C_QuestLog.GetNumQuestLogEntries()
        for i = 1, n do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and info.questID then
                fn(i, info.questID, info.title, info.level, info.isComplete)
            end
        end
    elseif GetNumQuestLogEntries then
        local n = GetNumQuestLogEntries()
        for i = 1, n do
            local title, level, _, isHeader, _, isComplete, _, questID = GetQuestLogTitle(i)
            if title and not isHeader and questID then
                fn(i, questID, title, level, isComplete)
            end
        end
    end
end

local function objectives(index, questID)
    local list = {}
    if C_QuestLog and C_QuestLog.GetQuestObjectives then
        local objs = C_QuestLog.GetQuestObjectives(questID)
        if objs then
            for j, o in ipairs(objs) do
                list[j] = { text = o.text or "", done = o.finished and 1 or 0, have = o.numFulfilled, need = o.numRequired }
            end
            return list
        end
    end
    if GetNumQuestLeaderBoards then
        for j = 1, GetNumQuestLeaderBoards(index) do
            local text, _, done = GetQuestLogLeaderBoard(j, index)
            list[j] = { text = text or "", done = done and 1 or 0 }
        end
    end
    return list
end

local function scanQuestLog()
    if not run then return end
    local present = {}
    iterateQuestLog(function(index, questID, title, level, isComplete)
        present[questID] = true
        if not questSeen[questID] then
            questSeen[questID] = true
            log("QI", questID, title, level)
        end
        local objs = objectives(index, questID)
        -- (by the counts, not the words: the text can change its form after logging in - "Troll Charm: 0/8"
        -- then "0/8 Troll Charm" - which isn't progress)
        local function key(o)
            local have, need = o.have, o.need
            if not have then have, need = o.text:match("(%d+)%s*/%s*(%d+)") end
            if have then return have .. "/" .. (need or "") .. ":" .. o.done end
            return o.text .. o.done
        end
        local snapParts = {}
        for j, o in ipairs(objs) do snapParts[j] = key(o) end
        local done = (C_QuestLog and C_QuestLog.IsComplete and C_QuestLog.IsComplete(questID))
            or isComplete == 1 or isComplete == true
        local snap = table.concat(snapParts, "^") .. "#" .. tostring(done and true or false)
        local old = questSnap[questID]
        if old and old ~= snap then
            local oldParts = { strsplit("^", (old:gsub("#.*$", ""))) }
            for j, o in ipairs(objs) do
                if oldParts[j] ~= key(o) then
                    log("O", questID, j, o.text, o.done)
                end
            end
            if snap:sub(-5) == "#true" and old:sub(-5) ~= "#true" then
                log("QDONE", questID, title)
            end
        end
        questSnap[questID] = snap
    end)
    for id in pairs(questSnap) do
        if not present[id] then questSnap[id] = nil end
    end
end

local scanPending = false
local function queueScan()
    if scanPending then return end
    scanPending = true
    C_Timer.After(1, function() scanPending = false; scanQuestLog() end) -- at most once per second
end

---------------------------------------------------------------- run management
local function charKey()
    return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
end

-- the character a run belongs to: its GUID (3.1), or for older runs the GUID of its last login (3.0 logged it)
local function runGuid(r)
    if r.guid then return r.guid end
    for i = #r.entries, 1, -1 do
        local e = r.entries[i]
        if e:find(SEP .. "LOGIN" .. SEP, 1, true) then
            local parts = { strsplit(SEP, e) }
            return parts[13] ~= "" and parts[13] or nil
        end
    end
end

local function startRun(fresh)
    LevelRouteLoggerDB = LevelRouteLoggerDB or { version = 1, runs = {} }
    local key = charKey()
    local runs = LevelRouteLoggerDB.runs
    runs[key] = runs[key] or {}
    local list = runs[key]
    -- a character made again under the same name (or another one) gets a run of its own
    local guid = UnitGUID and UnitGUID("player") or nil
    if not fresh and #list > 0 and guid then
        local was = runGuid(list[#list])
        if was and was ~= guid then fresh = true end
    end
    if fresh or #list == 0 then
        local _, race = UnitRace("player")
        local _, class = UnitClass("player")
        list[#list + 1] = {
            started = time(), char = key, race = race, class = class,
            faction = UnitFactionGroup("player"), build = (select(4, GetBuildInfo())),
            guid = guid, entries = {},
        }
    end
    run = list[#list]
    run.guid = run.guid or guid
    wipe(questSnap); wipe(questSeen)
    -- record quests already in the log without logging them as new
    iterateQuestLog(function(_, questID) questSeen[questID] = true end)
    scanQuestLog()
end

---------------------------------------------------------------- save prompt
-- Addons can't write to disk directly; SavedVariables are only written on /reload,
-- logout or a clean disconnect. So we prompt for a quick one-click /reload regularly.
local lastSave = time()
local savedCount = 0             -- entries already on disk
local saveDue = false
local snoozeUntil = 0

-- Settings (saved). Defaults are quiet: no glow, no popups, no chat message.
local DEFAULTS = { glow = false, reminder = 0, levelReminder = false, loginMessage = false }
local function settings()
    LevelRouteLoggerDB = LevelRouteLoggerDB or { version = 1, runs = {} }
    local db = LevelRouteLoggerDB
    if not db.settings then
        db.settings = {}
        -- migrate settings from older versions of this logger, if present
        if db.glowOff ~= nil then db.settings.glow = not db.glowOff end
        if db.saveInterval ~= nil and not db.promptsOff then db.settings.reminder = db.saveInterval end
        if db.levelPromptOff ~= nil and not db.promptsOff then db.settings.levelReminder = not db.levelPromptOff end
        db.glowOff, db.saveInterval, db.levelPromptOff, db.promptsOff = nil, nil, nil, nil
    end
    for k, v in pairs(DEFAULTS) do if db.settings[k] == nil then db.settings[k] = v end end
    return db.settings
end
local function saveInterval() return settings().reminder or 0 end

StaticPopupDialogs["LEVELROUTELOGGER_SAVE"] = {
    text = "|cff33ff99Level Route Logger|r\n\n%s unsaved log entries (%s min since last save).\nSave now? This does a quick /reload.",
    button1 = "Save now",
    button2 = "In 5 min",
    OnAccept = function() log("SAVE"); ReloadUI() end,
    OnCancel = function() snoozeUntil = time() + 300 end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function checkSave()
    if not run or paused then return end
    local interval = saveInterval()
    if interval > 0 and time() - lastSave >= interval * 60 then saveDue = true end
    if not saveDue or time() < snoozeUntil then return end
    if InCombatLockdown() or UnitAffectingCombat("player") then return end
    if StaticPopup_Visible("LEVELROUTELOGGER_SAVE") then return end
    local unsaved = #run.entries - savedCount
    if unsaved < 20 then return end
    StaticPopup_Show("LEVELROUTELOGGER_SAVE", tostring(unsaved), tostring(math.floor((time() - lastSave) / 60)))
end

---------------------------------------------------------------- activity glow on the XP bar
-- A thin, slowly pulsing green outline around the XP bar while recording (hidden when paused).
local XP_BARS = { "EllesmereEAB_XPBar_Bar", "MainStatusTrackingBarContainer", "MainMenuExpBar", "StatusTrackingBarManager" }
local glow

local function glowEnabled()
    return settings().glow
end

local function findXPBar()
    for _, name in ipairs(XP_BARS) do
        local fr = _G[name]
        if fr and fr.IsVisible and fr:IsVisible() and fr:GetWidth() > 0 then
            -- EllesmereUI's bar sits inside a bordered holder; outline the holder instead
            if name == "EllesmereEAB_XPBar_Bar" and fr:GetParent() and fr:GetParent():IsVisible() then
                return fr:GetParent(), name
            end
            return fr, name
        end
    end
end

local function edge(parent, size, alpha)
    local fr = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    fr:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = size })
    fr:SetBackdropBorderColor(0.3, 1, 0.5, alpha)
    fr:EnableMouse(false)
    return fr
end

-- (Re)attach the glow to whichever XP bar is currently visible. Returns true if attached.
local function attachGlow()
    local bar, name = findXPBar()
    if not bar then return glow ~= nil and glow.target ~= nil and glow.target:IsVisible() end
    if glow and glow.target == bar then return true end
    if not glow then
        glow = edge(bar, 1, 0.9)
        local outer = edge(glow, 2, 0.3)
        outer:SetPoint("TOPLEFT", glow, "TOPLEFT", -2, 2)
        outer:SetPoint("BOTTOMRIGHT", glow, "BOTTOMRIGHT", 2, -2)
        local ag = glow:CreateAnimationGroup()
        local anim = ag:CreateAnimation("Alpha")
        anim:SetFromAlpha(0.35); anim:SetToAlpha(1); anim:SetDuration(1.6); anim:SetSmoothing("IN_OUT")
        ag:SetLooping("BOUNCE")
        glow.anim = ag
    end
    glow:SetParent(bar)
    glow:ClearAllPoints()
    glow:SetPoint("TOPLEFT", bar, "TOPLEFT", -2, 2)
    glow:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 2, -2)
    glow:SetFrameStrata(bar:GetFrameStrata())
    glow:SetFrameLevel(math.min(bar:GetFrameLevel() + 50, 10000))
    glow.target, glow.targetName = bar, name
    return true
end

local function updateGlow()
    if not glowEnabled() then -- glow off: no need to look for the XP bar at all
        if glow then glow:Hide(); glow.anim:Stop() end
        return
    end
    if not attachGlow() then
        if glow then glow:Hide() end
        return
    end
    local on = run ~= nil and not paused and glowEnabled()
    glow:SetShown(on)
    if on and not glow.anim:IsPlaying() then glow.anim:Play()
    elseif not on then glow.anim:Stop() end
end

---------------------------------------------------------------- events
local handlers = {}

---------------------------------------------------------------- professions
-- Rank of every profession / secondary skill (First Aid, Cooking, Fishing), language-independent
local PROF_HEADERS = { [TRADE_SKILLS or "Professions"] = true, [SECONDARY_SKILLS or "Secondary Skills"] = true,
                       ["Professions"] = true, ["Secondary Skills"] = true }
local function professionRanks()
    local ranks = {}
    if GetNumSkillLines and GetSkillLineInfo then
        local inProf = false
        for i = 1, GetNumSkillLines() do
            local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
            if isHeader then inProf = PROF_HEADERS[name] or false
            elseif inProf and name then ranks[name] = { rank or 0, maxRank or 0 } end
        end
    elseif GetProfessions and GetProfessionInfo then
        for _, idx in pairs({ GetProfessions() }) do
            local name, _, rank, maxRank = GetProfessionInfo(idx)
            if name then ranks[name] = { rank or 0, maxRank or 0 } end
        end
    end
    return ranks
end

local lastRanks
local function profSnapshot(kind)
    local ranks = professionRanks()
    local parts = {}
    for name, r in pairs(ranks) do parts[#parts + 1] = name .. ":" .. r[1] .. "/" .. r[2] end
    table.sort(parts)
    log(kind or "PROF", table.concat(parts, ","))
    lastRanks = ranks
end

-- Skill-ups: compare with the last known ranks (weapon/defense skills are ignored)
local profPending = false
local function checkProfessions()
    profPending = false
    if not lastRanks then return end
    local ranks = professionRanks()
    for name, r in pairs(ranks) do
        local old = lastRanks[name]
        if not old then
            log("SKNEW", name, r[1], r[2])            -- profession learned
        elseif r[1] ~= old[1] or r[2] ~= old[2] then
            log("SK", name, r[1], r[2], old[1])       -- skill-up (or new max rank after training)
        end
    end
    lastRanks = ranks
end

local ADDON_VERSION = "3.1"

function handlers.PLAYER_LOGIN()
    startRun(false)
    run.locale = GetLocale and GetLocale() or "?"
    run.loggerVersion = ADDON_VERSION
    lastXP, lastXPMax, lastLevel = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
    local _, race = UnitRace("player")
    local _, class = UnitClass("player")
    log("LOGIN", GetZoneText(), GetSubZoneText(), GetBindLocation and GetBindLocation() or "", race or "", class or "",
        UnitGUID and UnitGUID("player") or "")
    lastBind = GetBindLocation and GetBindLocation() or nil
    lastGroup = -1
    handlers.GROUP_ROSTER_UPDATE()
    profSnapshot("PROF")
    LevelRouteLoggerDB.paused = LevelRouteLoggerDB.paused or {}
    paused = LevelRouteLoggerDB.paused[run.char] and true or false
    if settings().loginMessage then
        print(string.format("|cff33ff99LevelRouteLogger|r %s for %s (%d entries). /lrl for settings.",
            paused and "PAUSED" or "recording", run.char, #run.entries))
    end
    savedCount, lastSave = #run.entries, time()
    updateGlow()
    C_Timer.NewTicker(BREADCRUMB_INTERVAL, function()
        checkSave()
        updateGlow()
        if paused or not run or UnitOnTaxi("player") then return end
        local m, x, y = pos()
        local dx, dy = x - lastCrumb.x, y - lastCrumb.y
        if m ~= lastCrumb.m or (dx * dx + dy * dy) > BREADCRUMB_MIN_DIST * BREADCRUMB_MIN_DIST then
            log("P")
            lastCrumb.m, lastCrumb.x, lastCrumb.y = m, x, y
        end
    end)
end

function handlers.PLAYER_LOGOUT() log("LOGOUT") end

-- Quest dialog: offered quest (works for NPCs, objects and items)
function handlers.QUEST_DETAIL()
    local name, id, kind = cacheNpc()
    log("QD", GetQuestID and GetQuestID() or "", GetTitleText(), name, id, kind,
        GetRewardXP and GetRewardXP() or "", GetRewardMoney and GetRewardMoney() or "",
        GetObjectiveText and GetObjectiveText() or "")
end

function handlers.QUEST_ACCEPTED(a, b)
    local questID = b or a
    log("A", questID, lastNpc.name, lastNpc.id, lastNpc.kind)
    queueScan()
end

function handlers.QUEST_PROGRESS() cacheNpc() end

function handlers.QUEST_COMPLETE()
    local name, id, kind = cacheNpc()
    local choices = {}
    for i = 1, (GetNumQuestChoices and GetNumQuestChoices() or 0) do
        local itemName = GetQuestItemInfo("choice", i)
        local link = GetQuestItemLink and GetQuestItemLink("choice", i)
        choices[#choices + 1] = (itemName or "?") .. ":" .. itemIdFromLink(link)
    end
    log("QC", GetQuestID and GetQuestID() or "", GetTitleText(), name, id, kind,
        GetRewardXP and GetRewardXP() or "", GetRewardMoney and GetRewardMoney() or "",
        table.concat(choices, ","))
end

function handlers.QUEST_TURNED_IN(questID, xp, money)
    log("T", questID, xp, money, lastNpc.name, lastNpc.id, lastNpc.kind)
end

function handlers.QUEST_REMOVED(questID)
    log("QR", questID)
    queueScan()
end

function handlers.QUEST_LOG_UPDATE() queueScan() end
function handlers.UNIT_QUEST_LOG_CHANGED(unit) if unit == "player" then queueScan() end end

-- Quests offered by an NPC, including ones you don't take (useful for route planning)
function handlers.GOSSIP_SHOW()
    local name, id, kind = cacheNpc()
    local avail, active = {}, {}
    if C_GossipInfo and C_GossipInfo.GetAvailableQuests then
        for _, q in ipairs(C_GossipInfo.GetAvailableQuests() or {}) do
            avail[#avail + 1] = (q.questID or "?") .. ":" .. clean(q.title) .. ":" .. (q.questLevel or "")
        end
        for _, q in ipairs(C_GossipInfo.GetActiveQuests() or {}) do
            active[#active + 1] = (q.questID or "?") .. ":" .. clean(q.title)
        end
    end
    local opts = {}
    if C_GossipInfo and C_GossipInfo.GetOptions then
        for _, o in ipairs(C_GossipInfo.GetOptions() or {}) do
            opts[#opts + 1] = (o.gossipOptionID or "?") .. ":" .. clean(o.name)
        end
    end
    log("G", name, id, kind, table.concat(avail, ","), table.concat(active, ","), table.concat(opts, ","))
end

function handlers.QUEST_GREETING()
    local name, id, kind = cacheNpc()
    local avail = {}
    for i = 1, (GetNumAvailableQuests and GetNumAvailableQuests() or 0) do
        avail[#avail + 1] = "?:" .. clean(GetAvailableTitle(i)) .. ":" .. (GetAvailableLevel and GetAvailableLevel(i) or "")
    end
    log("G", name, id, kind, table.concat(avail, ","), "", "")
end

-- weapon skills by name (as the trainer lists them), for telling a weapon master from a class trainer
local WEAPON_SKILL = {}
for _, id in ipairs({ 196, 197, 198, 199, 200, 201, 202, 227, 264, 266, 1180, 2567, 5011, 15590 }) do
    local n = spellName(id); if n and n ~= "" then WEAPON_SKILL[n] = id end
end
local function trainerKind()
    if IsTradeskillTrainer and IsTradeskillTrainer() then return "prof" end
    for i = 1, (GetNumTrainerServices and GetNumTrainerServices() or 0) do
        local name = GetTrainerServiceInfo(i)
        if name and WEAPON_SKILL[name] then return "weapon" end
    end
    return "class"
end
function handlers.TRAINER_SHOW() local n, i, k = cacheNpc(); log("TR", n, i, k, trainerKind()) end

-- a vendor visit: what you sold (items used while it's open) and repaired, and what it did to your money
local shop
function handlers.MERCHANT_SHOW()
    local n, i, k = cacheNpc()
    log("V", n, i, k)
    shop = { npc = n, money = GetMoney and GetMoney() or 0, sold = 0, repaired = 0 }
end
function handlers.MERCHANT_CLOSED()
    local v = shop
    shop = nil
    if not v then return end
    log("VC", v.npc, (GetMoney and GetMoney() or 0) - v.money, v.sold, v.repaired)
end
function handlers.UI_INFO_MESSAGE(a, b)
    local msg = type(b) == "string" and b or a -- (message type, message; old clients: just the message)
    if type(msg) == "string" and not isSecret(msg) and ERR_NEWTAXIPATH and msg == ERR_NEWTAXIPATH then
        log("FPNEW", GetSubZoneText(), lastNpc.name, lastNpc.id)
    end
end
function handlers.CONFIRM_XP_LOSS() log("SPIRIT") end
local function instance()
    local name, kind, _, _, _, _, _, id = "", "", nil, nil, nil, nil, nil, ""
    if GetInstanceInfo then name, kind, _, _, _, _, _, id = GetInstanceInfo() end
    return id or "", kind or "", name or ""
end
function handlers.PLAYER_LEAVING_WORLD() local id, kind, name = instance(); log("LW", id, kind, name) end
function handlers.PLAYER_ENTERING_WORLD(isLogin, isReload)
    local id, kind, name = instance()
    log("EW", id, kind, name, isLogin and 1 or 0, isReload and 1 or 0)
end

function handlers.LEARNED_SPELL_IN_TAB(spellID)
    log("L", spellID, spellName(spellID))
end

function handlers.TAXIMAP_OPENED()
    local n, i, k = cacheNpc()
    local current = ""
    if NumTaxiNodes then
        for node = 1, NumTaxiNodes() do
            if TaxiNodeGetType(node) == "CURRENT" then current = TaxiNodeName(node) end
        end
    end
    log("FM", n, i, k, current)
end

function handlers.CONFIRM_BINDER(location) log("BINDQ", location, lastNpc.name, lastNpc.id) end

function handlers.ZONE_CHANGED_NEW_AREA()
    local instName, instType = "", ""
    if GetInstanceInfo then instName, instType = GetInstanceInfo() end
    log("Z", GetZoneText(), GetSubZoneText(), instName, instType)
end

function handlers.PLAYER_LEVEL_UP(level)
    log("LV", level)
    profSnapshot("PROF")
    if settings().levelReminder and time() - lastSave >= 10 * 60 then
        saveDue = true; snoozeUntil = 0
    end
end

function handlers.SKILL_LINES_CHANGED()
    if profPending then return end
    profPending = true
    C_Timer.After(1, checkProfessions) -- fires often (weapon skills); check at most once a second
end

function handlers.TIME_PLAYED_MSG(total, thisLevel) log("TP", total, thisLevel) end
function handlers.PLAYER_DEAD() log("D") end
function handlers.PLAYER_UNGHOST() log("RES") end

function handlers.CHAT_MSG_SYSTEM(msg) if not isSecret(msg) then log("S", msg) end end
-- Turn the client's own (localized) "%s dies, you gain %d experience." into a pattern,
-- so mob names are read correctly on any client language.
local function fmtToPattern(fmt)
    if not fmt then return nil end
    local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%%%%d?%$?s", "(.-)"):gsub("%%%%%d?%$?d", "(%%d+)")
    return "^" .. p
end
local KILL_PATTERN = fmtToPattern(COMBATLOG_XPGAIN_FIRSTPERSON) or "^(.-) dies, you gain (%d+) experience"

function handlers.CHAT_MSG_COMBAT_XP_GAIN(msg)
    if isSecret(msg) then return end
    local mob = msg:match(KILL_PATTERN) or msg:match("^(.-) dies") or ""
    log("X", msg, mob, mobIds[mob] or "")
end

-- XP gained, as a plain number (works in every language). Level-ups are handled.
function handlers.PLAYER_XP_UPDATE(unit)
    if unit and unit ~= "player" then return end
    local xp, xpMax, level = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
    if lastXP then
        local delta = (level > lastLevel) and ((lastXPMax - lastXP) + xp) or (xp - lastXP)
        if delta > 0 then log("XD", delta, GetXPExhaustion and (GetXPExhaustion() or 0) or "") end
    end
    lastXP, lastXPMax, lastLevel = xp, xpMax, level
end

-- Group size: grouping changes kill XP and quest speed, so it must be in the log
local function groupSize()
    return (IsInGroup and IsInGroup()) and GetNumGroupMembers() or 1
end
function handlers.GROUP_ROSTER_UPDATE()
    local n = groupSize()
    if n ~= lastGroup then
        lastGroup = n
        log("GRP", n, (IsInRaid and IsInRaid()) and "raid" or (n > 1 and "party" or "solo"))
    end
end

local lootPrefix = LOOT_ITEM_SELF and LOOT_ITEM_SELF:match("^(.-)%%s") or "You receive loot:"
local pushPrefix = LOOT_ITEM_PUSHED_SELF and LOOT_ITEM_PUSHED_SELF:match("^(.-)%%s") or "You receive item:"
local createPrefix = LOOT_ITEM_CREATED_SELF and LOOT_ITEM_CREATED_SELF:match("^(.-)%%s") or "You create:"
function handlers.CHAT_MSG_LOOT(msg)
    if isSecret(msg) then return end
    if msg:find(createPrefix, 1, true) then -- crafted (bars, bandages, cooked food, ...)
        local count = msg:match("x(%d+)%.?$") or "1"
        log("CRAFT", itemIdFromLink(msg), msg:match("%[(.-)%]") or "", count)
        return
    end
    if msg:find(lootPrefix, 1, true) or msg:find(pushPrefix, 1, true) then
        local count = msg:match("x(%d+)%.?$") or "1"
        log("LOOT", itemIdFromLink(msg), msg:match("%[(.-)%]") or "", count)
    end
end

-- quest items in your bags by the spell they cast (rebuilt when the bags change), so using one is logged
-- in combat too and from wherever you use it (action bar, item button, macro)
local questItemSpell = {}
local bagsDirty = true
local function scanQuestItems()
    bagsDirty = false
    wipe(questItemSpell)
    local slots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    local itemAt = C_Container and C_Container.GetContainerItemID
    local info = GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)
    local itemSpell = GetItemSpell or (C_Item and C_Item.GetItemSpell)
    if not (slots and itemAt and info and itemSpell) then return end
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, (slots(bag) or 0) do
            local id = itemAt(bag, slot)
            if id then
                local _, _, _, _, _, classID = info(id)
                if classID == 12 then
                    local _, sid = itemSpell(id)
                    if sid then questItemSpell[sid] = id end
                end
            end
        end
    end
end
function handlers.BAG_UPDATE_DELAYED() bagsDirty = true end
-- Casts: quest items (any time), and out of combat what isn't your own spell (other items, objects you
-- open, the hearthstone) - your class spells were most of the log and say nothing about the route
function handlers.UNIT_SPELLCAST_SUCCEEDED(unit, _, spellID)
    if unit ~= "player" or not spellID then return end
    if bagsDirty then scanQuestItems() end
    local item = questItemSpell[spellID]
    if item then log("QU", item, spellID, (GetItemInfo and GetItemInfo(item)) or "") return end
    if UnitAffectingCombat("player") then return end
    if IsPlayerSpell and IsPlayerSpell(spellID) and spellID ~= 8690 then return end
    log("C", spellID, spellName(spellID))
end

-- Kills: the combat log is off-limits to addons on this client, so we remember the NPC id of
-- hostile units you target and match it to the "<mob> dies, you gain X experience" message.
function handlers.PLAYER_TARGET_CHANGED()
    if UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsPlayer("target") then
        local name, id = unitInfo("target")
        if name ~= "" and id ~= "" then mobIds[name] = id end
    end
end

-- Diagnostics: report which function the game blocked, if any
local function reportBlocked(kind, addonName, func)
    if addonName ~= ADDON then return end
    local msg = string.format("%s: %s", kind, tostring(func))
    print("|cffff5555LevelRouteLogger blocked|r " .. msg)
    LevelRouteLoggerDB = LevelRouteLoggerDB or { version = 1, runs = {} }
    LevelRouteLoggerDB.blocked = LevelRouteLoggerDB.blocked or {}
    table.insert(LevelRouteLoggerDB.blocked, date("%Y-%m-%d %H:%M:%S") .. " " .. msg)
end
function handlers.ADDON_ACTION_FORBIDDEN(addonName, func) reportBlocked("FORBIDDEN", addonName, func) end
function handlers.ADDON_ACTION_BLOCKED(addonName, func) reportBlocked("BLOCKED", addonName, func) end

-- Where loot comes from: a quest object (GameObject id) or a mob (Creature id), and what it dropped
function handlers.LOOT_OPENED()
    if not GetNumLootItems then return end
    local srcs, items = {}, {}
    for slot = 1, GetNumLootItems() do
        local link = GetLootSlotLink and GetLootSlotLink(slot)
        if link then items[#items + 1] = itemIdFromLink(link) end
        if GetLootSourceInfo then
            local guid = GetLootSourceInfo(slot)
            if guid and not isSecret(guid) then
                local k, _, _, _, _, id = strsplit("-", guid)
                if k and id then srcs[k .. ":" .. id] = true end
            end
        end
    end
    local s = {}
    for k in pairs(srcs) do s[#s + 1] = k end
    table.sort(s)
    log("LO", table.concat(s, ","), table.concat(items, ","))
end

-- Gathering: picking a herb, mining a vein or skinning names what you gather
local GATHER = {}
for _, id in ipairs({ 2366, 2368, 3570, 11993, 2575, 2576, 3564, 10248, 8613, 8617, 8618, 10768 }) do
    local n = spellName(id); if n and n ~= "" then GATHER[n] = true end
end
function handlers.UNIT_SPELLCAST_SENT(unit, target, _, spellID)
    if unit ~= "player" or not target or isSecret(target) then return end
    local sname = spellID and spellName(spellID) or ""
    if GATHER[sname] then log("GN", target, sname) end
end

-- The hearthstone set somewhere new, and where flights land
function handlers.HEARTHSTONE_BOUND()
    local b = GetBindLocation and GetBindLocation()
    if b and b ~= lastBind then log("BIND", b, lastNpc.name, lastNpc.id); lastBind = b end
end
function handlers.PLAYER_CONTROL_GAINED()
    if onTaxi and not UnitOnTaxi("player") then
        onTaxi = false
        log("LAND", GetZoneText(), GetSubZoneText())
    end
end
function handlers.PLAYER_CONTROL_LOST()
    C_Timer.After(1, function() if UnitOnTaxi("player") then onTaxi = true end end)
end

-- Unit events: only ask the game for the player's own, not every party member / nearby unit
local PLAYER_ONLY = { UNIT_SPELLCAST_SUCCEEDED = true, UNIT_QUEST_LOG_CHANGED = true, UNIT_SPELLCAST_SENT = true }
for event in pairs(handlers) do
    if PLAYER_ONLY[event] and f.RegisterUnitEvent then
        pcall(f.RegisterUnitEvent, f, event, "player")
    else
        pcall(f.RegisterEvent, f, event)   -- ignore events the client doesn't know
    end
end
f:SetScript("OnEvent", function(_, event, ...)
    local ok, err = pcall(handlers[event], ...)
    if not ok and run then
        run.errors = run.errors or {}
        if #run.errors < 200 then run.errors[#run.errors + 1] = event .. ": " .. tostring(err) end
    end
end)

-- Flights taken and items used
hooksecurefunc("TakeTaxiNode", function(node)
    pcall(function() log("FLY", TaxiNodeName(node)); onTaxi = true end)
end)
-- Gossip options you pick (route steps that need "just talk to them" or a special option)
if C_GossipInfo and C_GossipInfo.SelectOption then
    hooksecurefunc(C_GossipInfo, "SelectOption", function(optionID)
        pcall(function()
            local text = ""
            for _, o in ipairs(C_GossipInfo.GetOptions() or {}) do
                if o.gossipOptionID == optionID then text = o.name or "" end
            end
            log("GS", optionID, text, lastNpc.name, lastNpc.id)
        end)
    end)
end
-- What you buy: vendor items (food, tools, spices) and trainer skills, with what they cost
if BuyMerchantItem then
    hooksecurefunc("BuyMerchantItem", function(index, quantity)
        pcall(function()
            local link = GetMerchantItemLink and GetMerchantItemLink(index)
            local _, _, price, stack = GetMerchantItemInfo(index)
            local id = tonumber(itemIdFromLink(link))
            local classID, subID, spell = "", "", ""
            local info = GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)
            local itemSpell = GetItemSpell or (C_Item and C_Item.GetItemSpell)
            if id and info then local _, _, _, _, _, c, sc = info(id); classID, subID = c or "", sc or "" end
            if id and itemSpell then spell = itemSpell(id) or "" end
            log("BUY", itemIdFromLink(link), link and link:match("%[(.-)%]") or "", quantity or stack or 1, price or 0,
                lastNpc.name, lastNpc.id, classID, subID, spell)
        end)
    end)
end
if BuyTrainerService then
    hooksecurefunc("BuyTrainerService", function(index)
        pcall(function()
            local name, sub = GetTrainerServiceInfo(index)
            local link = GetTrainerServiceItemLink and GetTrainerServiceItemLink(index)
            log("TRB", name or "", sub or "", GetTrainerServiceCost and GetTrainerServiceCost(index) or 0,
                lastNpc.name, lastNpc.id, link and link:match("spell:(%d+)") or "")
        end)
    end)
end
local function onUseItem(bag, slot)
    if shop then shop.sold = shop.sold + 1 end -- (an item used at an open vendor is sold)
    pcall(function()
        local link = C_Container and C_Container.GetContainerItemLink and C_Container.GetContainerItemLink(bag, slot)
            or (GetContainerItemLink and GetContainerItemLink(bag, slot))
        if link then log("U", itemIdFromLink(link), link:match("%[(.-)%]") or "") end
    end)
end
if C_Container and C_Container.UseContainerItem then
    hooksecurefunc(C_Container, "UseContainerItem", onUseItem)
elseif UseContainerItem then
    hooksecurefunc("UseContainerItem", onUseItem)
end
if RepairAllItems then
    hooksecurefunc("RepairAllItems", function() if shop then shop.repaired = 1 end end)
end
-- emotes (quests that want you to /salute or /dance at someone)
if DoEmote then
    hooksecurefunc("DoEmote", function(token, target)
        pcall(function()
            local who = target
            if not who or who == "" or who == "none" then who = UnitName("target") or "" end
            log("E", token or "", who or "")
        end)
    end)
end

---------------------------------------------------------------- pause (saved per character)
local panelRefresh -- set once the settings window exists
local function setPaused(on)
    if not run then return end
    if on and not paused then log("PAUSE") end
    paused = on
    if not on then log("RESUME") end
    LevelRouteLoggerDB.paused = LevelRouteLoggerDB.paused or {}
    LevelRouteLoggerDB.paused[run.char] = on or nil
    updateGlow()
    if panelRefresh then panelRefresh() end
end

local function addNote(text)
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return false end
    log("N", text)
    return true
end

---------------------------------------------------------------- settings window (same look as EatDrink)
local function accent()
    local g = EllesmereUI and EllesmereUI.ELLESMERE_GREEN
    if g and g.r then return g.r, g.g, g.b end
    return 0.05, 0.82, 0.62
end

local function fontPath()
    if EllesmereUI and EllesmereUI.GetFontPath then
        local ok, path = pcall(EllesmereUI.GetFontPath)
        if ok and path then return path end
    end
    return STANDARD_TEXT_FONT
end

local function addEdges(frame, r, g, b, a, layer)
    local edges = {}
    local px = 1 / (frame:GetEffectiveScale() or 1)
    local function e() local t = frame:CreateTexture(nil, layer or "BORDER"); t:SetColorTexture(r, g, b, a); edges[#edges + 1] = t; return t end
    local t = e(); t:SetPoint("TOPLEFT"); t:SetPoint("TOPRIGHT"); t:SetHeight(px)
    local bt = e(); bt:SetPoint("BOTTOMLEFT"); bt:SetPoint("BOTTOMRIGHT"); bt:SetHeight(px)
    local l = e(); l:SetPoint("TOPLEFT"); l:SetPoint("BOTTOMLEFT"); l:SetWidth(px)
    local rt = e(); rt:SetPoint("TOPRIGHT"); rt:SetPoint("BOTTOMRIGHT"); rt:SetWidth(px)
    function edges:SetColor(r2, g2, b2, a2) for _, x in ipairs(self) do x:SetColorTexture(r2, g2, b2, a2) end end
    return edges
end

-- Each option: label, short description, choices { {text, value} }, get(), set(value)
local OPTIONS = {
    { label = "Recording", desc = "Pause while AFK or doing other things",
      choices = { { "Recording", false }, { "Paused", true } },
      get = function() return paused end, set = function(v) setPaused(v) end },
    { label = "XP bar glow", desc = "Thin outline while recording",
      choices = { { "On", true }, { "Off", false } },
      get = function() return settings().glow end, set = function(v) settings().glow = v; updateGlow() end },
    { label = "Save reminder", desc = "Popup offering a quick /reload to save",
      choices = { { "Off", 0 }, { "15m", 15 }, { "30m", 30 }, { "60m", 60 } },
      get = function() return settings().reminder end, set = function(v) settings().reminder = v end },
    { label = "Remind on level-up", desc = "Also offer to save after a level-up",
      choices = { { "Off", false }, { "On", true } },
      get = function() return settings().levelReminder end, set = function(v) settings().levelReminder = v end },
    { label = "Login message", desc = "One chat line when you log in",
      choices = { { "Off", false }, { "On", true } },
      get = function() return settings().loginMessage end, set = function(v) settings().loginMessage = v end },
}

local panel
local function buildPanel()
    local FONT = fontPath()
    local ar, ag, ab = accent()
    local W, PAD, ROW_H, SEG_TOTAL, SEG_H = 440, 18, 46, 200, 22
    local TEXT_W = W - PAD * 2 - SEG_TOTAL - 12

    panel = CreateFrame("Frame", "LevelRouteLoggerPanel", UIParent)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")
    panel:SetClampedToScreen(true)
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    tinsert(UISpecialFrames, "LevelRouteLoggerPanel")

    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.077, 0.068, 0.058, 0.97)
    addEdges(panel, 1, 1, 1, 0.15)
    local top = panel:CreateTexture(nil, "ARTWORK")
    top:SetColorTexture(ar, ag, ab, 0.9)
    top:SetPoint("TOPLEFT", 1, -1); top:SetPoint("TOPRIGHT", -1, -1); top:SetHeight(2)

    local function text(size, r, g, b, a)
        local fs = panel:CreateFontString(nil, "OVERLAY")
        fs:SetFont(FONT, size, "")
        fs:SetTextColor(r, g, b, a)
        fs:SetJustifyH("LEFT")
        return fs
    end
    local eyebrow = text(12, ar, ag, ab, 0.9)
    eyebrow:SetPoint("TOPLEFT", PAD, -16)
    eyebrow:SetText("LEVEL ROUTE LOGGER")
    local title = text(19, 1, 1, 1, 1)
    title:SetPoint("TOPLEFT", eyebrow, "BOTTOMLEFT", 0, -4)
    title:SetText("Settings")
    local status = text(12, 1, 1, 1, 0.45)
    status:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    status:SetWidth(W - PAD * 2)
    status:SetWordWrap(true)

    local close = CreateFrame("Button", nil, panel)
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -8, -8)
    local x = close:CreateFontString(nil, "OVERLAY")
    x:SetFont(FONT, 18, "")
    x:SetPoint("CENTER")
    x:SetText("×")
    x:SetTextColor(1, 1, 1, 0.5)
    close:SetScript("OnEnter", function() x:SetTextColor(1, 1, 1, 0.9) end)
    close:SetScript("OnLeave", function() x:SetTextColor(1, 1, 1, 0.5) end)
    close:SetScript("OnClick", function() panel:Hide() end)

    local function divider(anchor, gap)
        local d = panel:CreateTexture(nil, "ARTWORK")
        d:SetColorTexture(1, 1, 1, 0.08)
        d:SetHeight(1)
        d:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -gap)
        d:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)
        return d
    end

    local function button(parent, label, w, h)
        local b = CreateFrame("Button", nil, parent)
        b:SetSize(w, h)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        b.edges = addEdges(b, 1, 1, 1, 0.18)
        b.text = b:CreateFontString(nil, "OVERLAY")
        b.text:SetFont(FONT, 12, "")
        b.text:SetPoint("CENTER")
        b.text:SetText(label)
        function b:SetActive(on)
            if on then
                self.bg:SetColorTexture(ar, ag, ab, 0.9); self.edges:SetColor(ar, ag, ab, 1)
                self.text:SetTextColor(0.05, 0.05, 0.05, 1)
            else
                self.bg:SetColorTexture(0.075, 0.113, 0.141, 1); self.edges:SetColor(1, 1, 1, 0.18)
                self.text:SetTextColor(1, 1, 1, 0.5)
            end
            self.active = on
        end
        b:SetScript("OnEnter", function(self) if not self.active then self.text:SetTextColor(1, 1, 1, 0.85) end end)
        b:SetScript("OnLeave", function(self) if not self.active then self.text:SetTextColor(1, 1, 1, 0.5) end end)
        b:SetActive(false)
        return b
    end

    panel.rows = {}
    local prev = divider(status, 12)
    for i, opt in ipairs(OPTIONS) do
        local row = CreateFrame("Frame", nil, panel)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, i == 1 and -4 or 0)
        row:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)
        prev = row

        local lbl = row:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(FONT, 15, "")
        lbl:SetTextColor(1, 1, 1, 0.9)
        lbl:SetPoint("TOPLEFT", 0, -8)
        lbl:SetText(opt.label)
        local sub = row:CreateFontString(nil, "OVERLAY")
        sub:SetFont(FONT, 11, "")
        sub:SetTextColor(1, 1, 1, 0.38)
        sub:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -3)
        sub:SetWidth(TEXT_W)
        sub:SetJustifyH("LEFT")
        sub:SetWordWrap(false)
        sub:SetText(opt.desc)

        local segW = math.floor(SEG_TOTAL / #opt.choices)
        local segs = {}
        for c = #opt.choices, 1, -1 do -- build right to left
            local choice = opt.choices[c]
            local b = button(row, choice[1], segW + 1, SEG_H)
            if c == #opt.choices then b:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            else b:SetPoint("RIGHT", segs[c + 1], "LEFT", 1, 0) end -- 1px overlap merges edges
            b:SetScript("OnClick", function()
                opt.set(choice[2])
                panelRefresh()
            end)
            segs[c] = b
        end
        function row:Refresh()
            local cur = opt.get()
            for c, b in ipairs(segs) do b:SetActive(opt.choices[c][2] == cur) end
        end
        if i < #OPTIONS then
            local line = row:CreateTexture(nil, "ARTWORK")
            line:SetColorTexture(1, 1, 1, 0.05)
            line:SetHeight(1)
            line:SetPoint("BOTTOMLEFT"); line:SetPoint("BOTTOMRIGHT")
        end
        panel.rows[i] = row
    end

    -- note input + actions
    local noteDiv = divider(prev, 6)
    local noteLbl = text(15, 1, 1, 1, 0.9)
    noteLbl:SetPoint("TOPLEFT", noteDiv, "BOTTOMLEFT", 0, -12)
    noteLbl:SetText("Note at my position")
    local noteSub = text(11, 1, 1, 1, 0.38)
    noteSub:SetPoint("TOPLEFT", noteLbl, "BOTTOMLEFT", 0, -3)
    noteSub:SetWidth(W - PAD * 2)
    noteSub:SetText("e.g. \"elite here\", \"good grind spot\", \"skip this quest\"")

    local box = CreateFrame("EditBox", nil, panel)
    box:SetAutoFocus(false)
    box:SetFont(FONT, 13, "")
    box:SetTextColor(1, 1, 1, 0.9)
    box:SetTextInsets(8, 8, 0, 0)
    box:SetHeight(26)
    box:SetPoint("TOPLEFT", noteSub, "BOTTOMLEFT", 0, -8)
    box:SetPoint("RIGHT", panel, "RIGHT", -(PAD + 74), 0)
    box:SetMaxLetters(200)
    local boxBg = box:CreateTexture(nil, "BACKGROUND")
    boxBg:SetAllPoints()
    boxBg:SetColorTexture(0.075, 0.113, 0.141, 1)
    local boxEdges = addEdges(box, 1, 1, 1, 0.18)
    box:SetScript("OnEditFocusGained", function() boxEdges:SetColor(ar, ag, ab, 0.85) end)
    box:SetScript("OnEditFocusLost", function() boxEdges:SetColor(1, 1, 1, 0.18) end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local addBtn = button(panel, "Add", 66, 26)
    addBtn:SetPoint("LEFT", box, "RIGHT", 8, 0)
    local function submit()
        if addNote(box:GetText()) then
            box:SetText("")
            box:ClearFocus()
            addBtn.text:SetText("Saved")
            C_Timer.After(1.5, function() addBtn.text:SetText("Add") end)
            panelRefresh()
        end
    end
    addBtn:SetScript("OnClick", submit)
    box:SetScript("OnEnterPressed", submit)

    local saveBtn = button(panel, "Save now (quick /reload)", 200, 26)
    saveBtn:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -14)
    saveBtn:SetScript("OnClick", function() log("SAVE"); ReloadUI() end)
    local saveHint = text(11, 1, 1, 1, 0.3)
    saveHint:SetPoint("LEFT", saveBtn, "RIGHT", 10, 0)
    saveHint:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)
    saveHint:SetWordWrap(true)
    saveHint:SetText("Data is also saved on logout.")

    local function layout()
        local h = 16 + eyebrow:GetStringHeight() + 4 + title:GetStringHeight() + 6 + status:GetStringHeight()
            + 12 + 4 + #OPTIONS * ROW_H + 6 + 12 + noteLbl:GetStringHeight() + 3 + noteSub:GetStringHeight()
            + 8 + 26 + 14 + 26 + 18
        panel:SetSize(W, h)
    end

    panelRefresh = function()
        if not panel:IsShown() then return end
        local unsaved = run and (#run.entries - savedCount) or 0
        local mins = math.floor((time() - lastSave) / 60)
        status:SetText(string.format("%s  ·  %s  ·  %d entries, %d not saved yet (last save %d min ago)",
            run and run.char or "?", paused and "|cffff8040paused|r" or "recording",
            run and #run.entries or 0, unsaved, mins))
        for _, r in ipairs(panel.rows) do r:Refresh() end
        layout()
    end
    panel:SetScript("OnShow", panelRefresh)
    -- keep the entry counter live while open
    local acc = 0
    panel:SetScript("OnUpdate", function(_, dt)
        acc = acc + dt
        if acc > 1 then acc = 0; panelRefresh() end
    end)
end

local function togglePanel()
    if not panel then buildPanel() end
    if panel:IsShown() then panel:Hide() else panel:Show() end
end

---------------------------------------------------------------- minimap button
local function setupMinimap()
    local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
    local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not LDB or not DBIcon or DBIcon:IsRegistered("LevelRouteLogger") then return end
    LevelRouteLoggerDB.minimap = LevelRouteLoggerDB.minimap or {}
    local obj = LDB:NewDataObject("LevelRouteLogger", {
        type = "launcher",
        text = "Level Route Logger",
        icon = "Interface\\Icons\\INV_Misc_Map_01",
        OnClick = function(_, button)
            if button == "RightButton" then setPaused(not paused) else togglePanel() end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("Level Route Logger")
            tt:AddLine(paused and "|cffff8040Paused|r" or "|cff33ff99Recording|r")
            tt:AddLine("|cffffffffClick|r settings   |cffffffffRight-click|r pause/resume", 0.7, 0.7, 0.7)
        end,
    })
    DBIcon:Register("LevelRouteLogger", obj, LevelRouteLoggerDB.minimap)
end

local function toggleMinimap()
    local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not DBIcon then return end
    local mm = LevelRouteLoggerDB.minimap
    mm.hide = not mm.hide
    if mm.hide then DBIcon:Hide("LevelRouteLogger") else DBIcon:Show("LevelRouteLogger") end
    print("|cff33ff99LevelRouteLogger|r minimap button " .. (mm.hide and "hidden (/lrl minimap to show)" or "shown"))
end

---------------------------------------------------------------- slash commands
SLASH_LEVELROUTELOGGER1 = "/lrl"
SLASH_LEVELROUTELOGGER2 = "/rlog"
SlashCmdList.LEVELROUTELOGGER = function(input)
    local cmd, rest = (input or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    local p = "|cff33ff99LevelRouteLogger|r "
    if cmd == "" then
        togglePanel()
    elseif cmd == "note" or cmd == "n" or cmd == "mark" or cmd == "m" then
        if addNote(rest) then print(p .. "note saved: " .. rest) else print(p .. "usage: /lrl note <text>") end
    elseif cmd == "pause" then
        setPaused(true); print(p .. "paused")
    elseif cmd == "resume" then
        setPaused(false); print(p .. "recording")
    elseif cmd == "save" or cmd == "s" then
        log("SAVE"); ReloadUI()
    elseif cmd == "minimap" then
        toggleMinimap()
    elseif cmd == "glow" and rest == "status" then
        print(p .. "glow attached to: " .. (glow and glow.targetName or "nothing (no visible XP bar found)")
            .. ", " .. (glow and glow:IsVisible() and "visible" or "not visible"))
    elseif cmd == "new" then
        startRun(true); print(p .. "started a new run")
    elseif cmd == "status" then
        local m, x, y = pos()
        print(string.format("%s%s, %d entries (%d not saved yet), %s. Position: %d, %.2f, %.2f",
            p, run and run.char or "?", run and #run.entries or 0, run and (#run.entries - savedCount) or 0,
            paused and "PAUSED" or "recording", m, x, y))
    else
        print(p .. "/lrl = settings, /lrl note <text>, /lrl pause, /lrl resume, /lrl save, /lrl status, /lrl minimap")
    end
end

local mmFrame = CreateFrame("Frame")
mmFrame:RegisterEvent("PLAYER_LOGIN")
mmFrame:SetScript("OnEvent", function()
    local ok, err = pcall(setupMinimap)
    if not ok then print("|cff33ff99LevelRouteLogger|r minimap button failed: " .. tostring(err)) end
end)
