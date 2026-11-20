-- Beam search over one player's actions within a turn, keeping the action
-- sequence that leads to each position. Used by the reply search
-- (ai/replysearch.lua) through its worker jobs (ai/jobs.lua). Mirrors
-- `search_turn` in chegg-headless (src/ai/reply.rs).

local sim  = require'ai.sim'
local eval = require'ai.eval'

local turnsearch = {}

-- Everything that matters within a turn, as far as players[idx] can see:
-- the board, everyone's mana and card counts, and idx's own hand.
function turnsearch.key(b, idx)
    local parts = {b.turn}
    for x=1, b.cols do
        for y=1, b.rows do
            local pc = b:getLivingPieceAt(x, y)
            if pc then
                parts[#parts+1] = ('%d,%d,%s,%d,%d,%d,%s'):format(x, y, pc.type,
                    pc.player==b.players[1] and 1 or 2,
                    pc.lastMoved==b.turn and 1 or 0,
                    pc.lastSpecialed==b.turn and 1 or 0,
                    pc.attackAs or '')
            end
        end
    end
    for _, p in ipairs(b.players) do
        parts[#parts+1] = ('%d/%d/%d/%s'):format(p.mana, #p.hand, #p.deck, p.dead and 1 or 0)
    end
    local hand = {}
    for i, card in ipairs(b.players[idx].hand) do hand[i] = card end
    table.sort(hand)
    parts[#parts+1] = table.concat(hand, '.')
    return table.concat(parts, '|')
end

local function append(list, v)
    local n = {}
    for i=1, #list do n[i] = list[i] end
    n[#n+1] = v
    return n
end

-- Searches from `root` (already re-dealt from players[idx]'s point of view).
-- Returns every distinct position reached, best score first, as
-- {board, seq (actions), keys (turnsearch.key before each action), score}.
-- With `part` and `parts`, only first actions numbered part, part+parts, ...
-- are explored, so several workers can split one search. See search's
-- `scorer` below for ranking positions some other way.
-- `scorer(board)` ranks positions (higher is kept); by default players[idx]'s
-- own evaluation at the end of its turn.
-- With `tactical`, every move or attack is also tried with each follow-up
-- by the same piece that takes a piece (sim.captureActions), and the pair
-- joins the same beam step: a move that sets up a capture (step then shoot,
-- a parrot copying a range before attacking) doesn't score better on its
-- own, so a narrow beam would drop it before the capture could follow.
-- Mirrors `search_turn_ext` in chegg-headless.
local function aliveCount(p)
    local n = 0
    for _, pc in ipairs(p.summons) do
        if pc:isAlive() then n = n+1 end
    end
    return n
end

-- With `noSummons`, summoning is left out, except a Wither (its summon
-- explodes): for modelling the opponent's reply, where summons crowd the
-- beam out of a second capture.
function turnsearch.search(root, idx, beam, depth, ctx, part, parts, scorer, tactical, noSummons)
    scorer = scorer or function(b) return eval.score(b, b.players[idx], 'opp') end
    local rootNode = {
        board = root,
        seq = {},
        keys = {},
        score = scorer(root),
    }
    local all = {rootNode}
    local seen = {[turnsearch.key(root, idx)] = true}
    local frontier = {rootNode}
    for d=1, depth do
        local nextFrontier = {}
        for _, node in ipairs(frontier) do
            local b = node.board
            local p = b.players[idx]
            if not sim.isOver(b) and b:isActivePlayer(p) then
                local before = turnsearch.key(b, idx)
                local n = 0
                for _, a in ipairs(sim.actions(b, p)) do
                    if a.k~='end' and not (noSummons and a.k=='summon' and a.card~='wither') then
                        n = n+1
                        if d>1 or not parts or (n-1)%parts==part-1 then
                            local c = sim.clone(b)
                            if sim.apply(c, c.players[idx], a) then
                                local key = turnsearch.key(c, idx)
                                if not seen[key] then
                                    seen[key] = true
                                    local child = {
                                        board = c,
                                        seq = append(node.seq, a),
                                        keys = append(node.keys, before),
                                    }
                                    local ax, ay
                                    if a.k=='move' then ax, ay = a.x, a.y
                                    elseif a.k=='attack' then ax, ay = a.fx, a.fy end
                                    if tactical and ax and not sim.isOver(c) and c:isActivePlayer(c.players[idx]) then
                                        local victim = c:getOpponent(c.players[idx])
                                        local victimIdx = sim.playerIndex(c, victim)
                                        local victims = aliveCount(victim)
                                        for _, f in ipairs(sim.captureActions(c, c.players[idx], ax, ay)) do
                                            local cc = sim.clone(c)
                                            if sim.apply(cc, cc.players[idx], f)
                                                and (sim.isOver(cc) or aliveCount(cc.players[victimIdx])<victims) then
                                                local key2 = turnsearch.key(cc, idx)
                                                if not seen[key2] then
                                                    seen[key2] = true
                                                    local pair = {
                                                        board = cc,
                                                        seq = append(child.seq, f),
                                                        keys = append(child.keys, key),
                                                        score = scorer(cc),
                                                    }
                                                    all[#all+1] = pair
                                                    nextFrontier[#nextFrontier+1] = pair
                                                end
                                            end
                                            ctx.check()
                                        end
                                    end
                                    child.score = scorer(c)
                                    all[#all+1] = child
                                    nextFrontier[#nextFrontier+1] = child
                                end
                            end
                        end
                        ctx.check()
                    end
                end
            end
        end
        if #nextFrontier==0 then break end
        table.sort(nextFrontier, function(x, y) return x.score>y.score end)
        for i=#nextFrontier, beam+1, -1 do nextFrontier[i] = nil end
        frontier = nextFrontier
    end
    table.sort(all, function(x, y) return x.score>y.score end)
    return all
end

return turnsearch
