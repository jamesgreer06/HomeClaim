-- HomeClaim Client Plugin
-- Handles visual markers and map integration
local M = {}

log("I", "HomeClaim", "Client plugin loading...")

local markers = {}
local mapMarkers = {}

-- Remove radius marker
local function removeRadiusMarker(name)
    if markers[name] then
        for _, obj in ipairs(markers[name].objects) do
            if obj and obj:isValid() then
                obj:delete()
            end
        end
        markers[name] = nil
    end
end

-- Create visual radius marker
local function createRadiusMarker(position, radius, name)
    -- Remove existing marker if any
    if markers[name] then
        removeRadiusMarker(name)
    end

    -- Create a circular marker using multiple objects
    local markerObjects = {}
    local segments = 32 -- Number of segments in the circle
    
    for i = 0, segments - 1 do
        local angle = (i / segments) * 2 * math.pi
        local x = position.x + math.cos(angle) * radius
        local y = position.y + math.sin(angle) * radius
        local z = position.z
        
        -- Create a small marker object at this point
        local markerName = "homeMarker_" .. name .. "_" .. i
        local marker = createObject("TSStatic")
        marker:setField("shapeName", 0, "art/shapes/interface/position_marker.dae")
        marker:setPosition(vec3(x, y, z))
        marker.scale = vec3(0.5, 0.5, 0.5)
        marker:setField("rotation", 0, "1 0 0 0")
        marker.useInstanceRenderData = true
        marker:setField("instanceColor", 0, "0 1 0 1") -- Green color
        marker:setField("collisionType", 0, "None")
        marker:setField("canSave", 0, "0")
        marker.canSave = false
        marker:registerObject(markerName)
        scenetree.MissionGroup:addObject(marker)
        
        table.insert(markerObjects, marker)
    end

    -- Create center marker
    local centerMarkerName = "homeCenter_" .. name
    local centerMarker = createObject("TSStatic")
    centerMarker:setField("shapeName", 0, "art/shapes/interface/position_marker.dae")
    centerMarker:setPosition(vec3(position.x, position.y, position.z))
    centerMarker.scale = vec3(1.5, 1.5, 1.5)
    centerMarker:setField("rotation", 0, "1 0 0 0")
    centerMarker.useInstanceRenderData = true
    centerMarker:setField("instanceColor", 0, "0 1 0 1") -- Green color
    centerMarker:setField("collisionType", 0, "None")
    centerMarker:setField("canSave", 0, "0")
    centerMarker.canSave = false
    centerMarker:registerObject(centerMarkerName)
    scenetree.MissionGroup:addObject(centerMarker)
    
    table.insert(markerObjects, centerMarker)

    markers[name] = {
        objects = markerObjects,
        position = position,
        radius = radius
    }
end

-- Add map marker
local function addMapMarker(position, name)
    -- Use BeamNG's map system to add a marker
    -- Try different map APIs that might be available
    if gui and gui.getMap then
        local map = gui.getMap()
        if map and map.addMarker then
            local markerId = map.addMarker({
                position = position,
                label = name,
                color = {0, 1, 0, 1} -- Green
            })
            mapMarkers[name] = markerId
            return
        end
    end
    
    -- Alternative: Use mission editor markers
    if scenetree and scenetree.MissionGroup then
        -- Create a visible marker object that shows on map
        local markerName = "mapMarker_" .. name
        local marker = createObject("TSStatic")
        marker:setField("shapeName", 0, "art/shapes/interface/position_marker.dae")
        marker:setPosition(vec3(position.x, position.y, position.z + 5)) -- Slightly elevated
        marker.scale = vec3(2, 2, 2)
        marker:setField("rotation", 0, "1 0 0 0")
        marker.useInstanceRenderData = true
        marker:setField("instanceColor", 0, "0 1 0 1") -- Green color
        marker:setField("collisionType", 0, "None")
        marker:setField("canSave", 0, "0")
        marker.canSave = false
        marker:registerObject(markerName)
        scenetree.MissionGroup:addObject(marker)
        mapMarkers[name] = marker
        log("I", "HomeClaim", "Map marker created for: " .. name)
    else
        log("W", "HomeClaim", "Could not create map marker for: " .. name)
    end
end

-- Remove map marker
local function removeMapMarker(name)
    if mapMarkers[name] and map and map.removeMarker then
        map.removeMarker(mapMarkers[name])
        mapMarkers[name] = nil
    end
end

-- Update all map markers
local function updateMapMarkers(homes)
    -- Clear existing markers
    for name, _ in pairs(mapMarkers) do
        removeMapMarker(name)
    end
    mapMarkers = {}

    -- Add new markers
    for playerId, home in pairs(homes) do
        addMapMarker(home.position, home.name)
    end
end


-- Event handlers
local function onHomeClaimCreateMarker(data)
    if data.position and data.radius and data.name then
        createRadiusMarker(
            vec3(data.position.x, data.position.y, data.position.z),
            data.radius,
            data.name
        )
    end
end

