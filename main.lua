require "include" -- TODO
require "common.scene_manager" -- TODO

if egg == nil then egg = {} end
egg.SimulationHandler = require "egg_fluid_simulation.simulation_handler"

local simulation_handler = nil -- simulation instance
local egg_batches = {} -- Table<SimulationHandlerBatchID>
local debug_example_setting = {
    n_eggs = 5,
    egg_area = 50*50 -- px
}

-- ### MAIN ### --

-- initialization
love.load = function()
    -- create the handler instance, it currently holds no eggs
    simulation_handler = egg.SimulationHandler()

    -- add 5 egg batches, the return value is the batch id which we need
    egg_batches = {}
    for i = 1, debug_example_setting.n_eggs do
        -- add a batch, return value is batch id
        local batch_id = simulation_handler:add(debug_example_setting.egg_area or nil)

        -- store batch id for later
        table.insert(egg_batches, batch_id)
    end
end

-- update loop
love.update = function(delta)
    -- update all egg batches
    simulation_handler:update(delta)

    --[[
    -- alternative, only update certain badges
    simulation_handler:update(delta, egg_batches[1], egg_batches[3])
    ]]
end

-- draw callback
love.draw = function()
    -- get screen bounds
    local x, y, w, h = 0, 0, love.graphics.getDimensions()

    -- background
    love.graphics.setColor(0.3, 0.2, 0.3, 1)
    love.graphics.rectangle("fill", x, y, w, h)

    -- draw all egg batches
    simulation_handler:draw()

    -- TODO: z
    local cutoff_z = 0
    simulation_handler:draw_below(0)
    local sprite_w, sprite_h = 80, 50
    love.graphics.rectangle("fill",
        x + 0.5 * w - 0.5 * sprite_w, y + 0.5 * h - 0.5 * sprite_h,
        sprite_w, sprite_h
    )
    simulation_handler:draw_above(0)
end
