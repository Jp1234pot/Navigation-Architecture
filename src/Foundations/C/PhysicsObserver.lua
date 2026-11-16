
-- Navigation Architecture v2.2
-- Module: PhysicsObserver
-- Read-only, on-demand observations of a character/NPC Model.
-- This module never writes physics, humanoid, or instance properties.

local Workspace = game:GetService("Workspace")

local PhysicsObserver = {}
PhysicsObserver.__index = PhysicsObserver

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function isFiniteVector3(value)
    return typeof(value) == "Vector3"
        and isFiniteNumber(value.X)
        and isFiniteNumber(value.Y)
        and isFiniteNumber(value.Z)
end

local function findRoot(model, humanoid)
    local root = model:FindFirstChild("HumanoidRootPart")
    if root and root:IsA("BasePart") then
        return root
    end

    if humanoid and humanoid.RootPart and humanoid.RootPart:IsA("BasePart") then
        return humanoid.RootPart
    end

    local primaryPart = model.PrimaryPart
    if primaryPart and primaryPart:IsA("BasePart") then
        return primaryPart
    end

    return nil
end

function PhysicsObserver.new()
    return setmetatable({
        Destroyed = false,
    }, PhysicsObserver)
end

-- Returns snapshot, status. Snapshot values are observations from this client,
-- not authoritative server state. Callers choose their own sampling cadence.
function PhysicsObserver:Observe(model)
    if self.Destroyed then
        return nil, "Destroyed"
    end

    if typeof(model) ~= "Instance" or not model:IsA("Model") then
        return nil, "InvalidModel"
    end

    local presentOk, isPresent = pcall(function()
        return model:IsDescendantOf(Workspace)
    end)
    if not presentOk or not isPresent then
        return nil, "ModelNotInWorkspace"
    end

    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        return nil, "HumanoidUnavailable"
    end

    local root = findRoot(model, humanoid)
    if not root then
        return nil, "RootUnavailable"
    end

    local success, snapshot = pcall(function()
        local assemblyRoot = root.AssemblyRootPart or root
        local state = humanoid:GetState()
        local position = root.Position
        local linearVelocity = root.AssemblyLinearVelocity
        local angularVelocity = root.AssemblyAngularVelocity
        local moveDirection = humanoid.MoveDirection

        return {
            model = model,
            humanoid = humanoid,
            root = root,
            assemblyRoot = assemblyRoot,
            timestamp = os.clock(),
            position = position,
            cframe = root.CFrame,
            assemblyLinearVelocity = linearVelocity,
            assemblyAngularVelocity = angularVelocity,
            rootAnchored = root.Anchored,
            assemblyRootAnchored = assemblyRoot.Anchored,
            humanoidState = state,
            moveDirection = moveDirection,
            velocityPropertySource = "BasePart.AssemblyLinearVelocity",
            movementIntentSource = "Humanoid.MoveDirection",
        }
    end)

    if not success then
        return nil, "ReadFailed"
    end

    if not isFiniteVector3(snapshot.position)
        or not isFiniteVector3(snapshot.assemblyLinearVelocity)
        or not isFiniteVector3(snapshot.assemblyAngularVelocity)
        or not isFiniteVector3(snapshot.moveDirection) then
        return nil, "NonFiniteObservation"
    end

    return snapshot, "OK"
end

-- Position-only variant for remote candidate analysis. It intentionally avoids
-- reading AssemblyLinearVelocity/AssemblyAngularVelocity, which are not
-- replicated properties and are not needed by the position-delta estimator.
function PhysicsObserver:ObservePosition(model)
    if self.Destroyed then
        return nil, "Destroyed"
    end

    if typeof(model) ~= "Instance" or not model:IsA("Model") then
        return nil, "InvalidModel"
    end

    local presentOk, isPresent = pcall(function()
        return model:IsDescendantOf(Workspace)
    end)
    if not presentOk or not isPresent then
        return nil, "ModelNotInWorkspace"
    end

    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        return nil, "HumanoidUnavailable"
    end

    local root = findRoot(model, humanoid)
    if not root then
        return nil, "RootUnavailable"
    end

    local success, snapshot = pcall(function()
        return {
            model = model,
            humanoid = humanoid,
            root = root,
            timestamp = os.clock(),
            position = root.Position,
            source = "PositionOnly",
        }
    end)
    if not success then
        return nil, "ReadFailed"
    end

    if not isFiniteVector3(snapshot.position) then
        return nil, "NonFiniteObservation"
    end

    return snapshot, "OK"
end

function PhysicsObserver:Destroy()
    self.Destroyed = true
end

return PhysicsObserver
