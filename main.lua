-- ═════════════════════════════════════════════════════════════════════════════
-- F3X Move + Rotate Tool  —  Self-Creating LocalScript
-- Place inside StarterPlayerScripts.
-- ═════════════════════════════════════════════════════════════════════════════

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")

local player    = Players.LocalPlayer
local mouse     = player:GetMouse()
local camera    = Workspace.CurrentCamera
local character = player.Character or player.CharacterAdded:Wait()

-- ─────────────────────────────────────────────────────────────────────────────
-- BUILD TOOL + YELLOW CUBE HANDLE
-- ─────────────────────────────────────────────────────────────────────────────
local tool = Instance.new("Tool")
tool.Name           = "F3X"
tool.RequiresHandle = true
tool.CanBeDropped   = false
tool.ToolTip        = "F3X — Click part to select | Drag arrows = move | R = Rotate mode"

local handle = Instance.new("Part")
handle.Name       = "Handle"
handle.Size       = Vector3.new(1, 1, 1)
handle.Color      = Color3.fromRGB(255, 215, 0)
handle.Material   = Enum.Material.SmoothPlastic
handle.CanCollide = false
handle.CastShadow = false
handle.Parent     = tool

script.Parent = tool
tool.Parent   = player.Backpack

-- ─────────────────────────────────────────────────────────────────────────────
-- CONFIG
-- ─────────────────────────────────────────────────────────────────────────────
local ARROW_LENGTH = 4
local ARROW_HEAD   = 1.2
local ARROW_RADIUS = 0.18
local ARROW_HEAD_R = 0.45
local MOVE_STEP    = 1      -- studs per step
local ROT_STEP     = 15     -- degrees per step
local PIX_PER_STEP = 10     -- pixels of drag per step

local ARC_RADIUS   = 3.5
local ARC_TUBE_R   = 0.18
local ARC_SEGMENTS = 24

local MOVE_COLORS = {
	X_POS = Color3.fromRGB(255, 60,  60),
	X_NEG = Color3.fromRGB(255, 60,  60),
	Y_POS = Color3.fromRGB( 60, 255, 60),
	Y_NEG = Color3.fromRGB( 60, 255, 60),
	Z_POS = Color3.fromRGB( 60, 120, 255),
	Z_NEG = Color3.fromRGB( 60, 120, 255),
}
local ROT_COLORS = {
	ROT_X = Color3.fromRGB(255, 60,  60),
	ROT_Y = Color3.fromRGB( 60, 255, 60),
	ROT_Z = Color3.fromRGB( 60, 120, 255),
}

-- ─────────────────────────────────────────────────────────────────────────────
-- STATE
-- ─────────────────────────────────────────────────────────────────────────────
local selectedPart   = nil

-- Constraints — only destroyed on explicit deselect, survive unequip & mode toggle
local alignPos  = nil
local alignOri  = nil
local att0      = nil   -- position att on part
local att1      = nil   -- position att on Terrain (target)
local attOri0   = nil   -- orientation att on part
local attOri1   = nil   -- orientation att on Terrain (target)

-- Desired transform — source of truth, never read back from the part
local targetPos = Vector3.new(0, 0, 0)
local targetRot = CFrame.new()  -- rotation-only (translation ignored)

local mode        = "MOVE"   -- "MOVE" | "ROTATE"
local arrowFolder = nil
local arrowHandles = {}      -- [tag] = true
local rotFolder   = nil
local rotHandles  = {}       -- [tag] = true
local highlightBox = nil

-- Drag state
local dragging      = false
local dragType      = nil   -- "MOVE" | "ROTATE"
local dragAxis      = nil   -- Vector3
local dragStart     = nil   -- Vector2 screen pos at drag begin
local dragAccum     = 0

-- ─────────────────────────────────────────────────────────────────────────────
-- HELPERS
-- ─────────────────────────────────────────────────────────────────────────────
local function isEquipped()
	return tool.Parent == character
end

