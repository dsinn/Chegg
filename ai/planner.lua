-- Turn planner: a beam search over the AI's own actions within one turn.
--
-- Greedy scores each single action as if the turn ended straight after it,
-- so it can't see combinations ("move into range, then attack"). The planner
-- explores sequences: from the current position it tries every action, keeps
-- the `beam` best resulting positions (scored as if the turn ended there),
-- expands those again, and so on for up to `depth` actions. The best position
-- seen anywhere, including ending the turn now, decides the first action. The
-- AI plans again after every action, since draws can change the picture.
--
-- It beats Greedy by about 90 Elo at beam 4, depth 8.

local sim  = require'ai.sim'
local eval = require'ai.eval'

local planner = {}

-- Everything that matters within a turn, so positions reached by different
-- move orders count once.
local function positionKey(b)
    local parts = {b.turn}
    for x=1, b.cols do
        for y=1, b.rows do
            local pc = b:getLivingPieceAt(x, y)
            if pc then
                parts[#parts+1] = ('%d%d%s%d%d%d%s'):format(x, y, pc.type,
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
    return table.concat(parts, ',')
end

function planner.choose(board, me, params, ctx, rng)
    local idx = sim.playerIndex(board, me)
    local noise = params.noise or 0
    local function jitter() return noise*(rng:random()*2-1) end

    local root = sim.clone(board, me, rng)
    local best = {k='end'}
    local bestScore = eval.score(root, root.players[idx], 'opp')+jitter()
    local beam = {{board=root}}
    local seen = {[positionKey(root)] = true}

    for _=1, params.depth do
        local nextBeam = {}
        for _, node in ipairs(beam) do
            local b = node.board
            local p = b.players[idx]
            if not sim.isOver(b) and b:isActivePlayer(p) then
                for _, a in ipairs(sim.actions(b, p)) do
                    if a.k~='end' then
                        local c = sim.clone(b, nil, rng)
                        local cp = c.players[idx]
                        if sim.apply(c, cp, a) then
                            local key = positionKey(c)
                            if not seen[key] then
                                seen[key] = true
                                local s = eval.score(c, cp, 'opp')+jitter()
                                local first = node.first or a
                                if s>=eval.WIN then return first end -- a winning line
                                if s>bestScore then best, bestScore = first, s end
                                nextBeam[#nextBeam+1] = {board=c, first=first, score=s}
                            end
                        end
                    end
                    ctx.check()
                end
            end
        end
        if #nextBeam==0 then break end
        table.sort(nextBeam, function(x, y) return x.score>y.score end)
        for i=#nextBeam, params.beam+1, -1 do nextBeam[i] = nil end
        beam = nextBeam
    end
    return best
end

return planner
