--// delivery.lua
--// Client-sided Roblox auto delivery script (Wayfort / DE-style delivery job)
--//
--// KEY INSIGHT:
--//   The delivery Ring (workspace.DeliveryLocationEffects) is STREAMED OUT when the
--//   target is far away, so its CFrame cannot be read from range. The actual target
--//   position lives in the always-loaded client delivery state
--//   (DeliveryJobTask.GetCurrentDeliveryState().PickupPosition / drop position).
--//
--// FLOW:
--//   1. Read the current target Vector3 from the delivery state (persistent).
--//   2. Sky-teleport directly above that XZ to STREAM the area in (sets RootPart
--//      CFrame directly = IY "Goto", not distance-limited).
--//   3. Wait for the Ring to stream in, then drop onto it.
--//   4. Invoke the real RemoteFunctions (AttemptDeliveryPickup /
--//      AttemptDeliveryComplete) to do the pickup / drop-off.
--//   5. Loop until the delivery is finished, then take the next job.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer

-- cloneref support (thcloneref / cloneref); falls back to identity.
local cloneref = (type(thcloneref) == "function" and thcloneref)
	or (type(cloneref) == "function" and cloneref)
	or function(...) return ... end

local RS = cloneref(ReplicatedStorage)
local Remotes = RS:WaitForChild("Remotes")

-- Persistent client modules (always loaded, never streamed out).
local DeliveryJobTask = require(RS.Modules.Client.Jobs.Tasks.DeliveryJobTask)
local DeliveryUtil = require(RS.Modules.Shared.Jobs.Delivery.DeliveryUtil)

local SKY_HEIGHT = 200       -- studs above target to teleport for streaming
local STREAM_TIMEOUT = 8     -- seconds to wait for the Ring to stream in

--========================================================================--
-- Character / teleport helpers
--========================================================================--
LocalPlayer.Idled:Connect(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
end)

local function getRoot()
	local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum and hum.RootPart then
		return hum.RootPart
	end
	return char:WaitForChild("HumanoidRootPart", 5)
end

-- Direct CFrame set = IY "Goto" method (not subject to the 1.1km limit).
local function setRootCFrame(cf)
	local root = getRoot()
	if not root then return end
	root.CFrame = cf
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
end

--========================================================================--
-- Noclip (lets the character pass through roofs / walls over a pickup point)
--========================================================================--

local noclipConn = nil

local function setNoclip(on)
	if on then
		if noclipConn then return end
		noclipConn = RunService.Stepped:Connect(function()
			local char = LocalPlayer.Character
			if not char then return end
			for _, part in ipairs(char:GetDescendants()) do
				if part:IsA("BasePart") and part.CanCollide then
					part.CanCollide = false
				end
			end
		end)
	else
		if noclipConn then
			noclipConn:Disconnect()
			noclipConn = nil
		end
	end
end

-- Raycast down to find the floor Y at an XZ position (only valid once streamed).
-- Ignores the character AND the DeliveryLocationEffects (Ring/RingGlow) so the
-- ray lands on real ground, not on the effect meshes.
local function findGroundY(position)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {
		LocalPlayer.Character,
		Workspace:FindFirstChild("DeliveryLocationEffects"),
	}
	-- Start just ABOVE the target's own Y, so a roof higher up is not picked
	-- as the "floor". Cast down to find the surface the boxes sit on.
	local origin = Vector3.new(position.X, position.Y + 10, position.Z)
	local result = Workspace:Raycast(origin, Vector3.new(0, -1500, 0), params)
	return result and result.Position.Y or nil
end

-- Wait until the delivery Ring has streamed into the workspace, return its CFrame.
local function waitForRing(timeout)
	local start = os.clock()
	while os.clock() - start < (timeout or STREAM_TIMEOUT) do
		local effects = Workspace:FindFirstChild("DeliveryLocationEffects")
		if effects then
			local ring = effects:FindFirstChild("Ring")
			if ring and ring:IsA("BasePart") then
				return ring.CFrame
			end
		end
		task.wait(0.1)
	end
	return nil
end

-- Wait until the Humanoid is actually standing on the ground (not falling).
local function waitUntilGrounded(timeout)
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then return end
	local start = os.clock()
	while os.clock() - start < (timeout or 3) do
		local state = hum:GetState()
		local root = hum.RootPart
		local stable = root and math.abs(root.AssemblyLinearVelocity.Y) < 2
		if (state == Enum.HumanoidStateType.Running
			or state == Enum.HumanoidStateType.RunningNoPhysics
			or state == Enum.HumanoidStateType.Landed)
			and stable then
			return
		end
		RunService.Heartbeat:Wait()
	end
end

-- Resolve the best landing XZ for the target (prefer the streamed Ring).
local function resolveLandXZ(targetPos)
	local ringCF = waitForRing(STREAM_TIMEOUT)
	return ringCF and ringCF.Position or targetPos
end

-- Place the character ON the floor at an XZ position. Returns true if grounded.
-- Never leaves the character floating: if the raycast misses we still drop the
-- character so gravity lands it, and we do NOT anchor.
local function dropOntoGround(landPos)
	local groundY = findGroundY(landPos)
	if groundY then
		-- Place exactly on the floor.
		setRootCFrame(CFrame.new(landPos.X, groundY + 3, landPos.Z))
	else
		-- Unknown floor: place slightly above the target and let gravity settle.
		setRootCFrame(CFrame.new(landPos.X, landPos.Y + 5, landPos.Z))
	end
	waitUntilGrounded(3)
	return true
end

