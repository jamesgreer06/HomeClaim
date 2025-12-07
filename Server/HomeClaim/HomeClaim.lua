-- HomeClaim Plugin for BeamMP
-- Allows players to claim home areas with vehicle persistence

print("HomeClaim: Plugin file loading...")

local HOME_DATA_PATH = "Resources/Server/HomeClaim/homes.json"
local VEHICLE_DATA_PATH = "Resources/Server/HomeClaim/vehicles.json"
local CONFIG_PATH = "Resources/Server/HomeClaim/config.json"
local DEFAULT_RADIUS = 50 -- meters
local MIN_DISTANCE_BETWEEN_HOMES = 100 -- minimum distance between home centers (prevents overlap)

-- Load configuration
local function loadConfig()
    if FS.Exists(CONFIG_PATH) then
        local file = io.open(CONFIG_PATH, "r")
        if file then
            local content = file:read("*all")
            file:close()
            if content and content ~= "" then
                local config = Util.JsonDecode(content)
                if config then
                    DEFAULT_RADIUS = config.defaultRadius or DEFAULT_RADIUS
                    MIN_DISTANCE_BETWEEN_HOMES = config.minDistanceBetweenHomes or MIN_DISTANCE_BETWEEN_HOMES
                end
            end
        end
    end
end

local homes = {}
local vehicleStates = {}

-- Load saved data on init
local function loadHomes()
    if FS.Exists(HOME_DATA_PATH) then
        local file = io.open(HOME_DATA_PATH, "r")
        if file then
            local content = file:read("*all")
            file:close()
            if content and content ~= "" then
                homes = Util.JsonDecode(content) or {}
            end
        end
    end
end

local function saveHomes()
    local file = io.open(HOME_DATA_PATH, "w")
    if file then
        file:write(Util.JsonEncode(homes))
        file:close()
    end
end

local function loadVehicleStates()
    if FS.Exists(VEHICLE_DATA_PATH) then
        local file = io.open(VEHICLE_DATA_PATH, "r")
        if file then
            local content = file:read("*all")
            file:close()
            if content and content ~= "" then
                vehicleStates = Util.JsonDecode(content) or {}
            end
        end
    end
end

local function saveVehicleStates()
    local file = io.open(VEHICLE_DATA_PATH, "w")
    if file then
        file:write(Util.JsonEncode(vehicleStates))
        file:close()
    end
end

-- Calculate distance between two 3D points
local function getDistance(pos1, pos2)
    local dx = pos1.x - pos2.x
    local dy = pos1.y - pos2.y
    local dz = pos1.z - pos2.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Check if a position is within a home radius
local function isWithinHomeRadius(pos, home)
    local distance = getDistance(pos, home.position)
    return distance <= home.radius
end

-- Check if two homes would overlap
local function wouldOverlap(newPos, newRadius, existingHome)
    local distance = getDistance(newPos, existingHome.position)
    local combinedRadius = newRadius + existingHome.radius
    return distance < combinedRadius
end

-- Check if new home is too close to existing homes
local function isTooClose(newPos, newRadius)
    for playerId, home in pairs(homes) do
        if wouldOverlap(newPos, newRadius, home) then
            return true, MP.GetPlayerName(tonumber(playerId)) or "Unknown"
        end
        -- Also check minimum distance requirement
        local distance = getDistance(newPos, home.position)
        if distance < MIN_DISTANCE_BETWEEN_HOMES then
            return true, MP.GetPlayerName(tonumber(playerId)) or "Unknown"
        end
    end
    return false, nil
end

-- Get player's current position
local function getPlayerPosition(playerId)
    local vehicles = MP.GetPlayerVehicles(playerId)
    
    if not vehicles then
        return nil
    end
    
    -- MP.GetPlayerVehicles returns a table mapping vehicle ID -> vehicle data
    -- Use pairs() to iterate over the key-value pairs
    for vehicleId, vehicleData in pairs(vehicles) do
        -- Convert vehicleId to number (MP.GetPositionRaw expects number, not string)
        local vid = tonumber(vehicleId)
        if vid then
            local rawPos, err = MP.GetPositionRaw(playerId, vid)
            
            -- Check if error is empty (success)
            if err == "" and rawPos and rawPos.pos then
                -- Extract position from pos array {1: x, 2: y, 3: z}
                local x = rawPos.pos[1]
                local y = rawPos.pos[2]
                local z = rawPos.pos[3]
                
                if x and y and z then
                    return {x = x, y = y, z = z}
                end
            end
        end
    end
    
    return nil
end

