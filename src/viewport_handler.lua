local inputDevice = require("input_device")
local utils = require("utils")

local viewportHandler = {}

local movementButton = 2

local viewport = {
    x = 0,
    y = 0,

    scale = 1,

    width = love.graphics.getWidth(),
    height = love.graphics.getHeight(),

    visible = true
}

viewportHandler.viewport = viewport

function viewportHandler.roomVisible(room, viewport)
    local actuallX = viewport.x / viewport.scale
    local actuallY = viewport.y / viewport.scale

    local actuallWidth = viewport.width / viewport.scale
    local actuallHeight = viewport.height / viewport.scale

    local cameraRect = {x = actuallX, y = actuallY, width = actuallWidth, height = actuallHeight}
    local roomRect = {x = room.x, y = room.y, width = room.width, height = room.height}

    return utils.aabbCheck(cameraRect, roomRect)
end

function viewportHandler.getMousePosition()
    if love.mouse.isCursorSupported() then
        return love.mouse.getX(), love.mouse.getY()

    else
        return viewport.width / 2, viewport.height / 2
    end
end

function viewportHandler.zoomIn()
    local mouseX, mouseY = viewportHandler.getMousePosition()

    viewport.scale *= 2
    viewport.x = viewport.x * 2 + mouseX
    viewport.y = viewport.y * 2 + mouseY
end

function viewportHandler.zoomOut()
    local mouseX, mouseY = viewportHandler.getMousePosition()

    viewport.scale /= 2
    viewport.x = (viewport.x - mouseX) / 2
    viewport.y = (viewport.y - mouseY) / 2
end

function viewportHandler.addDevice()
    inputDevice.newInputDevice{
        keypressed = function(key, scancode, isrepeat)
            if key == "+" and not isrepeat then
                viewportHandler.zoomIn()

            elseif key == "-" and not isrepeat then
                viewportHandler.zoomOut()

            elseif key == "w" or key == "up" then
                viewport.y -= 8

            elseif key == "a" or key == "left" then
                viewport.x -= 8

            elseif key == "s" or key == "down" then
                viewport.y += 8

            elseif key == "d" or key == "right" then
                viewport.x += 8
            end
        end,

        mousedragmoved = function(dx, dy, button, istouch)
            if button == movementButton then
                viewport.x -= dx
                viewport.y -= dy
            end
        end,

        mousemoved = function(x, y, dx, dy, istouch)
            if istouch then
                viewport.x -= dx
                viewport.y -= dy
            end
        end,

        resize = function(width, height)
            viewport.width = width
            viewport.height = height
        end,

        wheelmoved = function(dx, dy)
            if dy > 0 then
                viewportHandler.zoomIn()

            elseif dy < 0 then
                viewportHandler.zoomOut()
            end
        end,

        visible = function(visible)
            viewport.visible = visible
        end
    }
end

return viewportHandler