-- Returns true if the mouse is currently over any F3X handle part
local function mouseIsOverHandle()
	local t = mouse.Target
	if not t then return false end
	local tag = t:GetAttribute("ArrowTag")
	return tag ~= nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- FIND UNANCHORED PART UNDER MOUSE  (deep hierarchy search)
-- Only called when the mouse is NOT over a handle.
-- ─────────────────────────────────────────────────────────────────────────────
local function getTargetPart()
	-- Exclude our own handle visuals so the raycast never hits them
	local excl = { character }
	if arrowFolder then table.insert(excl, arrowFolder) end
	if rotFolder   then table.insert(excl, rotFolder)   end

	-- Fast path via mouse.Target (already excludes nothing, but we check manually)
	local hit = mouse.Target
	if hit and not hit:IsDescendantOf(character) then
		if arrowFolder and hit:IsDescendantOf(arrowFolder) then hit = nil end
		if rotFolder   and hit:IsDescendantOf(rotFolder)   then hit = nil end
	end
	if hit and hit:IsA("BasePart") and not hit.Anchored then return hit end

	-- Raycast path
	local unitRay = camera:ScreenPointToRay(mouse.X, mouse.Y)
	local params  = RaycastParams.new()
	params.FilterType                 = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = excl

	local result = Workspace:Raycast(unitRay.Origin, unitRay.Direction * 2000, params)
	if not result or not result.Instance then return nil end
	local inst = result.Instance

	if inst:IsA("BasePart") and not inst.Anchored then return inst end

	-- Walk up ancestry
	local anc = inst.Parent
	while anc and anc ~= Workspace do
		if anc:IsA("BasePart") and not anc.Anchored then return anc end
		anc = anc.Parent
	end

	-- Walk to top-level under Workspace, then search descendants
	local top = inst
	while top.Parent and top.Parent ~= Workspace do top = top.Parent end
	for _, desc in ipairs(top:GetDescendants()) do
		if desc:IsA("BasePart") and not desc.Anchored then return desc end
	end

	return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- CONSTRAINTS
-- ─────────────────────────────────────────────────────────────────────────────
local function destroyConstraints()
	if alignPos then alignPos:Destroy(); alignPos = nil end
	if alignOri then alignOri:Destroy(); alignOri = nil end
	if att0     then att0:Destroy();     att0     = nil end
	if att1     then att1:Destroy();     att1     = nil end
	if attOri0  then attOri0:Destroy();  attOri0  = nil end
	if attOri1  then attOri1:Destroy();  attOri1  = nil end
end

local function buildConstraints(part)
	destroyConstraints()

	-- ── AlignPosition ──────────────────────────────────────────────────────
	att0        = Instance.new("Attachment")
	att0.Name   = "F3X_PosAtt0"
	att0.Parent = part

	att1               = Instance.new("Attachment")
	att1.Name          = "F3X_PosAtt1"
	att1.WorldPosition = targetPos          -- place at current target, not part pos
	att1.Parent        = Workspace.Terrain

	alignPos                 = Instance.new("AlignPosition")
	alignPos.Name            = "F3X_AlignPos"
	alignPos.Attachment0     = att0
	alignPos.Attachment1     = att1
	alignPos.MaxForce        = 1e6
	alignPos.MaxVelocity     = 60
	alignPos.Responsiveness  = 30
	alignPos.RigidityEnabled = false
	alignPos.Parent          = part

	-- ── AlignOrientation ───────────────────────────────────────────────────
	attOri0        = Instance.new("Attachment")
	attOri0.Name   = "F3X_OriAtt0"
	attOri0.Parent = part

	attOri1             = Instance.new("Attachment")
	attOri1.Name        = "F3X_OriAtt1"
	-- WorldCFrame on a Terrain attachment sets world orientation correctly
	attOri1.WorldCFrame = targetRot
	attOri1.Parent      = Workspace.Terrain

	alignOri                     = Instance.new("AlignOrientation")
	alignOri.Name                = "F3X_AlignOri"
	alignOri.Attachment0         = attOri0
	alignOri.Attachment1         = attOri1
	alignOri.MaxTorque           = 1e6
	alignOri.MaxAngularVelocity  = 10
	alignOri.Responsiveness      = 30
	alignOri.RigidityEnabled     = false
	alignOri.Parent              = part
