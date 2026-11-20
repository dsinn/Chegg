-- Computer opponent. Plays `player` on `board` through the same functions the
-- UI uses, one action at a time. Thinking runs in a coroutine that is given a
-- few milliseconds per frame, so the game keeps drawing while it decides.

local sim        = require'ai.sim'
local greedy     = require'ai.greedy'
local montecarlo = require'ai.montecarlo'
local planner    = require'ai.planner'
local replysearch = require'ai.replysearch'

local ai = {}
ai.__index = ai

-- Difficulty presets. Tune these to change how strong each level plays.
-- Strengths were measured in chegg-headless with the tuned weights in
-- ai/eval.lua; each step is roughly 100-200 Elo.
--   strategy     'greedy' (best single action), 'planner' (beam search over
--                the turn's actions), 'reply' (plans turns, checks the
--                opponent's replies, uses worker threads; ai/replysearch.lua)
--                or 'montecarlo' (ai/montecarlo.lua; at the budgets Lua
--                affords it plays worse than greedy).
--   noise        random +-points added to each scored position; more noise
--                means more mistakes.
--   beam, depth  planner and reply: positions kept per step, actions planned.
--   candidates   reply only: plans whose replies are checked.
--   spread       reply only: how differently each shortlisted plan must place
--                the AI's pieces (see ai/replysearch.lua); 0 = just the best.
--   samples      reply only: re-deals of the hidden cards per reply check.
--   replyBeam, replyDepth
--                reply only: the turn planner that plays the opponent's reply
--                (finds "move, then attack"); without them, Greedy.
--   minimax      reply only: instead, search the opponent's reply turn at
--                replyBeam x replyDepth and assume the worst outcome for the
--                AI (the way people punish pieces left in reach).
--   guided       minimax only: rank the opponent's partial replies by the
--                damage they set up against the AI, so combos whose first
--                step looks harmless (a frog pull, then the kill) are found.
--   actionDelay  seconds between visible actions, so a human can follow.
ai.levels = {
    easy = {
        strategy = 'greedy',
        noise = 20,
        actionDelay = 0.5,
    },
    medium = {
        strategy = 'greedy',
        noise = 8,
        actionDelay = 0.4,
    },
    hard = {
        strategy = 'reply',
        beam = 8,
        depth = 10,
        candidates = 12,
        spread = 8,
        samples = 4,
        replyBeam = 4,
        replyDepth = 8,
        minimax = true,
        guided = true,
        actionDelay = 0.3,
    },
}

-- The computer's decks: a varied pool of strong decks, one picked at random
-- each game. Found by a MAP-Elites deck search in chegg-headless (the best deck
-- for each pair of most-used minions, 2026-11-20); the comment on each is its
-- win rate for the planner against random decks.
ai.decks = {
    {'zombie', 'zombie', 'zombie', 'zombie', 'creeper', 'creeper', 'creeper', 'pufferfish', 'pufferfish', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'phantom', 'box'}, -- 87%
    {'zombie', 'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'pufferfish', 'pufferfish', 'golem', 'golem', 'skeleton', 'skeleton', 'blaze', 'blaze', 'phantom'}, -- 87%
    {'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'pufferfish', 'golem', 'skeleton', 'skeleton', 'skeleton', 'blaze', 'slime', 'wither'}, -- 83%
    {'zombie', 'zombie', 'golem', 'golem', 'golem', 'golem', 'skeleton', 'skeleton', 'skeleton', 'blaze', 'phantom', 'phantom', 'farlander', 'parrot', 'wither'}, -- 83%
    {'zombie', 'zombie', 'creeper', 'golem', 'golem', 'frog', 'skeleton', 'skeleton', 'blaze', 'phantom', 'phantom', 'farlander', 'farlander', 'farlander', 'slime'}, -- 83%
    {'zombie', 'creeper', 'golem', 'frog', 'frog', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton'}, -- 83%
    {'zombie', 'zombie', 'zombie', 'zombie', 'zombie', 'pig', 'pufferfish', 'frog', 'frog', 'skeleton', 'skeleton', 'phantom', 'phantom', 'phantom', 'slime'}, -- 83%
    {'zombie', 'zombie', 'pig', 'pufferfish', 'golem', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'blaze', 'phantom', 'phantom', 'phantom', 'parrot'}, -- 83%
    {'creeper', 'golem', 'golem', 'golem', 'frog', 'frog', 'frog', 'skeleton', 'skeleton', 'skeleton', 'phantom', 'phantom', 'phantom', 'farlander', 'farlander'}, -- 82%
    {'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'pig', 'golem', 'blaze', 'wither'}, -- 82%
    {'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'rabbit', 'golem', 'frog', 'phantom', 'farlander'}, -- 81%
    {'creeper', 'pufferfish', 'golem', 'golem', 'frog', 'frog', 'frog', 'skeleton', 'skeleton', 'blaze', 'blaze', 'blaze', 'phantom', 'phantom', 'phantom'}, -- 81%
}

function ai.randomDeck()
    return table.copy(ai.decks[love.math.random(1, #ai.decks)])
end

local SLICE = 0.012       -- seconds of thinking per frame
local MAX_ACTIONS = 40    -- safety net: actions per turn before forcing the end
local TURN_START_DELAY = 0.7

function ai.new(level, board, player)
    local self = setmetatable({}, ai)
    self.level = ai.levels[level] and level or 'easy'
    self.params = ai.levels[self.level]
    self.board = board
    self.player = player
    self.rng = love.math.newRandomGenerator(os.time())
    self.delay = 0
    self.thinkTime = 0
    self.sliceStart = 0
    self.ctx = {
        check = function()
            if love.timer.getTime()-self.sliceStart>SLICE then coroutine.yield() end
        end,
        -- Gives up the rest of this frame (while worker threads think).
        wait = function() coroutine.yield() end,
        outOfTime = function()
            local now = self.thinkTime+(love.timer.getTime()-self.sliceStart)
            return now>(self.params.timeBudget or math.huge)
        end,
    }
    return self
end

local function gameOver(board)
    return sim.isOver(board)
end

function ai:placeKing()
    local b, me = self.board, self.player
    local backRow = me==b.otherplayer and 1 or b.rows
    local options = {}
    for x=3, b.cols-2 do
        if b:canSummonAt(me, 'king', x, backRow) then options[#options+1] = x end
    end
    if options[1] then
        return {k='summon', card='king', x=options[self.rng:random(1, #options)], y=backRow}
    end
    for y=1, b.rows do
        for x=1, b.cols do
            if b:canSummonAt(me, 'king', x, y) then return {k='summon', card='king', x=x, y=y} end
        end
    end
end

function ai:decide()
    local b, me = self.board, self.player
    if b.turn<=0 then
        -- Opening: place the king, then pass.
        if table.find(me.hand, 'king') and not sim.findKing(me) then
            return self:placeKing()
        end
        return {k='end'}
    end
    if self.params.strategy=='greedy' then
        return greedy.choose(b, me, self.params, self.ctx, self.rng)
    elseif self.params.strategy=='planner' then
        return planner.choose(b, me, self.params, self.ctx, self.rng)
    elseif self.params.strategy=='reply' then
        return replysearch.choose(b, me, self.params, self.ctx, self.rng, self)
    end
    return montecarlo.choose(b, me, self.params, self.ctx, self.rng)
end

function ai:perform(action)
    local b, me = self.board, self.player
    action = action or {k='end'}
    local ok = sim.apply(b, me, action)
    self.actionsThisTurn = self.actionsThisTurn+1
    if (not ok or self.actionsThisTurn>=MAX_ACTIONS)
    and not gameOver(b) and b:isActivePlayer(me) and b:canEndTurn(me) then
        b:endTurn(me)
    end
    self.delay = self.params.actionDelay
end

function ai:isThinking()
    return self.co~=nil
end

function ai:update(dt)
    local b, me = self.board, self.player
    if gameOver(b) or not b:isActivePlayer(me) then
        self.co, self.turnSeen = nil, nil
        return
    end
    if self.turnSeen~=b.turn then
        self.turnSeen = b.turn
        self.actionsThisTurn = 0
        self.delay = math.max(self.delay, TURN_START_DELAY)
    end
    if self.delay>0 then
        self.delay = self.delay-dt
        return
    end

    if not self.co then
        self.thinkTime = 0
        self.co = coroutine.create(function() return self:decide() end)
    end
    self.sliceStart = love.timer.getTime()
    sounds.muted = true
    local ok, result = coroutine.resume(self.co)
    sounds.muted = false
    self.thinkTime = self.thinkTime+(love.timer.getTime()-self.sliceStart)
    if not ok then
        local trace = debug.traceback(self.co, result)
        self.co = nil
        error('AI error: '..trace, 0)
    end
    if coroutine.status(self.co)~='dead' then return end
    self.co = nil
    self:perform(result)
end

return ai
