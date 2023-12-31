--Endless TBC with improved haste proc and Paladin seal twisting
-- both seal will remains for 300ms, guess an AA must land within this window

--[[
	Copyright (C) 2006-2007 Nymbia
	Copyright (C) 2010 Hendrik "Nevcairiel" Leppkes < h.leppkes@gmail.com >

	This program is free software; you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation; either version 2 of the License, or
	(at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License along
	with this program; if not, write to the Free Software Foundation, Inc.,
	51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
]]
local Quartz3 = LibStub("AceAddon-3.0"):GetAddon("Quartz3")
local L = LibStub("AceLocale-3.0"):GetLocale("Quartz3")

local MODNAME = "Swing"
local Swing = Quartz3:NewModule(MODNAME, "AceEvent-3.0")
local Player = Quartz3:GetModule("Player")

local media = LibStub("LibSharedMedia-3.0")
local lsmlist = AceGUIWidgetLSMlists

----------------------------
-- Upvalues
local CreateFrame, GetTime, UIParent = CreateFrame, GetTime, UIParent
local UnitClass, UnitDamage, UnitAttackSpeed, UnitRangedDamage = UnitClass, UnitDamage, UnitAttackSpeed, UnitRangedDamage
local math_abs, bit_band, unpack = math.abs, bit.band, unpack
local COMBATLOG_FILTER_ME = COMBATLOG_FILTER_ME

local playerclass
local autoshotname = GetSpellInfo(75)
local slam = GetSpellInfo(1464)
local swordprocname = GetSpellInfo(12281)
local resetspells = {
	[GetSpellInfo(845)] = true, -- Cleave
	[GetSpellInfo(78)] = true, -- Heroic Strike
	[GetSpellInfo(6807)] = true, -- Maul
	[GetSpellInfo(2973)] = true, -- Raptor Strike
	[GetSpellInfo(56815)] = true, -- Rune Strike
}

local resetautoshotspells = {
	--[GetSpellInfo(19434)] = true, -- Aimed Shot
}

local swingbar, swingbar_width, swingstatusbar, remainingtext, durationtext
--Paladin twisting
local doublesealduration = 0.3 --timing with 2 seals
local GCDduration = 1.5 --default, updated via events
local twistframe
local twistsealtiming --twist between this line and AA landing
local twistcasttiming --don't cast after this or twist becomes impossible
--
local swingmode -- nil is none, 0 is meleeing, 1 is autoshooting
local starttime, duration
local slamstart

local db, getOptions

local defaults = {
	profile = {
		barcolor = {1, 1, 1},
		swingalpha = 1,
		swingheight = 4,
		swingposition = "top",
		swinggap = -4,
		
		durationtext = true,
		remainingtext = true,
		twistingseal = false, --Paladin twisting timing (default:off)
		
		x = 300,
		y = 300,
	}
}

local function OnUpdate()
	-- Endless fix: swing continue while slamming
	--if slamstart then return end
	if starttime then
		local spent = GetTime() - starttime
		remainingtext:SetFormattedText("%.1f", duration - spent)
		local perc = spent / duration
		if perc > 1 then
			return swingbar:Hide()
		else
		  swingstatusbar:SetValue(perc)
		  --update twist lines position
		  local p = (duration - doublesealduration) * swingbar_width / duration
		  twistsealtiming:SetPoint("TOPLEFT", p, 0)
		  p = (duration - doublesealduration - GCDduration) * swingbar_width / duration
		  twistcasttiming:SetPoint("TOPLEFT", p, 0)
		end
	end
end

local function OnHide()
	swingbar:SetScript("OnUpdate", nil)
end

local function OnShow()
	swingbar:SetScript("OnUpdate", OnUpdate)
end

function Swing:OnInitialize()
	self.db = Quartz3.db:RegisterNamespace(MODNAME, defaults)
	db = self.db.profile
	
	self:SetEnabledState(Quartz3:GetModuleEnabled(MODNAME))
	Quartz3:RegisterModuleOptions(MODNAME, getOptions, L["Swing"])

end

--GCD detection taken from TellMeWhen
--in TBC GCD is only given when a spell is triggering it
--see ACTIONBAR_UPDATE_COOLDOWN event where we try to capture it
local defaultSpells = {
        ROGUE = 1752, -- sinister strike
        PRIEST = 139, -- renew
        DRUID = 774, -- rejuvenation
        WARRIOR = 6673, -- battle shout
        MAGE = 168, -- frost armor
        WARLOCK = 1454, -- life tap
        PALADIN = 1152, -- purify
        SHAMAN = 324, -- lightning shield
        HUNTER = 1978, -- serpent sting
        DEATHKNIGHT = 45462 -- plague strike
}
local defaultSpell = defaultSpells[select(2, UnitClass("player"))]
local function TellMeWhen_GetGCD()
        return IsSpellKnown(defaultSpell) and select(2, GetSpellCooldown(defaultSpell)) or 1.5
end

function Swing:OnEnable()
	local _, c = UnitClass("player")
	playerclass = playerclass or c
	-- fired when autoattack is enabled/disabled.
	self:RegisterEvent("PLAYER_ENTER_COMBAT")
	self:RegisterEvent("PLAYER_LEAVE_COMBAT")
	-- fired when autoshot (or autowand) is enabled/disabled
	self:RegisterEvent("START_AUTOREPEAT_SPELL")
	self:RegisterEvent("STOP_AUTOREPEAT_SPELL")
	
	self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
	--GCD detection
	self:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN")
	--haste proc to redraw swingbar
	self:RegisterEvent("UNIT_ATTACK_SPEED")
	
	self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
	-- slam stuff
	if playerclass == "WARRIOR" then
		self:RegisterEvent("UNIT_SPELLCAST_START")
		self:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
	end
	
	self:RegisterEvent("UNIT_ATTACK")
	if not swingbar then
		swingbar = CreateFrame("Frame", "Quartz3SwingBar", UIParent)
		swingbar:SetFrameStrata("HIGH")
		swingbar:SetScript("OnShow", OnShow)
		swingbar:SetScript("OnHide", OnHide)
		swingbar:SetMovable(true)
		swingbar:RegisterForDrag("LeftButton")
		swingbar:SetClampedToScreen(true)
		
		swingstatusbar = CreateFrame("StatusBar", nil, swingbar)

		--twist frame at DIALOG strata to display above swingbar
		twistframe = CreateFrame("Frame", nil, swingbar)
		twistframe:SetFrameStrata("DIALOG")
		twistsealtiming = twistframe:CreateTexture()
		--yellow (twist window until AA lands)
		twistsealtiming:SetTexture(1, 1, 0, 1)
		twistcasttiming = twistframe:CreateTexture()
		--red (no more cast or GCD will prevent twist)
		twistcasttiming:SetTexture(1, 0, 0, 1)
		
		durationtext = swingstatusbar:CreateFontString(nil, "OVERLAY")
		remainingtext = swingstatusbar:CreateFontString(nil, "OVERLAY")
		swingbar:Hide()
	end
	self:ApplySettings()
end

function Swing:OnDisable()
	swingbar:Hide()
end

function Swing:PLAYER_ENTER_COMBAT()
	local _,_,offhandlow, offhandhigh = UnitDamage("player")
	if math_abs(offhandlow - offhandhigh) <= 0.1 or playerclass == "DRUID" then
		swingmode = 0 -- shouldn"t be dual-wielding
	end
end

function Swing:PLAYER_LEAVE_COMBAT()
	if not swingmode or swingmode == 0 then
		swingmode = nil
	end
end

function Swing:START_AUTOREPEAT_SPELL()
	swingmode = 1
end

function Swing:STOP_AUTOREPEAT_SPELL()
	if not swingmode or swingmode == 1 then
		swingmode = nil
	end
end

do
	local swordspecproc = false
	function Swing:COMBAT_LOG_EVENT_UNFILTERED(event, timestamp, combatevent, srcGUID, srcName, srcFlags, dstName, dstGUID, dstFlags, spellID, spellName)
		if swingmode ~= 0 then return end
		if combatevent == "SPELL_EXTRA_ATTACKS" and spellName == swordprocname and (bit_band(srcFlags, COMBATLOG_FILTER_ME) == COMBATLOG_FILTER_ME) then
			swordspecproc = true
		elseif (combatevent == "SWING_DAMAGE" or combatevent == "SWING_MISSED") and (bit_band(srcFlags, COMBATLOG_FILTER_ME) == COMBATLOG_FILTER_ME) then
			if swordspecproc then
				swordspecproc = false
			else
				self:MeleeSwing()
			end
		elseif (combatevent == "SWING_MISSED") and (bit_band(dstFlags, COMBATLOG_FILTER_ME) == COMBATLOG_FILTER_ME) and spellID == "PARRY" and duration then
		  duration = duration * 0.6
		  --
		  -- Detect Haste effect (see UNIT_ATTACK_SPEED)
		  -- Maybe used to add/fix timers for end of buffs (shift
		  -- twist timing to account for buffs ending before next AA)
		  --[[
		elseif (combatevent == "SPELL_AURA_APPLIED" or combatevent == "SPELL_AURA_REMOVED") and (bit_band(dstFlags, COMBATLOG_FILTER_ME) == COMBATLOG_FILTER_ME) and (spellID == 28507 or spellID == 35476 or spellID == 32182 or spellID == 2825) then
		  --Haste potion: 28507
		  --Drums of Battle: 35476
		  --Heroism: 32182
		  --Bloodlust: 2825
		  --Dragonspine Trophy: 34775
		  --Mongoose: 28093 (and more trinket)
		  --weapon effect
		  --Flurry: 16280 (shaman), 12970 (warrior), 13877 (rogue)
		  Swing:UNIT_ATTACK(nil, "player") --update duration
		  --]]
		end
	end
end

function Swing:UNIT_SPELLCAST_SUCCEEDED(event, unit, spell)
	if unit ~= "player" then return end
	if swingmode == 0 then
		if resetspells[spell] then
			self:MeleeSwing()
		elseif spell == slam and slamstart then
			--Endless fix: Wotlk doesn't reset, TBC does
			--starttime = starttime + GetTime() - slamstart
			starttime = GetTime()
			slamstart = nil
		end
	elseif swingmode == 1 then
		if spell == autoshotname then
			self:Shoot()
		end
	end
	if resetautoshotspells[spell] then
		swingmode = 1
		self:Shoot()
	end
end

function Swing:UNIT_SPELLCAST_START(event, unit, spell) 
	if unit == "player" and spell == slam then
		slamstart = GetTime()
	end
end 

function Swing:UNIT_SPELLCAST_INTERRUPTED(event, unit, spell) 
	if unit == "player" and spell == slam and slamstart then 
		slamstart = nil
	end 
end 

function Swing:UNIT_ATTACK(event, unit)
	if unit == "player" then
		if not swingmode then
			return
		elseif swingmode == 0 then
			duration = UnitAttackSpeed("player")
		else
			duration = UnitRangedDamage("player")
		end
		durationtext:SetFormattedText("%.1f", duration)
	end
end

function Swing:UNIT_ATTACK_SPEED(event, unit)
  Swing:UNIT_ATTACK(event, unit)
end

function Swing:ACTIONBAR_UPDATE_COOLDOWN()
  local newGCD = TellMeWhen_GetGCD()
  if newGCD >= 1 then --else assume it didn't change
    GCDduration = TellMeWhen_GetGCD()
  end
end

function Swing:MeleeSwing()
	duration = UnitAttackSpeed("player")
	durationtext:SetFormattedText("%.1f", duration)
	starttime = GetTime()
	swingbar:Show()
end

function Swing:Shoot()
	duration = UnitRangedDamage("player")
	durationtext:SetFormattedText("%.1f", duration)
	starttime = GetTime()
	swingbar:Show()
end

function Swing:ApplySettings()
	db = self.db.profile
	if swingbar and self:IsEnabled() then
		swingbar:ClearAllPoints()
		swingbar:SetHeight(db.swingheight)
		swingbar_width = Player.Bar:GetWidth() - 8
		swingbar:SetWidth(swingbar_width)
		swingbar:SetBackdrop({bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", tile = true, tileSize = 16})
		swingbar:SetBackdropColor(0,0,0)
		swingbar:SetAlpha(db.swingalpha)
		swingbar:SetScale(Player.db.profile.scale)

		if db.swingposition == "bottom" then
			swingbar:SetPoint("TOP", Player.Bar, "BOTTOM", 0, -1 * db.swinggap)
		elseif db.swingposition == "top" then
			swingbar:SetPoint("BOTTOM", Player.Bar, "TOP", 0, db.swinggap)
		else -- L["Free"]
			swingbar:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", db.x, db.y)
		end
		if db.twistingseal then
		  twistsealtiming:SetSize(1, db.swingheight)
		  twistcasttiming:SetSize(1, db.swingheight)
		  twistframe:SetPoint("TOPLEFT", 0, 0)
		  twistframe:SetPoint("BOTTOMRIGHT", 0, 0)
		  twistframe:Show()
		else
		  twistframe:Hide()
		end
		
		swingstatusbar:SetAllPoints(swingbar)
		swingstatusbar:SetStatusBarTexture(media:Fetch("statusbar", Player.db.profile.texture))
		swingstatusbar:GetStatusBarTexture():SetHorizTile(false)
		swingstatusbar:GetStatusBarTexture():SetVertTile(false)
		swingstatusbar:SetStatusBarColor(unpack(db.barcolor))
		swingstatusbar:SetMinMaxValues(0, 1)
		
		if db.durationtext then
			durationtext:Show()
			durationtext:ClearAllPoints()
			durationtext:SetPoint("BOTTOMLEFT", swingbar, "BOTTOMLEFT")
			durationtext:SetJustifyH("LEFT")
		else
			durationtext:Hide()
		end
		durationtext:SetFont(media:Fetch("font", Player.db.profile.font), 9)
		durationtext:SetShadowColor( 0, 0, 0, 1)
		durationtext:SetShadowOffset( 0.8, -0.8 )
		durationtext:SetTextColor(1,1,1)
		durationtext:SetNonSpaceWrap(false)
		durationtext:SetWidth(swingbar_width)
		
		if db.remainingtext then
			remainingtext:Show()
			remainingtext:ClearAllPoints()
			remainingtext:SetPoint("BOTTOMRIGHT", swingbar, "BOTTOMRIGHT")
			remainingtext:SetJustifyH("RIGHT")
		else
			remainingtext:Hide()
		end
		remainingtext:SetFont(media:Fetch("font", Player.db.profile.font), 9)
		remainingtext:SetShadowColor( 0, 0, 0, 1)
		remainingtext:SetShadowOffset( 0.8, -0.8 )
		remainingtext:SetTextColor(1,1,1)
		remainingtext:SetNonSpaceWrap(false)
		remainingtext:SetWidth(swingbar_width)
	end
end

do
	local locked = true
	local function nothing()
	end
	local function dragstart()
		swingbar:StartMoving()
	end
	local function dragstop()
		db.x = swingbar:GetLeft()
		db.y = swingbar:GetBottom()
		swingbar:StopMovingOrSizing()
	end
	
	local function setOpt(info, value)
		db[info[#info]] = value
		Swing:ApplySettings()
	end

	local function getOpt(info)
		return db[info[#info]]
	end
	
	local function getColor(info)
		return unpack(getOpt(info))
	end

	local function setColor(info, r, g, b, a)
		setOpt(info, {r, g, b, a})
	end
	
	local options
	function getOptions()
		options = options or {
		type = "group",
		name = L["Swing"],
		desc = L["Swing"],
		get = getOpt,
		set = setOpt,
		order = 600,
		args = {
			toggle = {
				type = "toggle",
				name = L["Enable"],
				desc = L["Enable"],
				get = function()
					return Quartz3:GetModuleEnabled(MODNAME)
				end,
				set = function(info, v)
					Quartz3:SetModuleEnabled(MODNAME, v)
				end,
				order = 100,
			},
			barcolor = {
				type = "color",
				name = L["Bar Color"],
				desc = L["Set the color of the swing timer bar"],
				get = getColor,
				set = setColor,
				order = 103,
			},
			swingheight = {
				type = "range",
				name = L["Height"],
				desc = L["Set the height of the swing timer bar"],
				min = 1, max = 20, step = 1,
				order = 104,
			},
			swingalpha = {
				type = "range",
				name = L["Alpha"],
				desc = L["Set the alpha of the swing timer bar"],
				min = 0.05, max = 1, bigStep = 0.05,
				isPercent = true,
				order = 105,
			},
			swingposition = {
				type = "select",
				name = L["Bar Position"],
				desc = L["Set the position of the swing timer bar"],
				values = {["top"] = L["Top"], ["bottom"] = L["Bottom"], ["free"] = L["Free"]},
				order = 106,
			},
			lock = {
				type = "toggle",
				name = L["Lock"],
				desc = L["Toggle Cast Bar lock"],
				get = function()
					return locked
				end,
				set = function(info, v)
					if v then
						swingbar.Hide = nil
						swingbar:EnableMouse(false)
						swingbar:SetScript("OnDragStart", nil)
						swingbar:SetScript("OnDragStop", nil)
						if not swingmode then
							swingbar:Hide()
						end
					else
						swingbar:Show()
						swingbar:EnableMouse(true)
						swingbar:SetScript("OnDragStart", dragstart)
						swingbar:SetScript("OnDragStop", dragstop)
						swingbar:SetAlpha(1)
						swingbar.Hide = nothing
					end
					locked = v
				end,
				hidden = function()
					return db.swingposition ~= "free"
				end,
				order = 107,
			},
			x = {
				type = "range",
				name = L["X"],
				desc = L["Set an exact X value for this bar's position."],
				min = -2560, max = 2560, bigStep = 1,
				order = 108,
				hidden = function()
					return db.swingposition ~= "free"
				end,
			},
			y = {
				type = "range",
				name = L["Y"],
				desc = L["Set an exact Y value for this bar's position."],
				min = -2560,
				max = 2560,
				order = 108,
				hidden = function()
					return db.swingposition ~= "free"
				end,
			},
			swinggap = {
				type = "range",
				name = L["Gap"],
				desc = L["Tweak the distance of the swing timer bar from the cast bar"],
				min = -35, max = 35, step = 1,
				order = 108,
			},
			durationtext = {
				type = "toggle",
				name = L["Duration Text"],
				desc = L["Toggle display of text showing your total swing time"],
				order = 109,
			},
			remainingtext = {
				type = "toggle",
				name = L["Remaining Text"],
				desc = L["Toggle display of text showing the time remaining until you can swing again"],
				order = 110,
			},
			twistingseal = {
				type = "toggle",
				name = "Twisting Seals",
				desc = "Toggle display of lines showing the timing to cast (red) and twist seal (yellow)",
				--name = L["Twisting Seals"],
				--desc = L["Toggle display of lines showing the timing to cast (red) and twist seal (yellow)"],
				order = 111,
			},
		},
	}
	return options
	end
end