end

-- Push targetPos into the live constraint (never resets from part position)
local function flushPosition()
	if att1 then att1.WorldPosition = targetPos end
end

-- Push targetRot into the live constraint
local function flushRotation()
	if attOri1 then attOri1.WorldCFrame = targetRot end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- MOVE ARROWS
-- ─────────────────────────────────────────────────────────────────────────────
local MOVE_AXES = {
	{ tag = "X_POS", dir = Vector3.new( 1, 0, 0) },
	{ tag = "X_NEG", dir = Vector3.new(-1, 0, 0) },
	{ tag = "Y_POS", dir = Vector3.new( 0, 1, 0) },
	{ tag = "Y_NEG", dir = Vector3.new( 0,-1, 0) },
	{ tag = "Z_POS", dir = Vector3.new( 0, 0, 1) },
	{ tag = "Z_NEG", dir = Vector3.new( 0, 0,-1) },
}
local MOVE_DIR = {}
for _, a in ipairs(MOVE_AXES) do MOVE_DIR[a.tag] = a.dir end

local function buildArrowModel(parent, origin, dir, color, tag)
	local m = Instance.new("Model")
	m.Name   = "Arrow_" .. tag
	m.Parent = parent

	local shaft = Instance.new("Part")
	shaft.Name       = "Shaft"
	shaft.Anchored   = true
	shaft.CanCollide = false
	shaft.CastShadow = false
	shaft.Size       = Vector3.new(ARROW_RADIUS*2, ARROW_RADIUS*2, ARROW_LENGTH)
	shaft.CFrame     = CFrame.new(origin + dir*(ARROW_LENGTH/2), origin + dir*ARROW_LENGTH)
	shaft.Color      = color
	shaft.Material   = Enum.Material.Neon
	shaft.Parent     = m

	local head = Instance.new("Part")
	head.Name       = "Head"
	head.Anchored   = true
	head.CanCollide = false
	head.CastShadow = false
	head.Size       = Vector3.new(ARROW_HEAD_R*2, ARROW_HEAD_R*2, ARROW_HEAD)
	head.CFrame     = CFrame.new(origin + dir*(ARROW_LENGTH+ARROW_HEAD/2), origin + dir*(ARROW_LENGTH+ARROW_HEAD))
	head.Color      = color
	head.Material   = Enum.Material.Neon
	head.Parent     = m

	local cone = Instance.new("SpecialMesh")
	cone.MeshType = Enum.MeshType.FileMesh
	cone.MeshId   = "rbxassetid://1033714"
	cone.Scale    = Vector3.new(ARROW_HEAD_R*2, ARROW_HEAD_R*2, ARROW_HEAD*2)
	cone.Parent   = head

	local hdl = Instance.new("Part")
	hdl.Name         = "DragHandle"
	hdl.Anchored     = true
	hdl.CanCollide   = false
	hdl.CastShadow   = false
	hdl.Transparency = 0.85
	hdl.Size         = Vector3.new(ARROW_HEAD_R*3, ARROW_HEAD_R*3, ARROW_LENGTH+ARROW_HEAD)
	hdl.CFrame       = CFrame.new(origin + dir*((ARROW_LENGTH+ARROW_HEAD)/2), origin + dir*(ARROW_LENGTH+ARROW_HEAD))
	hdl.Color        = color
	hdl.Parent       = m
	hdl:SetAttribute("ArrowTag",   tag)
	hdl:SetAttribute("HandleType", "MOVE")
end