-- Teleport TO a known world position, even if it's currently streamed out:
--   1. Sky-teleport above the XZ to force the area to stream in.
--   2. Wait for the Ring to appear.
--   3. Noclip ON briefly to pass through any roof/cover above the point.
--   4. Noclip OFF and SETTLE the character solidly on the floor, so the server
--      registers us as physically inside the highlighted collection zone
--      (collection fails if we are noclipped / not touching the ground).
local function teleportToPosition(targetPos)
	-- Step 1: sky teleport to stream the area.
	setRootCFrame(CFrame.new(targetPos.X, targetPos.Y + SKY_HEIGHT, targetPos.Z))
	task.wait(0.6)

	-- Step 2: find the streamed location.
	local landPos = resolveLandXZ(targetPos)
	local groundY = findGroundY(landPos)
	local floorY = groundY and (groundY + 3) or (landPos.Y + 3)

	-- Step 3: noclip ON, move down through any roof to just above the floor.
	setNoclip(true)
	setRootCFrame(CFrame.new(landPos.X, floorY + 1, landPos.Z))
	task.wait(0.15)

	-- Step 4: noclip OFF so the character is solid again, then let it settle
	-- onto the floor inside the zone (this is what the server checks).
	setNoclip(false)
	setRootCFrame(CFrame.new(landPos.X, floorY, landPos.Z))
	waitUntilGrounded(3)
	return landPos
end

--========================================================================--
-- Delivery state helpers
--========================================================================--

local function getState()
	local ok, state = pcall(DeliveryJobTask.GetCurrentDeliveryState)
	if ok and type(state) == "table" then
		return state
	end
	return nil
end

local function hasActiveDelivery()
	local ok, active = pcall(DeliveryJobTask.HasActiveDelivery)
	return ok and active == true
end

local function isDeliveryDriver()
	local team = LocalPlayer.Team
	return team ~= nil and team.Name == "Delivery Driver"
end

-- Pull the current target Vector3 out of the state, handling both the pickup
-- phase and the drop-off phase (field name varies, so check several).
local function getTargetPosition(state)
	if not state then return nil end
	if state.ItemsCarried and state.ItemsCarried > 0 then
		-- We are carrying packages => heading to the drop-off destination.
		return state.DestinationPosition
	end
	-- Otherwise we still need to pick up.
	return state.PickupPosition
end

local function carrying(state)
	return state and state.ItemsCarried and state.ItemsCarried > 0
end

-- How many packages we currently carry (0 if unknown).
local function itemsCarried(state)
	return (state and state.ItemsCarried) or 0
end

-- Target number of packages to collect at a pickup (defaults to 4).
local function maxCapacity(state)
	return (state and state.MaxCapacity) or 4
end

-- Whether the game still allows collecting more packages at this pickup.
local function canCollectMore(state)
	if not state then return false end
	local ok, result = pcall(DeliveryUtil.CanCollectMoreAtPickup, state)
	if ok then
		return result == true
	end
	-- Fallback: collect until we hit MaxCapacity.
	return itemsCarried(state) < maxCapacity(state)
end

-- Re-snap the character onto the ground at an XZ position WITHOUT anchoring,
-- so it stays inside the collection radius but can still touch the floor.
-- Only re-snaps if it has drifted away (avoids constant jitter).
local function holdOnGround(landPos)
	local root = getRoot()
	if not root or not root.Parent then return end
	local pos = root.Position
	local flatDist = (Vector2.new(pos.X, pos.Z) - Vector2.new(landPos.X, landPos.Z)).Magnitude
	-- Only re-snap if we have drifted out of the zone. Re-snapping keeps the
	-- character SOLID (no noclip) so collection still registers.
	if flatDist > 6 then
		local groundY = findGroundY(landPos)
		local y = groundY and (groundY + 3) or pos.Y
		root.CFrame = CFrame.new(landPos.X, y, landPos.Z)
		root.AssemblyLinearVelocity = Vector3.zero
	end
end

--========================================================================--
-- Step 1: Ensure we are on the Delivery Driver team / have a job.
--========================================================================--

if not isDeliveryDriver() or not hasActiveDelivery() then
	Remotes.RequestStartJobSession:FireServer("Delivery", "jobPad")
	local timeout = os.clock() + 20
	while not isDeliveryDriver() and os.clock() < timeout do
		task.wait(0.3)
	end
end

--========================================================================--
-- Step 2: Main delivery loop.
--========================================================================--

while isDeliveryDriver() do
	local state = getState()

	-- If there's no active delivery, request a fresh job session.
	if not state or not hasActiveDelivery() then
		Remotes.RequestStartJobSession:FireServer("Delivery", "jobPad")
		task.wait(1.5)
	else
		local targetPos = getTargetPosition(state)
		if typeof(targetPos) == "Vector3" then
			local wasCarrying = carrying(state)

			-- Stream-in + teleport onto the GROUND at the target location.
			local landPos = teleportToPosition(targetPos)

			-- Use the game's own client function (confirmed to work with no args).
			-- It handles both pickup and drop-off via the proper RemoteFunctions.
			local tries = 0
			repeat
				-- Keep ourselves on the ground inside the radius (no anchoring,
				-- so the character can still physically touch / collect).
				holdOnGround(landPos)

				pcall(DeliveryJobTask.InteractWithDeliveryLocation)
				task.wait(0.3)
				state = getState() or state
				tries = tries + 1

				local phaseChanged
				if wasCarrying then
					-- Drop-off: done when we are no longer carrying / delivery ended.
					phaseChanged = (not carrying(state)) or (not hasActiveDelivery())
				else
					-- Pickup: done only once we can't collect any more here
					-- (all packages collected / at MaxCapacity), NOT after box 1.
					phaseChanged = not canCollectMore(state)
				end
			until phaseChanged or tries > 40 or not hasActiveDelivery()

			task.wait(0.5)
		else
			-- No usable target position yet; wait for state to update.
			task.wait(0.5)
		end
	end
end
