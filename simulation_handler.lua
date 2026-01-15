local prefix = "egg_fluid_simulation" -- path prefix, change this depending on where the library is located

require(prefix .. ".math")

--- @class egg.SimulationHandler
local SimulationHandler = {}

--- @brief table of simulation parameters, this default is used for any setting not specified
local default_settings = {
    -- shader paths
    particle_texture_shader_path = prefix .. "/simulation_handler_particle_texture.glsl",
    threshold_shader_path = prefix .. "/simulation_handler_threshold.glsl",
    outline_shader_path = prefix .. "/simulation_handler_outline.glsl",

    -- overall fps, the simulation will be run at this fixed rate, regardless of fps
    step_delta = 1 / 60, -- seconds
    max_n_steps = 8, -- cf. update

    -- particle configs for egg white
    egg_white = {
        particle_density = 1 / 32, -- n particles / px^2
        min_radius = 4, -- px
        max_radius = 4, -- px
        min_mass = 1, -- fraction
        max_mass = 1, -- fraction
        damping = 0.7, -- in [0, 1], higher is more dampened

        color = { 253 / 255, 253 / 255, 255 / 255, 1 }, -- rgba, components in [0, 1]
        default_radius = 50, -- total radius of egg white at rest, px

        collision_strength = 1, -- in [0, 1]
        collision_overlap_fraction = 10, -- > 0

        cohesion_strength = 0.8, -- in [0, 1]
        cohesion_interaction_distance_fraction = 2,

        follow_strength = 0.99, -- in [0, 1]
    },

    -- particle configs for egg yolk
    egg_yolk = {
        particle_density = 1 / 64,
        min_radius = 4,
        max_radius = 4,
        min_mass = 1,
        max_mass = 1,
        damping = 0.5,

        color = { 255 / 255, 129 / 255, 0 / 255, 1 },
        default_radius = 16, -- total radius of yolk at rest, px

        collision_strength = 1, -- in [0, 1]
        collision_overlap_fraction = 1, -- > 0

        cohesion_strength = 0.8, -- in [0, 1]
        cohesion_interaction_distance_fraction = 2,

        follow_strength = 0, -- in [0, 1]
    },

    n_sub_steps = 1, -- number of solver sub steps

    -- render texture config
    canvas_msaa = 0, -- msaa for render textures
    particle_texture_padding = 3, -- px
    texture_format = "rgba8", -- love.PixelFormat
    particle_texture_resolution_factor = 4, -- fraction
    texture_scale = 4, -- fraction

    -- shader config
    composite_alpha = 0.5,

    threshold_shader_threshold = 0.5, -- in [0, 1]
    threshold_shader_smoothness = 0.001,

    texture_format = (function()
        -- texture format needs to have non [0, 1] range, find first available on this machine
        local available_formats
        if love.getVersion() >= 12 then
            available_formats = love.graphics.getTextureFormats({
                canvas = true
            })
        else
            available_formats = love.graphics.getCanvasFormats()
        end

        local texture_format = "rgba8"
        --[[ TODO
        for _, format in ipairs({
            "r32f",
            "r16f",
            "rg32f",
            "rg16f",
            "rgba32f",
            "rgba16f"
        }) do
            if available_formats[format] == true then
                texture_format = format
                break
            end
        end
        ]]

        return texture_format
    end)()
}

--- @brief add a new batch to the simulation
--- @overload fun(self: egg.SimulationHandler, x: number, y: number)
--- @param x number x position, px
--- @param y number y position, px
--- @param white_radius number? radius of the egg white, px
--- @param yolk_radius number? radius of egg yolk, px
--- @return number id of the new batch
function SimulationHandler:add(x, y, white_radius, yolk_radius)
    local white_settings = self._settings.egg_white
    local yolk_settings = self._settings.egg_yolk

    if white_radius == nil then white_radius = white_settings.default_radius end
    if yolk_radius == nil then
        local fraction = yolk_settings.default_radius / white_settings.default_radius
        yolk_radius = white_radius * fraction
    end

    self:_assert(
        x, "number",
        y, "number",
        white_radius, "number",
        yolk_radius, "number"
    )

    local white_area = math.pi * white_radius^2 -- area of a circle = pi * r^2
    local white_n_particles = math.ceil(white_settings.particle_density * white_area)

    local yolk_area = math.pi * yolk_radius^2
    local yolk_n_particles = math.ceil(yolk_settings.particle_density * yolk_area)

    local batch_id, batch = self:_new_batch(
        x, y,
        white_radius, white_radius, white_n_particles,
        yolk_radius, yolk_radius, yolk_n_particles
    )

    self._batch_id_to_batch[batch_id] = batch
    self._n_batches = self._n_batches + 1

    self._total_n_white_particles = self._total_n_white_particles + batch.n_white_particles
    self._total_n_yolk_particles = self._total_n_yolk_particles + batch.n_yolk_particles

    return batch_id
end