-- Handle /home claim command
local function handleHomeClaim(playerId, homeName)
    -- Check if player already has a home
    local playerIdStr = tostring(playerId)
    if homes[playerIdStr] then
        MP.SendChatMessage(playerId, "You already have a home claimed. Use /home delete to remove it first.")
        return
    end

    -- Validate home name
    if not homeName or homeName == "" then
        MP.SendChatMessage(playerId, "Usage: /home claim <NAME>")
        return
    end

    -- Get player position
    local position = getPlayerPosition(playerId)
    if not position then
        MP.SendChatMessage(playerId, "Unable to get your position. Please be in a vehicle.")
        return
    end

    -- Check for overlaps
    local tooClose, nearbyPlayer = isTooClose(position, DEFAULT_RADIUS)
    if tooClose then
        MP.SendChatMessage(playerId, "Cannot claim home here. Too close to " .. nearbyPlayer .. "'s home.")
        return
    end

    -- Create home entry
    homes[playerIdStr] = {
        name = homeName,
        position = position,
        radius = DEFAULT_RADIUS,
        playerName = MP.GetPlayerName(playerId)
    }

    saveHomes()

    -- Notify player and create visual marker
    MP.SendChatMessage(playerId, "Home '" .. homeName .. "' claimed successfully! Radius: " .. DEFAULT_RADIUS .. "m")
    
    -- Send event to client to create visual marker
    local markerPacket = Util.JsonEncode({
        position = position,
        radius = DEFAULT_RADIUS,
        name = homeName
    })
    MP.TriggerClientEvent(playerId, "HCCreateMarker", markerPacket)

    -- Send event to update map
    local mapPacket = Util.JsonEncode({
        homes = {[playerIdStr] = homes[playerIdStr]}
    })
    MP.TriggerClientEvent(playerId, "HCUpdateMap", mapPacket)
end

-- Handle /home delete command
local function handleHomeDelete(playerId)
    local playerIdStr = tostring(playerId)
    if not homes[playerIdStr] then
        MP.SendChatMessage(playerId, "You don't have a home claimed.")
        return
    end

    homes[playerIdStr] = nil
    vehicleStates[playerIdStr] = nil
    saveHomes()
    saveVehicleStates()

    MP.SendChatMessage(playerId, "Home deleted successfully.")
    
    -- Notify client to remove markers
    MP.TriggerClientEvent(playerId, "HCRemoveMarker", "{}")
    MP.TriggerClientEvent(playerId, "HCUpdateMap", Util.JsonEncode({homes = {}}))
end

-- Handle /home info command
local function handleHomeInfo(playerId)
    local playerIdStr = tostring(playerId)
    local home = homes[playerIdStr]
    if not home then
        MP.SendChatMessage(playerId, "You don't have a home claimed.")
        return
    end

    MP.SendChatMessage(playerId, "Home: " .. home.name)
    MP.SendChatMessage(playerId, "Position: X=" .. math.floor(home.position.x) .. " Y=" .. math.floor(home.position.y) .. " Z=" .. math.floor(home.position.z))
    MP.SendChatMessage(playerId, "Radius: " .. home.radius .. "m")
end

