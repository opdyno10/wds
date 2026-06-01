-- DeliveryAutoFarm.client.lua
-- Put this LocalScript in StarterPlayerScripts, or run it from your own in-game AFK/autofarm toggle.
-- To stop it from another script: thisScript:SetAttribute("Running", false)
-- If this is pasted into a runtime where `script` is nil, stop it with: _G.DeliveryAutoFarm.Running = false

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer

local CONFIG = {
	TeamName = "Delivery Driver",
	JobName = "Delivery",
	JobPadName = "jobPad",

	EffectsFolderName = "DeliveryLocationEffects",
	RingName = "Ring",
	LocationInstanceName = "DeliveryLocation",
	PickupItemsFolderName = "DeliveryPickupItems_DeliveryLocation",

	TeleportYOffset = 4,
	TeleportRetryCount = 5,
	TeleportRetryDelay = 0.12,
	TeleportArriveTolerance = 25,

	PollDelay = 0.2,
	JobRequestRetryDelay = 3,
	InteractDelay = 0.35,
	LocationInstanceWaitTime = 8,
	LocationInstanceMaxDistance = 260,
	BoxSpawnGraceTime = 2,
	TargetChangeTimeout = 8,
	StateCFrameFreshTime = 120,

	PreferStateCFrameOverRing = true,
	RequireStateCFrameAfterStuds = 1100,

	FireDeliveryCompletedOnDropoff = true,
	DeliveryCompletedAttempts = 3,
	DeliveryCompletedRetryDelay = 0.25,
}

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local requestStartJobSession = remotes:WaitForChild("RequestStartJobSession")
local deliveryLocationInteracted = remotes:WaitForChild("DeliveryLocationInteracted")
local deliveryCompleted = remotes:FindFirstChild("DeliveryCompleted")

local deliveryStateChanged = remotes:FindFirstChild("DeliveryStateChanged")
	or remotes:FindFirstChild("deliveryStateChanged")
	or ReplicatedStorage:FindFirstChild("DeliveryStateChanged")
	or ReplicatedStorage:FindFirstChild("deliveryStateChanged")

local lastStateCFrame = nil
local lastStateCFrameAt = 0
local scriptRef = typeof(script) == "Instance" and script or nil
local runtimeState = type(_G.DeliveryAutoFarm) == "table" and _G.DeliveryAutoFarm or {}
runtimeState.Running = runtimeState.Running ~= false
_G.DeliveryAutoFarm = runtimeState

local function toCFrame(value)
	local valueType = typeof(value)

	if valueType == "CFrame" then
		return value
	elseif valueType == "Vector3" then
		return CFrame.new(value)
	elseif valueType == "Instance" then
		if value:IsA("BasePart") then
			return value.CFrame
		elseif value:IsA("Attachment") then
			return value.WorldCFrame
		elseif value:IsA("Model") then
			return value:GetPivot()
		elseif value:IsA("CFrameValue") then
			return value.Value
		elseif value:IsA("Vector3Value") then
			return CFrame.new(value.Value)
		end
	elseif valueType == "table" then
		local x = value.X or value.x
		local y = value.Y or value.y
		local z = value.Z or value.z

		if type(x) == "number" and type(y) == "number" and type(z) == "number" then
			return CFrame.new(x, y, z)
		end

		return toCFrame(value.CFrame)
			or toCFrame(value.cframe)
			or toCFrame(value.TargetCFrame)
			or toCFrame(value.targetCFrame)
			or toCFrame(value.LocationCFrame)
			or toCFrame(value.locationCFrame)
			or toCFrame(value.DropoffCFrame)
			or toCFrame(value.dropoffCFrame)
			or toCFrame(value.DestinationCFrame)
			or toCFrame(value.destinationCFrame)
			or toCFrame(value.Position)
			or toCFrame(value.position)
			or toCFrame(value.TargetPosition)
			or toCFrame(value.targetPosition)
			or toCFrame(value.DropoffPosition)
			or toCFrame(value.dropoffPosition)
			or toCFrame(value.DestinationPosition)
			or toCFrame(value.destinationPosition)
	end

	return nil