--- @brief removes a batch from the simulation
--- @param batch_id number id of the batch to remove, acquired from SimulationHandler.add
--- @return nil
function SimulationHandler:remove(batch_id)
    self:_assert(batch_id, "number")

    local batch = self._batch_id_to_batch[batch_id]
    if batch == nil then
        self:_error(false, "In SimulationHandler.remove: no batch with id `", batch_id, "`")
        return
    end

    self._batch_id_to_batch[batch_id] = nil
    self._n_batches = self._n_batches - 1
    self._total_n_white_particles = self._total_n_white_particles - batch.n_white_particles
    self._total_n_yolk_particles = self._total_n_yolk_particles - batch.n_yolk_particles

    -- env updated next step
end

--- @brief set the target position a batch should move to
--- @param batch_id number batch id returned by SimulationHandler.add
--- @param x number x coordinate, in px
--- @param y number y coordinate, in px
function SimulationHandler:set_target_position(batch_id, x, y)
    self:_assert(batch_id, "number", x, "number", y, "number")

    local batch = self._batch_id_to_batch[batch_id]
    if batch == nil then
        self:_error(false, "In SimulationHandler.set_target_position: no batch with id `", batch_id, "`")
    else
        batch.target_x = x
        batch.target_y = y
    end
end

--- @brief list the ids of all batches
--- @return number[] array of batch ids
function SimulationHandler:list_ids()
    local ids = {}
    for id, _ in pairs(self._batch_id_to_batch) do
        table.insert(ids, id)
    end
    return ids
end

--- @brief draw all supplied batches, or all if none supplied
--- @overload fun(self: egg.SimulationHandler)
--- @param batches number[]? array of batch ids
--- @return nil
function SimulationHandler:draw(batches)
    if batches ~= nil then
        self:_assert(batches, "table")
    end

    self:_draw()
end

--- @brief draw all particles below the z render priority
--- @overload fun(self: egg.SimulationHandler, z_cutoff: number)
--- @param z_cutoff number z cutoff value, usually < 0
--- @param batches number[]? array of batch ids to draw
--- @return nil
function SimulationHandler:draw_below(z_cutoff, batches)
    if batches ~= nil then
        self:_assert(
            z_cutoff, "number",
            batches, "table"
        )
    else
        self:_assert(
            z_cutoff, "number"
        )
    end

    -- TODO
end

--- @brief draw all particles above the z render priority
--- @overload fun(self: egg.SimulationHandler, z_cutoff: number)
--- @param z_cutoff number z cutoff value, usually > 0
--- @param batches number[]? array of batch ids to draw (default: all batches)
--- @return nil
function SimulationHandler:draw_above(z_cutoff, batches)
    if batches ~= nil then
        self:_assert(
            z_cutoff, "number",
            batches, "table"
        )
    else
        self:_assert(
            z_cutoff, "number"
        )
    end

    -- TODO
end

--- @brief
function SimulationHandler:update(delta, batches)
    if batches ~= nil then
        self:_assert(
            delta, "number",
            batches, "table"
        )
    else
        self:_assert(
            delta, "number"
        )
    end

    local settings = self._settings

    -- accumulate delta time, run sim at fixed framerate for better stability
    self._elapsed = self._elapsed + delta
    local step = debugger.get("step_delta") -- TODO settings.step_delta
    local n_steps = 0
    while self._elapsed >= step do
        self:_step(step)
        self._elapsed = self._elapsed - step

        -- safety check to prevent death spiral on lag frames
        n_steps = n_steps + 1
        if n_steps > settings.max_n_steps then
            self._elapsed = 0
            break
        end
    end
end

-- ### internals, never call any of the functions below ### --

--- @brief [internal] allocate a new instance
--- @param settings table? override settings
function SimulationHandler._new(settings) -- sic, no :, self is returned instance, not type
    if settings == nil then settings = default_settings end

    local self = setmetatable({}, {
        __index = SimulationHandler
    })

    if settings ~= default_settings then
        -- iterate through all keys in default settings, and assign new settings unless it already exists
        -- this way, the argument settings do not need to specify all parameters

        local seen = {}
        local function apply_default_settings(new_settings, defaults)
            for key, default_value in pairs(defaults) do
                if new_settings[key] == nil then
                    if type(default_value) == "table" then
                        new_settings[key] = {}
                        apply_default_settings(new_settings[key], default_value)
                    else
                        new_settings[key] = default_value
                    end
                elseif type(new_settings[key]) == "table" and type(default_value) == "table" then
                    apply_default_settings(new_settings[key], default_value)
                end
            end

            return new_settings
        end

        settings = apply_default_settings(settings, default_settings)
    end

    self._settings = settings
    self:_reinitialize()

    return self
end