local function spawnMoveArrows(part)
	if arrowFolder then arrowFolder:Destroy() end
	arrowHandles  = {}
	arrowFolder        = Instance.new("Folder")
	arrowFolder.Name   = "F3X_MoveArrows"
	arrowFolder.Parent = Workspace
	for _, ax in ipairs(MOVE_AXES) do
		buildArrowModel(arrowFolder, part.Position, ax.dir, MOVE_COLORS[ax.tag], ax.tag)
		arrowHandles[ax.tag] = true
	end
end

local function updateMoveArrows()
	if not selectedPart or not arrowFolder then return end
	local o = selectedPart.Position
	for tag in pairs(arrowHandles) do
		local dir   = MOVE_DIR[tag]
		local model = arrowFolder:FindFirstChild("Arrow_" .. tag)
		if model then
			local shaft = model:FindFirstChild("Shaft")
			local head  = model:FindFirstChild("Head")
			local hdl   = model:FindFirstChild("DragHandle")
			if shaft then shaft.CFrame = CFrame.new(o + dir*(ARROW_LENGTH/2),           o + dir*ARROW_LENGTH) end
			if head  then head.CFrame  = CFrame.new(o + dir*(ARROW_LENGTH+ARROW_HEAD/2), o + dir*(ARROW_LENGTH+ARROW_HEAD)) end
			if hdl   then hdl.CFrame   = CFrame.new(o + dir*((ARROW_LENGTH+ARROW_HEAD)/2), o + dir*(ARROW_LENGTH+ARROW_HEAD)) end
		end
	end
end

local function hideMoveArrows()
	if arrowFolder then arrowFolder:Destroy(); arrowFolder = nil end
	arrowHandles = {}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- ROTATION RING HANDLES
-- ─────────────────────────────────────────────────────────────────────────────
local ROT_AXES = {
	{ tag = "ROT_X", axis = Vector3.new(1,0,0) },
	{ tag = "ROT_Y", axis = Vector3.new(0,1,0) },
	{ tag = "ROT_Z", axis = Vector3.new(0,0,1) },
}
local ROT_AXIS_MAP = {}
for _, a in ipairs(ROT_AXES) do ROT_AXIS_MAP[a.tag] = a.axis end

local function ringBasis(axis)
	local up = axis:Cross(Vector3.new(0,1,0))
	if up.Magnitude < 0.01 then up = axis:Cross(Vector3.new(1,0,0)) end
	up = up.Unit
	return up, axis:Cross(up).Unit
end

local function buildRing(parent, center, axis, color, tag)
	local m      = Instance.new("Model")
	m.Name       = "Ring_" .. tag
	m.Parent     = parent

	local up, right = ringBasis(axis)
	local segAngle  = (2 * math.pi) / ARC_SEGMENTS

	for i = 0, ARC_SEGMENTS - 1 do
		local a0  = i * segAngle
		local a1  = a0 + segAngle
		local mid = (a0 + a1) / 2
		local p0  = center + (up*math.cos(a0)  + right*math.sin(a0))  * ARC_RADIUS
		local p1  = center + (up*math.cos(a1)  + right*math.sin(a1))  * ARC_RADIUS
		local pm  = center + (up*math.cos(mid) + right*math.sin(mid)) * ARC_RADIUS

		local seg       = Instance.new("Part")
		seg.Name        = "Seg_" .. i
		seg.Anchored    = true
		seg.CanCollide  = false
		seg.CastShadow  = false
		seg.Size        = Vector3.new(ARC_TUBE_R*2, ARC_TUBE_R*2, (p1-p0).Magnitude)
		seg.CFrame      = CFrame.new(pm, p1)
		seg.Color       = color
		seg.Material    = Enum.Material.Neon
		seg.Parent      = m
	end

	-- Invisible disc as clickable zone for the whole ring
	-- Use a hollow-looking disc by making it very thin; tag all surface-adjacent parts
	local disc       = Instance.new("Part")
	disc.Name        = "DiscHandle"
	disc.Anchored    = true
	disc.CanCollide  = false
	disc.CastShadow  = false
	disc.Transparency = 0.92
	disc.Size        = Vector3.new(ARC_RADIUS*2 + 1.5, 0.2, ARC_RADIUS*2 + 1.5)
	-- Orient flat face perpendicular to axis (Y of part = axis)
	if math.abs(axis:Dot(Vector3.new(0,1,0))) > 0.99 then
		disc.CFrame = CFrame.new(center)
	else
		local look = axis:Cross(Vector3.new(0,1,0)).Unit
		disc.CFrame = CFrame.fromMatrix(center, look, axis)
	end
	disc.Color  = color
	disc.Parent = m
	disc:SetAttribute("ArrowTag",   tag)
	disc:SetAttribute("HandleType", "ROTATE")