end

local function findCFrameDeep(value, depth, seen)
	depth = depth or 0
	if depth > 8 then
		return nil
	end

	local ok, cframe = pcall(toCFrame, value)
	if ok and cframe then
		return cframe
	end

	if typeof(value) ~= "table" then
		return nil
	end

	seen = seen or {}
	if seen[value] then
		return nil
	end
	seen[value] = true

	for key, childValue in pairs(value) do
		cframe = findCFrameDeep(childValue, depth + 1, seen) or findCFrameDeep(key, depth + 1, seen)
		if cframe then
			return cframe
		end
	end

	return nil
end

local function rememberStateCFrameFromArgs(...)
	for index = 1, select("#", ...) do
		local cframe = findCFrameDeep(select(index, ...))
		if cframe then
			lastStateCFrame = cframe
			lastStateCFrameAt = os.clock()
			return true
		end
	end

	return false
end

if deliveryStateChanged then
	if deliveryStateChanged:IsA("RemoteEvent") then
		deliveryStateChanged.OnClientEvent:Connect(rememberStateCFrameFromArgs)
	elseif deliveryStateChanged:IsA("BindableEvent") then
		deliveryStateChanged.Event:Connect(rememberStateCFrameFromArgs)
	end
end

if scriptRef and scriptRef:GetAttribute("Running") == nil then
	scriptRef:SetAttribute("Running", true)
end

local function isRunning()
	if scriptRef then
		return scriptRef:GetAttribute("Running") ~= false
	end

	return runtimeState.Running ~= false
end

local function isDeliveryDriver()
	return localPlayer.Team and localPlayer.Team.Name == CONFIG.TeamName
end

local function ensureDeliveryJob()
	local lastRequest = 0

	while isRunning() and not isDeliveryDriver() do
		local now = os.clock()

		if now - lastRequest >= CONFIG.JobRequestRetryDelay then
			requestStartJobSession:FireServer(CONFIG.JobName, CONFIG.JobPadName)
			lastRequest = now
		end

		task.wait(CONFIG.PollDelay)
	end

	return isDeliveryDriver()
end

local function getCharacterRoot()
	local character = localPlayer.Character or localPlayer.CharacterAdded:Wait()
	local root = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 10)

	return character, root
end

