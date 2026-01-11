local prefix = "egg_fluid_simulation" -- path prefix, change this depending on where the library is located

require(prefix .. ".math")
pcall(require, "table.clear")

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
    },

    n_sub_steps = 2, -- number of solver sub steps

    -- render texture config
    canvas_msaa = 0, -- msaa for render textures
    particle_texture_padding = 3, -- px
    texture_format = "rgba8", -- love.PixelFormat
    particle_texture_resolution_factor = 4, -- fraction
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
    local white_n_particles = white_settings.particle_density * white_area

    local yolk_area = math.pi * yolk_radius^2
    local yolk_n_particles = yolk_settings.particle_density * yolk_area

    local batch_id, batch = self:_new_batch(
        x, y,
        white_radius, white_radius, white_n_particles,
        yolk_radius, yolk_radius, yolk_n_particles
    )

    assert(self._batch_id_to_batch[batch_id] == nil) -- should never trigger
    self._batch_id_to_batch[batch_id] = batch

    return batch_id
end

--- @brief removes a batch from the simulation
--- @param batch_id number id of the batch to remove, acquired from SimulationHandler.add
--- @return nil
function SimulationHandler:remove(batch_id)
    self:_assert(batch_id, "number")

    self._batch_id_to_batch[batch_id] = nil
    -- env updated next step
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

    self:_draw(self:_collect_batches(batches))
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
    local step = settings.step_delta
    local n_steps = 0
    while self._elapsed >= step do
        self:_step(settings.step_delta, self:_collect_batches(batches))

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
            format = settings.texture_format,
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

-- particle property indices
-- the compiler will inline these so that we get the performance
-- of an array table, while still keeping it somewhat legible
local _x = 1 -- x position, px
local _y = 2 -- y position, px
local _z = 3 -- render priority
local _velocity_x = 4 -- x velocity, px / s
local _velocity_y = 5 -- y velocity, px / s
local _previous_x = 6 -- last steps x position, px
local _previous_y = 7 -- last steps y position, px
local _radius = 8 -- radius, px
local _mass = 9 -- mass, fraction

--- @brief [internal] create a new particle batch
function SimulationHandler:_new_batch(
    center_x, center_y,
    white_x_radius, white_y_radius, white_n_particles,
    yolk_x_radius, yolk_y_radius, yolk_n_particles
)
    local batch = {
        white_particles = {},
        yolk_particles = {}
    }

    -- generate uniformly distributed value in interval
    local random_number = function(min, max)
        local t = love.math.random(0, 1)
        return math.mix(min, max, t)
    end

    -- generate 2d vector, magnitude follows normal distribution around center
    local random_normal = function(x_radius, y_radius)
        local standard_deviation_x = x_radius / 1.96 -- ~95% of gaussian falls into [0, 1]
        local standard_deviation_y = y_radius / 1.96

        local dx = love.math.randomNormal(standard_deviation_x, 0)
        local dy = love.math.randomNormal(standard_deviation_y, 0)

        return math.normalize(dx, dy)
    end

    local new_particle = function(settings, x_radius, y_radius)
        -- generate position on circle, with gaussian distribution, mean at center
        local angle = random_number(0, 2 * math.pi)

        local dx, dy = random_normal(x_radius, y_radius)
        local x = center_x + dx
        local y = center_y + dy

        -- mass and radius use the same interpolation factor, since volume and mass are correlated
        -- we could compute mass as a function of radius, but being able to choose the mass distribution
        -- manually gives more freedom when fine-tuning the simulation
        local t = random_number(0, 1)
        local mass = math.mix(settings.min_mass, settings.max_mass, t)
        local radius = math.mix(settings.min_radius, settings.max_radius, t)

        return {
            [_x] = x,
            [_y] = y,
            [_z] = 0,
            [_velocity_x] = 0,
            [_velocity_y] = 0,
            [_previous_x] = x,
            [_previous_y] = y,
            [_radius] = radius,
            [_mass] = mass
        }
    end

    for _ = 1, white_n_particles do
        table.insert(batch.white_particles, new_particle(
            self._settings.egg_white,
            white_x_radius, white_y_radius
        ))
    end

    for _ = 1, yolk_n_particles do
        table.insert(batch.yolk_particles, new_particle(
            self._settings.egg_yolk,
            yolk_x_radius, yolk_y_radius
        ))
    end

    self._current_batch_id = self._current_batch_id + 1
    return self._current_batch_id, batch
