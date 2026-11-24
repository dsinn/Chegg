local menu = {}
menu.__index = menu

-- Vertical offsets (px) from the window's centre to the top of each element.
menu.layout = {
    deckEditor = -76, vsHumanLabel = -7, directIp = 24,
    vsAiLabel = 93, aiGrid = 124, quit = 294,
}

function menu:new()
    setmetatable(self, menu)

    local savedDeck = love.filesystem.getInfo'decks/deck.lua'

    -- One centred column, as in the mock-up: deck editor, 'vs human' (direct ip),
    -- 'vs ai' (a 2x2 grid of levels), quit. Offsets are from the window's vertical centre.
    local colWidth, gap, rowHeight = 300, 10, 60
    local function centreX() return love.graphics.getWidth()/2-colWidth/2 end
    local function centreY() return love.graphics.getHeight()/2 end
    local function wideButton(top, text, press, activeIf)
        return {
            xy = function() return centreX(), centreY()+top end,
            widthheight = function() return colWidth, rowHeight end,
            press = press,
            text = text,
            activeIf = activeIf,
        }
    end

    self.activepreview = require'preview'.new{
        buttons = {
            wideButton(menu.layout.deckEditor, 'deck editor', function() setMode(require'uis.deckbuild'.new{}) end),
            wideButton(menu.layout.directIp, 'direct ip', function()
                if not savedDeck then return end
                setMode(require'uis.lobby'.new{
                    deck = love.filesystem.load'decks/deck.lua'(),
                })
            end, function() return savedDeck end),
            wideButton(menu.layout.quit, 'quit', function() love.event.push'quit' end),
        }
    }

    -- Single player: the AI levels in a 2x2 grid under a 'vs ai' label.
    local function startVsComputer(level)
        if not savedDeck then return end
        setMode(require'uis.game'.new{
            deck = love.filesystem.load'decks/deck.lua'(),
            isStartingPlayer = love.math.random(1, 2)==1,
            opponentType = 'ai',
            opponentDeck = require'ai'.randomDeck(level),
            aiLevel = level,
            seed = love.math.random(1, 9999999),
        })
    end
    local cellWidth = (colWidth-gap)/2
    for i, level in ipairs{'peaceful', 'medium', 'easy', 'hard'} do
        local col, row = (i-1)%2, math.floor((i-1)/2)
        table.insert(self.activepreview.buttons, {
            xy = function()
                return centreX()+col*(cellWidth+gap), centreY()+menu.layout.aiGrid+row*(rowHeight+gap)
            end,
            widthheight = function() return cellWidth, rowHeight end,
            press = function() startVsComputer(level) end,
            text = level,
            activeIf = function() return savedDeck end,
        })
    end
    return self
end

local labelFont = love.graphics.newImageFont('text.png', ' abcdefghijklmnopqrstuvwxyz1234567890+-/().,:;|')
labelFont:setFilter('nearest', 'nearest')

-- The whole logo (crown, title and subtitle) is one image.
local logo = love.graphics.newImage('cardshark.png')
logo:setFilter('nearest', 'nearest')

function menu:draw()
    love.graphics.clear(1/2,1/2,1/2)
    love.graphics.setColor(1,1,1)
    love.graphics.draw(logo, love.graphics.getWidth()/2, 10, 0, 2, 2, logo:getWidth()/2, 0)
    love.graphics.setColor(0,0,0)
    for label, offset in pairs{['vs human']=menu.layout.vsHumanLabel, ['vs ai']=menu.layout.vsAiLabel} do
        love.graphics.printf(label, labelFont, 0, love.graphics.getHeight()/2+offset, love.graphics.getWidth()/2, 'center', 0, 2, 2)
    end
    love.graphics.setColor(1,1,1)
    if self.activepreview then self.activepreview:draw() end
end

function menu:mousemoved(x, y, xDelta, yDelta, istouch)
    local intercepted
    if self.activepreview then intercepted = self.activepreview:mousemoved(x, y, xDelta, yDelta, istouch, intercepted) end
end

function menu:mousepressed(x, y, button, istouch, presses)
    local intercepted
    if self.activepreview then intercepted = self.activepreview:mousepressed(x, y, button, istouch, presses, intercepted) end
end

function menu:mousereleased(x, y, button, istouch, presses)
    local intercepted
    if self.activepreview then intercepted = self.activepreview:mousereleased(x, y, button, istouch, presses, intercepted) end
end

return menu
