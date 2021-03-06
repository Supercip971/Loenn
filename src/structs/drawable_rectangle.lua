-- A spritebatchable rectangle drawing implementation
-- Stretches a 1x1 white pixel to achieve the same effect

local utils = require("utils")
local drawing = require("drawing")
local drawableSprite = require("structs.drawable_sprite")

local drawableRectangle = {}

drawableRectangle.tintingPixelFilename = "assets/1x1-tinting-pixel.png"
drawableRectangle.tintingPixel = love.graphics.newImage(drawableRectangle.tintingPixelFilename)
drawableRectangle.fakeTintingPixelImageMeta = {
    x = 0,
    y = 0,

    width = 1,
    height = 1,

    offsetX = 0,
    offsetY = 0,
    realWidth = 1,
    realHeight = 1,

    image = drawableRectangle.tintingPixel,
    filename = drawableRectangle.tintingPixelFilename,

    quad = love.graphics.newQuad(0, 0, 1, 1, 1, 1),

    loadedAt = os.time()
}

local function getDrawableSpriteForRectangle(x, y, width, height, color)
    local data = {}

    data.x = x
    data.y = y

    data.scaleX = width
    data.scaleY = height

    data.justificationX = 0
    data.justificationY = 0

    data.color = utils.getColor(color)

    return drawableSprite.spriteFromMeta(drawableRectangle.fakeTintingPixelImageMeta, data)
end


local drawableRectangleMt = {}
drawableRectangleMt.__index = {}

function drawableRectangleMt.__index:getRectangleRaw()
    return self.x, self.y, self.width, self.height
end

function drawableRectangleMt.__index:getRectangle()
    return utils.rectangle(self:getRectangle())
end

function drawableRectangleMt.__index:drawRectangle(mode, color)
    mode = mode or self.mode or "fill"
    color = color or self.color

    if color then
        drawing.callKeepOriginalColor(function()
            love.graphics.setColor(color)
            love.graphics.rectangle(mode, self:getRectangleRaw())
        end)

    else
        love.graphics.rectangle(mode, self:getRectangleRaw())
    end
end

-- Gets a drawable sprite, using a stretched version of the 1x1 tintable
function drawableRectangleMt.__index:getDrawableSprite()
    if self.mode == "fill" or self.mode == "nil" then
        return getDrawableSpriteForRectangle(self.x, self.y, self.width, self.height, self.color)

    elseif self.mode == "line" then
        -- TODO - Implement
    end
end

function drawableRectangleMt.__index:draw()
    self:drawRectangle(self.mode, self.color)
end

-- Accepting rectangles on `x` argument, or passing in the values manually
function drawableRectangle.fromRectangle(mode, color, x, y, width, height)
    local rectangle = {
        _type = "drawableRectangle"
    }

    rectangle.color = color
    rectangle.mode = mode

    if type(x) == "table" then
        rectangle.x = x.x or x[1]
        rectangle.y = x.y or x[2]

        rectangle.width = x.width or x[3]
        rectangle.height = x.height or x[4]

    else
        rectangle.x = x
        rectangle.y = y

        rectangle.width = width
        rectangle.height = height
    end

    return setmetatable(rectangle, drawableRectangleMt)
end

return drawableRectangle