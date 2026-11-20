-- Easy: try every legal action on a copy of the board, score the result as if
-- the turn ended straight after, and take the best one. Ending the turn is
-- one of the options, so it stops once nothing beats standing still.

local sim  = require'ai.sim'
local eval = require'ai.eval'

local greedy = {}

-- Score of the position after doing `action` and then ending the turn,
-- from `me`'s point of view. Nil if the action turns out to be illegal.
function greedy.scoreAction(board, me, action, rng)
    local idx = sim.playerIndex(board, me)
    local c = sim.clone(board, me, rng)
    local cme = c.players[idx]
    if action.k~='end' and not sim.apply(c, cme, action) then return nil end
    return eval.score(c, cme, 'opp')
end

function greedy.choose(board, me, params, ctx, rng)
    local best, bestScore
    for _, a in ipairs(sim.actions(board, me)) do
        local s = greedy.scoreAction(board, me, a, rng)
        if s then
            -- Noise makes Easy beatable: close calls go either way.
            s = s+(params.noise or 0)*(rng:random()*2-1)
            if not bestScore or s>bestScore then
                best, bestScore = a, s
            end
        end
        ctx.check()
    end
    return best
end

return greedy