local function onHomeClaimRemoveMarker(data)
    -- Remove all markers
    for name, _ in pairs(markers) do
        removeRadiusMarker(name)
    end
    for name, _ in pairs(mapMarkers) do
        removeMapMarker(name)
    end
end

local function onHomeClaimUpdateMap(data)
    if data.homes then
        updateMapMarkers(data.homes)
    end
end

-- Spawn a vehicle with the given config data
local function onHomeClaimSpawnVehicle(data)
    log("I", "HomeClaim", "onHomeClaimSpawnVehicle called")
    -- First decode: wrapper packet {"config": "..."}
    local config = jsonDecode(data)
    if not config then
        log("W", "HomeClaim", "Failed to decode wrapper or missing config: " .. tostring(config))
        return
    end
    log("I", "HomeClaim", "Successfully decoded wrapper packet")
    
    -- Extract position
    local spawnPos = nil
    if config.pos and type(config.pos) == "table" and #config.pos >= 3 then
        spawnPos = vec3(config.pos[1], config.pos[2], config.pos[3])
    end
    
    -- Extract rotation
    local spawnRot = nil
    if config.rot and type(config.rot) == "table" and #config.rot >= 4 then
        spawnRot = quat(config.rot[1], config.rot[2], config.rot[3], config.rot[4])
    end
    
    -- Extract jbeam (vehicle model)
    local jbeam = config.jbm
    if not jbeam then
        log("W", "HomeClaim", "No jbeam/model specified in vehicle config")
        return
    end
    
    if not spawnPos then
        log("W", "HomeClaim", "No position specified in vehicle config")
        return
    end
    
    -- Extract part config filename (if available)
    local partConfig = config.vcf and config.vcf.partConfigFilename or nil
    
    -- Spawn vehicle using core_vehicles.spawnNewVehicle
    -- Use the full config JSON string for spawnOptions.config (decoded.config is the inner JSON string)
    local spawnOptions = {
        pos = spawnPos,
        rot = spawnRot or quat(0, 0, 1, 0),
        config = config, -- Full vehicle config JSON string
        autoEnterVehicle = true,
        centeredPosition = true
    }
    
    log("I", "HomeClaim", "Spawning vehicle: " .. jbeam .. " at position " .. tostring(spawnPos))
    core_vehicles.spawnNewVehicle(jbeam, spawnOptions)
end

-- Track if we've already requested vehicle restoration
local hasRequestedVehicles = false

-- Game state update handler - detect when world is ready (state 2)
local function onGameStateUpdate(state)
    -- Extract state number from table if it's a table
    local stateNum = state
    if type(state) == "table" then
        -- Try to get state from common table fields
        stateNum = state.state or state.value or state[1] or nil
        log("I", "HomeClaim", "Game state update (table): " .. tostring(stateNum))
    else
        log("I", "HomeClaim", "Game state update: " .. tostring(state))
    end
    
    if stateNum == 2 and not hasRequestedVehicles then
        log("I", "HomeClaim", "Game state 2 reached, requesting vehicle restoration from server")
        hasRequestedVehicles = true
        -- Send server event to request vehicle restoration
        if MPGameNetwork then
            TriggerServerEvent("homeClaim:requestVehicles", "ready")
        end
    end
end

local function HCSpawnVehicle(data)
    log("I", "HomeClaim", "*** RECEIVED HCSpawnVehicle event ***")
    log("I", "HomeClaim", "Data type: " .. type(data) .. ", length: " .. (data and tostring(string.len(data)) or "nil"))
    if data ~= "null" and data then
        log("I", "HomeClaim", "Calling onHomeClaimSpawnVehicle...")
        onHomeClaimSpawnVehicle(data)
    else
        log("W", "HomeClaim", "SpawnVehicle event received with null or empty data")
    end
    log("I", "HomeClaim", "Event handler registered for HCSpawnVehicle")
end

local function HCCreateMarker(data)
    if data ~= "null" and data then
        data = jsonDecode(data)
        if data then
            onHomeClaimCreateMarker(data)
        end
    end
end

local function HCRemoveMarker(data)
    onHomeClaimRemoveMarker({})
end

local function HCUpdateMap(data)
    if data ~= "null" and data then
        data = jsonDecode(data)
        if data then
            onHomeClaimUpdateMap(data)
        end
    end
end

local function onExtensionLoaded()
    -- Register event handlers (only if MPGameNetwork is available)
    if MPGameNetwork then
        log("I", "HomeClaim", "MPGameNetwork available, registering event handlers")
        AddEventHandler("HCSpawnVehicle", HCSpawnVehicle)
        AddEventHandler("HCCreateMarker", HCCreateMarker)
        AddEventHandler("HCRemoveMarker", HCRemoveMarker)
        AddEventHandler("HCUpdateMap", HCUpdateMap)
    else
        log("W", "HomeClaim", "MPGameNetwork not available, event handlers not registered")
    end
end

local function onExtensionUnloaded()

end

-- Export game state update handler
M.onGameStateUpdate = onGameStateUpdate

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