--- @brief [internal] clear the simulation, useful for debugging
function SimulationHandler:_reinitialize()
    self._batch_id_to_batch = {}
    self._current_batch_id = 1
    self._n_batches = 0

    self._white_data = {}
    self._total_n_white_particles = 0

    self._yolk_data = {}
    self._total_n_yolk_particles = 0

    self._canvases_need_update = false
    self._elapsed = 0

    self:_initialize_shaders()
    self:_initialize_particle_texture()

    self._egg_white_canvas = nil -- love.Canvas
    self._egg_yolk_canvas = nil -- love.Canvas

    self._last_egg_white_env = nil -- cf. _step
    self._last_egg_yolk_env = nil
end

--- @brief [internal] load and compile necessary shaders
function SimulationHandler:_initialize_shaders()
    local new_shader = function(path, defines)
        if defines == nil then defines = {} end
        local success, shader_or_error = pcall(
            love.graphics.newShader,
            path
        )

        if not success then
            self:_error(true, "In SimulationHandler._initialize_shader: unable to create shader at `", path, "`: ", shader_or_error)
        else
            return shader_or_error
        end
    end

    self._particle_texture_shader = new_shader(self._settings.particle_texture_shader_path)
    self._threshold_shader = new_shader(self._settings.threshold_shader_path)
    self._outline_shader = new_shader(self._settings.outline_shader_path)

    -- on vulkan, first use of a shader would cause stutter, so force use here, equivalent to precompiling the shader
    if love.getVersion() >= 12 and love.graphics.getRendererInfo() == "Vulkan" then
        love.graphics.push("all")
        local texture = love.graphics.newCanvas(1, 1)
        love.graphics.setCanvas(texture)
        for _, shader in ipairs({
            self._particle_texture_shader,
            self._threshold_shader,
            self._outline_shader
        }) do
            love.graphics.setShader(shader)
            love.graphics.rectangle("fill", 0, 0, 1, 1)
            love.graphics.setShader(nil)
        end
        love.graphics.pop("all")
    end
end

--- @brief [internal] initialize mass distribution texture used for particle density estimation
function SimulationHandler:_initialize_particle_texture()
    -- create particle texture, this will hold density information
    -- we use the same texture for all particles regardless of size,
    -- instead love.graphics.scale'ing based on particle size,
    -- this way all draws are batched

    local settings = self._settings
    local radius = math.max(
        settings.egg_white.max_radius,
        settings.egg_yolk.max_radius
    ) * settings.particle_texture_resolution_factor

    local padding = self._settings.particle_texture_padding -- px

    -- create canvas, transparent outer padding so derivative on borders is 0
    local canvas_width = (radius + padding) * 2
    local canvas_height = canvas_width



    self._particle_texture = love.graphics.newCanvas(canvas_width, canvas_height, {
            format = "rgba16", -- first [0, 1] format that has 4 components
            msaa = 0,
            readable = true,
            dpiscale = 1
        }
    )
    self._particle_texture:setFilter("linear", "linear")
    self._particle_texture:setWrap("clampzero")

    -- create mesh with correct texture coordinates
    -- before love12, love.graphics.rectangle does not have
    -- the correct uv, so we need to use a temporary mesh
    local x, y, width, height = 0, 0, 2 * radius, 2 * radius
    local mesh = love.graphics.newMesh({
        { x,         y,          0, 0,  1, 1, 1, 1 },
        { x + width, y,          1, 0,  1, 1, 1, 1 },
        { x + width, y + height, 1, 1,  1, 1, 1, 1 },
        { x,         y + height, 0, 1,  1, 1, 1, 1 }
    }, "triangles", "static")

    mesh:setVertexMap(
        1, 2, 4,
        2, 3, 4
    )  -- triangulate

    -- fill particle with density data using shader
    love.graphics.push("all")
    love.graphics.reset()
    love.graphics.setCanvas(self._particle_texture)
    love.graphics.setShader(self._particle_texture_shader)

    love.graphics.translate(
        (canvas_width - width) / 2,
        (canvas_height - height) / 2
    )

    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(mesh)

    love.graphics.setShader(nil)
    love.graphics.setCanvas(nil)
    love.graphics.pop()
end

local _x_offset = 0  -- x position, px
local _y_offset = 1  -- y position, px
local _z_offset = 2  -- render priority
local _velocity_x_offset = 3 -- x velocity, px / s
local _velocity_y_offset = 4 -- y velocity, px / s
local _previous_x_offset = 5 -- last steps x position, px
local _previous_y_offset = 6 -- last steps y position, px
local _radius_offset = 7 -- radius, px
local _mass_offset = 8 -- mass, fraction
local _inverse_mass_offset = 9 -- 1 / mass, precomputed for performance
local _batch_id = 10

local _stride = _batch_id + 1

-- compute property indices for environment particle array
local _get_property_indices = function(particle_i)
    local base = (particle_i - 1) * _stride + 1 -- 1-based

    local x = base + _x_offset
    local y = base + _y_offset
    local z = base + _z_offset
    local velocity_x = base + _velocity_x_offset
    local velocity_y = base + _velocity_y_offset
    local previous_x = base + _previous_x_offset
    local previous_y = base + _previous_y_offset
    local radius = base + _radius_offset
    local mass = base + _mass_offset
    local inverse_mass = base + _inverse_mass_offset
    local batch_i = base + _batch_id

    return x, y, z,
        velocity_x, velocity_y,
        previous_x, previous_y,
        radius, mass, inverse_mass,
        batch_i
