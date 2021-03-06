local autotiler = require("autotiler")
local spriteLoader = require("sprite_loader")
local drawing = require("drawing")
local fileLocations = require("file_locations")
local colors = require("colors")
local tasks = require("task")
local utils = require("utils")
local atlases = require("atlases")
local entityHandler = require("entities")
local smartDrawingBatch = require("structs.smart_drawing_batch")
local drawableSprite = require("structs.drawable_sprite")
local drawableFunction = require("structs.drawable_function")
local drawableRectangle = require("structs.drawable_rectangle")
local viewportHandler = require("viewport_handler")
local matrix = require("matrix")
local configs = require("configs")

local celesteRender = {}

local tilesetFileFg = utils.joinpath(fileLocations.getCelesteDir(), "Content", "Graphics", "ForegroundTiles.xml")
local tilesetFileBg = utils.joinpath(fileLocations.getCelesteDir(), "Content", "Graphics", "BackgroundTiles.xml")

celesteRender.tilesMetaFg = autotiler.loadTilesetXML(tilesetFileFg)
celesteRender.tilesMetaBg = autotiler.loadTilesetXML(tilesetFileBg)

celesteRender.tilesSpriteMetaCache = {}

local triggerFontSize = 1

local tilesFgDepth = -10000
local tilesBgDepth = 10000

local decalsFgDepth = -10500
local decalsBgDepth = 9000

local triggersDepth = -math.huge

local PRINT_BATCHING_DURATION = false
local ALWAYS_REDRAW_UNSELECTED_ROOMS = configs.editor.alwaysRedrawUnselectedRooms
local ALLOW_NON_VISIBLE_BACKGROUND_DRAWING = configs.editor.prepareRoomRenderInBackground

local roomCache = {}
local roomRandomMatrixCache = {}

local batchingTasks = {}

function celesteRender.sortBatchingTasks(state, tasks)
    local visibleTasks = {}
    local nonVisibileTasks = {}

    for i = #batchingTasks, 1, -1 do
        local task = batchingTasks[i]
        local viewport = state.viewport
        local room = task.data.room

        if not task.done then
            if viewport.visible and viewportHandler.roomVisible(room, viewport) then
                table.insert(visibleTasks, task)

            else
                table.insert(nonVisibileTasks, task)
            end

        else
            table.remove(batchingTasks, i)
        end
    end

    return visibleTasks, nonVisibileTasks
end

function celesteRender.processTasks(state, calcTime, maxTasks, backgroundTime, backgroundTasks)
    local visible, notVisible = celesteRender.sortBatchingTasks(state, batchingTasks)

    backgroundTime = backgroundTime or calcTime
    backgroundTasks = backgroundTasks or maxTasks

    local success, timeSpent, tasksDone = tasks.processTasks(calcTime, maxTasks, visible)
    tasks.processTasks(backgroundTime - timeSpent, backgroundTasks - tasksDone, notVisible)
end

function celesteRender.clearBatchingTasks()
    batchingTasks = {}
end

function celesteRender.invalidateRoomCache(roomName, key)
    if roomName then
        if utils.typeof(roomName) == "room" then
            roomName = roomName.name
        end

        if key and roomCache[roomName] then
            roomCache[roomName][key] = nil

        else
            roomCache[roomName] = {}
        end

    else
        roomCache = {}
    end
end

function celesteRender.getRoomRandomMatrix(room, key)
    local roomName = room.name
    local tileWidth, tileHeight = room[key].matrix:size()
    local regen = false

    if roomRandomMatrixCache[roomName] and roomRandomMatrixCache[roomName][key] then
        local m = roomRandomMatrixCache[roomName][key]
        local randWidth, randHeight = m:size()

        regen = tileWidth ~= randWidth or tileHeight ~= randHeight

    else
        regen = true
    end

    if regen then
        utils.setRandomSeed(roomName)

        local m = matrix.fromFunction(math.random, tileWidth, tileHeight)

        roomRandomMatrixCache[roomName] = roomRandomMatrixCache[roomName] or {}
        roomRandomMatrixCache[roomName][key] = m
    end

    return roomRandomMatrixCache[roomName][key]
end

function celesteRender.getRoomCache(roomName, key)
    if utils.typeof(roomName) == "room" then
        roomName = roomName.name
    end

    if roomCache[roomName] and roomCache[roomName][key] then
        return roomCache[roomName][key]
    end

    return false
end

