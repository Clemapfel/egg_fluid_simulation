require "egg_fluid_simulation.math"

--- @class egg.SimulationHandler
local SimulationHandler = {}

local default_settings = {
    egg_white = {
        particle_density = 1 / 4, -- n particles / px^2
        min_radius = 4,
        max_radius = 4,
        min_mass = 1,
        max_mass = 1,
    },

    egg_yolk = {
        particle_density = 1 / 8, -- n particles / px^2
        min_radius = 4,
        max_radius = 4,
        min_mass = 1,
        max_mass = 1
    }
}

--- @brief
function SimulationHandler:add(area)

end

--- @brief
function SimulationHandler:remove()

end

--- @brief
function SimulationHandler:list_ids()

end

--- @brief
function SimulationHandler:update(delta, ...)

end

--- @brief
function SimulationHandler:draw()

end

--- @brief
function SimulationHandler:draw_below(z_cutoff)

end

--- @brief
function SimulationHandler:draw_above(z_cutoff)

end

-- ### internals, never call functions below ## ---

--- @brief [internal]
function SimulationHandler._new(settings) -- sic, no :, self is returned instance, not type
    local self = {}

    self._settings = settings
    self._batches = {}

    return self
end

local _x = 1
local _y = 2
local _z = 3
local _radius = 4

--- @brief [internal]
function SimulationHandler:_new_batch(
    center_x, center_y,
    x_radius, y_radius,
    n_white_particles, n_yolk_particles
)
    local batch = {
        egg_white = {},
        egg_yolk = {}
    }

    local random_uniform = function(min, max)
        local t = love.math.random(0, 1)
        return math.mix(min, max, t)
    end

    local random_normal = function(min, max)
        local t = love.math.randomNormal(1, 0)
        return math.mix(min, max, t)
    end

    local add_particle = function(to_add_to, settings)

        local angle = random_uniform(0, 2 * math.pi)
        local x_distance = random_normal(0, x_radius)
        local y_distance = random_normal(0, y_radius)

        local x = center_x + math.cos(angle) * x_distance
        local y = center_y + math.sin(angle) * y_distance

        local t = random_uniform(0, 1)
        local mass = math.mix(settings.min_mass, settings.max_mass, t)
        local radius = math.mix(settings.min_radius, settings.max_radius, t)

        table.insert(to_add_to, {
            [_x] = x,
            [_y] = y,
            [_z] = 0,
            [_radius] =

        })
    end

    for _ = 1, n_white_particles do
        add_particle(batch.egg_white, default_settings.egg_white)
    end

    for _ = 1, n_yolk_particles do
        add_particle(batch.egg_yolk, default_settings.egg_yolk)
    end
end

--- @brief [internal] throw error with pretty printing
function SimulationHandler:_error(...)
    local message = { "[ERROR]" }

    -- get current line number, if possible
    local debug_line_number_acquired = false
    if debug ~= nil then
        local info = debug.getinfo(3, "Sl")
        if info ~= nil and info.short_src ~= nil and info.lastlinedefined ~= nil then
            table.insert(message, "In " .. info.short_src .. ":" .. info.lastlinedefined .. ": ")
            debug_line_number_acquired = true
        end
    end

    for i = 1, select("#", ...) do
        table.insert(message, select(i, ...))
    end

    -- write to error stream and flush and print to console immediately
    io.stderr:write(table.concat(message, " "))
    io.stderr:flush()
end

--- @brief [internal] assert function arguments to be of a specific type
function SimulationHandler:_assert(...)
    local should_exit = true

    local n = select("#", ...)
    if not n % 2 == 0 then
        self:_error("In SimulationHandler._assert: number of arguments is not a multiple of 2")
        return should_exit
    end

    for i = 1, n do
        local instance = select(i + 0, ...)
        local instance_type = select(i + 1, ...)
        if not type(instance) == instance_type then
            self:_error("for argument #", i, ": expected `", instance_type, "`, got `", instance_type, "`")
            return should_exit
        end
    end

    return not should_exit
end

-- return type object, which returns a simulation handler on call
return setmetatable(SimulationHandler, {
    __call = function(...)
        return setmetatable(SimulationHandler._new(...), {
            __index = SimulationHandler
        })
    end
})