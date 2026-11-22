-- Computer opponent. Plays `player` on `board` through the same functions the
-- UI uses, one action at a time. Thinking runs in a coroutine that is given a
-- few milliseconds per frame, so the game keeps drawing while it decides.

local sim        = require'ai.sim'
local greedy     = require'ai.greedy'
local peaceful   = require'ai.peaceful'
local montecarlo = require'ai.montecarlo'
local planner    = require'ai.planner'
local replysearch = require'ai.replysearch'
local turnsearch = require'ai.turnsearch'

local ai = {}
ai.__index = ai

-- Difficulty presets. Tune these to change how strong each level plays.
-- Peaceful is a training opponent that never fights (ai/peaceful.lua). Easy
-- and Medium were measured in chegg-headless with the tuned weights in
-- ai/eval.lua; Medium is several hundred Elo stronger.
--   strategy     'peaceful' (never attacks, minions close in), 'greedy' (best
--                single action), 'planner' (beam search over
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
--   tactical     minimax only: the reply search also tries each action with
--                every follow-up capture, so "step, then shoot" and "copy,
--                then shoot" are seen even when the step alone looks idle.
--   ownTactical  reply only: the same extension in the search over the AI's
--                own turn.
--   setups       with tactical/ownTactical: the extension also follows a
--                setup (a frog's pull, a parrot's copy) with the kills it
--                makes possible, by any piece in reach, so "pull, then hit
--                with another piece" is seen too.
--   vacate       with setups: also a frog's pull through a square one of the
--                mover's pieces just left (clearing the frog's line first).
--   refute       minimax only: when every plan loses the game to the reply
--                found for it, search the turn again assuming the opponent
--                plays those replies whenever they still work.
--   cautious     reply only: this many extra plans from a search that fears
--                leaving its pieces in reach 5x more (and values its own
--                material as much more), so quiet turns are weighed against
--                plans that all expose a piece.
--   replySummons minimax only: false leaves the opponent's summons out of
--                its reply (a Wither's still in: its summon explodes), so
--                the reply search spends its depth on captures.
--   ponder       reply only: think during the other player's turn. After
--                each of their actions it decides its own next turn as if
--                they ended theirs there, and uses that decision if they do.
--   actionDelay  seconds between visible actions, so a human can follow.
ai.levels = {
    peaceful = {
        strategy = 'peaceful',
        actionDelay = 0.5,
    },
    easy = {
        strategy = 'greedy',
        noise = 8,
        actionDelay = 0.4,
    },
    medium = {
        strategy = 'reply',
        beam = 12,
        depth = 10,
        candidates = 20,
        spread = 8,
        samples = 4,
        replyBeam = 4,
        replyDepth = 8,
        minimax = true,
        tactical = true,
        ownTactical = true,
        setups = true,
        vacate = true,
        refute = true,
        cautious = 4,
        replySummons = false,
        ponder = true,
        actionDelay = 0.3,
    },
}

-- The computer's decks: a varied pool of strong decks, one picked at random
-- each game. Most were found by a MAP-Elites deck search in chegg-headless
-- (the best deck for each pair of most-used minions, 2026-11-20). On
-- 2026-11-21 the pool was rebuilt around frogs after playtesting: Medium's
-- frog pulls set up its ranged attackers (Skeletons, Blazes) and Phantoms,
-- and the decks without them win far less. The Creeper-heavy rushes (3 to 11
-- Creepers) were dropped: against a player who keeps out of reach they can
-- only attack by walking into range, and frog-and-ranged decks beat every
-- one of them 98-100% with Medium. The comment on each deck is Medium's win
-- rate against random decks (reply 8:10:12 with weights/trade20-econ.txt, 50
-- games each, `decks rate`; about +-7%). Dropped with them: three decks with
-- one frog or none (Farlander/Phantom 56%, Skeleton/Phantom/Parrot 39%,
-- Golem/Wither/Parrot 32%). The Cat and Sniffer decks swap those two in for
-- the weakest cards; they pay off against a player who holds back.
-- On 2026-11-22 the zombie swarms (now Easy's) and the ten-Skeleton deck gave
-- way to four Skeleton/frog decks chosen by the user: 10+5 and 8+7, and 6+4
-- and 7+3 filled out from the best-rated fillers (in a separate 200-game run
-- where the first deck below scored 87%: 6+4 with 2 Golems and 3 Phantoms
-- 96.5%, 7+3 with 3 Golems, a Cat and a Sniffer 91%), then a Slime swapped
-- in for a Phantom and for two Golems respectively.
ai.decks = {
    {'creeper', 'golem', 'golem', 'golem', 'frog', 'frog', 'frog', 'skeleton', 'skeleton', 'skeleton', 'phantom', 'phantom', 'phantom', 'farlander', 'farlander'}, -- 99%
    {'cat', 'sniffer', 'golem', 'golem', 'golem', 'frog', 'frog', 'frog', 'skeleton', 'skeleton', 'skeleton', 'phantom', 'phantom', 'phantom', 'farlander'}, -- 92%
    {'cat', 'sniffer', 'zombie', 'golem', 'golem', 'frog', 'frog', 'frog', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'blaze', 'blaze', 'blaze'}, -- 91%
    {'zombie', 'zombie', 'golem', 'golem', 'frog', 'frog', 'frog', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'blaze', 'blaze', 'blaze'}, -- 91%
    {'golem', 'golem', 'frog', 'frog', 'frog', 'frog', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'phantom', 'phantom', 'slime'},
    {'cat', 'sniffer', 'golem', 'frog', 'frog', 'frog', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'phantom', 'slime'},
    {'frog', 'frog', 'frog', 'frog', 'frog', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton'},
    {'frog', 'frog', 'frog', 'frog', 'frog', 'frog', 'frog', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton'},
    {'creeper', 'pufferfish', 'golem', 'golem', 'frog', 'frog', 'frog', 'skeleton', 'skeleton', 'blaze', 'blaze', 'blaze', 'phantom', 'phantom', 'phantom'}, -- 80%
}

-- Easy's (and Peaceful's) decks: Medium's decks (added below), the swarms
-- Medium dropped, and themed decks for fun rather than strength. A quarter of
-- their games use a mixed deck instead (ai.mixedDeck below).
ai.easyDecks = {
    -- zombie swarms
    {'zombie', 'zombie', 'zombie', 'zombie', 'zombie', 'pig', 'pufferfish', 'frog', 'frog', 'skeleton', 'skeleton', 'phantom', 'phantom', 'phantom', 'slime'},
    {'zombie', 'zombie', 'zombie', 'zombie', 'cat', 'sniffer', 'pufferfish', 'frog', 'frog', 'skeleton', 'skeleton', 'phantom', 'phantom', 'phantom', 'slime'},
    -- creeper swarms
    {'zombie', 'zombie', 'zombie', 'zombie', 'creeper', 'creeper', 'creeper', 'pufferfish', 'pufferfish', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'phantom', 'box'},
    {'zombie', 'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'pufferfish', 'pufferfish', 'golem', 'golem', 'skeleton', 'skeleton', 'blaze', 'blaze', 'phantom'},
    {'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'creeper', 'pufferfish', 'golem', 'skeleton', 'skeleton', 'skeleton', 'blaze', 'slime', 'wither'},
    -- The End: Endermen, Phantoms and Shulkers
    {'farlander', 'farlander', 'farlander', 'farlander', 'farlander', 'phantom', 'phantom', 'phantom', 'phantom', 'phantom', 'box', 'box', 'box', 'box', 'box'},
    -- The Nether: Blazes, Withers and (wither) Skeletons
    {'skeleton', 'skeleton', 'skeleton', 'skeleton', 'skeleton', 'blaze', 'blaze', 'blaze', 'blaze', 'blaze', 'blaze', 'blaze', 'wither', 'wither', 'wither'},
    -- Swamp: Frogs, Slimes and Pufferfish
    {'pufferfish', 'pufferfish', 'pufferfish', 'pufferfish', 'pufferfish', 'frog', 'frog', 'frog', 'frog', 'frog', 'slime', 'slime', 'slime', 'slime', 'slime'},
}

-- Easy and Peaceful also play Medium's decks.
for _, d in ipairs(ai.decks) do table.insert(ai.easyDecks, 1, d) end

ai.deckPools = {peaceful = ai.easyDecks, easy = ai.easyDecks, medium = ai.decks}

-- How often Easy (and Peaceful) play a mixed deck instead of a pool deck.
ai.MIXED_DECK_CHANCE = 0.25

-- How often Peaceful plays an animal farm: each of its 15 cards drawn
-- uniformly at random from these animals.
ai.FARM_DECK_CHANCE = 0.25
ai.farmAnimals = {'pig', 'rabbit', 'cat', 'sniffer', 'parrot'}

function ai.farmDeck()
    local deck = {}
    for i = 1, 15 do deck[i] = ai.farmAnimals[love.math.random(1, #ai.farmAnimals)] end
    return deck
end

-- A deck with at most one of each minion: 15 of the 17 deck cards, at random.
function ai.mixedDeck()
    local kinds = {}
    for name, data in pairs(require'pieces'.getTypesData()) do
        if data.deck then kinds[#kinds+1] = name end
    end
    table.sort(kinds)
    for i = #kinds, 2, -1 do
        local j = love.math.random(1, i)
        kinds[i], kinds[j] = kinds[j], kinds[i]
    end
    local deck = {}
    for i = 1, math.min(15, #kinds) do deck[i] = kinds[i] end
    return deck
end

-- A deck from a `--deck` launch option (see main.lua), or nil and a reason:
-- a number picks that deck of ai.decks; a card name picks at random among
-- the decks holding it; 15 comma-separated card names are the deck itself.
function ai.deckFromOption(spec, pool)
    pool = pool or ai.decks
    local n = tonumber(spec)
    if n then
        if pool[n] then return table.copy(pool[n]) end
        return nil, ('there are only %d decks'):format(#pool)
    end
    local Piece = require'pieces'
    local function card(name)
        local data = Piece.getTypeData(name)
        return data and data.deck and name
    end
    if spec:find(',') then
        local deck = {}
        for name in spec:gmatch('[^,]+') do
            name = name:lower():match('^%s*(.-)%s*$')
            if not card(name) then return nil, ("'%s' isn't a deck card"):format(name) end
            deck[#deck+1] = name
        end
        if #deck~=15 then return nil, ('a deck needs 15 cards, not %d'):format(#deck) end
        return deck
    end
    local name = spec:lower()
    if not card(name) then return nil, ("'%s' isn't a deck card"):format(spec) end
    local holding = {}
    for _, d in ipairs(pool) do
        for _, c in ipairs(d) do
            if c==name then holding[#holding+1] = d break end
        end
    end
    if #holding==0 then return nil, ('no deck in this pool holds a %s'):format(name) end
    return table.copy(holding[love.math.random(1, #holding)])
end

-- A deck for an AI of the given level: the --deck launch option if it names
-- one, otherwise a random deck from that level's pool (for Easy and Peaceful,
-- sometimes a mixed deck instead; for Peaceful, sometimes an animal farm).
function ai.randomDeck(level)
    local pool = ai.deckPools[level] or ai.decks
    local spec = LaunchOptions and LaunchOptions.aiDeck
    if spec then
        local deck, why = ai.deckFromOption(spec, pool)
        if deck then return deck end
        print(('--deck %s ignored: %s'):format(spec, why))
    end
    if level=='peaceful' and love.math.random()<ai.FARM_DECK_CHANCE then
        return ai.farmDeck()
    end
    if pool==ai.easyDecks and love.math.random()<ai.MIXED_DECK_CHANCE then
        return ai.mixedDeck()
    end
    return table.copy(pool[love.math.random(1, #pool)])
end

local SLICE = 0.012       -- seconds of thinking per frame
local MAX_ACTIONS = 40    -- safety net: actions per turn before forcing the end
local TURN_START_DELAY = 0.7

function ai.new(level, board, player)
    local self = setmetatable({}, ai)
    self.level = ai.levels[level] and level or 'peaceful'
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
    if self.params.strategy=='peaceful' then
        return peaceful.choose(b, me, self.params, self.ctx, self.rng)
    elseif self.params.strategy=='greedy' then
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

-- Runs `co` for this frame's slice. Returns true and its result once it has
-- finished.
function ai:resume(co)
    self.sliceStart = love.timer.getTime()
    sounds.muted = true
    local ok, result = coroutine.resume(co)
    sounds.muted = false
    self.thinkTime = self.thinkTime+(love.timer.getTime()-self.sliceStart)
    if not ok then
        error('AI error: '..debug.traceback(co, result), 0)
    end
    if coroutine.status(co)~='dead' then return false end
    return true, result
end

-- Pondering (the `ponder` setting): while the other player takes their turn,
-- decide our next turn as if they ended theirs now, on a copy of the board.
-- Each of their actions starts it again from the new position. The ponder is
-- adopted at the start of our turn when the position is the one it expected
-- (same pieces, mana and hand, so the same card drawn), and dropped
-- otherwise; workers drop its abandoned jobs (ai/pool.lua).
function ai:ponderUpdate()
    local b, me = self.board, self.player
    local idx = sim.playerIndex(b, me)
    local from = turnsearch.key(b, idx)
    local p = self.ponder
    if not p or p.from~=from then
        p = {from=from}
        self.ponder = p
        local opp = b:getOpponent(me)
        if b.turn>0 and opp and b:isActivePlayer(opp) and b:canEndTurn(opp) then
            -- The copy gets its own generator: start-of-turn effects must not
            -- advance the game's.
            local c = sim.clone(b, nil, love.math.newRandomGenerator(self.rng:random(1, 1073741823)))
            local cme = c.players[idx]
            sim.apply(c, c.players[sim.playerIndex(b, opp)], {k='end'})
            if not sim.isOver(c) and c:isActivePlayer(cme) then
                p.expect = turnsearch.key(c, idx)
                p.memory = {}
                p.co = coroutine.create(function()
                    return replysearch.choose(c, cme, self.params, self.ctx, self.rng, p.memory)
                end)
            end
        end
    end
    if p.co and not p.done then
        local done, result = self:resume(p.co)
        if done then p.done, p.result = true, result end
    end
end

-- At the start of our turn: continue or use the ponder if it expected this
-- position.
-- Counts, for tests: turns that used a ponder (finished or still running)
-- and turns whose ponder expected a different position.
function ai:adoptPonder()
    local p = self.ponder
    self.ponder = nil
    if not (p and p.co) then return end
    if p.expect~=turnsearch.key(self.board, sim.playerIndex(self.board, self.player)) then
        self.ponderMisses = (self.ponderMisses or 0)+1
        return
    end
    self.ponderHits = (self.ponderHits or 0)+1
    if p.done then
        self.plan = p.memory.plan
        self.pending = {p.result}
    else
        self.co, self.coMemory = p.co, p.memory
    end
end

function ai:update(dt)
    local b, me = self.board, self.player
    if gameOver(b) or not b:isActivePlayer(me) then
        self.co, self.coMemory, self.pending, self.turnSeen = nil, nil, nil, nil
        if self.params.ponder and not gameOver(b) then
            self:ponderUpdate()
        else
            self.ponder = nil
        end
        return
    end
    if self.turnSeen~=b.turn then
        self.turnSeen = b.turn
        self.actionsThisTurn = 0
        self.delay = math.max(self.delay, TURN_START_DELAY)
        self.thinkTime = 0
        self:adoptPonder()
    end
    -- Thinking goes on during the delay between visible actions.
    if self.delay>0 then self.delay = self.delay-dt end

    if not self.co and not self.pending then
        self.thinkTime = 0
        self.co = coroutine.create(function() return self:decide() end)
    end
    if self.co then
        local done, result = self:resume(self.co)
        if done then
            if self.coMemory then self.plan = self.coMemory.plan end
            self.co, self.coMemory, self.pending = nil, nil, {result}
        end
    end
    if self.pending and self.delay<=0 then
        local action = self.pending[1]
        self.pending = nil
        self:perform(action)
    end
end

return ai
