-- TODO: remove
require "include"
require "common.scene_manager"
require "common.game_state"
require "common.scene_manager"
require "common.music_manager"
require "common.sound_manager"
require "common.input_manager"
-- TODO

if egg == nil then egg = {} end
egg.SimulationHandler = require "egg_fluid_simulation.simulation_handler"

local simulation_handler = nil -- simulation instance
local egg_batches = {} -- Table<SimulationHandlerBatchID>

-- TODO: remove
local colors = {
    rt.Palette.RED,
    rt.Palette.MINT,
    rt.Palette.BLUE,
    rt.Palette.ORANGE
}

DEBUG_INPUT:signal_connect("keyboard_key_pressed", function(_, which)
    if which == "h" then
        simulation_handler:_reinitialize()
        egg_batches = {}
    elseif which == "j" then
        local w, h = love.graphics.getDimensions()
        local mid_w, mid_h = w / 2, h / 2
        local rx, ry = w * 0.5, h * 0.5
        local white_r, white_g, white_b, white_a = rt.Palette.GRAY_10:unpack()
        local yolk_r, yolk_g, yolk_b, yolk_a = colors[math.wrap(#egg_batches, #colors)]:unpack()

        local corner = math.wrap(#egg_batches, 4)
        local x, y = mid_w, mid_h
        if corner == 1 then
            x, y = mid_w - rx, mid_h - ry
        elseif corner == 2 then
            x, y = mid_w + rx, mid_h - ry
        elseif corner == 3 then
            x, y = mid_w + rx, mid_h + ry
        elseif corner == 4 then
            x, y = mid_w - rx, mid_h + ry
        end

        table.insert(egg_batches, 1, simulation_handler:add(
            x, y,
            50, 15,
            { white_r, white_g, white_b, white_a },
            { yolk_r, yolk_g, yolk_b, yolk_a }
        ))
    elseif which == "g" then
        local last = egg_batches[1]
        if last ~= nil then
            table.remove(egg_batches, 1)
            simulation_handler:remove(last)
        end
    end
end)
-- TODO

-- ### MAIN ### --

-- initialization
love.load = function()
    -- create the handler instance, it currently holds no eggs
    simulation_handler = egg.SimulationHandler()
end

-- update loop
love.update = function(delta)
    local x, y = love.mouse.getPosition()

    for batch in values(egg_batches) do
        simulation_handler:set_target_position(batch, x, y)
    end

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
    rt.Palette.GRAY_5:bind()
    love.graphics.rectangle("fill", x, y, w, h)

    -- draw all egg batches
    love.graphics.setColor(1, 1, 1, 1)
    simulation_handler:draw()

    --[[
    local cutoff_z = 0
    simulation_handler:draw_below(0)
    local sprite_w, sprite_h = 80, 50
    love.graphics.rectangle("fill",
        x + 0.5 * w - 0.5 * sprite_w, y + 0.5 * h - 0.5 * sprite_h,
        sprite_w, sprite_h
    )
    simulation_handler:draw_above(0)
    ]]--
end