function celesteRender.getRoomBackgroundColor(room, selected)
    local roomColor = room.color or 0
    local color = colors.roomBackgroundDefault

    if roomColor >= 0 and roomColor < #colors.roomBackgroundColors then
        color = colors.roomBackgroundColors[roomColor + 1]
    end

    local r, g, b = color[1], color[2], color[3]
    local a = selected and 1.0 or 0.3

    return {r, g, b, a}
end

function celesteRender.getRoomBorderColor(room, selected)
    local roomColor = room.color or 0
    local color = colors.roomBorderDefault

    if roomColor >= 0 and roomColor < #colors.roomBorderColors then
        color = colors.roomBorderColors[roomColor + 1]
    end

    return color
end

function celesteRender.getOrCacheTileSpriteQuad(cache, tile, texture, quad, fg)
    if not cache[tile] then
        cache[tile] = {
            [false] = matrix.filled(nil, 6, 15),
            [true] = matrix.filled(nil, 6, 15)
        }
    end

    local quadCache = cache[tile][fg]
    local quadX, quadY = quad[1], quad[2]

    if not quadCache:get0(quadX, quadY) then
        local spriteMeta = atlases.gameplay[texture]
        local spritesWidth, spritesHeight = spriteMeta.image:getDimensions()
        local res = love.graphics.newQuad(spriteMeta.x - spriteMeta.offsetX + quadX * 8, spriteMeta.y - spriteMeta.offsetY + quadY * 8, 8, 8, spritesWidth, spritesHeight)

        quadCache:set0(quadX, quadY, res)

        return res
    end

    return quadCache:get0(quadX, quadY)
end

local function drawInvalidTiles(batch, missingTiles, fg)
    local color = fg and colors.tileFGMissingColor or colors.tileBGMissingColor

    local canvas = love.graphics.getCanvas()
    local r, g, b, a = love.graphics.getColor()

    love.graphics.setCanvas(batch._canvas)
    love.graphics.setColor(color)

    for _, missing in ipairs(missingTiles) do
        local x, y = missing[1], missing[2]

        love.graphics.rectangle("fill", x * 8, y * 8, 8, 8)
    end

    love.graphics.setCanvas(canvas)
    love.graphics.setColor(r, g, b, a)
end

-- randomMatrix is for custom randomness, mostly to give the correct "slice" of the matrix when making fake tiles
function celesteRender.getTilesBatch(room, tiles, meta, fg, randomMatrix)
    local tilesMatrix = tiles.matrix

    -- Getting upvalues
    local gameplayAtlas = atlases.gameplay
    local cache = celesteRender.tilesSpriteMetaCache
    local autotiler = autotiler
    local meta = meta

    local airTile = "0"
    local emptyTile = " "
    local wildcard = "*"

    local defaultQuad = {{0, 0}}
    local defaultSprite = ""

    local drawableSpriteType = "drawableSprite"

    local width, height = tilesMatrix:size()
    local batch = smartDrawingBatch.createGridCanvasBatch(false, width, height, 8, 8)

    local random = randomMatrix or celesteRender.getRoomRandomMatrix(room, fg and "tilesFg" or "tilesBg")

    local missingTiles = {}

    for x = 1, width do
        for y = 1, height do
            local rng = random:getInbounds(x, y)
            local tile = tilesMatrix:getInbounds(x, y)

            if tile ~= airTile then
                if meta.paths[tile] then
                    -- TODO - Render overlay sprites
                    local quads, sprites = autotiler.getQuads(x, y, tilesMatrix, meta, airTile, emptyTile, wildcard, defaultQuad, defaultSprite)
                    local quadCount = #quads

                    if quadCount > 0 then
                        local randQuad = quads[utils.mod1(rng, quadCount)]
                        local texture = meta.paths[tile] or emptyTile

                        local spriteMeta = atlases.gameplay[texture]

                        if spriteMeta then
                            local quad = celesteRender.getOrCacheTileSpriteQuad(cache, tile, texture, randQuad, fg)

                            batch:set(x, y, spriteMeta, quad, x * 8 - 8, y * 8 - 8)

                        else
                            -- Missing texture, not found on disk
                            table.insert(missingTiles, {x, y})
                        end
                    end

                else
                    -- Unknown tileset id
                    table.insert(missingTiles, {x, y})
                end
            end
        end

        tasks.yield()
    end

    drawInvalidTiles(batch, missingTiles, fg)

    tasks.update(batch)

    return batch
end