-- Save all vehicles within player's home radius
local function savePlayerVehicles(playerId)
    local playerIdStr = tostring(playerId)
    local home = homes[playerIdStr]
    if not home then
        return
    end

    local vehicles = MP.GetPlayerVehicles(playerId)
    if not vehicles then
        return
    end
    
    -- Check if vehicles table is empty (it's a key-value table, not array)
    local hasVehicles = false
    for _ in pairs(vehicles) do
        hasVehicles = true
        break
    end
    
    if not hasVehicles then
        -- Clear saved vehicles if player has none
        if vehicleStates[playerIdStr] then
            vehicleStates[playerIdStr] = {}
            saveVehicleStates()
        end
        return
    end

    local savedVehicles = {}
    -- MP.GetPlayerVehicles returns a table mapping vehicle ID -> vehicle data (JSON string)
    for vehicleId, vehicleDataString in pairs(vehicles) do
        -- Convert vehicleId to number
        local vid = tonumber(vehicleId)
        if not vid then
            goto continue
        end
        
        local rawPos, err = MP.GetPositionRaw(playerId, vid)
        if err == "" and rawPos and rawPos.pos then
            -- Extract position from pos array
            local x = rawPos.pos[1]
            local y = rawPos.pos[2]
            local z = rawPos.pos[3]
            local pos = {x = x, y = y, z = z}
            
            -- Check if vehicle is within home radius
            if isWithinHomeRadius(pos, home) then
                -- Extract JSON from vehicle data (may have prefix)
                local jsonStart = string.find(vehicleDataString, "{")
                local config = vehicleDataString
                if jsonStart then
                    config = string.sub(vehicleDataString, jsonStart, -1)
                end
                
                -- Parse to get model and rotation
                local vehicleData = nil
                local model = nil
                local rotation = nil
                
                if config then
                    local parsed = Util.JsonDecode(config)
                    if parsed then
                        vehicleData = parsed
                        -- Extract model
                        if vehicleData.jbm then
                            model = vehicleData.jbm
                        end
                        -- Extract rotation
                        if vehicleData.rot then
                            rotation = vehicleData.rot
                        end
                    end
                end
                
                -- Try to get existing saved data for this vehicle (for rotation if not in current data)
                if not rotation and vehicleStates[playerIdStr] then
                    for _, v in ipairs(vehicleStates[playerIdStr]) do
                        if v.vehicleId == vid then
                            rotation = v.rotation
                            break
                        end
                    end
                end
                
                local savedVehicleData = {
                    vehicleId = vid,
                    position = pos,
                    rotation = rotation,
                    config = config,
                    model = model
                }
                table.insert(savedVehicles, savedVehicleData)
            end
        end
        
        ::continue::
    end

    vehicleStates[playerIdStr] = savedVehicles
    saveVehicleStates()
    print("HomeClaim: Saved " .. #savedVehicles .. " vehicles for player " .. playerIdStr)
end

-- Restore player's vehicles when they join
local function restorePlayerVehicles(playerId)
    local playerIdStr = tostring(playerId)
    local savedVehicles = vehicleStates[playerIdStr]
    if not savedVehicles or #savedVehicles == 0 then
        print("HomeClaim: No saved vehicles to restore for player " .. playerIdStr)
        return
    end

    local home = homes[playerIdStr]
    if not home then
        print("HomeClaim: No home found for player " .. playerIdStr .. ", cannot restore vehicles")
        return
    end

    print("HomeClaim: Restoring " .. #savedVehicles .. " vehicles for player " .. playerIdStr)
    print("HomeClaim: Spawning vehicles immediately for player " .. playerIdStr)
    
    -- Spawn vehicles immediately (user triggered /loadhome manually, so they're ready)
    for i, vehicleData in ipairs(savedVehicles) do
            print("HomeClaim: Processing vehicle " .. i .. " of " .. #savedVehicles)
            
            -- Extract config JSON if it exists
            local configJson = vehicleData.config
            print("HomeClaim: Vehicle " .. i .. " config exists: " .. tostring(configJson ~= nil))
            if not configJson then
                print("HomeClaim: Vehicle " .. i .. " has no config, skipping")
                goto continue
            end
            
            -- Parse config to update position and rotation
            local jsonStart = string.find(configJson, "{")
            if jsonStart then
                configJson = string.sub(configJson, jsonStart, -1)
            end
            
            local config = Util.JsonDecode(configJson)
            if not config then
                print("HomeClaim: Failed to decode config for vehicle " .. i)
                goto continue
            end
            
            -- Ensure required fields exist
            if not config.jbm and vehicleData.model then
                config.jbm = vehicleData.model
            end
            
            if not config.jbm then
                print("HomeClaim: Vehicle " .. i .. " has no jbm/model, skipping")
                goto continue
            end
            
            -- Update position in config (must be array [x, y, z])
            if vehicleData.position then
                config.pos = {
                    vehicleData.position.x,
                    vehicleData.position.y,
                    vehicleData.position.z
                }
            end
            
            -- Update rotation in config (must be array [x, y, z, w] for quaternion)
            if vehicleData.rotation and type(vehicleData.rotation) == "table" then
                if #vehicleData.rotation == 4 then
                    config.rot = vehicleData.rotation
                else
                    print("HomeClaim: Vehicle " .. i .. " has invalid rotation format")
                end
            end
            
            -- Ensure player ID is set to the owner
            config.pid = playerId
            
            print("HomeClaim: Sending spawn request for vehicle " .. i .. " to player " .. playerIdStr)
            print("HomeClaim: Vehicle model (jbm): " .. tostring(config.jbm))
            print("HomeClaim: Position: " .. tostring(vehicleData.position and (vehicleData.position.x .. ", " .. vehicleData.position.y .. ", " .. vehicleData.position.z) or "none"))
            
            -- Send spawn request to client
            print("HomeClaim: Triggering client event 'HCSpawnVehicle' for player " .. playerId)
            MP.TriggerClientEventJson(playerId, "HCSpawnVehicle", config)
            print("HomeClaim: Client event triggered")
            
            ::continue::
        end
        
    print("HomeClaim: Sent spawn requests for " .. #savedVehicles .. " vehicles to player " .. playerIdStr)
end

-- Helper function to split message into words
local function messageSplit(message)
    local words = {}
    for word in string.gmatch(message, "%S+") do
        table.insert(words, word)
    end
    return words
end

-- Handle client request for vehicle restoration (when game state 2 is reached)
function onClientRequestVehicles(playerId, data)
    local playerIdStr = tostring(playerId)
    print("HomeClaim: Client requested vehicle restoration for player " .. playerIdStr)
    
    local savedVehicles = vehicleStates[playerIdStr]
    if not savedVehicles or #savedVehicles == 0 then
        print("HomeClaim: No saved vehicles for player " .. playerIdStr)
        return
    end
    
    if not homes[playerIdStr] then
        print("HomeClaim: No home found for player " .. playerIdStr)
        return
    end
    
    print("HomeClaim: Restoring " .. #savedVehicles .. " vehicles for player " .. playerIdStr)
    restorePlayerVehicles(playerId)
end

-- Chat message handler
function onChatMessage(senderId, senderName, message)
    -- Check for /loadhome command
    if string.sub(message, 0, 9) == '/loadhome' then
        local playerIdStr = tostring(senderId)
        if not homes[playerIdStr] then
            MP.SendChatMessage(senderId, "You don't have a home claimed. Use /home claim <NAME> first.")
            return 1
        end
        
        local savedVehicles = vehicleStates[playerIdStr]
        if not savedVehicles or #savedVehicles == 0 then
            MP.SendChatMessage(senderId, "No saved vehicles found at your home.")
            return 1
        end
        
        MP.SendChatMessage(senderId, "Loading " .. #savedVehicles .. " vehicle(s) at your home...")
        restorePlayerVehicles(senderId)
        return 1
    end
    
    -- Check if message starts with /home (using 0-based indexing like the example)
    if string.sub(message, 0, 5) ~= '/home' then 
        return 0 
    end
    
    local args = messageSplit(message)
    
    if #args < 2 then
        MP.SendChatMessage(senderId, "Home commands: /home claim <NAME>, /home delete, /home info")
        return 1
    end
    
    if string.lower(args[2]) == "claim" then
        if args[3] == nil then
            MP.SendChatMessage(senderId, "Usage: /home claim <NAME>")
            return 1
        end
        handleHomeClaim(senderId, args[3])
        return 1
    elseif string.lower(args[2]) == "delete" then
        handleHomeDelete(senderId)
        return 1
    elseif string.lower(args[2]) == "info" then
        handleHomeInfo(senderId)
        return 1
    else
        MP.SendChatMessage(senderId, "Unknown command: " .. args[2])
        MP.SendChatMessage(senderId, "Home commands: /home claim <NAME>, /home delete, /home info")
        return 1
    end
end

-- Player disconnect handler
function onPlayerDisconnect(playerId)
    savePlayerVehicles(playerId)
end

-- Player join handler (called after onPlayerJoining)
function onPlayerJoin(playerId)
    -- Send existing home data to client for map markers
    local playerIdStr = tostring(playerId)
    if homes[playerIdStr] then
        -- Wait a moment for client to be ready
        MP.CreateTimer(function()
            local mapPacket = Util.JsonEncode({
                homes = {[playerIdStr] = homes[playerIdStr]}
            })
            MP.TriggerClientEvent(playerId, "HCUpdateMap", mapPacket)
            
            local markerPacket = Util.JsonEncode({
                position = homes[playerIdStr].position,
                radius = homes[playerIdStr].radius,
                name = homes[playerIdStr].name
            })
            MP.TriggerClientEvent(playerId, "HCCreateMarker", markerPacket)
        end, 1000) -- 1 second delay
    end
    
    -- Don't restore vehicles automatically - player must use /loadhome command
end

-- Vehicle spawn handler - save config for vehicles in home
function onVehicleSpawn(playerId, vehicleId, data)
    local playerIdStr = tostring(playerId)
    local home = homes[playerIdStr]
    if not home then
        return
    end

    -- Extract JSON from data (may have prefix like "USER:Name:0-1:{...}")
    local jsonStart = string.find(data, "{")
    if not jsonStart then
        return
    end
    local jsonData = string.sub(data, jsonStart, -1)
    
    -- Parse vehicle data to get position and model
    local vehicleData = Util.JsonDecode(jsonData)
    if vehicleData and vehicleData.pos then
        local pos = {x = vehicleData.pos[1], y = vehicleData.pos[2], z = vehicleData.pos[3]}
        if isWithinHomeRadius(pos, home) then
            -- Store vehicle config
            if not vehicleStates[playerIdStr] then
                vehicleStates[playerIdStr] = {}
            end
            
            -- Extract model from config if available (jbm is a string like "miramar")
            local model = nil
            if vehicleData.jbm then
                model = vehicleData.jbm
            end
            
            -- Extract rotation if available
            local rotation = nil
            if vehicleData.rot then
                rotation = vehicleData.rot
            end
            
            -- Convert vehicleId to number for consistency
            local vid = tonumber(vehicleId)
            if not vid then
                return
            end
            
            -- Find or create entry for this vehicle
            local found = false
            for i, v in ipairs(vehicleStates[playerIdStr]) do
                if v.vehicleId == vid then
                    v.config = data
                    v.position = {x = pos.x, y = pos.y, z = pos.z}
                    v.rotation = rotation or v.rotation
                    v.model = model or v.model
                    found = true
                    break
                end
            end
            
            if not found then
                -- New vehicle entry
                table.insert(vehicleStates[playerIdStr], {
                    vehicleId = vid,
                    position = {x = pos.x, y = pos.y, z = pos.z},
                    rotation = rotation,
                    config = data,
                    model = model
                })
            end
            
            saveVehicleStates()
        end
    end
end

-- Vehicle edit handler - update config
function onVehicleEdited(playerId, vehicleId, data)
    local playerIdStr = tostring(playerId)
    local home = homes[playerIdStr]
    if not home then
        return
    end

    -- Convert vehicleId to number
    local vid = tonumber(vehicleId)
    if not vid then
        return
    end
    
    local rawPos, err = MP.GetPositionRaw(playerId, vid)
    if err == "" and rawPos and rawPos.pos then
        -- Extract position from pos array
        local x = rawPos.pos[1]
        local y = rawPos.pos[2]
        local z = rawPos.pos[3]
        local pos = {x = x, y = y, z = z}
        
        if isWithinHomeRadius(pos, home) then
            if vehicleStates[playerIdStr] then
                local rotation = nil
                if rawPos.rot then
                    rotation = rawPos.rot
                end
                
                for i, v in ipairs(vehicleStates[playerIdStr]) do
                    if v.vehicleId == vid then
                        v.config = data
                        v.position = pos
                        v.rotation = rotation or v.rotation
                        saveVehicleStates()
                        return
                    end
                end
            end
        end
    end
end

-- Console input handler (for server console commands)
function onConsoleInput(input)
    if string.sub(input, 1, 6) == "home " then
        local args = {}
        for word in string.gmatch(input, "%S+") do
            table.insert(args, word)
        end
        
        if #args >= 2 and args[2] == "claim" then
            print("HomeClaim: Console command 'home claim' - this command must be used in-game by a player")
            return
        elseif #args >= 2 and args[2] == "info" then
            print("HomeClaim: Console command 'home info' - this command must be used in-game by a player")
            return
        end
    end
end

-- Initialize function
local function initialize()
    print("HomeClaim: Initializing plugin...")
    
    -- Create data directory if it doesn't exist
    if not FS.Exists("Resources/Server/HomeClaim") then
        FS.CreateDirectory("Resources/Server/HomeClaim")
    end

    loadConfig()
    loadHomes()
    loadVehicleStates()
    
    local homeCount = 0
    for _ in pairs(homes) do
        homeCount = homeCount + 1
    end
    
    print("HomeClaim plugin initialized. " .. homeCount .. " homes found.")
    print("Default radius: " .. DEFAULT_RADIUS .. "m, Min distance: " .. MIN_DISTANCE_BETWEEN_HOMES .. "m")
end

-- onInit event handler (called by BeamMP)
function onInit()
    print("HomeClaim: onInit event triggered")
    initialize()
end

-- Register events
print("HomeClaim: Registering events...")
MP.RegisterEvent("onConsoleInput", "onConsoleInput")
MP.RegisterEvent("onChatMessage", "onChatMessage")
MP.RegisterEvent("onPlayerDisconnect", "onPlayerDisconnect")
MP.RegisterEvent("onPlayerJoining", "onPlayerJoin")
MP.RegisterEvent("onVehicleSpawn", "onVehicleSpawn")
MP.RegisterEvent("onVehicleEdited", "onVehicleEdited")
MP.RegisterEvent("onVehicleReset", "onVehicleEdited")
MP.RegisterEvent("homeClaim:requestVehicles", "onClientRequestVehicles")
print("HomeClaim: All events registered")

