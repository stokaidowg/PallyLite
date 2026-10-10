-- PallyLite
-- A simple PallyPower: pick a blessing for each class in your group, then one
-- click (or one key) blesses the next person who is missing theirs.
-- Assignments sync with other PallyLite and PallyPower paladins in the group.

local _, PLAYER_CLASS = UnitClass("player")
if PLAYER_CLASS ~= "PALADIN" then
  return
end

PallyLite = {}
local PL = PallyLite

local pairs, ipairs, floor, getn, insert = pairs, ipairs, math.floor, table.getn, table.insert
local strfind, strsub, tonumber, tostring = string.find, string.sub, tonumber, tostring

local BLESSINGS = { "Might", "Wisdom", "Kings", "Salvation", "Light", "Sanctuary" }
local ICONS = {
  Might = "Interface\\Icons\\Spell_Holy_FistOfJustice",
  Wisdom = "Interface\\Icons\\Spell_Holy_SealOfWisdom",
  Kings = "Interface\\Icons\\Spell_Magic_MageArmor",
  Salvation = "Interface\\Icons\\Spell_Holy_SealOfSalvation",
  Light = "Interface\\Icons\\Spell_Holy_PrayerOfHealing02",
  Sanctuary = "Interface\\Icons\\Spell_Nature_LightningShield",
}

-- automatic picks, best first; blessings another paladin already gives are skipped
local PRIORITY = {
  WARRIOR = { "Might", "Kings", "Light", "Sanctuary" },
  ROGUE = { "Might", "Kings", "Salvation", "Light", "Sanctuary" },
  HUNTER = { "Might", "Kings", "Salvation", "Wisdom", "Light", "Sanctuary" },
  PALADIN = { "Wisdom", "Kings", "Might", "Salvation", "Light", "Sanctuary" },
  SHAMAN = { "Wisdom", "Kings", "Salvation", "Might", "Light", "Sanctuary" },
  DRUID = { "Wisdom", "Kings", "Salvation", "Might", "Light", "Sanctuary" },
  PRIEST = { "Wisdom", "Kings", "Salvation", "Light", "Sanctuary" },
  MAGE = { "Wisdom", "Kings", "Salvation", "Light", "Sanctuary" },
  WARLOCK = { "Wisdom", "Kings", "Salvation", "Light", "Sanctuary" },
  -- hunter and warlock pets (no Salvation: some of them tank)
  PET = { "Might", "Kings", "Light", "Sanctuary" },
}
local CLASS_ORDER = { "WARRIOR", "ROGUE", "HUNTER", "PALADIN", "SHAMAN", "DRUID", "PRIEST", "MAGE", "WARLOCK", "PET" }

-- PallyPower's wire ids (PLPWR protocol)
local PP_PREFIX = "PLPWR"
local LITE_PREFIX = "PLITE"
local PP_BLESSING = { [0] = "Wisdom", [1] = "Might", [2] = "Salvation", [3] = "Light", [4] = "Kings", [5] = "Sanctuary" }
local PP_CLASS = { [0] = "WARRIOR", [1] = "ROGUE", [2] = "PRIEST", [3] = "DRUID", [4] = "PALADIN",
  [5] = "HUNTER", [6] = "MAGE", [7] = "WARLOCK", [8] = "SHAMAN", [9] = "PET" }
local BLESSING_ID, CLASS_ID = {}, {}
for id, key in pairs(PP_BLESSING) do
  BLESSING_ID[key] = id
end
for id, class in pairs(PP_CLASS) do
  CLASS_ID[class] = id
end

local REFRESH = 60 -- re-bless when a blessing has less than this many seconds left
local UNKNOWN = 99999 -- blessing present, time left unknown
local ROW_HEIGHT = 22
local WIDTH = 160

BINDING_HEADER_PALLYLITE = "PallyLite"
BINDING_NAME_PALLYLITE_NEXT = "Bless the next person who needs it"

local C -- PallyLite_config, bound on ADDON_LOADED
local FONT
local ME = UnitName("player")

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cfff58cbaPally|cffffffffLite|r: " .. msg)
end

local function Error(msg)
  UIErrorsFrame:AddMessage(msg, 1, 0.3, 0.3, 1, 3)
end

-- "WARRIOR" -> "Warriors"
local function Plural(class)
  return strsub(class, 1, 1) .. string.lower(strsub(class, 2)) .. "s"
end