local function getRoomTileBatch(room, tiles, fg)
    local key = fg and "tilesFg" or "tilesBg"
    local meta = fg and celesteRender.tilesMetaFg or celesteRender.tilesMetaBg

    roomCache[room.name] = roomCache[room.name] or {}
    roomCache[room.name][key] = roomCache[room.name][key] or tasks.newTask(
        (-> celesteRender.getTilesBatch(room, tiles, meta, fg)),
        (task -> PRINT_BATCHING_DURATION and print(string.format("Batching '%s' in '%s' took %s ms", key, room.name, task.timeTotal * 1000))),
        batchingTasks,
        {room = room}
    )

    return roomCache[room.name][key].result
end

function celesteRender.getTilesFgBatch(room, tiles, viewport)
    return getRoomTileBatch(room, tiles, true)
end

function celesteRender.getTilesBgBatch(room, tiles, viewport)
    return getRoomTileBatch(room, tiles, false)
end

local function getDecalsBatch(decals)
    local batch = smartDrawingBatch.createOrderedBatch()

    for i, decal in ipairs(decals) do
        local texture = decal.texture
        local meta = atlases.gameplay[texture]

        local x = decal.x or 0
        local y = decal.y or 0

        local scaleX = decal.scaleX or 1
        local scaleY = decal.scaleY or 1

        if meta then
            local drawable = drawableSprite.spriteFromTexture(texture)

            drawable:setScale(scaleX, scaleY)
            drawable:setOffset(0, 0) -- No automagicall calculations
            drawable:setPosition(
                x - meta.offsetX * scaleX - math.floor(meta.realWidth / 2) * scaleX,
                y - meta.offsetY * scaleY - math.floor(meta.realHeight / 2) * scaleY
            )

            batch:addFromDrawable(drawable)
        end

        if i % 25 == 0 then
            tasks.yield()
        end
    end

    tasks.update(batch)

    return batch
end

local function getRoomDecalsBatch(room, decals, fg)
    local key = fg and "decalsFg" or "decalsBg"

    roomCache[room.name] = roomCache[room.name] or {}
    roomCache[room.name][key] = roomCache[room.name][key] or tasks.newTask(
        (-> getDecalsBatch(decals)),
        (task -> PRINT_BATCHING_DURATION and print(string.format("Batching '%s' in '%s' took %s ms", key, room.name, task.timeTotal * 1000))),
        batchingTasks,
        {room = room}
    )

    return roomCache[room.name][key].result
end

function celesteRender.getDecalsFgBatch(room, decals, viewport)
    return getRoomDecalsBatch(room, decals, true)
end

function celesteRender.getDecalsBgBatch(room, decals, viewport)
    return getRoomDecalsBatch(room, decals, false)
end

function celesteRender.drawDecalsFg(room, decals)
    local batch = celesteRender.getDecalsFgBatch(room, decals)

    if batch then
        love.graphics.draw(batch, 0, 0)
    end
end

function celesteRender.drawDecalsBg(room, decals)
    local batch = celesteRender.getDecalsBgBatch(room, decals)

    if batch then
        love.graphics.draw(batch, 0, 0)
    end
end

local function getOrCreateSmartBatch(batches, key)
    batches[key] = batches[key] or smartDrawingBatch.createOrderedBatch()

    return batches[key]
end

-- TODO - Clean up, some of this logic should be in entities.lua or other helper file
local function getEntityBatchTaskFunc(room, entities, viewport, registeredEntities)
    local batches = {}

    for i, entity in ipairs(entities) do
        local name = entity._name
        local handler = registeredEntities[name]

        if handler then
            local defaultDepth = type(handler.depth) == "function" and handler.depth(room, entity, viewport) or handler.depth or 0

            if handler.sprite then
                local sprites = handler.sprite(room, entity, viewport)

                if sprites then
                    if #sprites == 0 and utils.typeof(sprites) == "drawableSprite" then
                        local batch = getOrCreateSmartBatch(batches, sprites.depth or defaultDepth)
                        batch:addFromDrawable(sprites)

                    else
                        for j, sprite in ipairs(sprites) do
                            if utils.typeof(sprite) == "drawableSprite" then
                                local batch = getOrCreateSmartBatch(batches, sprite.depth or defaultDepth)
                                batch:addFromDrawable(sprite)
                            end
                        end
                    end
                end

            elseif handler.rectangle then
                local rectangle = handler.rectangle(room, entity, viewport)
                local drawable = drawableRectangle.fromRectangle(handler.mode or "fill", handler.color or colors.default, rectangle)
                local batch = getOrCreateSmartBatch(batches, defaultDepth)

                batch:addFromDrawable(drawable)
            end

            if handler.draw then
                local batch = getOrCreateSmartBatch(batches, defaultDepth)
                batch:addFromDrawable(drawableFunction.fromFunction(handler.draw, room, entity, viewport))
            end

            if i % 25 == 0 then
                tasks.yield()
            end
        end
    end

    tasks.update(batches)

    return batches