end

-- fallback implementations for luajit
pcall(require, "table.new")
if table.new == nil then
    function table.new(n_array, n_hash)
        return {} -- lua cannot preallocate
    end
end

pcall(require, "table.clear")
if not table.clear then
    function table.clear(t)
        for key in pairs(t) do
            t[key] = nil
        end
        return t
    end
end

--- @brief [internal] create a new particle batch
function SimulationHandler:_new_batch(
    center_x, center_y,
    white_x_radius, white_y_radius, white_n_particles,
    yolk_x_radius, yolk_y_radius, yolk_n_particles
)
    local batch = {
        white_particle_indices = {},
        yolk_particle_indices = {},
        target_x = center_x,
        target_y = center_y
    }

    -- generate uniformly distributed value in interval
    local random_uniform = function(min, max)
        local t = love.math.random(0, 1)
        return math.mix(min, max, t)
    end

    -- generate normally distributed value in interval
    local random_normal = function(x_radius, y_radius)
        return math.clamp(love.math.randomNormal(0.25, 0.5), 0, 1)
    end

    -- uniformly distribute points across the disk using fibonacci spiral
    local fibonacci_spiral = function(i, n, x_radius, y_radius)
        local golden_ratio = (1 + math.sqrt(5)) / 2
        local golden_angle = 2 * math.pi / (golden_ratio * golden_ratio)

        local r = math.sqrt((i - 1) / n)
        local theta = i * golden_angle

        local x = r * x_radius * math.cos(theta)
        local y = r * y_radius * math.sin(theta)

        return x, y
    end

    -- add particle data to the batch particle property buffer
    local add_particle = function(
        array, settings,
        x_radius, y_radius,
        particle_i, n_particles,
        batch_id
    )
        -- generate position
        local dx, dy = fibonacci_spiral(particle_i, n_particles, x_radius, y_radius)
        local x = center_x + dx
        local y = center_y + dy

        -- mass and radius use the same interpolation factor, since volume and mass are correlated
        -- we could compute mass as a function of radius, but being able to choose the mass distribution
        -- manually gives more freedom when fine-tuning the simulation
        local t = random_normal(0, 1)
        local mass = math.mix(
            debugger.get("min_mass"), -- TODO settings.min_mass,
            debugger.get("max_mass"), -- TODO settings.max_mass,
            t
        )
        local radius = math.mix(settings.min_radius, settings.max_radius, t)

        local n = #array + 1
        array[n + _x_offset] = x
        array[n + _y_offset] = y
        array[n + _z_offset] = 0
        array[n + _velocity_x_offset] = 0
        array[n + _velocity_y_offset] = 0
        array[n + _previous_x_offset] = x
        array[n + _previous_y_offset] = y
        array[n + _radius_offset] = radius
        array[n + _mass_offset] = mass
        array[n + _inverse_mass_offset] = 1 / mass
        array[n + _batch_id] = batch_id

        return n
    end
    
    local batch_id = self._current_batch_id
    self._current_batch_id = self._current_batch_id + 1

    for i = 1, white_n_particles do
        table.insert(batch.white_particle_indices, add_particle(
            self._white_data,
            self._settings.egg_white,
            white_x_radius, white_y_radius,
            i, white_n_particles,
            batch_id
        ))
    end

    for i = 1, yolk_n_particles do
        table.insert(batch.yolk_particle_indices, add_particle(
            self._yolk_data,
            self._settings.egg_yolk,
            yolk_x_radius, yolk_y_radius,
            i, yolk_n_particles,
            batch_id
        ))
    end

    batch.n_white_particles = white_n_particles
    batch.n_yolk_particles = yolk_n_particles

    return batch_id, batch
end

