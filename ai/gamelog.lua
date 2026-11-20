-- Game logs for games against the computer, so they can be replayed and
-- studied in chegg-headless (`cargo run --release --bin replay -- <log>`).
--
-- A log is plain text, one record per line:
--   chegg-log 1
--   date 2026-11-20 14:03:11
--   seed <random generator state when the game began>
--   bottom P1|P2                 the player at the bottom of the screen
--   computer P1|P2 <level>       one line per computer player
--   settings P1|P2 key=value...  that level's settings (ai/init.lua)
--   deck P1|P2 <card>.<card>...  decks in their starting order
--   start <state>
--   then for every action, from either side:
--   act P1|P2 <action> t=<seconds since the start>
--   state <state after it>
--   and at the end: result P1|P2|none
-- Actions and states use chegg-headless's notation (src/notation.rs):
-- 'S card x y' summon, 'M fx fy x y' move, 'A fx fy x y' attack, 'E' end turn.

local gamelog = {}

local function opt(v)
    if v==nil then return '-' end
    return tostring(v)
end

local function seat(board, player)
    return player==board.players[1] and 'P1' or 'P2'
end

-- The full position, as chegg-headless's state_to_string prints it.
function gamelog.state(board)
    local parts = {'T'..board.turn}
    for i, p in ipairs(board.players) do
        local s = {}
        for _, pc in ipairs(p.summons) do s[#s+1] = pc.pos[1]..'.'..pc.pos[2] end
        parts[#parts+1] = ('P%d:%s,%d,%d,%d,h=%s,d=%s,s=%s'):format(
            i, p==board.localplayer and 'B' or 'T', p.mana, p.manaMax, p.dead and 1 or 0,
            table.concat(p.hand, '.'), table.concat(p.deck, '.'), table.concat(s, ';'))
    end
    local cells = {}
    for x=1, board.cols do
        for y=1, board.rows do
            local pc = board:getLivingPieceAt(x, y)
            if pc then
                cells[#cells+1] = ('%d,%d,%s,%d,%d,%s,%s,%s'):format(
                    x, y, pc.type, pc.player==board.players[1] and 1 or 2, pc.summonTurn,
                    opt(pc.lastMoved), opt(pc.lastSpecialed), opt(pc.attackAs))
            end
        end
    end
    parts[#parts+1] = 'G:'..table.concat(cells, ';')
    return table.concat(parts, '|')
end

-- Starts logging `board`'s game. Call it before the first action.
--   rng        the players' random generator (ai/rng.lua), for its state
--   computers  {[player] = level} for each computer player
--   write      function(line) that stores one line
--   clock      optional function returning seconds, for the t= stamps
-- Wraps the board's action methods on this board only (the AI's simulation
-- copies are separate tables), and logs each one that changes the game.
-- Actions that happen inside another (a King's summon ending the turn, a
-- defeat ending it) are part of that action, not logged on their own.
function gamelog.attach(board, rng, computers, write, clock)
    clock = clock or os.clock
    local t0 = clock()
    write('chegg-log 1')
    write('date '..os.date('%Y-%m-%d %H:%M:%S'))
    write('seed '..rng:getState())
    write('bottom '..seat(board, board.localplayer))
    for i, p in ipairs(board.players) do
        if computers[p] then
            write(('computer P%d %s'):format(i, computers[p]))
            -- The level's settings (ai/init.lua), since they change between versions.
            local lv = require'ai'.levels[computers[p]]
            if lv then
                local kv = {}
                for k, v in pairs(lv) do kv[#kv+1] = k..'='..tostring(v) end
                table.sort(kv)
                write(('settings P%d %s'):format(i, table.concat(kv, ' ')))
            end
        end
    end
    for i, p in ipairs(board.players) do
        write(('deck P%d %s'):format(i, table.concat(p.deck, '.')))
    end
    local last = gamelog.state(board)
    write('start '..last)

    local depth, finished = 0, false
    local function wrap(name, describe)
        local original = board[name]
        board[name] = function(b, player, ...)
            depth = depth+1
            local text = depth==1 and describe(player, ...)
            local results = {pcall(original, b, player, ...)}
            depth = depth-1
            if not results[1] then error(results[2], 0) end
            if text then
                local now = gamelog.state(b)
                if now~=last then
                    last = now
                    write(('act %s %s t=%.1f'):format(seat(b, player), text, clock()-t0))
                    write('state '..now)
                    if not finished and (b.players[1].dead or b.players[2].dead) then
                        finished = true
                        local p1, p2 = b.players[1].dead, b.players[2].dead
                        write('result '..((p1 and p2) and 'none' or p1 and 'P2' or 'P1'))
                    end
                end
            end
            return unpack(results, 2, table.maxn(results))
        end
    end
    wrap('summonAt', function(_, card, x, y) return ('S %s %d %d'):format(card, x, y) end)
    wrap('movePiece', function(_, piece, x, y)
        if not (piece and x and y) then return end
        return ('M %d %d %d %d'):format(piece.pos[1], piece.pos[2], x, y)
    end)
    wrap('attackWithPiece', function(_, piece, x, y)
        if not (piece and x and y) then return end
        return ('A %d %d %d %d'):format(piece.pos[1], piece.pos[2], x, y)
    end)
    wrap('endTurn', function() return 'E' end)
end

-- Where the game keeps logs: logs/<date>-<level>.txt in its save folder.
function gamelog.toFile(level)
    if not love.filesystem.getInfo('logs') then love.filesystem.createDirectory('logs') end
    local name = ('logs/%s-%s.txt'):format(os.date('%Y%m%d-%H%M%S'), level)
    return function(line) love.filesystem.append(name, line..'\n') end
end

return gamelog