end

function celesteRender.getEntityBatch(room, entities, viewport, registeredEntities, forceRedraw)
    registeredEntities = registeredEntities or entityHandler.registeredEntities

    roomCache[room.name] = roomCache[room.name] or {}

    if forceRedraw and roomCache[room.name].entities.result ~= nil then
        roomCache[room.name].entities = nil
    end

    roomCache[room.name].entities = roomCache[room.name].entities or tasks.newTask(
        (-> getEntityBatchTaskFunc(room, entities, viewport, registeredEntities)),
        (task -> PRINT_BATCHING_DURATION and print(string.format("Batching 'entities' in '%s' took %s ms", room.name, task.timeTotal * 1000))),
        batchingTasks,
        {room = room}
    )

    return roomCache[room.name].entities.result
end

-- TODO - Make this saner in terms of setColor calls?
-- This could just be one rendering function
local function getTriggerBatchTaskFunc(room, triggers, viewport)
    local font = love.graphics.getFont()
    local batch = smartDrawingBatch.createOrderedBatch()

    for i, trigger in ipairs(triggers) do
        local func = function()
            local name = trigger._name or ""
            local displayName = utils.humanizeVariableName(name)

            local x = trigger.x or 0
            local y = trigger.y or 0

            local width = trigger.width or 16
            local height = trigger.height or 16

            drawing.callKeepOriginalColor(function()
                love.graphics.setColor(colors.triggerColor)

                love.graphics.rectangle("line", x, y, width, height)
                love.graphics.rectangle("fill", x, y, width, height)

                love.graphics.setColor(colors.triggerTextColor)

                drawing.printCenteredText(displayName, x, y, width, height, font, triggerFontSize)
            end)
        end

        batch:addFromDrawable(drawableFunction.fromFunction(func))

        if i % 25 == 0 then
            tasks.yield()
        end
    end

    tasks.update(batch)

    return batch
end

function celesteRender.getTriggerBatch(room, triggers, viewport, forceRedraw)
    roomCache[room.name] = roomCache[room.name] or {}

    if forceRedraw and roomCache[room.name].triggers.result ~= nil then
        roomCache[room.name].triggers = nil
    end

    roomCache[room.name].triggers = roomCache[room.name].triggers or tasks.newTask(
        (-> getTriggerBatchTaskFunc(room, triggers, viewport)),
        (task -> PRINT_BATCHING_DURATION and print(string.format("Batching 'triggers' in '%s' took %s ms", room.name, task.timeTotal * 1000))),
        batchingTasks,
        {room = room}
    )

    return roomCache[room.name].triggers.result
end

function celesteRender.drawTriggers(room, triggers, viewport)
    local batch = celesteRender.getTriggerBatch(room, triggers, viewport)

    batch:draw()
end

local depthBatchingFunctions = {
    {"Background Tiles", "tilesBg", celesteRender.getTilesBgBatch, tilesBgDepth},
    {"Background Decals", "decalsBg", celesteRender.getDecalsBgBatch, decalsBgDepth},
    {"Entities", "entities", celesteRender.getEntityBatch},
    {"Foreground Tiles", "tilesFg", celesteRender.getTilesFgBatch, tilesFgDepth},
    {"Foreground Decals", "decalsFg", celesteRender.getDecalsFgBatch, decalsFgDepth},
    {"Triggers", "triggers", celesteRender.getTriggerBatch, triggersDepth}
}

-- Force all non finished room batch tasks to finish
function celesteRender.forceRoomBatchRender(room, viewport)
    for i, data in ipairs(depthBatchingFunctions) do
        local description, key, func, depth = data[1], data[2], data[3], data[4]
        local result = func(room, room[key], viewport)
        local task = roomCache[room.name][key]

        if not result and task then
            tasks.processTask(task)
        end
    end
end