end

--- @brief [internal] perform a full step of the simulation, includes substeps
function SimulationHandler:_step(delta, batches)
    local settings = self._settings

    local n_sub_steps = settings.n_sub_steps
    local sub_delta = delta / n_sub_steps

    -- setup environments for yolks and white separately
    local create_environment = function(current_settings, old_env_maybe)
        if old_env_maybe == nil then
            return {
                particles = {}, -- Table<Particle>
                particle_to_particle_collided = {}, -- HashTable<Particle, Particle>

                spatial_hash = {}, -- Table<Table<Particle>>
                spatial_hash_cell_radius = current_settings.min_radius, -- px

                damping = current_settings.damping,

                min_x = math.huge, -- particle position bounds, px
                min_y = math.huge,
                max_x = -math.huge,
                max_y = -math.huge,

                center_of_mass_x = 0, -- set in post-solve, px
                center_of_mass_y = 0,
                centroid_x = 0,
                centroid_y = 0
            }
        else
            -- if old env present, keep allocated to keep gc pressure low
            local env = old_env_maybe

            local clear = table.clear
            if clear == nil then
                clear = function(t)
                    for key, _ in t do t[key] = nil end
                end
            end

            clear(env.particles)
            clear(env.particle_to_particle_collided)
            for _, column in pairs(env.spatial_hash) do
                for _, row in pairs(column) do
                    clear(row)
                end
            end

            env.min_x = math.huge
            env.min_y = math.huge
            env.max_x = -math.huge
            env.max_y = -math.huge
        end
    end

    local white_env = create_environment(self._settings.egg_white, self._last_egg_white_env)
    local yolk_env = create_environment(self._settings.egg_yolk, self._last_egg_yolk_env)

    -- collect active particles
    for _, batch in ipairs(batches) do
        for _, particle in ipairs(batch.white_particles) do
            table.insert(white_env.particles, particle)
        end

        for _, particle in ipairs(batch.yolk_particles) do
            table.insert(yolk_env.particles, particle)
        end
    end

    for sub_step_i = 1, n_sub_steps do
        -- pre solve: integrate velocity
        local pre_solve = function(env)
            local damping = 1 - env.damping
            for _, particle in ipairs(env.particles) do
                particle[_previous_x] = particle[_x]
                particle[_previous_y] = particle[_y]

                particle[_velocity_x] = particle[_velocity_x] * damping * sub_delta
                particle[_velocity_y] = particle[_velocity_y] * damping * sub_delta

                particle[_x] = particle[_x] + sub_delta * particle[_velocity_x]
                particle[_y] = particle[_y] + sub_delta * particle[_velocity_y]
            end
        end

        pre_solve(white_env)
        pre_solve(yolk_env)

        -- add particle to the spatial hash
        local add_to_spatial_hash = function(env, particle)
            local cell_x = math.floor(particle[_x] / env.spatial_hash_cell_radius)
            local cell_y = math.floor(particle[_y] / env.spatial_hash_cell_radius)

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

            table.insert(row, particle)

            local radius = particle[_radius]
            env.min_x = math.min(env.min_x, particle[_x] - radius)
            env.min_y = math.min(env.min_y, particle[_y] - radius)
            env.max_x = math.max(env.max_x, particle[_x] + radius)
            env.max_y = math.max(env.max_y, particle[_y] + radius)
        end

        for _, batch in ipairs(batches) do
            for _, particle in ipairs(white_env.particles) do
                add_to_spatial_hash(white_env, particle)
            end

            for _, particle in ipairs(yolk_env.particles) do
                add_to_spatial_hash(yolk_env, particle)
            end
        end

        -- TODO

        -- post solve
        local post_solve = function(env)
            local center_of_mass_x, center_of_mass_y = 0, 0
            local total_mass = 0

            local centroid_x, centroid_y = 0, 0
            local n = #env.particles

            for _, particle in ipairs(env.particles) do
                particle[_velocity_x] = (particle[_x] - particle[_previous_x]) / sub_delta
                particle[_velocity_y] = (particle[_y] - particle[_previous_y]) / sub_delta

                centroid_x = centroid_x + particle[_x]
                centroid_y = centroid_y + particle[_y]

                center_of_mass_x = center_of_mass_x + particle[_x] * particle[_mass]
                center_of_mass_y = center_of_mass_y + particle[_y] * particle[_mass]
                total_mass = total_mass + particle[_mass]
            end

            env.center_of_mass_x = center_of_mass_x / total_mass
            env.center_of_mass_y = center_of_mass_y / total_mass
            env.centroid_x = centroid_x / n
            env.centroid_y = centroid_y / n
        end

        post_solve(white_env)
        post_solve(yolk_env)

    end -- for i = 1, n_substeps

    -- after solver, resize render textures if necessary
    local resize_canvas_maybe = function(canvas, env)
        local current_w, current_h = 0, 0
        if canvas ~= nil then
            current_w, current_h = canvas:getDimensions()
        end

        local padding = 2 * settings.particle_texture_padding -- sic, reuse
        local new_w = env.max_x - env.min_x + 2 * padding
        local new_h = env.max_y - env.min_y + 2 * padding

        if new_w > current_w or new_h > current_h then
            local new_canvas = love.graphics.newCanvas(new_w, new_h, {
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

        local draw_particle = function(particle)
            local radius = particle[_radius]
            local scale_x = (2 * radius) / (texture_w - 2 * padding)
            local scale_y = (2 * radius) / (texture_h - 2 * padding)

            love.graphics.draw(self._particle_texture,
                particle[_x], particle[_y],
                0,
                scale_x, scale_y,
                0.5 * texture_w, 0.5 * texture_h
            )
        end

        do -- egg whites
            local env = self._last_egg_white_env
            local canvas_width, canvas_height = self._egg_white_canvas:getDimensions()

            love.graphics.setCanvas(self._egg_white_canvas)
            love.graphics.clear(0, 0, 0, 0)

            -- translate to canvas local space
            love.graphics.push()
            love.graphics.translate(
                -env.centroid_x + canvas_width / 2,
                -env.centroid_y + canvas_height / 2
            )

            for _, batch in ipairs(batches) do
                for _, particle in ipairs(batch.white_particles) do
                    draw_particle(particle)
                end
            end

            love.graphics.pop()
            love.graphics.setCanvas(nil)
        end

        do -- egg yolks
            local env = self._last_egg_yolk_env
            local canvas_width, canvas_height = self._egg_yolk_canvas:getDimensions()

            love.graphics.setCanvas(self._egg_yolk_canvas)
            love.graphics.clear(0, 0, 0, 0)

            love.graphics.push()
            love.graphics.translate(
                -env.centroid_x + canvas_width / 2,
                -env.centroid_y + canvas_height / 2
            )

            for _, batch in ipairs(batches) do
                for _, particle in ipairs(batch.yolk_particles) do
                    draw_particle(particle)
                end
            end

            love.graphics.pop()
            love.graphics.setCanvas(nil)
        end

        love.graphics.pop()
        self._canvases_need_update = false
    end

    -- now draw canvases
    love.graphics.push("all")
    love.graphics.setBlendMode("alpha", "premultiplied")
    love.graphics.setColor(1, 1, 1, 1)

    local draw_canvas = function(canvas, env)
        local canvas_width, canvas_height = canvas:getDimensions()
        love.graphics.draw(canvas,
            env.centroid_x - 0.5 * canvas_width,
            env.centroid_y - 0.5 * canvas_height
        )
    end

    draw_canvas(self._egg_white_canvas, self._last_egg_white_env)
    draw_canvas(self._egg_white_canvas, self._last_egg_yolk_env)

    love.graphics.pop()
end


--- @brief [internal] helper for update/draw, collects batches and asserts type correctness
function SimulationHandler:_collect_batches(batches)
    if batches == nil then
        -- if unspecified, use all batches
        local collected = {}
        for _, batch in pairs(self._batch_id_to_batch) do
            table.insert(collected, batch)
        end
        return collected
    else
        local collected = {}
        for _, batch_id in pairs(batches) do
            local batch = self._batch_id_to_batch[batch_id]
            if batch == nil then
                self:_error(false, "In SimulationHandler.update: no batch width id `", batch_id, "`, this id will be ignored")
            else
                table.insert(collected, batch)
            end
        end

        return collected
    end
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

    message = table.concat(message, " ")

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