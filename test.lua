require "include"
require "common.game_state"
require "common.scene_manager"
require "common.music_manager"
require "common.sound_manager"
require "common.input_manager"

local _state = {} -- ignore this

-- import types
local SimulationHandler = require "egg_fluid_simulation.test.simulation_handler"

-- handler instance
local simulation_handler = SimulationHandler() -- simulation instance

-- list of batch ids
local batch_ids = {} -- Table

-- configs, we will be swapping between these at run time
local solid_white_config, solid_yolk_config = simulation_handler:get_white_config(), simulation_handler:get_yolk_config()
local fluid_config = {}

fluid_config.min_mass = 1 / 20
fluid_config.max_mass = 1 - 1 / 20
fluid_config.follow_strength = 0.8
fluid_config.min_radius = 3.5
fluid_config.max_radius = 3.5
fluid_config.damping = 0.05
fluid_config.motion_blur = 0

-- update loop
love.update = function(delta)
    _state.performance_measure_start()

    -- get position to move the batches towards
    local x, y = _state.get_target_position()

    -- update target position
    for _, batch in ipairs(batch_ids) do
        simulation_handler:set_target_position(batch, x, y)
    end

    -- update handler
    simulation_handler:update(delta)

    _state.performance_measure_end()
    _state.update(delta)
end

love.draw = function()
    love.graphics.clear(0.5, 0.5, 0.5, 1)
    _state.draw_path()

    -- draw all batches
    love.graphics.setColor(1, 1, 1, 1)
    simulation_handler:draw()

    _state.draw_overlay()
end

-- swap between configs
_state.current_egg_config = true
_state.swap_egg_config = function()
    local which = _state.current_egg_config
    if which == true then
        simulation_handler:set_white_config(fluid_config)
        simulation_handler:set_yolk_config(fluid_config)
    elseif which == false then
        simulation_handler:set_white_config(solid_white_config)
        simulation_handler:set_yolk_config(solid_yolk_config)
    end

    _state.current_egg_config = not _state.current_egg_config
end

--- ### internals, ignore everything below ###

local Path = require "egg_fluid_simulation.test.path"

-- input handling
local _new_batch_key = "j"
local _remove_batch_key = "h"
local _regenerate_path_key = "g"
local _swap_egg_config_key = "l"

love.keypressed = function(which)
    if which == _new_batch_key then
        local w, h = love.graphics.getDimensions()
        local mid_w, mid_h = w / 2, h / 2
        local rx, ry = w * 0.5, h * 0.5

        local corner = math.wrap(#batch_ids, 4)
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

        table.insert(batch_ids, 1, simulation_handler:add(
            x, y
        ))
    elseif which == _remove_batch_key then
        local last = batch_ids[1]
        if last ~= nil then
            table.remove(batch_ids, 1)
            simulation_handler:remove(last)
        end
    elseif which == _regenerate_path_key then
        _state.regenerate_path()
    elseif which == _swap_egg_config_key then
        _state.swap_egg_config()
    end
end

-- performance measurement
_state.performance_history = {}
_state.performance_history_n = 100
_state.performance_sum = 0
for _ = 1, _state.performance_history_n do
    table.insert(_state.performance_history, 0)
end

function _state.performance_measure_start()
    _state.performance_before = love.timer.getTime()
end

function _state.performance_measure_end()
    local elapsed = love.timer.getTime() - _state.performance_before

    _state.performance_sum = _state.performance_sum - _state.performance_history[1] + elapsed
    table.insert(_state.performance_history, elapsed)
    table.remove(_state.performance_history, 1)
end

function _state.draw_overlay()
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print(string.format([[
Press `%s` to spawn a new batch
Press `%s` to remove the last batch
Press `%s` to generate a new path
Press `%s` to swap configs
]],
        string.upper(_new_batch_key),
        string.upper(_remove_batch_key),
        string.upper(_regenerate_path_key),
        string.upper(_swap_egg_config_key)
    ), 10, 10)

    local font = love.graphics.getFont()
    local text = string.format("FPS: %.1f | # Particles: %i | Frame Usage: %.5f%%",
        love.timer.getFPS(), -- current fps
        simulation_handler:get_n_particles(),
        ((_state.performance_sum / #_state.performance_history) / love.timer.getFPS()) * 100
    )
    local text_w = love.graphics.getFont():getWidth(text)
    love.graphics.print(text, love.graphics.getWidth() - text_w - 10, 10)
end

_state.elapsed = 0
_state.velocity = 300
_state.path_t = 0
_state.path = Path(0, 0, 0, 0)

function _state.regenerate_path()
    local points = {}
    local w, h = love.graphics.getDimensions()
    local mid_w, mid_h = w / 2, h / 2
    local rx = math.min(w, h) / 2.5
    local ry = rx

    local n_points = math.floor(love.math.random(3, 7))
    local offset = love.math.random(0, 2 * math.pi)
    for i = 1, n_points do
        local angle = (i - 1) / n_points * 2 * math.pi + offset
        table.insert(points, mid_w + math.cos(angle) * rx)
        table.insert(points, mid_h + math.sin(angle) * ry)
    end

    table.insert(points, points[1])
    table.insert(points, points[2])

    _state.path:create_from_and_reparameterize(points)
end

love.load = function()
    _state.regenerate_path()
end

function _state.update(delta)
    if _state.path == nil then _state.regenerate_path() end
    _state.elapsed = _state.elapsed + delta
    _state.path_t = math.fract(_state.elapsed / (_state.path:get_length() / _state.velocity))
end

function _state.get_target_position()
    return _state.path:at(_state.path_t)
end

function _state.draw_path()
    local black, white = { 0, 0, 0, 1 }, { 1, 1, 1, 1 }
    local line_width = 3
    local points = _state.path:get_points()

    love.graphics.setLineJoin("none")

    local draw_circles = function()
        for i = 1, #points, 2 do
            local x = points[i+0]
            local y = points[i+1]
            love.graphics.circle("fill", x, y, love.graphics.getLineWidth())
        end
    end

    love.graphics.setLineWidth(line_width + 1.5)
    love.graphics.setColor(black)
    love.graphics.line(points)

    love.graphics.setLineWidth(line_width)
    love.graphics.setColor(white)
    love.graphics.line(points)

    local x, y = _state.get_target_position()
    local radius = 10

    love.graphics.setLineWidth(line_width + 1.5)
    love.graphics.setColor(black)
    love.graphics.circle("line", x, y, radius)
    draw_circles()

    love.graphics.setLineWidth(line_width)
    love.graphics.setColor(white)
    love.graphics.circle("fill", x, y, radius)
    draw_circles()
end
