-- Update notices, shared by our add-ons (SnapUI, SnapGuide, SnapAuction, PallyLite, HitNumbers,
-- pfQuestGuide). Each ships this same file; whichever loads first does the work and the rest
-- just register. Players with any of them tell their party, raid or guild which versions they
-- run ("SNAPV" addon messages); if someone has a newer version of one you use, you get one
-- chat line per add-on per session pointing at its GitHub page. Nothing else is sent.
-- Edit the copy in SnapUI-dev\shared and run copy-shared.js; a newer REV replaces older copies.

local REV = 1
if SnapVersions and (SnapVersions.rev or 0) >= REV then
  return
end

local V = SnapVersions or { mine = {}, told = {}, replied = {} }
SnapVersions = V
V.rev = REV
local PREFIX = "SNAPV"
local URL = "https://github.com/stokaidowg/"

-- "1.10" > "1.9": compare number by number
local function Newer(a, b)
  local pa, pb = {}, {}
  for n in string.gfind(a or "", "%d+") do table.insert(pa, tonumber(n)) end
  for n in string.gfind(b or "", "%d+") do table.insert(pb, tonumber(n)) end
  for i = 1, math.max(table.getn(pa), table.getn(pb)) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x > y end
  end
  return false
end
V.Newer = Newer

-- an add-on says it's here; its version comes from its .toc
function V.Register(name)
  local v = GetAddOnMetadata and GetAddOnMetadata(name, "Version")
  if v and v ~= "" then V.mine[name] = v end
end

local function Message()
  local parts = {}
  for name, v in pairs(V.mine) do table.insert(parts, name .. "=" .. v) end
  table.sort(parts)
  return table.concat(parts, ",")
end

local lastSent = {}
local function Send(channel)
  if not SendAddonMessage then return end
  local msg = Message()
  if msg == "" then return end
  local t = GetTime()
  if lastSent[channel] and t - lastSent[channel] < 60 then return end
  lastSent[channel] = t
  SendAddonMessage(PREFIX, msg, channel)
end

local function Heard(msg, channel, sender)
  if sender == UnitName("player") then return end
  local behind = false
  for name, v in string.gfind(msg or "", "([%w]+)=([%d%.]+)") do
    local mine = V.mine[name]
    if mine then
      if Newer(v, mine) and not V.told[name] then
        V.told[name] = true
        DEFAULT_CHAT_FRAME:AddMessage("|cff4fc3f7" .. name .. "|r " .. v .. " is out (you have " .. mine ..
          "). Get it from |cffffffff" .. URL .. name .. "/releases|r")
      elseif Newer(mine, v) then
        behind = true
      end
    end
  end
  -- they're behind on something: answer once, so they hear about it too
  if behind and not V.replied[sender] then
    V.replied[sender] = true
    lastSent[channel] = nil
    Send(channel)
  end
end

local f = V.frame or CreateFrame("Frame")
V.frame = f
f:UnregisterAllEvents()
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PARTY_MEMBERS_CHANGED")
f:RegisterEvent("RAID_ROSTER_UPDATE")
f:RegisterEvent("CHAT_MSG_ADDON")
local loggedIn = false
f:SetScript("OnEvent", function()
  if event == "CHAT_MSG_ADDON" then
    if arg1 == PREFIX then Heard(arg2, arg3, arg4) end
  elseif event == "PLAYER_ENTERING_WORLD" then
    if not loggedIn then
      loggedIn = true
      if IsInGuild and IsInGuild() then Send("GUILD") end
    end
    if GetNumRaidMembers() > 0 then Send("RAID") elseif GetNumPartyMembers() > 0 then Send("PARTY") end
  elseif event == "RAID_ROSTER_UPDATE" then
    if GetNumRaidMembers() > 0 then Send("RAID") end
  elseif event == "PARTY_MEMBERS_CHANGED" then
    if GetNumRaidMembers() == 0 and GetNumPartyMembers() > 0 then Send("PARTY") end
  end
end)