end

local function spawnRotHandles(part)
	if rotFolder then rotFolder:Destroy() end
	rotHandles   = {}
	rotFolder        = Instance.new("Folder")
	rotFolder.Name   = "F3X_RotHandles"
	rotFolder.Parent = Workspace
	for _, ax in ipairs(ROT_AXES) do
		buildRing(rotFolder, part.Position, ax.axis, ROT_COLORS[ax.tag], ax.tag)
		rotHandles[ax.tag] = true
	end
end

local function updateRotRings()
	if not selectedPart or not rotFolder then return end
	local center = selectedPart.Position
	for _, ax in ipairs(ROT_AXES) do
		local m = rotFolder:FindFirstChild("Ring_" .. ax.tag)
		if m then
			local axis       = ax.axis
			local up, right  = ringBasis(axis)
			local segAngle   = (2 * math.pi) / ARC_SEGMENTS
			for i = 0, ARC_SEGMENTS - 1 do
				local seg = m:FindFirstChild("Seg_" .. i)
				if seg then
					local a0  = i * segAngle
					local a1  = a0 + segAngle
					local mid = (a0 + a1) / 2
					local p0  = center + (up*math.cos(a0)  + right*math.sin(a0))  * ARC_RADIUS
					local p1  = center + (up*math.cos(a1)  + right*math.sin(a1))  * ARC_RADIUS
					local pm  = center + (up*math.cos(mid) + right*math.sin(mid)) * ARC_RADIUS
					seg.Size  = Vector3.new(ARC_TUBE_R*2, ARC_TUBE_R*2, (p1-p0).Magnitude)
					seg.CFrame = CFrame.new(pm, p1)
				end
			end
			local disc = m:FindFirstChild("DiscHandle")
			if disc then
				if math.abs(axis:Dot(Vector3.new(0,1,0))) > 0.99 then
					disc.CFrame = CFrame.new(center)
				else
					local look = axis:Cross(Vector3.new(0,1,0)).Unit
					disc.CFrame = CFrame.fromMatrix(center, look, axis)
				end
			end
		end
	end
end

local function hideRotHandles()
	if rotFolder then rotFolder:Destroy(); rotFolder = nil end
	rotHandles = {}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SHOW HANDLES FOR CURRENT MODE
-- ─────────────────────────────────────────────────────────────────────────────
local function showHandlesForMode()
	if not selectedPart or not isEquipped() then return end
	if mode == "MOVE" then
		hideRotHandles()
		spawnMoveArrows(selectedPart)
	else
		hideMoveArrows()
		spawnRotHandles(selectedPart)
	end
end

local function toggleMode()
	if not selectedPart then return end
	mode = (mode == "MOVE") and "ROTATE" or "MOVE"
	showHandlesForMode()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SELECT / DESELECT
-- Constraints are NEVER destroyed by clicking off or unequipping.
-- They are only rebuilt when the player selects a DIFFERENT part.
-- ─────────────────────────────────────────────────────────────────────────────

-- Hides all visual UI for the current selection without touching constraints.
local function hideUI()
	hideMoveArrows()
	hideRotHandles()
	if highlightBox then highlightBox:Destroy(); highlightBox = nil end
end