--- @brief [internal] perform a full step of the simulation, includes substeps
function SimulationHandler:_step(delta)
    local settings = self._settings

    local n_sub_steps = debugger.get("n_sub_steps")-- TODO settings.n_sub_steps
    local sub_delta = delta / n_sub_steps

    local collision_overlap_fraction = math.max(0, debugger.get("collision_overlap_fraction"))-- TODO current_settings.collision_strength)
    local cohesion_interaction_distance_fraction = math.max(0, debugger.get("cohesion_interaction_distance_fraction")) -- TODO current_settings.cohesion_interaction_distance_fraction

    local follow_compliance, collision_compliance, cohesion_compliance
    local should_apply_follow, should_apply_collision, should_apply_cohesion

    do
        -- convert settings settings to XPBD compliance parameters
        local function strength_to_compliance(strength)
            local alpha = 1 - math.clamp(strength, 0, 1)
            local alpha_per_substep = alpha / (sub_delta^2)
            return alpha_per_substep
        end

        local collision_strength = debugger.get("collision_strength") -- TODO current_settings.collision_strength
        local cohesion_strength = debugger.get("cohesion_strength") -- TODO current_settings.cohesion_strength
        local follow_strength = debugger.get("follow_strength") -- TODO current_settings.follow_strength)

        follow_compliance = strength_to_compliance(follow_strength)
        should_apply_follow = follow_strength > 0

        collision_compliance = strength_to_compliance(collision_strength)
        should_apply_collision = collision_strength > 0

        cohesion_compliance = strength_to_compliance(cohesion_strength)
        should_apply_cohesion = cohesion_strength > 0
    end

    -- setup environments for yolks and white separately
    local create_environment = function(current_settings, old_env_maybe)
        local spatial_hash_cell_radius = math.max(
            collision_overlap_fraction,
            cohesion_interaction_distance_fraction
        ) * 2 * current_settings.max_radius

        if old_env_maybe == nil then
            return {
                particles = {}, -- Table<Number>, particles inline
                collided = {}, -- Table<ParticleIndex, Set<ParticleIndex>>

                spatial_hash = {}, -- Table<Table<particle_index>>
                spatial_hash_cell_radius = spatial_hash_cell_radius, -- px

                damping = debugger.get("damping"), -- TODO current_settings.damping,

                min_x = math.huge, -- particle position bounds, px
                min_y = math.huge,
                max_x = -math.huge,
                max_y = -math.huge,

                n_particles = 0,

                center_of_mass_x = 0, -- set in post-solve, px
                center_of_mass_y = 0,
                centroid_x = 0,
                centroid_y = 0
            }
        else
            -- if old env present, keep allocated to keep gc / allocation pressure low
            local env = old_env_maybe

            for _, column in pairs(env.spatial_hash) do
                for _, row in pairs(column) do
                    table.clear(row)
                end
                -- do not clear column
            end

            -- reset collision record
            for _, entry in pairs(env.collided) do
                table.clear(entry)
            end

            env.min_x = math.huge
            env.min_y = math.huge
            env.max_x = -math.huge
            env.max_y = -math.huge
            env.spatial_hash_cell_radius = spatial_hash_cell_radius

            return env
        end
    end

    local white_env = create_environment(self._settings.egg_white, self._last_egg_white_env)
    local yolk_env = create_environment(self._settings.egg_yolk, self._last_egg_yolk_env)

    white_env.particles = self._white_data
    white_env.n_particles = self._total_n_white_particles

    yolk_env.particles = self._yolk_data
    yolk_env.n_particles = self._total_n_yolk_particles

    for sub_step_i = 1, n_sub_steps do
        -- pre-solve: integrate velocity
        local function pre_solve(env)
            local damping = env.damping
            local particles = env.particles
            for particle_i = 1, env.n_particles do
                local x, y, z, velocity_x, velocity_y, previous_x, previous_y, radius, mass, inverse_mass, batch_id = _get_property_indices(particle_i)

                particles[previous_x] = particles[x]
                particles[previous_y] = particles[y]

                particles[velocity_x] = particles[velocity_x] * damping
                particles[velocity_y] = particles[velocity_y] * damping

                particles[x] = particles[x] + sub_delta * particles[velocity_x]
                particles[y] = particles[y] + sub_delta * particles[velocity_y]
            end
        end

        pre_solve(white_env)
        pre_solve(yolk_env)

        -- convert particle position to spatial hash indices
        local function position_to_cell_xy(position_x, position_y, cell_size)
            local cell_x = math.floor(position_x / cell_size)
            local cell_y = math.floor(position_y / cell_size)
            return cell_x, cell_y
        end

        -- XPBD: enforce distance to anchor to be 0
        local function enforce_position(ax, ay, a_inverse_mass, px, py, alpha)
            if a_inverse_mass < math.eps then
                return false
            end

            local current_distance = math.distance(ax, ay, px, py)
            local dx, dy = math.normalize(px - ax, py - ay)

            local constraint_violation = current_distance -- target_distance = 0
            local correction = constraint_violation / (a_inverse_mass + alpha)

            local x_correction = dx * correction * a_inverse_mass
            local y_correction = dy * correction * a_inverse_mass

            return true, x_correction, y_correction
        end

        -- make all particles move towards their target
        local function move_towards_target(env)
            if not should_apply_follow then return end
            local data = env.particles
            for particle_i = 1, env.n_particles do
                local x, y, z, velocity_x, velocity_y, previous_x, previous_y, radius, mass, inverse_mass, batch_id = _get_property_indices(particle_i)
                local batch = self._batch_id_to_batch[data[batch_id]]
                if batch ~= nil then
                    local target_x, target_y = batch.target_x, batch.target_y
                    local should_apply, x_correction, y_correction = enforce_position(
                        data[x], data[y], data[inverse_mass],
                        target_x, target_y,
                        follow_compliance
                    )

                    if should_apply then
                        data[x] = data[x] + x_correction
                        data[y] = data[y] + y_correction
                    end
                end
            end
        end

        move_towards_target(white_env)
        move_towards_target(yolk_env)

        -- construct the spatial hash
        local function rebuild_spatial_hash(env)
            for particle_i = 1, env.n_particles do
                local x, y, z, velocity_x, velocity_y, previous_x, previous_y, radius, mass, inverse_mass, batch_id = _get_property_indices(particle_i)

                local cell_x, cell_y = position_to_cell_xy(
                    env.particles[x],
                    env.particles[y],
                    env.spatial_hash_cell_radius
                )

                local column = env.spatial_hash[cell_x]
                if column == nil then
                    column = {}
                    env.spatial_hash[cell_x] = column
                end

                local row = column[cell_y]
                if row == nil then
                    row = {}
                    column[cell_y] = row
                end

                table.insert(row, particle_i)
            end
        end

        rebuild_spatial_hash(white_env)
        rebuild_spatial_hash(yolk_env)

        -- XPBD: enforce distance between two particles to be a specific value
        local function enforce_distance(
            ax, ay, bx, by,
            inverse_mass_a, inverse_mass_b,
            target_distance,
            alpha
        )
            local dx = bx - ax
            local dy = by - ay

            local current_distance = math.magnitude(dx, dy)
            dx, dy = math.normalize(dx, dy)

            local constraint_violation = current_distance - target_distance

            local mass_sum = inverse_mass_a + inverse_mass_b
            if mass_sum <= math.eps then return false end

            local correction = -constraint_violation / (mass_sum + alpha)

            local max_correction = math.abs(constraint_violation)
            correction = math.clamp(correction, -max_correction, max_correction)

            local a_correction_x = -dx * correction * inverse_mass_a
            local a_correction_y = -dy * correction * inverse_mass_a

            local b_correction_x =  dx * correction * inverse_mass_b
            local b_correction_y =  dy * correction * inverse_mass_b

            return true, a_correction_x, a_correction_y, b_correction_x, b_correction_y
        end

        -- has this particle-particle interaction already happened
        local function particles_already_collided(env, a_i, b_i)
            return a_i == b_i
                or (env.collided[a_i] ~= nil and env.collided[a_i][b_i] == true)
                or (env.collided[b_i] ~= nil and env.collided[b_i][a_i] == true)
        end

        -- store which particles interacted with which already
        local function notify_particles_collided(env, a_i, b_i)
            local a_entry = env.collided[a_i]
            if a_entry == nil then
                a_entry = {}
                env.collided[a_i] = a_entry
            end

            local b_entry = env.collided[b_i]
            if b_entry == nil then
                b_entry = {}
                env.collided[b_i] = b_entry
            end

            a_entry[b_i] = true
            b_entry[a_i] = true
        end

        -- enforce particle-particle interactions
        local function collide_particles(env)
            local data = env.particles

            -- iterate neighbors of all particles
            for self_i = 1, env.n_particles do
                local self_x, self_y, self_z, self_velocity_x, self_velocity_y, self_previous_x, self_previous_y, self_radius, self_mass, self_inverse_mass, self_batch_id = _get_property_indices(self_i)

                local cell_x, cell_y = position_to_cell_xy(
                    data[self_x],
                    data[self_y],
                    env.spatial_hash_cell_radius
                )

                for x_offset = -1, 1 do
                    local column = env.spatial_hash[cell_x + x_offset]
                    if column == nil then goto next_column end

                    for y_offset = -1, 1 do
                        local row = column[cell_y + y_offset]
                        if row == nil then goto next_row end

                        for _, other_i in ipairs(row) do
                            if particles_already_collided(env, self_i, other_i) then
                                goto next_pair
                            end

                            local other_x, other_y, other_z, other_velocity_x, other_velocity_y, other_previous_x, other_previous_y, other_radius, other_mass, other_inverse_mass, other_batch_id = _get_property_indices(other_i)

                            -- minimum allowable distance between particles
                            local min_distance = collision_overlap_fraction * (data[self_radius] + data[other_radius])

                            if should_apply_collision
                                and min_distance > math.eps
                                and math.distance(
                                data[self_x], data[self_y],
                                data[other_x], data[other_y]
                            ) <= min_distance
                            then
                                local should_apply, self_cx, self_cy, other_cx, other_cy = enforce_distance(
                                    data[self_x], data[self_y],
                                    data[other_x], data[other_y],
                                    data[self_inverse_mass], data[other_inverse_mass],
                                    min_distance, collision_compliance
                                )

                                if should_apply then
                                    data[self_x]  = data[self_x]  + self_cx
                                    data[self_y]  = data[self_y]  + self_cy
                                    data[other_x] = data[other_x] + other_cx
                                    data[other_y] = data[other_y] + other_cy
                                end
                            end

                            -- maximum distance in which particles considers adherence
                            local interaction_distance = cohesion_interaction_distance_fraction * (data[self_radius] + data[other_radius])

                            if should_apply_cohesion
                                and data[self_batch_id] == data[other_batch_id]
                                and math.distance(
                                data[self_x], data[self_y],
                                data[other_x], data[other_y]
                            ) < interaction_distance
                            then
                                local should_apply, self_cx, self_cy, other_cx, other_cy = enforce_distance(
                                    data[self_x], data[self_y],
                                    data[other_x], data[other_y],
                                    data[self_inverse_mass], data[other_inverse_mass],
                                    interaction_distance, cohesion_compliance
                                )

                                if should_apply then
                                    data[self_x]  = data[self_x]  + self_cx
                                    data[self_y]  = data[self_y]  + self_cy
                                    data[other_x] = data[other_x] + other_cx
                                    data[other_y] = data[other_y] + other_cy
                                end
                            end

                            notify_particles_collided(env, self_i, other_i)

                            ::next_pair::
                        end

                        ::next_row::
                    end

                    ::next_column::
                end
            end
        end

        collide_particles(white_env)
        collide_particles(yolk_env)

        -- update velocity from position change, compute centers
        local function post_solve(env)
            local center_of_mass_x, center_of_mass_y = 0, 0
            local total_mass = 0

            local centroid_x, centroid_y = 0, 0

            local particles = env.particles
            for particle_i = 1, env.n_particles do
                local x, y, z, velocity_x, velocity_y, previous_x, previous_y, radius, mass, inverse_mass, batch_id = _get_property_indices(particle_i)

                particles[velocity_x] = (particles[x] - particles[previous_x]) / sub_delta
                particles[velocity_y] = (particles[y] - particles[previous_y]) / sub_delta

                centroid_x = centroid_x + particles[x]
                centroid_y = centroid_y + particles[y]

                center_of_mass_x = center_of_mass_x + particles[x] * particles[mass]
                center_of_mass_y = center_of_mass_y + particles[y] * particles[mass]
                total_mass = total_mass + particles[mass]

                local r = particles[radius]
                env.min_x = math.min(env.min_x, env.particles[x] - r)
                env.min_y = math.min(env.min_y, env.particles[y] - r)
                env.max_x = math.max(env.max_x, env.particles[x] + r)
                env.max_y = math.max(env.max_y, env.particles[y] + r)
            end

            env.center_of_mass_x = center_of_mass_x / total_mass
            env.center_of_mass_y = center_of_mass_y / total_mass
            env.centroid_x = centroid_x / env.n_particles
            env.centroid_y = centroid_y / env.n_particles
        end

        post_solve(white_env)
        post_solve(yolk_env)
    end -- for substeps

    -- after solver, resize render textures if necessary
    local resize_canvas_maybe = function(canvas, env)
        local current_w, current_h = 0, 0
        if canvas ~= nil then
            current_w, current_h = canvas:getDimensions()
        end

        local max_radius = math.max(self._settings.egg_white.max_radius, self._settings.egg_yolk.max_radius)
        local padding = 2 * settings.particle_texture_padding
            + max_radius * debugger.get("texture_scale") -- TODO self._settings.texture_scale

        local new_w = env.max_x - env.min_x + 2 * padding
        local new_h = env.max_y - env.min_y + 2 * padding

        if new_w > current_w or new_h > current_h then
            local new_canvas = love.graphics.newCanvas(
                math.max(new_w, current_w),
                math.max(new_h, current_h),
            {
                msaa = settings.canvas_msaa,
                format = settings.texture_format
            })
            new_canvas:setFilter("linear", "linear")

            if canvas ~= nil then
                canvas:release() -- free old as early as possible, uses quite a lot of vram
            end
            return new_canvas
        else
            return canvas
        end
    end

    self._egg_white_canvas = resize_canvas_maybe(self._egg_white_canvas, white_env)
    self._egg_yolk_canvas = resize_canvas_maybe(self._egg_yolk_canvas, yolk_env)

    -- keep env of last step
    self._last_egg_white_env = white_env
    self._last_egg_yolk_env = yolk_env

    self._canvases_need_update = true