-- pets get their own row, "PET", whatever class the client gives them
local function IsPet(unit)
  return unit == "pet" or strfind(unit, "pet%d") ~= nil
end

local function UnitKind(unit)
  if IsPet(unit) then
    return "Pet", "PET"
  end
  return UnitClass(unit)
end

local function FormatTime(t)
  if t >= 60 then
    return floor(t / 60) .. "m"
  end
  return floor(t) .. "s"
end

-- [[ spellbook ]] --
-- known[key] = { name, icon, rank, greater, gicon } for every blessing we can cast
PL.known = {}

function PL:ScanSpells()
  local known = {}
  local i = 1
  while true do
    local name, rankText = GetSpellName(i, BOOKTYPE_SPELL)
    if not name then
      break
    end
    for _, key in ipairs(BLESSINGS) do
      if name == "Blessing of " .. key then
        known[key] = known[key] or {}
        known[key].name = name
        known[key].icon = GetSpellTexture(i, BOOKTYPE_SPELL)
        local _, _, rank = strfind(rankText or "", "(%d+)")
        rank = tonumber(rank) or 1
        if rank > (known[key].rank or 0) then
          known[key].rank = rank
        end
      elseif name == "Greater Blessing of " .. key then
        known[key] = known[key] or {}
        known[key].greater = name
        known[key].gicon = GetSpellTexture(i, BOOKTYPE_SPELL)
        known[key].rank = known[key].rank or 1
      end
    end
    i = i + 1
  end
  self.known = known
end

-- [[ other paladins ]] --
-- others[name] = { assign = { [class] = key }, ranks = { [key] = "rank..talent" }, lite = bool }
PL.others = {}

local function Other(name)
  if not PL.others[name] then
    PL.others[name] = { assign = {}, ranks = {} }
  end
  return PL.others[name]
end

-- blessings other paladins give this class. A PallyLite paladin whose name sorts
-- after ours picks around us instead, so we ignore those to avoid flip-flopping.
function PL:Taken(class)
  local taken = {}
  for name, o in pairs(self.others) do
    local key = o.assign[class]
    if key and not (o.lite and name > ME) then
      taken[key] = name
    end
  end
  return taken
end

-- the blessing we give a class: the user's (or raid leader's) choice, else an
-- automatic pick that nobody else covers
function PL:Assigned(class)
  local chosen = C.assign[class]
  if chosen then
    if chosen ~= "none" and self.known[chosen] then
      return chosen, self.known[chosen]
    end
    return
  end

  local taken = self:Taken(class)
  for _, key in ipairs(PRIORITY[class] or BLESSINGS) do
    if self.known[key] and not taken[key] then
      return key, self.known[key]
    end
  end
end