local function selectPart(part)
	-- If clicking the same part again, do nothing at all
	if part == selectedPart then return end

	-- Switching to a new part: destroy old constraints first, then rebuild
	hideUI()
	destroyConstraints()
	selectedPart = nil

	if not part then return end

	selectedPart = part
	-- Capture the part's current real transform as the starting target
	targetPos = part.Position
	local cf  = part.CFrame
	targetRot = CFrame.fromMatrix(Vector3.new(), cf.RightVector, cf.UpVector, -cf.LookVector)

	buildConstraints(part)   -- builds with targetPos / targetRot already set

	highlightBox                      = Instance.new("SelectionBox")
	highlightBox.Adornee              = part
	highlightBox.Color3               = Color3.fromRGB(0, 255, 128)
	highlightBox.LineThickness        = 0.06
	highlightBox.SurfaceTransparency  = 0.7
	highlightBox.SurfaceColor3        = Color3.fromRGB(0, 255, 128)
	highlightBox.Parent               = Workspace

	if isEquipped() then showHandlesForMode() end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- MOVE / ROTATE STEPS
-- ─────────────────────────────────────────────────────────────────────────────
local function doMove(dir, sign)
	targetPos = targetPos + dir * MOVE_STEP * sign
	flushPosition()
end

local function doRotate(axis, sign)
	local angle = math.rad(ROT_STEP) * sign
	targetRot   = CFrame.fromAxisAngle(axis, angle) * targetRot
	flushRotation()
	-- Position target is intentionally NOT changed — the part stays in place
	-- (AlignPosition still holds targetPos; only orientation changes)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SCREEN-SPACE DRAG PROJECTION
-- ─────────────────────────────────────────────────────────────────────────────
local function screenDeltaSign(delta2D, worldDir)
	if not selectedPart then return 0 end
	local o3  = selectedPart.Position
	local oS  = camera:WorldToViewportPoint(o3)
	local tS  = camera:WorldToViewportPoint(o3 + worldDir)
	local ax2 = Vector2.new(tS.X - oS.X, tS.Y - oS.Y)
	if ax2.Magnitude < 0.001 then return 0 end
	return delta2D:Dot(ax2.Unit)
end

local function rotDeltaSign(delta2D, rotAxis)
	-- Use a tangent vector perpendicular to the rotation axis in world space
	local up = rotAxis:Cross(Vector3.new(0, 1, 0))
	if up.Magnitude < 0.01 then up = rotAxis:Cross(Vector3.new(1, 0, 0)) end
	local tangent = rotAxis:Cross(up.Unit).Unit
	return screenDeltaSign(delta2D, tangent)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- DRAG START / STOP
-- ─────────────────────────────────────────────────────────────────────────────
local function beginDrag(htype, axis)
	dragging   = true
	dragType   = htype
	dragAxis   = axis
	dragStart  = Vector2.new(mouse.X, mouse.Y)
	dragAccum  = 0
end

local function endDrag()
	dragging   = false
	dragType   = nil
	dragAxis   = nil
	dragStart  = nil
	dragAccum  = 0
end

-- ─────────────────────────────────────────────────────────────────────────────
-- INPUT — use InputBegan for EVERYTHING drag-related.
-- tool.Activated is used ONLY for part selection (fires on click-release when
-- no handle is under the mouse).
-- ─────────────────────────────────────────────────────────────────────────────

-- Part selection: fires when the player clicks and releases without hitting a handle.
-- Clicking empty space does NOTHING — constraints are never removed this way.
tool.Activated:Connect(function()
	if mouseIsOverHandle() then return end
	local part = getTargetPart()
	if part then
		selectPart(part)   -- no-op if same part, rebuilds only if different
	end
	-- Clicking empty space: intentionally ignored — aligns stay forever
end)