end

--- @brief [internal] udpate render textures if necessary, then draw all supplied batches
function SimulationHandler:_draw(batches)
    if self._egg_white_canvas == nil or self._egg_yolk_canvas == nil then
        -- no batches added yet
        return
    end

    love.graphics.setColor(1, 1, 1, 1)

    -- draw particles to canvases
    if self._canvases_need_update then
        love.graphics.push("all")
        love.graphics.reset()
        love.graphics.setBlendMode("add", "premultiplied")

        local texture_w, texture_h = self._particle_texture:getDimensions()
        local padding = self._settings.particle_texture_padding

        local draw_env = function(env, canvas, color)
            local canvas_width, canvas_height = canvas:getDimensions()

            love.graphics.setCanvas(canvas)
            love.graphics.clear(0, 0, 0, 0)
            love.graphics.setColor(1, 1, 1, 1)

            -- translate to canvas local space
            love.graphics.push()
            love.graphics.translate(
                -env.centroid_x + canvas_width / 2,
                -env.centroid_y + canvas_height / 2
            )

            love.graphics.setBlendMode("alpha", "premultiplied")

            local particles = env.particles
            local texture_scale = debugger.get("texture_scale") --TODO self._settings.texture_scale
            for particle_i = 1, env.n_particles do
                local x, y, z, velocity_x, velocity_y, previous_x, previous_y, radius, mass, inverse_mass, batch_id = _get_property_indices(particle_i)

                local scale_x = (2 * particles[radius]) / (texture_w - 2 * padding) * texture_scale
                local scale_y = (2 * particles[radius]) / (texture_h - 2 * padding) * texture_scale

                love.graphics.draw(self._particle_texture,
                    particles[x], particles[y],
                    0,
                    scale_x, scale_y,
                    0.5 * texture_w, 0.5 * texture_h
                )
            end

            love.graphics.pop()
            love.graphics.setCanvas(nil)
        end

        draw_env(self._last_egg_white_env, self._egg_white_canvas)
        draw_env(self._last_egg_yolk_env, self._egg_yolk_canvas)

        love.graphics.setLineWidth(1)
        for _, batch in pairs(self._batch_id_to_batch) do
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.circle("fill", batch.target_x, batch.target_y, 5)
            love.graphics.setColor(0, 0, 0, 0, 1)
            love.graphics.circle("line", batch.target_x, batch.target_y, 5)
        end

        love.graphics.pop()
        self._canvases_need_update = false
    end

    -- now draw canvases
    love.graphics.push("all")
    love.graphics.setBlendMode("alpha", "premultiplied")
    love.graphics.setColor(1, 1, 1, 1)

    local safe_send = function(shader, uniform, value)
        local success, error_maybe = pcall(shader.send, shader, uniform, value)
        if not success then
            self:_error(false, "In SimulationHandler._draw: ", error_maybe)
        end
    end

    local composite_alpha = debugger.get("composite_alpha") -- TODO self._settings.composite_alpha
    safe_send(self._threshold_shader, "threshold", debugger.get("threshold_shader_threshold")) -- TODO self._settings.threshold_shader_threshold)
    safe_send(self._threshold_shader, "smoothness", debugger.get("threshold_shader_smoothness")) -- TODO self._settings.threshold_shader_smoothness)

    local draw_canvas = function(canvas, env, color)
        local canvas_width, canvas_height = canvas:getDimensions()
        local canvas_x, canvas_y = env.centroid_x - 0.5 * canvas_width,
            env.centroid_y - 0.5 * canvas_height

        love.graphics.setBlendMode("alpha", "premultiplied")

        -- premultiply color
        local r, g, b, a = (unpack or table.unpack)(color)
        r = r * a * composite_alpha
        g = g * a * composite_alpha
        b = b * a * composite_alpha
        love.graphics.setColor(r, g, b, a)

        love.graphics.setShader(self._threshold_shader)
        love.graphics.draw(canvas, canvas_x, canvas_y)
        love.graphics.setShader()
    end

    draw_canvas(self._egg_white_canvas, self._last_egg_white_env, self._settings.egg_white.color)
    draw_canvas(self._egg_yolk_canvas, self._last_egg_yolk_env, self._settings.egg_yolk.color)

    love.graphics.pop()
