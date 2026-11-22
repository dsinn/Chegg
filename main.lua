local activeMode

-- Launch options, after the game folder:
--   --turns   show the raw turn number used by the AI's game logs ('log turn N'),
--             to refer to moments when studying them (ai/gamelog.lua)
--   --deck X  the computer's deck, instead of a random one from its level's pool
--             (ai.decks for Medium, ai.easyDecks for Easy and Peaceful):
--             a number (that deck of the pool), a card name (a random pool deck
--             holding it, e.g. --deck sniffer), or 15 comma-separated cards
LaunchOptions = {}

function love.load(args)
    args = args or {}
    for i, a in ipairs(args) do
        if a=='--turns' then LaunchOptions.showLogTurns = true end
        if a=='--deck' then LaunchOptions.aiDeck = args[i+1] end
    end
    require'utils'
    require'sounds'

    spriteAtlas = love.graphics.newImage'sprites.png'
    spriteAtlas:setFilter('nearest', 'nearest')

    spriteSize = 50
    function genQuad(xi, yi)
        return love.graphics.newQuad((xi-1)*spriteSize, (yi-1)*spriteSize, spriteSize, spriteSize, spriteAtlas)
    end

    activeMode = require'uis.mainmenu'.new{}
end

function setMode(mode)
    activeMode = mode or activeMode
end

function love.update(delta)
    if activeMode and activeMode.update then
        activeMode:update(delta)
    end
end

function love.draw()
    if activeMode then
        activeMode:draw()
    end
end

function love.mousemoved(x, y, xDelta, yDelta, istouch)
    if activeMode and activeMode.mousemoved then
        activeMode:mousemoved(x, y, xDelta, yDelta, istouch)
    end
end

function love.mousepressed(x, y, button, istouch, presses)
    if activeMode and activeMode.mousepressed then
        activeMode:mousepressed(x, y, button, istouch, presses)
    end
end

function love.mousereleased(x, y, button, istouch, presses)
    if activeMode and activeMode.mousereleased then
        activeMode:mousereleased(x, y, button, istouch, presses)
    end
end

function love.wheelmoved(x, y)
    if activeMode and activeMode.wheelmoved then
        activeMode:wheelmoved(x, y)
    end
end

function love.keypressed(...)
    if activeMode and activeMode.keypressed then
        activeMode:keypressed(...)
    end
end

function love.textinput(...)
    if activeMode and activeMode.textinput then
        activeMode:textinput(...)
    end
end

function love.quit()
    if EnetDisconnect and EnetDisconnect() then
        EnetHandle()
    end
end

