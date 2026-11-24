-- Converts a board to a string of plain data and back, so positions can be
-- sent to the AI's worker threads (which can't share tables or functions).
-- Only living pieces are kept; a decoded board is silent, like sim.clone's.

local Board = require'board'
local Piece = require'pieces'
local Player = require'player'

local snapshot = {}

local function copyList(t)
    local n = {}
    for i=1, #t do n[i] = t[i] end
    return n
end

function snapshot.encode(board)
    local players, pieces = {}, {}
    for i, p in ipairs(board.players) do
        local summons = {}
        for _, pc in ipairs(p.summons) do
            if pc:isAlive() then
                pieces[#pieces+1] = {
                    type = pc.type,
                    owner = i,
                    x = pc.pos[1],
                    y = pc.pos[2],
                    summonTurn = pc.summonTurn,
                    lastMoved = pc.lastMoved,
                    lastSpecialed = pc.lastSpecialed,
                    attackAs = pc.attackAs,
                }
                summons[#summons+1] = #pieces
            end
        end
        players[i] = {
            mana = p.mana,
            manaMax = p.manaMax,
            dead = p.dead and true or false,
            hand = copyList(p.hand),
            deck = copyList(p.deck),
            bottom = p==board.localplayer,
            summons = summons,
        }
    end
    return table.serialize{
        turn = board.turn,
        rows = board.rows,
        cols = board.cols,
        homeRows = board.homeRows,
        players = players,
        pieces = pieces,
    }
end

function snapshot.decode(text)
    local chunk = assert(loadstring(text, 'snapshot'))
    local data = setfenv(chunk, {})()
    local nb = setmetatable({
        rows = data.rows,
        cols = data.cols,
        homeRows = data.homeRows,
        turn = data.turn,
        grid = {},
        players = {},
        silent = true,
    }, Board)
    for x=1, nb.cols do
        nb.grid[x] = {}
        for y=1, nb.rows do nb.grid[x][y] = {} end
    end
    for i, pd in ipairs(data.players) do
        local np = setmetatable({
            mana = pd.mana,
            manaMax = pd.manaMax,
            dead = pd.dead or nil,
            hand = pd.hand,
            deck = pd.deck,
            summons = {},
            board = nb,
        }, Player)
        nb.players[i] = np
        if pd.bottom then nb.localplayer = np else nb.otherplayer = np end
    end
    local made = {}
    for k, pd in ipairs(data.pieces) do
        local pc = Piece.restore{
            type = pd.type,
            board = nb,
            player = nb.players[pd.owner],
            pos = {pd.x, pd.y},
            summonTurn = pd.summonTurn,
            lastMoved = pd.lastMoved,
            lastSpecialed = pd.lastSpecialed,
            attackAs = pd.attackAs,
        }
        table.insert(nb.grid[pd.x][pd.y], pc)
        made[k] = pc
    end
    for i, pd in ipairs(data.players) do
        for _, k in ipairs(pd.summons) do
            table.insert(nb.players[i].summons, made[k])
        end
    end
    return nb
end

return snapshot