end

--- @brief [internal] throw error with pretty printing
function SimulationHandler:_error(is_fatal, ...)
    -- make it so output is flushed to console immediately, because
    -- love.errorhandler does not flush
    io.stdout:setvbuf("no")

    local message = {}
    if is_fatal then
        table.insert(message, "[ERROR]")
    else
        table.insert(message, "[WARNING]")
    end

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
        local arg = select(i, ...)
        table.insert(message, arg)
    end

    message = table.concat(message, " ") .. "\n"

    -- write to error stream and flush and print to console immediately
    if is_fatal then
        error(message)
    else
        io.stderr:write(message)
        io.stderr:flush()
    end
end

--- @brief [internal] assert function arguments to be of a specific type
function SimulationHandler:_assert(...)
    local should_exit = true

    local n = select("#", ...)
    if n % 2 ~= 0 then
        self:_error(true, "In SimulationHandler._assert: number of arguments is not a multiple of 2")
        return should_exit
    end

    for i = 1, n, 2 do
        local instance = select(i + 0, ...)
        local instance_type = select(i + 1, ...)
        if not type(instance) == instance_type then
            self:_error(true, "for argument #", i, ": expected `", instance_type, "`, got `", instance_type, "`")
            return should_exit
        end
    end

    return not should_exit
end

-- return type, invoking the type returns and instance: `local instance = SimulationHandler()`
return setmetatable(SimulationHandler, {
    __call = function(...)
        return SimulationHandler._new(...)
    end
})