function celesteRender.getRoomBatches(room, viewport)
    roomCache[room.name] = roomCache[room.name] or {}

    if not roomCache[room.name].complete then
        local depthBatches = {}
        local done = true

        for i, data in ipairs(depthBatchingFunctions) do
            local description, key, func, depth = data[1], data[2], data[3], data[4]
            local batches = func(room, room[key], viewport)

            if batches then
                if depth then
                    depthBatches[depth] = batches

                else
                    for d, batch in pairs(batches) do
                        depthBatches[d] = batch
                    end
                end

            else
                done = false
            end
        end

        -- Not done, but all the tasks have been started
        -- Attempt to render other rooms while we wait
        if not done then
            return false
        end

        local orderedBatches = $()

        for depth, batches in pairs(depthBatches) do
            orderedBatches += {depth, batches}
        end

        orderedBatches := sortby(v -> v[1])
        orderedBatches := reverse
        orderedBatches := map(v -> v[2])

        roomCache[room.name].complete = orderedBatches
    end

    return roomCache[room.name].complete
end

local function drawRoomFromBatches(room, viewport, selected)
    local orderedBatches = celesteRender.getRoomBatches(room, viewport)

    if orderedBatches then
        for depth, batch <- orderedBatches do
            batch:draw()
        end
    end
end

-- Return the canvas if it is ready, otherwise make a task for it
local function getRoomCanvas(room, viewport, selected)
    local orderedBatches = celesteRender.getRoomBatches(room, viewport)

    roomCache[room.name] = roomCache[room.name] or {}

    if orderedBatches and not roomCache[room.name].canvas then
        roomCache[room.name].canvas = tasks.newTask(
            function(task)
                local canvas = love.graphics.newCanvas(room.width or 0, room.height or 0)

                canvas:renderTo(function()
                    for depth, batch <- orderedBatches do
                        batch:draw()
                    end
                end)

                tasks.update(canvas)
            end,
            nil,
            batchingTasks,
            {room = room}
        )
    end

    return roomCache[room.name].canvas and roomCache[room.name].canvas.result
end

function celesteRender.drawRoom(room, viewport, selected, visible)
    -- Getting the canvas starts background drawing tasks
    -- This should start regardless of the room being visible or not
    local redrawRoom = selected or ALWAYS_REDRAW_UNSELECTED_ROOMS
    local canvas = not redrawRoom and getRoomCanvas(room, viewport, selected)

    if visible then
        local roomX = room.x or 0
        local roomY = room.y or 0

        local width = room.width or 40 * 8
        local height = room.height or 23 * 8

        local roomVisibleWidth, roomVisibleHeight = viewportHandler.getRoomVisibleSize(room, viewport)

        local backgroundColor = celesteRender.getRoomBackgroundColor(room, selected)
        local borderColor = celesteRender.getRoomBorderColor(room, selected)

        viewportHandler.drawRelativeTo(roomX, roomY, function()
            drawing.callKeepOriginalColor(function()
                love.graphics.setColor(backgroundColor)
                love.graphics.rectangle("fill", 0, 0, width, height)

                love.graphics.setColor(borderColor)
                love.graphics.rectangle("line", 0, 0, width, height)
            end)

            if redrawRoom then
                -- Invalidate the canvas, so it is updated properly when the selected room changes
                -- TODO - Move into code responsible for changing selected room?

                celesteRender.invalidateRoomCache(room.name, "canvas")
                drawRoomFromBatches(room, viewport, selected)

            else
                if canvas then
                    -- No need to draw the canvas if we can only see the border
                    if roomVisibleWidth > 2 and roomVisibleHeight > 2 then
                        love.graphics.draw(canvas)
                    end
                end
            end
        end)
    end
end

function celesteRender.drawFiller(filler, viewport)
    local x = filler.x * 8
    local y = filler.y * 8

    local width = filler.width * 8
    local height = filler.height * 8

    viewportHandler.drawRelativeTo(x, y, function()
        drawing.callKeepOriginalColor(function()
            love.graphics.setColor(colors.fillerColor)
            love.graphics.rectangle("fill", 0, 0, width, height)
        end)
    end)
end

function celesteRender.drawMap(state)
    if state.map then
        local map = state.map
        local viewport = state.viewport

        if viewport.visible then
            for i, filler in ipairs(map.fillers) do
                if viewportHandler.fillerVisible(filler, viewport) then
                    celesteRender.drawFiller(filler, viewport)
                end
            end

            for i, room in ipairs(map.rooms) do
                local roomVisible = viewportHandler.roomVisible(room, viewport)

                if ALLOW_NON_VISIBLE_BACKGROUND_DRAWING or roomVisible then
                    celesteRender.drawRoom(room, viewport, room == state.selectedRoom, roomVisible)
                end
            end
        end
    end
end

return celesteRender