-- Drag start: fires on mouse-down
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end

	if input.KeyCode == Enum.KeyCode.R and isEquipped() then
		toggleMode()
		return
	end

	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
	if not isEquipped() or not selectedPart then return end

	local t = mouse.Target
	if not t then return end
	local tag   = t:GetAttribute("ArrowTag")
	local htype = t:GetAttribute("HandleType")
	if not tag or not htype then return end

	-- Make sure the handle belongs to the current mode
	if htype == "MOVE" and mode == "MOVE" and MOVE_DIR[tag] then
		beginDrag("MOVE", MOVE_DIR[tag])
	elseif htype == "ROTATE" and mode == "ROTATE" and ROT_AXIS_MAP[tag] then
		beginDrag("ROTATE", ROT_AXIS_MAP[tag])
	end
end)

UserInputService.InputEnded:Connect(function(input, _)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		endDrag()
	end
end)

tool.Equipped:Connect(function()
	if selectedPart then showHandlesForMode() end
end)

tool.Unequipped:Connect(function()
	endDrag()
	-- Only hide the visual handles — constraints stay active permanently
	hideMoveArrows()
	hideRotHandles()
	-- Note: highlightBox intentionally kept so player can see what's selected
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- RENDER STEP
-- ─────────────────────────────────────────────────────────────────────────────
RunService.RenderStepped:Connect(function()

	-- 1. Track handles to selected part's actual physics position
	if selectedPart and isEquipped() then
		if mode == "MOVE" and arrowFolder then
			updateMoveArrows()
		elseif mode == "ROTATE" and rotFolder then
			updateRotRings()
		end
	end

	-- 2. Hover glow — move arrows
	if arrowFolder then
		local hovTag = mouse.Target and mouse.Target:GetAttribute("ArrowTag")
		for tag in pairs(arrowHandles) do
			local m = arrowFolder:FindFirstChild("Arrow_" .. tag)
			if m then
				local hov   = (tag == hovTag)
				local shaft = m:FindFirstChild("Shaft")
				local head  = m:FindFirstChild("Head")
				if shaft then local r = hov and ARROW_RADIUS*3 or ARROW_RADIUS*2; shaft.Size = Vector3.new(r, r, ARROW_LENGTH) end
				if head  then local r = hov and ARROW_HEAD_R*3 or ARROW_HEAD_R*2; head.Size  = Vector3.new(r, r, ARROW_HEAD)  end
			end
		end
	end

	-- 3. Hover glow — rotation rings
	if rotFolder then
		local hovTag = mouse.Target and mouse.Target:GetAttribute("ArrowTag")
		for _, ax in ipairs(ROT_AXES) do
			local m = rotFolder:FindFirstChild("Ring_" .. ax.tag)
			if m then
				local hov = (ax.tag == hovTag)
				for _, child in ipairs(m:GetChildren()) do
					if child:IsA("Part") and child.Name:sub(1,3) == "Seg" then
						local r = hov and ARC_TUBE_R*2.5 or ARC_TUBE_R*2
						child.Size = Vector3.new(r, r, child.Size.Z)
					end
				end
			end
		end
	end

	-- 4. Process drag
	if not dragging or not dragAxis or not dragStart or not selectedPart then return end

	local cur    = Vector2.new(mouse.X, mouse.Y)
	local delta  = cur - dragStart
	local signed = dragType == "MOVE"
		and screenDeltaSign(delta, dragAxis)
		or  rotDeltaSign(delta, dragAxis)

	dragAccum = dragAccum + signed

	if math.abs(dragAccum) >= PIX_PER_STEP then
		local steps = math.floor(math.abs(dragAccum) / PIX_PER_STEP)
		local sign  = dragAccum > 0 and 1 or -1

		for _ = 1, steps do
			if dragType == "MOVE" then
				doMove(dragAxis, sign)
			else
				doRotate(dragAxis, sign)
			end
		end

		dragAccum = dragAccum - steps * PIX_PER_STEP * sign
		dragStart = cur
	end
end)

print("[F3X] Ready — equip yellow cube | Click part = select | Drag arrows = move 1 stud | R = rotate mode | Drag rings = rotate 15° | Position & rotation persist when unequipped")
