-- Headless game copies for the AI: clone a board, list a player's legal
-- actions on it, and apply them. All rules come from board/pieces/player, so
-- the AI can never disagree with the real game about what is legal.
--
-- An action is a plain table:
--   {k='summon', card=type, x=, y=}
--   {k='move',   fx=, fy=, x=, y=}   (includes attack-moves and Enderman swaps)
--   {k='attack', fx=, fy=, x=, y=}
--   {k='end'}
-- Actions use coordinates only, so one action can be applied to any copy.

local Board  = require'board'
local Piece  = require'pieces'
local Player = require'player'

local sim = {}

local function copyList(t)
    local n = {}
    for i=1, #t do n[i] = t[i] end
    return n
end

-- Re-deal what `viewer` can't know: the order of its own deck, and which of
-- the opponent's remaining cards are in hand versus in the deck.
local function determinize(nb, viewer, rng)
    table.randomSort(rng, viewer.deck)
    for _, p in ipairs(nb.players) do
        if p~=viewer then
            local keep, pool = {}, {}
            for _, card in ipairs(p.hand) do
                -- An unplaced king is public knowledge; never shuffle it away.
                table.insert(card=='king' and keep or pool, card)
            end
            local handSize = #pool
            for _, card in ipairs(p.deck) do pool[#pool+1] = card end
            table.randomSort(rng, pool)
            p.hand, p.deck = keep, {}
            for i, card in ipairs(pool) do
                if i<=handSize then
                    p.hand[#p.hand+1] = card
                else
                    p.deck[#p.deck+1] = card
                end
            end
        end
    end
end

-- Copies `board` into a silent board (no sounds, particles or network) that
-- shares no mutable state with the original. Dead pieces are left out.
-- If `viewer` is given, hidden information is re-dealt from its point of view.
-- Returns the new board.
function sim.clone(board, viewer, rng)
    local nb = setmetatable({
        rows = board.rows,
        cols = board.cols,
        homeRows = board.homeRows,
        turn = board.turn,
        grid = {},
        players = {},
        silent = true,
    }, Board)
    for x=1, nb.cols do
        local col = {}
        for y=1, nb.rows do col[y] = {} end
        nb.grid[x] = col
    end

    local playerMap = {}
    for i, p in ipairs(board.players) do
        local np = setmetatable({
            mana = p.mana,
            manaMax = p.manaMax,
            dead = p.dead,
            hand = copyList(p.hand),
            deck = copyList(p.deck),
            summons = {},
            rng = rng or p.rng,
            board = nb,
        }, Player)
        playerMap[p] = np
        nb.players[i] = np
    end
    nb.localplayer = playerMap[board.localplayer]
    nb.otherplayer = playerMap[board.otherplayer]

    local pieceMap = {}
    for x=1, board.cols do
        for y=1, board.rows do
            for _, pc in ipairs(board.grid[x][y]) do
                if pc:isAlive() then
                    local np = setmetatable(table.copy(pc), Piece)
                    np.board = nb
                    np.player = playerMap[pc.player]
                    np.pos = {x, y}
                    table.insert(nb.grid[x][y], np)
                    pieceMap[pc] = np
                end
            end
        end
    end
    -- Keep each player's summon order, since start/end-of-turn hooks run in it.
    for p, np in pairs(playerMap) do
        for _, s in ipairs(p.summons) do
            if pieceMap[s] then table.insert(np.summons, pieceMap[s]) end
        end
    end

    if viewer and rng then
        determinize(nb, playerMap[viewer], rng)
    end
    return nb
end

function sim.playerIndex(board, player)
    return table.find(board.players, player)
end

function sim.findKing(player)
    for _, pc in ipairs(player.summons) do
        if pc.type=='king' and pc:isAlive() then return pc end
    end
end

function sim.isOver(board)
    for _, p in ipairs(board.players) do
        if p.dead then return true end
    end
    return false
end

-- Every legal action for `player` right now, in the same terms as the UI:
-- a square a piece can travel to is a move, otherwise an attack if allowed.
function sim.actions(board, player)
    local acts = {}
    if player.dead or not board:isActivePlayer(player) then return acts end
    local cols, rows = board.cols, board.rows

    local seen = {}
    for _, card in ipairs(player.hand) do
        if not seen[card] then
            seen[card] = true
            if board:canSummon(player, card) then
                for y=1, rows do
                    for x=1, cols do
                        if board:canSummonAt(player, card, x, y) then
                            acts[#acts+1] = {k='summon', card=card, x=x, y=y}
                        end
                    end
                end
            end
        end
    end

    for _, pc in ipairs(player.summons) do
        if pc:isAlive() and (pc:canMove() or pc:canSpecial()) then
            local px, py = pc.pos[1], pc.pos[2]
            local r = math.max(pc.moveRange or 0, pc.attackRange or 0)
            for y=math.max(1, py-r), math.min(rows, py+r) do
                for x=math.max(1, px-r), math.min(cols, px+r) do
                    if pc:canTravelTo(x, y) then
                        acts[#acts+1] = {k='move', fx=px, fy=py, x=x, y=y}
                    elseif pc:canAttackTo(x, y) then
                        acts[#acts+1] = {k='attack', fx=px, fy=py, x=x, y=y}
                    end
                end
            end
        end
    end

    if board:canEndTurn(player) then
        acts[#acts+1] = {k='end'}
    end
    return acts
end

-- Applies `action` for `player` through the normal game functions.
-- Returns true if it was legal and happened.
function sim.apply(board, player, action)
    local k = action.k
    if k=='end' then
        if not board:canEndTurn(player) then return false end
        board:endTurn(player)
        return true

    elseif k=='summon' then
        local card = action.card
        if not (board:canSummon(player, card) and board:canSummonAt(player, card, action.x, action.y)) then
            return false
        end
        local i = table.find(player.hand, card)
        if not i then return false end
        table.remove(player.hand, i)
        return board:summonAt(player, card, action.x, action.y) and true or false

    else
        if not (board:isWithinBounds(action.fx, action.fy) and board:isWithinBounds(action.x, action.y)) then
            return false
        end
        local pc = board:getLivingPieceAt(action.fx, action.fy)
        if not pc or pc.player~=player then return false end
        if k=='move' then
            return board:movePiece(player, pc, action.x, action.y) and true or false
        elseif k=='attack' then
            return board:attackWithPiece(player, pc, action.x, action.y) and true or false
        end
    end
    return false
end

function sim.describe(a)
    if a.k=='summon' then return ('summon %s at %d,%d'):format(a.card, a.x, a.y) end
    if a.k=='end' then return 'end turn' end
    return ('%s %d,%d -> %d,%d'):format(a.k, a.fx, a.fy, a.x, a.y)
end

return sim