local function normalizeCharacter(character, root)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if humanoid then
		humanoid.Sit = false
		humanoid.PlatformStand = false
		humanoid.AutoRotate = true

		pcall(function()
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)
	end

	if character then
		for _, descendant in ipairs(character:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Anchored = false
				descendant.AssemblyLinearVelocity = Vector3.zero
				descendant.AssemblyAngularVelocity = Vector3.zero
			end
		end
	elseif root then
		root.Anchored = false
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end

	return humanoid
end

local function cframeFromRingInstance(ring)
	if not ring then
		return nil
	end

	local cframe = toCFrame(ring)
	if cframe then
		return cframe
	end

	for _, descendant in ipairs(ring:GetDescendants()) do
		cframe = toCFrame(descendant)
		if cframe then
			return cframe
		end
	end

	return nil
end

local function getRootPosition()
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	return root and root.Position or nil
end

local function isFreshStateCFrame()
	return lastStateCFrame ~= nil and os.clock() - lastStateCFrameAt <= CONFIG.StateCFrameFreshTime
end

local function cframesClose(first, second)
	if not first or not second then
		return false
	end

	return (first.Position - second.Position).Magnitude <= 6
end

local function clearStateCFrameIfSame(cframe)
	if cframesClose(lastStateCFrame, cframe) then
		lastStateCFrame = nil
		lastStateCFrameAt = 0
	end
end

local function findCurrentRing()
	local effectsFolder = Workspace:FindFirstChild(CONFIG.EffectsFolderName)
	if not effectsFolder then
		return nil
	end

	local directRing = effectsFolder:FindFirstChild(CONFIG.RingName)
	if directRing then
		return directRing
	end

	for _, descendant in ipairs(effectsFolder:GetDescendants()) do
		if descendant.Name == CONFIG.RingName then
			return descendant
		end
	end

	return nil
end

local function addCandidate(candidates, seen, instance)
	if instance and not seen[instance] then
		seen[instance] = true
		table.insert(candidates, instance)
	end
end

local function collectDeliveryLocationCandidates()
	local candidates = {}
	local seen = {}
	local ring = findCurrentRing()
	local effectsFolder = Workspace:FindFirstChild(CONFIG.EffectsFolderName)

	if ring then
		local current = ring
		while current and current ~= Workspace do
			if current.Name == CONFIG.LocationInstanceName then
				addCandidate(candidates, seen, current)
			end

			current = current.Parent
		end
	end

	if effectsFolder then
		local direct = effectsFolder:FindFirstChild(CONFIG.LocationInstanceName)
		addCandidate(candidates, seen, direct)

		for _, descendant in ipairs(effectsFolder:GetDescendants()) do
			if descendant.Name == CONFIG.LocationInstanceName then
				addCandidate(candidates, seen, descendant)
			end
		end
	end

	for _, descendant in ipairs(Workspace:GetDescendants()) do
		if descendant.Name == CONFIG.LocationInstanceName then
			addCandidate(candidates, seen, descendant)
		end
	end

	return candidates
end

local function distanceFromCFrame(instance, cframe)
	local instanceCFrame = cframeFromRingInstance(instance)

	if not instanceCFrame or not cframe then
		return nil
	end

	return (instanceCFrame.Position - cframe.Position).Magnitude
end

local function findDeliveryLocationInstance(targetCFrame)
	local candidates = collectDeliveryLocationCandidates()
	local bestCandidate = nil
	local bestDistance = math.huge
	local fallbackCandidate = nil

	for _, candidate in ipairs(candidates) do
		if candidate.Parent then
			fallbackCandidate = fallbackCandidate or candidate

			local distance = distanceFromCFrame(candidate, targetCFrame)
			if distance and distance < bestDistance then
				bestCandidate = candidate
				bestDistance = distance
			end
		end
	end

	if bestCandidate then
		if bestDistance <= CONFIG.LocationInstanceMaxDistance then
			return bestCandidate
		end

		return nil
	end

	return fallbackCandidate
end

local function waitForDeliveryLocationInstance(targetCFrame)
	local startedAt = os.clock()

	while isRunning() and os.clock() - startedAt <= CONFIG.LocationInstanceWaitTime do
		local locationInstance = findDeliveryLocationInstance(targetCFrame)
		if locationInstance then
			return locationInstance
		end

		task.wait(CONFIG.PollDelay)
	end

	return findDeliveryLocationInstance(targetCFrame)
end

local function readCurrentTargetCFrame()
	local freshStateCFrame = isFreshStateCFrame() and lastStateCFrame or nil

	if freshStateCFrame and CONFIG.PreferStateCFrameOverRing then
		return freshStateCFrame
	end

	local ring = findCurrentRing()
	local ringCFrame = cframeFromRingInstance(ring)
	local rootPosition = getRootPosition()

	if freshStateCFrame and ringCFrame and rootPosition then
		local ringDistance = (ringCFrame.Position - rootPosition).Magnitude

		if ringDistance >= CONFIG.RequireStateCFrameAfterStuds then
			return freshStateCFrame
		end
	end

	return ringCFrame or freshStateCFrame
end

local function waitForCurrentTargetCFrame()
	while isRunning() do
		local cframe = readCurrentTargetCFrame()

		if cframe then
			return cframe
		end

		task.wait(CONFIG.PollDelay)
	end

	return nil
end

local function setCharacterCFrame(goalCFrame)
	local character, root = getCharacterRoot()
	if not character or not root then
		return false
	end

	normalizeCharacter(character, root)

	pcall(function()
		character:PivotTo(goalCFrame)
	end)

	pcall(function()
		root.CFrame = goalCFrame
		root.Anchored = false
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end)

	normalizeCharacter(character, root)

	return true
end

local function moveCharacterTo(targetCFrame)
	local target = targetCFrame + Vector3.new(0, CONFIG.TeleportYOffset, 0)

	for _ = 1, CONFIG.TeleportRetryCount do
		if not isRunning() then
			return false
		end

		if not setCharacterCFrame(target) then
			return false
		end

		task.wait(CONFIG.TeleportRetryDelay)

		local _, root = getCharacterRoot()
		if root and (root.Position - target.Position).Magnitude <= CONFIG.TeleportArriveTolerance then
			return true
		end
	end

	return false
end

local function fireRemote(remote, ...)
	if not remote then
		return false
	end

	local args = table.pack(...)

	if remote:IsA("RemoteEvent") then
		remote:FireServer(table.unpack(args, 1, args.n))
		return true
	elseif remote:IsA("RemoteFunction") then
		task.spawn(function()
			pcall(function()
				remote:InvokeServer(table.unpack(args, 1, args.n))
			end)
		end)
		return true
	end

	return false
end

local function attemptDeliveryCompleted()
	if not CONFIG.FireDeliveryCompletedOnDropoff then
		return
	end

	for _ = 1, CONFIG.DeliveryCompletedAttempts do
		if not isRunning() then
			return
		end

		fireRemote(deliveryCompleted)
		task.wait(CONFIG.DeliveryCompletedRetryDelay)
	end
end

local function fireDeliveryLocationInteracted(locationInstance)
	if locationInstance then
		deliveryLocationInteracted:FireServer(locationInstance)
	else
		deliveryLocationInteracted:FireServer()
	end
end

local function getPickupItemsFolder()
	return Workspace:FindFirstChild(CONFIG.PickupItemsFolderName)
end

local function anyPickupItemsStillExist()
	local folder = getPickupItemsFolder()
	if not folder then
		return false
	end

	for _, item in ipairs(folder:GetChildren()) do
		if item.Parent == folder then
			return true
		end
	end

	return false
end

local function waitForPickupItemsDeleted()
	local startedAt = os.clock()
	local sawItems = anyPickupItemsStillExist()

	while isRunning() do
		local itemsExist = anyPickupItemsStillExist()

		if itemsExist then
			sawItems = true
		elseif sawItems then
			return true
		elseif os.clock() - startedAt >= CONFIG.BoxSpawnGraceTime then
			return true
		end

		task.wait(CONFIG.PollDelay)
	end

	return false
end

local function sameSpot(first, second)
	return cframesClose(first, second)
end

local function waitForTargetChange(previousCFrame)
	local startedAt = os.clock()

	while isRunning() and os.clock() - startedAt < CONFIG.TargetChangeTimeout do
		local currentCFrame = readCurrentTargetCFrame()

		if currentCFrame and not sameSpot(currentCFrame, previousCFrame) then
			return true
		end

		task.wait(CONFIG.PollDelay)
	end

	return false
end

local function interactAtCurrentTarget(isDropoff)
	local targetCFrame = waitForCurrentTargetCFrame()
	if not targetCFrame then
		return nil
	end

	if not moveCharacterTo(targetCFrame) then
		return nil
	end

	task.wait(CONFIG.InteractDelay)
	local locationInstance = waitForDeliveryLocationInstance(targetCFrame)

	clearStateCFrameIfSame(targetCFrame)

	fireDeliveryLocationInteracted(locationInstance)

	if isDropoff then
		attemptDeliveryCompleted()
	end

	return targetCFrame, locationInstance
end

task.spawn(function()
	while isRunning() do
		if ensureDeliveryJob() then
			local pickupCFrame, pickupLocationInstance = interactAtCurrentTarget(false)

			if pickupCFrame then
				waitForPickupItemsDeleted()

				local dropoffCFrame = interactAtCurrentTarget(true)

				if dropoffCFrame then
					waitForTargetChange(dropoffCFrame)
				end
			end
		end

		task.wait(CONFIG.PollDelay)
	end
end)