-- [[ sync (PallyPower's PLPWR protocol) ]] --
local function Channel()
  if GetNumRaidMembers() > 0 then
    return "RAID"
  elseif GetNumPartyMembers() > 0 then
    return "PARTY"
  end
end

local function Send(msg, prefix)
  local channel = Channel()
  if channel then
    SendAddonMessage(prefix or PP_PREFIX, msg, channel)
  end
end

-- raid leader/assistant, or party leader (same rule PallyPower uses)
local function IsLeader(name)
  if GetNumRaidMembers() > 0 then
    for i = 1, GetNumRaidMembers() do
      local rname, rank = GetRaidRosterInfo(i)
      if rname == name then
        return rank and rank >= 1
      end
    end
    return false
  end
  for i = 1, GetNumPartyMembers() do
    if UnitName("party" .. i) == name then
      return UnitIsPartyLeader("party" .. i)
    end
  end
  return false
end

-- "SELF <rank+talent per blessing>@<blessing id per class>"
function PL:SelfMessage()
  local talent = 0
  local _, _, _, _, points = GetTalentInfo(3, 1) -- Improved Blessing of Might/Wisdom
  talent = tonumber(points) or 0

  local msg = "SELF "
  for id = 0, 5 do
    local info = self.known[PP_BLESSING[id]]
    if info then
      local t = (id <= 1) and talent or 0
      msg = msg .. strsub(tostring(info.rank or 1), -1) .. t
    else
      msg = msg .. "nn"
    end
  end
  msg = msg .. "@"
  for id = 0, 9 do
    local key = PP_CLASS[id] and self:Assigned(PP_CLASS[id])
    msg = msg .. (key and BLESSING_ID[key] or "n")
  end
  return msg
end

-- announce ourselves when something changed (or when asked)
function PL:SendSelf(force)
  if not Channel() or not next(self.known) then
    return
  end
  local msg = self:SelfMessage()
  if force or msg ~= self.lastSelf then
    self.lastSelf = msg
    Send(msg)
    Send("HI", LITE_PREFIX)
  end
end

function PL:OnMessage(prefix, msg, sender)
  if sender == ME then
    return
  end

  if prefix == LITE_PREFIX then
    Other(sender).lite = true
    self.dirty = true
    return
  end

  if msg == "REQ" then
    self:SendSelf(true)
  elseif strfind(msg, "^SELF") then
    local _, _, numbers, assign = strfind(msg, "^SELF ([0-9n]*)@?([0-9n]*)")
    local o = Other(sender)
    o.assign, o.ranks = {}, {}
    numbers = numbers or ""
    for id = 0, 5 do
      local rank = strsub(numbers, id * 2 + 1, id * 2 + 1)
      if rank ~= "" and rank ~= "n" then
        o.ranks[PP_BLESSING[id]] = rank
      end
    end
    for id = 0, 9 do
      local b = tonumber(strsub(assign or "", id + 1, id + 1))
      if PP_CLASS[id] and b and PP_BLESSING[b] then
        o.assign[PP_CLASS[id]] = PP_BLESSING[b]
      end
    end
    self.dirty = true
  elseif strfind(msg, "^ASSIGN ") then
    local _, _, name, class, skill = strfind(msg, "^ASSIGN (%S+) (%S+) (%S+)")
    class, skill = tonumber(class), tonumber(skill)
    if not name or not class or not skill or not PP_CLASS[class] then
      return
    end
    if name ~= sender and not IsLeader(sender) then
      return
    end
    local key = PP_BLESSING[skill]
    if name == ME then
      C.assign[PP_CLASS[class]] = key or "none"
      Print(sender .. " assigned you " .. (key and ("Blessing of " .. key) or "nothing") .. " on " .. Plural(PP_CLASS[class]) .. ".")
    else
      Other(name).assign[PP_CLASS[class]] = key
    end
    self.dirty = true
  elseif strfind(msg, "^MASSIGN ") then
    local _, _, name, skill = strfind(msg, "^MASSIGN (%S+) (%S+)")
    skill = tonumber(skill)
    if not name or not skill or (name ~= sender and not IsLeader(sender)) then
      return
    end
    local key = PP_BLESSING[skill]
    for _, class in pairs(PP_CLASS) do
      if name == ME then
        C.assign[class] = key or "none"
      else
        Other(name).assign[class] = key
      end
    end
    if name == ME then
      Print(sender .. " assigned you " .. (key and ("Blessing of " .. key) or "nothing") .. " on every class.")
    end
    self.dirty = true
  elseif strfind(msg, "^CLEAR") then
    -- a leader clears everyone's assignments; anyone else only their own
    for name, o in pairs(self.others) do
      if name == sender or IsLeader(sender) then
        o.assign = {}
      end
    end
    if IsLeader(sender) then
      for _, class in ipairs(CLASS_ORDER) do
        C.assign[class] = "none"
      end
      Print(sender .. " cleared all blessing assignments.")
    end
    self.dirty = true
  end
end

-- forget paladins who left the group
function PL:PruneOthers()
  local present = {}
  for _, unit in ipairs(self:GroupUnits()) do
    if UnitExists(unit) then
      present[UnitName(unit) or ""] = true
    end
  end
  for name in pairs(self.others) do
    if not present[name] then
      self.others[name] = nil
    end
  end
end

-- [[ blessing timers ]] --
-- 1.12 can't tell how long a buff has left on anyone else, so we time the blessings
-- we cast ourselves (nampower's SPELL_GO_SELF) and give a little warning before they fade.
-- mine[name][key] = { expires = time, warned = bool, gone = bool }
local mine = {}
local DURATION, GREATER_DURATION = 300, 900
local WARN_SOUND = "MapPing"

local function NormGuid(guid)
  if type(guid) ~= "string" then
    return nil
  end
  guid = string.gsub(string.gsub(string.upper(guid), "^0X", ""), "^0+", "")
  if guid == "" then
    return nil
  end
  return guid
end

local function SpellNameById(id)
  if GetSpellRecField then
    local ok, name = pcall(GetSpellRecField, id, "name")
    if ok and type(name) == "string" then
      return name
    end
  end
  if SpellInfo then
    local ok, name = pcall(SpellInfo, id)
    if ok and type(name) == "string" then
      return name
    end
  end
end

-- the group unit with this guid (no guid = a self cast)
local function GuidUnit(guid)
  guid = NormGuid(guid)
  if not guid then
    return "player"
  end
  if not UnitGUID then
    return nil
  end
  local units = PL:GroupUnits()
  insert(units, "player")
  for _, unit in ipairs(units) do
    if UnitExists(unit) and NormGuid(UnitGUID(unit)) == guid then
      return unit
    end
  end
end

function PL:Track(spellId, targetGuid)
  local spell = spellId and SpellNameById(spellId)
  if not spell then
    return
  end
  local _, _, key = strfind(spell, "^Greater Blessing of (%a+)")
  local greater = key ~= nil
  if not key then
    _, _, key = strfind(spell, "^Blessing of (%a+)")
  end
  local unit = key and ICONS[key] and GuidUnit(targetGuid)
  if not unit then
    return
  end

  local duration = greater and GREATER_DURATION or DURATION
  if GetSpellDuration then
    local ok, ms = pcall(GetSpellDuration, spellId)
    if ok and tonumber(ms) and tonumber(ms) > 0 then
      duration = tonumber(ms) / 1000
    end
  end

  -- a Greater Blessing lands on everyone of the target's class
  local targets = { unit }
  if greater then
    local _, class = UnitKind(unit)
    targets = {}
    for _, u in ipairs(self:GroupUnits()) do
      local _, c = UnitKind(u)
      if UnitExists(u) and c == class and UnitIsVisible(u) and not UnitIsDeadOrGhost(u) then
        insert(targets, u)
      end
    end
  end

  local expires = GetTime() + duration
  for _, u in ipairs(targets) do
    local name = UnitName(u)
    if name then
      mine[name] = mine[name] or {}
      mine[name][key] = { expires = expires }
    end
  end
  self.dirty = true
end

local function TrackedLeft(unit, key)
  local t = mine[UnitName(unit) or ""]
  t = t and t[key]
  if t then
    local left = t.expires - GetTime()
    return left > 0 and left or 0
  end
end

-- the blessing is no longer on them: right at the end it faded (warn), earlier it
-- was dispelled or overwritten (forget it quietly)
local function Lost(name, key)
  local t = mine[name or ""]
  t = t and t[key]
  if t then
    if t.expires - GetTime() < 10 then
      t.gone = true
    else
      mine[name][key] = nil
    end
  end
end

local function Warn(msg)
  UIErrorsFrame:AddMessage(msg, 1, 0.82, 0, 1, 4)
  PlaySound(WARN_SOUND)
end

local function NameList(names)
  local n = getn(names)
  if n > 4 then
    return names[1] .. ", " .. names[2] .. ", " .. names[3] .. " and " .. (n - 3) .. " more"
  end
  return table.concat(names, ", ")
end

function PL:CheckWarnings()
  local warn = C.warn or 30
  local present = {}
  for _, unit in ipairs(self:GroupUnits()) do
    if UnitExists(unit) then
      present[UnitName(unit) or ""] = unit
    end
  end
  present[ME] = present[ME] or "player"

  local now = GetTime()
  local soon, faded = {}, {}
  local function Add(list, key, name)
    list[key] = list[key] or {}
    insert(list[key], name == ME and "you" or name)
  end
  for name, keys in pairs(mine) do
    local unit = present[name]
    for key, t in pairs(keys) do
      local left = t.expires - now
      if not unit or UnitIsDeadOrGhost(unit) or not UnitIsConnected(unit) then
        keys[key] = nil
      elseif t.gone or left <= 0 then
        keys[key] = nil
        Add(faded, key, name)
      elseif left <= warn and not t.warned then
        t.warned = true
        Add(soon, key, name)
      end
    end
    if not next(keys) then
      mine[name] = nil
    end
  end

  if warn <= 0 then
    return
  end
  for key, names in pairs(soon) do
    Warn("Blessing of " .. key .. " fades in " .. FormatTime(warn) .. ": " .. NameList(names))
  end
  for key, names in pairs(faded) do
    Warn("Blessing of " .. key .. " faded: " .. NameList(names))
  end
end

-- [[ group scan ]] --
-- Returns the seconds left on any version of the blessing (UNKNOWN if the
-- client can't tell), or nil when the unit doesn't have it.
local function Remaining(unit, key, info)
  local names = { "Blessing of " .. key, "Greater Blessing of " .. key }

  if C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName then
    local best
    for _, name in ipairs(names) do
      local aura = C_UnitAuras.GetAuraDataBySpellName(unit, name, "HELPFUL")
      if aura then
        local left = UNKNOWN
        if aura.expirationTime and aura.expirationTime > 0 then
          left = aura.expirationTime - GetTime()
        end
        if not best or left > best then
          best = left
        end
      end
    end
    if best == UNKNOWN then
      return TrackedLeft(unit, key) or UNKNOWN
    end
    return best
  end

  -- plain 1.12: match buff icons against the blessing's icons
  for i = 1, 32 do
    local texture = UnitBuff(unit, i)
    if not texture then
      break
    end
    if texture == info.icon or texture == info.gicon then
      return TrackedLeft(unit, key) or UNKNOWN
    end
  end
end

local function InRange(spell, unit)
  if not UnitIsVisible(unit) then
    return false
  end
  local check = (C_Spell and C_Spell.IsSpellInRange) or IsSpellInRange
  if check then
    local ok, result = pcall(check, spell, unit)
    if ok and result ~= nil then
      return result == 1 or result == true
    end
  end
  return unit == "player" or CheckInteractDistance(unit, 4)
end

-- everyone in the group, then their pets
function PL:GroupUnits()
  local units = {}
  if GetNumRaidMembers() > 0 then
    for i = 1, 40 do
      insert(units, "raid" .. i)
    end
    for i = 1, 40 do
      insert(units, "raidpet" .. i)
    end
  else
    insert(units, "player")
    for i = 1, 4 do
      insert(units, "party" .. i)
    end
    insert(units, "pet")
    for i = 1, 4 do
      insert(units, "partypet" .. i)
    end
  end
  return units
end

-- rows[class] = { class, label, key, info, total, missing, soonest, members = { {unit, name, left, state} } }
function PL:Scan()
  local rows = {}
  for _, unit in ipairs(self:GroupUnits()) do
    if UnitExists(unit) then
      local label, class = UnitKind(unit)
      local row = rows[class]
      if not row then
        local key, info = self:Assigned(class)
        row = { class = class, label = label, key = key, info = info, total = 0, missing = 0, members = {} }
        rows[class] = row
      end

      local member = { unit = unit, name = UnitName(unit) }
      row.total = row.total + 1
      if not IsPet(unit) and not UnitIsConnected(unit) then
        member.state = "offline"
      elseif UnitIsDeadOrGhost(unit) then
        member.state = "dead"
      elseif row.key then
        member.left = Remaining(unit, row.key, row.info)
        if not member.left then
          Lost(member.name, row.key)
          row.missing = row.missing + 1
        elseif member.left ~= UNKNOWN and (not row.soonest or member.left < row.soonest) then
          row.soonest = member.left
        end
      end
      insert(row.members, member)
    end
  end
  self.rows = rows
end

-- [[ casting ]] --
function PL:Cast(spell, unit)
  if SetAutoloot then
    -- SuperWoW: cast straight on the unit, leaving your target alone
    CastSpellByName(spell, unit)
  else
    local hadTarget = UnitExists("target")
    TargetUnit(unit)
    CastSpellByName(spell)
    if hadTarget then
      TargetLastTarget()
    else
      ClearTarget()
    end
  end
end

-- who to bless next in a row: missing first, then the one running out soonest.
-- force: anyone alive and in range counts, even with plenty of time left (a manual refresh)
local function NextMember(row, spell, force)
  local best, bestLeft
  for _, m in ipairs(row.members) do
    if not m.state and (force or not m.left or m.left < REFRESH) and InRange(spell, m.unit) then
      local left = m.left or -1
      if not best or left < bestLeft then
        best, bestLeft = m, left
      end
    end
  end
  return best
end

-- returns true if a blessing was cast
function PL:BlessRow(class, single, quiet, force)
  self:Scan()
  local row = self.rows[class]
  if not row or not row.key then
    return
  end

  local info = row.info
  local spell = info.name or info.greater
  -- Greater Blessings don't work on pets
  if class == "PET" then
    if not info.name then
      return
    end
    single = true
  end
  -- Greater Blessings cover the whole class but cost a reagent: only use them for 2+ people
  if info.greater and not single and (row.total > 1 or not info.name) then
    spell = info.greater
  end

  local member = NextMember(row, spell, force)
  if not member then
    if not quiet then
      if force then
        Error("No " .. row.label .. " is in range")
      else
        Error(row.missing > 0 and ("No " .. row.label .. " missing " .. row.key .. " is in range")
          or ("Every " .. row.label .. " has " .. row.key .. " (Shift-click to refresh anyway)"))
      end
    end
    return
  end

  self:Cast(spell, member.unit)
  self.dirty = true
  return true
end

-- keybinding / "/plite next": the first class (in panel order) that needs a blessing
function PL:BlessNext()
  self:Scan()
  for _, class in ipairs(CLASS_ORDER) do
    local row = self.rows[class]
    if row and row.key and self:BlessRow(class, nil, true) then
      return
    end
  end
  Error("Everyone in range is blessed")
end

-- right-click / wheel: auto -> each known blessing -> none -> auto
function PL:CycleAssignment(class, step)
  local options = { "auto" }
  for _, key in ipairs(BLESSINGS) do
    if self.known[key] then
      insert(options, key)
    end
  end
  insert(options, "none")

  local current = C.assign[class] or "auto"
  local index = 1
  for i, key in ipairs(options) do
    if key == current then
      index = i
    end
  end
  index = index + step
  if index > getn(options) then
    index = 1
  elseif index < 1 then
    index = getn(options)
  end

  local choice = options[index]
  C.assign[class] = choice ~= "auto" and choice or nil

  -- tell PallyPower users about the new assignment
  local key = self:Assigned(class)
  Send("ASSIGN " .. ME .. " " .. CLASS_ID[class] .. " " .. (key and BLESSING_ID[key] or -1))
  self:Update()
end

-- [[ panel ]] --
local function Backdrop(frame)
  if pfUI and pfUI.api and pfUI.api.CreateBackdrop and not pfUI.api.emulated then
    pfUI.api.CreateBackdrop(frame, nil, true, 0.85)
  else
    frame:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.85)
    frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
  end
end

local function RowTooltip()
  local row = PL.rows and PL.rows[this.class]
  if not row then
    return
  end
  GameTooltip:SetOwner(this, "ANCHOR_LEFT")
  local how = C.assign[row.class] and "" or " |cff888888(auto)"
  GameTooltip:SetText(row.label .. ": " .. (row.key and ("Blessing of " .. row.key) or "no blessing") .. how)

  for _, m in ipairs(row.members) do
    local status, r, g, b
    if m.state then
      status, r, g, b = m.state, 0.5, 0.5, 0.5
    elseif not row.key then
      status, r, g, b = "", 1, 1, 1
    elseif not m.left then
      status, r, g, b = "missing", 1, 0.3, 0.3
    elseif m.left == UNKNOWN then
      status, r, g, b = "blessed", 0.3, 1, 0.3
    else
      status = FormatTime(m.left)
      if m.left < REFRESH then
        r, g, b = 1, 0.8, 0.2
      else
        r, g, b = 0.3, 1, 0.3
      end
    end
    GameTooltip:AddDoubleLine(m.name or "?", status, 1, 1, 1, r, g, b)
  end

  local header
  for name, o in pairs(PL.others) do
    local key = o.assign[row.class]
    if key then
      if not header then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Other paladins", 0.96, 0.55, 0.73)
        header = true
      end
      local clash = key == row.key and "  |cffff5050(same as you)" or ""
      GameTooltip:AddDoubleLine(name .. (o.lite and "" or " |cff888888(PallyPower)"), key .. clash, 1, 1, 1, 1, 1, 1)
    end
  end

  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("|cfff58cbaClick|r bless the next one who needs it", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("|cfff58cbaShift-click|r refresh it even if it's already on", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("|cfff58cbaCtrl-click|r use the single blessing, not Greater", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("|cfff58cbaRight-click / wheel|r change the blessing", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("|cfff58cbaDrag|r move", 0.8, 0.8, 0.8)
  GameTooltip:Show()
end

local function SavePosition()
  local point, _, relpoint, x, y = PL.frame:GetPoint()
  C.pos = { point, relpoint, x, y }
end

local rows = {}

local function GetRow(i)
  if not rows[i] then
    local b = CreateFrame("Button", nil, PL.frame)
    b:SetHeight(ROW_HEIGHT)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:EnableMouseWheel(true)
    Backdrop(b)

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetWidth(ROW_HEIGHT - 4)
    b.icon:SetHeight(ROW_HEIGHT - 4)
    b.icon:SetPoint("LEFT", 2, 0)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    b.text = b:CreateFontString(nil, "OVERLAY")
    b.text:SetFont(FONT, 11, "OUTLINE")
    b.text:SetPoint("LEFT", b.icon, "RIGHT", 4, 0)
    b.text:SetJustifyH("LEFT")

    b.time = b:CreateFontString(nil, "OVERLAY")
    b.time:SetFont(FONT, 11, "OUTLINE")
    b.time:SetPoint("RIGHT", -4, 0)
    b.time:SetJustifyH("RIGHT")

    -- small icons for blessings other paladins give this class
    b.others = {}
    for j = 1, 3 do
      local t = b:CreateTexture(nil, "ARTWORK")
      t:SetWidth(11)
      t:SetHeight(11)
      t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      b.others[j] = t
    end

    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetTexture(1, 1, 1, 0.15)
    b.hl:SetAllPoints()

    b:SetScript("OnClick", function()
      if arg1 == "RightButton" then
        PL:CycleAssignment(this.class, 1)
      else
        PL:BlessRow(this.class, IsControlKeyDown(), nil, IsShiftKeyDown())
      end
    end)
    b:SetScript("OnMouseWheel", function()
      PL:CycleAssignment(this.class, arg1 > 0 and -1 or 1)
    end)
    b:SetScript("OnEnter", RowTooltip)
    b:SetScript("OnLeave", function()
      GameTooltip:Hide()
    end)
    b:SetScript("OnDragStart", function()
      PL.frame:StartMoving()
    end)
    b:SetScript("OnDragStop", function()
      PL.frame:StopMovingOrSizing()
      SavePosition()
    end)
    rows[i] = b
  end
  return rows[i]
end

function PL:Update()
  self:Scan()
  self:SendSelf()
  local n = 0
  local anyKnown = next(self.known) ~= nil

  for _, class in ipairs(CLASS_ORDER) do
    local row = self.rows[class]
    if row then
      n = n + 1
      local b = GetRow(n)
      b.class = class
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -(n - 1) * (ROW_HEIGHT + 2))
      b:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", 0, -(n - 1) * (ROW_HEIGHT + 2))

      local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
      local hex = color and format("|cff%02x%02x%02x", floor(color.r * 255), floor(color.g * 255), floor(color.b * 255)) or "|cffffffff"

      if row.key then
        local blessed = row.total - row.missing
        b.icon:SetTexture((row.total > 1 and class ~= "PET" and row.info.gicon) or row.info.icon or row.info.gicon)
        b.icon:SetVertexColor(1, 1, 1)
        local countColor = row.missing > 0 and "|cffff5050" or "|cff50ff50"
        b.text:SetText(hex .. row.label .. "|r " .. countColor .. blessed .. "/" .. row.total)
        if row.soonest then
          b.time:SetText((row.soonest < REFRESH and "|cffffcc33" or "|cffaaaaaa") .. FormatTime(row.soonest))
        else
          b.time:SetText("")
        end
      else
        b.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        b.icon:SetVertexColor(0.4, 0.4, 0.4)
        b.text:SetText(hex .. row.label .. "|r |cff888888-")
        b.time:SetText("")
      end

      -- other paladins' blessings for this class, right of the text
      local j = 0
      for _, o in pairs(self.others) do
        local key = o.assign[class]
        if key and j < 3 then
          j = j + 1
          local t = b.others[j]
          t:SetTexture(ICONS[key])
          t:ClearAllPoints()
          t:SetPoint("RIGHT", b, "RIGHT", -30 - (j - 1) * 12, 0)
          t:Show()
        end
      end
      for k = j + 1, 3 do
        b.others[k]:Hide()
      end

      b:Show()
    end
  end

  for i = n + 1, getn(rows) do
    rows[i]:Hide()
  end

  if n > 0 and anyKnown and C.shown ~= false then
    self.frame:SetHeight(n * (ROW_HEIGHT + 2) - 2)
    self.frame:Show()
  else
    self.frame:Hide()
  end
end

function PL:CreatePanel()
  local f = CreateFrame("Frame", "PallyLiteFrame", UIParent)
  self.frame = f
  f:SetWidth(WIDTH)
  f:SetHeight(ROW_HEIGHT)
  f:SetMovable(true)
  f:SetClampedToScreen(true)
  f:SetFrameStrata("MEDIUM")
  if C.pos then
    f:SetPoint(C.pos[1], UIParent, C.pos[2], C.pos[3], C.pos[4])
  else
    f:SetPoint("LEFT", UIParent, "CENTER", 250, 0)
  end
  f:Hide()
end

-- [[ events ]] --
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PARTY_MEMBERS_CHANGED")
events:RegisterEvent("RAID_ROSTER_UPDATE")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("LEARNED_SPELL_IN_TAB")
events:RegisterEvent("UNIT_AURA")
events:RegisterEvent("CHAT_MSG_ADDON")
-- nampower: our own casts, for the blessing timers
pcall(events.RegisterEvent, events, "SPELL_GO_SELF")
for _, cvar in ipairs({ "NP_EnableSpellStartEvents", "NP_EnableSpellGoEvents" }) do
  pcall(SetCVar, cvar, "1")
end
events:SetScript("OnEvent", function()
  if event == "ADDON_LOADED" then
    if arg1 ~= "PallyLite" then
      return
    end
    PallyLite_config = PallyLite_config or {}
    C = PallyLite_config
    C.assign = C.assign or {}
    FONT = pfUI and pfUI.font_default or STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
    PL:CreatePanel()
  end
  if not C then
    return
  end
  ME = UnitName("player")

  if event == "SPELL_GO_SELF" then
    -- itemId, spellId, casterGuid, targetGuid
    PL:Track(arg2, arg4)
    return
  end

  if event == "CHAT_MSG_ADDON" then
    if (arg1 == PP_PREFIX or arg1 == LITE_PREFIX) and (arg3 == "PARTY" or arg3 == "RAID") then
      PL:OnMessage(arg1, arg2, arg4)
    end
    return
  end

  if event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_TAB" or event == "PLAYER_ENTERING_WORLD" then
    PL.spellsDirty = true
  end

  if event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
    PL:PruneOthers()
    -- just joined a group (or logged in to one): ask the other paladins for their assignments
    local grouped = Channel() ~= nil
    if grouped and not PL.grouped then
      PL.syncPending = true
    end
    PL.grouped = grouped
    PL.lastSelf = nil -- re-announce to whoever just joined
  end

  PL.dirty = true
end)

events:SetScript("OnUpdate", function()
  if not C then
    return
  end
  local now = GetTime()
  -- refresh on changes, and every second anyway for the timers
  if (this.tick or 0) > now and not (PL.dirty and (this.fast or 0) < now) then
    return
  end
  this.tick = now + 1
  this.fast = now + 0.2
  if PL.spellsDirty then
    PL.spellsDirty = nil
    PL:ScanSpells()
  end
  if PL.syncPending and next(PL.known) then
    PL.syncPending = nil
    Send("REQ")
  end
  PL.dirty = nil
  PL:Update()
  PL:CheckWarnings()
end)

-- [[ slash command ]] --
SLASH_PALLYLITE1 = "/plite"
SLASH_PALLYLITE2 = "/pallylite"
SlashCmdList["PALLYLITE"] = function(msg)
  msg = string.lower(msg or "")
  local _, _, warn = strfind(msg, "^warn%s*(%w*)$")
  if warn then
    if warn == "off" or warn == "0" then
      C.warn = 0
      Print("Blessing warnings are off.")
    elseif tonumber(warn) then
      C.warn = tonumber(warn)
      Print("You'll be warned " .. C.warn .. "s before your blessings fade.")
    else
      Print("Blessing warnings: " .. ((C.warn or 30) > 0 and ((C.warn or 30) .. "s before they fade") or "off")
        .. ". /plite warn <seconds> or /plite warn off")
    end
  elseif msg == "next" then
    PL:BlessNext()
  elseif msg == "reset" then
    C.assign = {}
    PL:Update()
    Print("Every class is back to automatic blessings.")
  elseif msg == "sync" then
    Send("REQ")
    PL:SendSelf(true)
    Print(Channel() and "Asked the other paladins for their assignments." or "You're not in a group.")
  elseif msg == "help" then
    Print("/plite - show or hide the bar")
    Print("/plite next - bless the next person who needs it (same as the keybinding)")
    Print("/plite sync - re-sync assignments with the other paladins")
    Print("/plite reset - set every class back to automatic")
    Print("/plite warn <seconds|off> - warning before your blessings fade (default 30s)")
  else
    C.shown = C.shown == false
    PL:Update()
  end
end

-- update notices (version.lua)
if SnapVersions then SnapVersions.Register("PallyLite") end
