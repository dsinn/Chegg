local menu = {}
menu.__index = menu

function menu:new()
    setmetatable(self, menu)

    local savedDeck = love.filesystem.getInfo'decks/deck.lua'

    self.activepreview = require'preview'.new{
        buttons = {
            {
                xy = function() return love.graphics.getWidth()/2-100, love.graphics.getHeight()/2-30 end,
                widthheight = function() return 200, 60 end,
                press = function() setMode(require'uis.deckbuild'.new{}) end,
                text = savedDeck and 'edit deck' or 'create deck',
            },
            {
                xy = function() return love.graphics.getWidth()/2-100, love.graphics.getHeight()/2+40 end,
                widthheight = function() return 200, 60 end,
                press = function()
                    if not savedDeck then return end
                    setMode(require'uis.lobby'.new{
                        deck = love.filesystem.load'decks/deck.lua'(),
                    })
                end,
                text = 'play',
                activeIf = function() return savedDeck end,
            },
            {
                xy = function() return love.graphics.getWidth()/2-100, love.graphics.getHeight()/2+250 end,
                widthheight = function() return 200, 50 end,
                press = function() love.event.push'quit' end,
                text = 'quit',
            },
        }
    }

    -- Single player: one button per AI difficulty, under a 'vs computer' label.
    local function startVsComputer(level)
        if not savedDeck then return end
        setMode(require'uis.game'.new{
            deck = love.filesystem.load'decks/deck.lua'(),
            isStartingPlayer = love.math.random(1, 2)==1,
            opponentType = 'ai',
            opponentDeck = require'ai'.randomDeck(),
            aiLevel = level,
            seed = love.math.random(1, 9999999),
        })
    end
    for i, level in ipairs{'peaceful', 'easy', 'medium'} do
        table.insert(self.activepreview.buttons, {
            xy = function() return love.graphics.getWidth()/2-215+(i-1)*145, love.graphics.getHeight()/2+165 end,
            widthheight = function() return 140, 60 end,
            press = function() startVsComputer(level) end,
            text = level,
            activeIf = function() return savedDeck end,
        })
    end
    return self
end

local text = love.graphics.newImageFont('bigtext.png', ' abcdefghijklmnopqrstuvwxyz!?')
text:setFilter('nearest', 'nearest')

local crown = genQuad(1, 1)

function menu:draw()
    love.graphics.clear(1/2,1/2,1/2)
    love.graphics.setColor(0,0,0)
    love.graphics.printf('chegg', text, 0, 100, love.graphics.getWidth()/2, 'center', 0, 2, 2)
    love.graphics.setColor(1,1,1)
    love.graphics.draw(spriteAtlas, crown, love.graphics.getWidth()/2, 60, 0, 2, 2, 35, 25)
    love.graphics.setColor(0,0,0)
    love.graphics.printf('vs computer', text, 0, love.graphics.getHeight()/2+125, love.graphics.getWidth()/2, 'center', 0, 2, 2)
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
