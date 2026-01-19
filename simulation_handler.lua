local prefix = "egg_fluid_simulation" -- path prefix, change this depending on where the library is located
require(prefix .. ".math")

--- @class egg.SimulationHandler
local SimulationHandler = {}

--- @brief table of simulation parameters, this default is used for any setting not specified
local settings = {
    -- overall fps, the simulation will be run at this fixed rate, regardless of fps
    step_delta = 1 / 60, -- seconds
    max_n_steps = 8, -- cf. update
    n_sub_steps = 1, -- number of solver sub steps
    max_n_collision_fraction = 0.4,

    -- particle configs for egg white
    white = {
        particle_density = 1 / 128, -- n particles / px^2
        min_radius = 2, -- px
        max_radius = 2, -- px
        min_mass = 1, -- fraction
        max_mass = 2, -- fraction
        damping = 0.7, -- in [0, 1], higher is more dampened

        color = { 253 / 255, 253 / 255, 255 / 255, 1 }, -- rgba, components in [0, 1]
        default_radius = 50 * 1.5, -- total radius of egg white at rest, px

        collision_strength = 1, -- in [0, 1]
        collision_overlap_factor = 2, -- > 0

        cohesion_strength = 1 - 0.01, -- in [0, 1]
        cohesion_interaction_distance_factor = 3,

        follow_strength = 0.999, -- in [0, 1]
    },

    -- particle configs for egg yolk
    yolk = {
        particle_density = 1 / 128,
        min_radius = 2,
        max_radius = 2,
        min_mass = 1,
        max_mass = 1.5,
        damping = 0.5,

        color = { 255 / 255, 129 / 255, 0 / 255, 1 },
        default_radius = 15 * 1.5, -- total radius of yolk at rest, px

        collision_strength = 1, -- in [0, 1]
        collision_overlap_factor = 2, -- > 0

        cohesion_strength = 1, -- in [0, 1]
        cohesion_interaction_distance_factor = 6,

        follow_strength = 0.9991, -- in [0, 1]
    },

    -- render texture config
    canvas_msaa = 4, -- msaa for render textures
    particle_texture_padding = 3, -- px
    particle_texture_resolution_factor = 4, -- fraction
    texture_scale = 4, -- fraction

    -- shader config
    composite_alpha = 0.5,
    threshold_shader_threshold = 0.5, -- in [0, 1]
    threshold_shader_smoothness = 0.001,

    -- shader paths
    particle_texture_shader_path = prefix .. "/simulation_handler_particle_texture.glsl",
    threshold_shader_path = prefix .. "/simulation_handler_threshold.glsl",
    outline_shader_path = prefix .. "/simulation_handler_outline.glsl",
    instanced_draw_shader_path = prefix .. "/simulation_handler_instanced_draw.glsl"
}

local make_proxy = function(t)
    return setmetatable({}, {
        __index = function(self, key)
            return debugger.get(key) or rawget(settings, key) or rawget(t, key)
        end
    })
end

settings.white = make_proxy(settings.white)
settings.yolk = make_proxy(settings.yolk)
settings = make_proxy(settings)

-- error types
local _FATAL = true
local _WARNING = false

--- @brief add a new batch to the simulation
--- @overload fun(self: egg.SimulationHandler, x: number, y: number)
--- @param x number x position, px
--- @param y number y position, px
--- @param white_radius number? radius of the egg white, px
--- @param yolk_radius number? radius of egg yolk, px
--- @return number id of the new batch
function SimulationHandler:add(x, y, white_radius, yolk_radius, white_color, yolk_color)
    local white_settings = self._settings.white
    local yolk_settings = self._settings.yolk

    if white_radius == nil then white_radius = white_settings.default_radius end
    if yolk_radius == nil then
        local fraction = yolk_settings.default_radius / white_settings.default_radius
        yolk_radius = white_radius * fraction
    end
    
    white_color = white_color or white_settings.color
    yolk_color = yolk_color or yolk_settings.color

    self:_assert(
        x, "number",
        y, "number",
        white_radius, "number",
        yolk_radius, "number",
        white_color, "table",
        yolk_color, "table"
    )
    
    if white_radius <= 0 then 
        self:_error(_FATAL, "In SimulationHandler.add: white radius cannot be 0 or negative")
    end

    if yolk_radius <= 0 then
        self:_error(_FATAL, "In SimulationHandler.add: yolk radius cannot be 0 or negative")
    end

    local white_area = math.pi * white_radius^2 -- area of a circle = pi * r^2
    local white_n_particles = math.max(5, math.ceil(white_settings.particle_density * white_area))

    local yolk_area = math.pi * yolk_radius^2
    local yolk_n_particles = math.max(3, math.ceil(yolk_settings.particle_density * yolk_area))

    self._total_n_white_particles = self._total_n_white_particles + white_n_particles
    self._total_n_yolk_particles = self._total_n_yolk_particles + yolk_n_particles

    local batch_id, batch = self:_new_batch(
        x, y,
        white_radius, white_radius, white_n_particles, white_color,
        yolk_radius, yolk_radius, yolk_n_particles, yolk_color
    )

    self._batch_id_to_batch[batch_id] = batch
    self._n_batches = self._n_batches + 1

    return batch_id
end

--- @brief removes a batch from the simulation
--- @param batch_id number id of the batch to remove, acquired from SimulationHandler.add
--- @return nil
function SimulationHandler:remove(batch_id)
    self:_assert(batch_id, "number")

    local batch = self._batch_id_to_batch[batch_id]
    if batch == nil then
        self:_error(_WARNING, "In SimulationHandler.remove: no batch with id `", batch_id, "`")
        return
    end

    self._batch_id_to_batch[batch_id] = nil
    self._n_batches = self._n_batches - 1
    self._total_n_white_particles = self._total_n_white_particles - batch.n_white_particles
    self._total_n_yolk_particles = self._total_n_yolk_particles - batch.n_yolk_particles

    self:_remove(batch.white_particle_indices, batch.yolk_particle_indices)
end

--- @brief set the target position a batch should move to
--- @param batch_id number batch id returned by SimulationHandler.add
--- @param x number x coordinate, in px
--- @param y number y coordinate, in px
function SimulationHandler:set_target_position(batch_id, x, y)
    self:_assert(batch_id, "number", x, "number", y, "number")

    local batch = self._batch_id_to_batch[batch_id]
    if batch == nil then
        self:_error(_WARNING, "In SimulationHandler.set_target_position: no batch with id `", batch_id, "`")
    else
        batch.target_x = x
        batch.target_y = y
    end
end

do
    --- argument assertion helper for set_*_color functions
    local _assert_color = function(scope, r, g, b, a)
        if a == nil then a = 1 end

        self:_assert(
            r, "number",
            g, "number",
            b, "number",
            a, "number"
        )
        if r > 1 or r < 0
            or g > 1 or g < 0
            or b > 1 or b < 0
            or a > 1 or a < 0
        then
            self:_error(_WARNING, "In SimulationHandler.", scope, ": color component is outside of [0, 1]")
        end

        return math.clamp(r, 0, 1),
            math.clamp(g, 0, 1),
            math.clamp(b, 0, 1),
            math.clamp(a, 0, 1)
    end

    --- @brief overwrite the color of the yolk particles
    --- @param batch_id number id of the batch, returned by SimulationHandler.add
    --- @param r number red component, in [0, 1]
    --- @param g number green component, in [0, 1]
    --- @param b number blue component, in [0, 1]
    --- @param a number opacity component, in [0, 1]
    function SimulationHandler:set_egg_yolk_color(batch_id, r, g, b, a)
        self:_assert(batch_id, "number")
        r, g, b, a = _assert_color("set_egg_yolk_color", r, g, b, a)

        local batch = self._batch_id_to_batch[batch_id]
        if batch == nil then
            self:_error(_WARNING, "In SimulationHandler.set_egg_yolk_color: no batch with id `", batch_id, "`")
        else
            local color = batch.yolk_color
            color[1], color[2], color[3], color[4] = r, g, b, a
            self:_update_particle_color(batch, true) -- yolk only
        end

        if self._use_instancing then
            self:_update_color_mesh()
        end
    end

    --- @brief overwrite the color of the white particles
    --- @param batch_id number id of the batch, returned by SimulationHandler.add
    --- @param r number red component, in [0, 1]
    --- @param g number green component, in [0, 1]
    --- @param b number blue component, in [0, 1]
    --- @param a number opacity component, in [0, 1]
    function SimulationHandler:set_egg_white_color(batch_id, r, g, b, a)
        self:_assert(batch_id, "number")
        r, g, b, a = _assert_color("set_egg_white_color", r, g, b, a)

        local batch = self._batch_id_to_batch[batch_id]
        if batch == nil then
            self:_error(_WARNING, "In SimulationHandler.set_egg_white_color: no batch with id `", batch_id, "`")
        else
            local color = batch.white_color
            color[1], color[2], color[3], color[4] = r, g, b, a
            self:_update_particle_color(batch, false) -- white only
        end

        if self._use_instancing then
            self:_update_color_mesh()
        end
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

--- @brief draw all batches
--- @return nil
function SimulationHandler:draw()
    self:_update_canvases()
    self:_draw_canvases()
end

--- @brief update all batches
function SimulationHandler:update(delta)
    self:_assert(
        delta, "number"
    )

    local settings = self._settings

    -- accumulate delta time, run sim at fixed framerate for better stability
    self._elapsed = self._elapsed + delta
    local step = settings.step_delta
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

    self._interpolation_alpha = math.clamp(self._elapsed / step, 0, 1)

    if self._use_instancing then
        self:_update_data_mesh()
        -- no need to update color mesh
    end
end

-- ### internals, never call any of the functions below ### --

--- @brief [internal] allocate a new instance
--- @param settings table? override settings
function SimulationHandler._new() -- sic, no :, self is returned instance, not type
    local self = setmetatable({}, {
        __index = SimulationHandler
    })

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

    self._white_data_mesh_data = {}
    self._white_color_data_mesh_data = {}

    self._yolk_data_mesh_data = {}
    self._yolk_color_data_mesh_data = {}

    self._max_radius = 1

    self._canvases_need_update = false
    self._elapsed = 0

    self:_initialize_shaders()
    self:_initialize_particle_texture()

    local supported = love.graphics.getSupported()
    self._use_instancing = true --[[supported.instancing == true
        and (supported.glsl3 == true or supported.glsl4 == true)]]

    if self._use_instancing then
        local position_name = "particle_position"
        local velocity_name = "particle_velocity"
        local radius_name = "particle_radius"
        local color_name = "particle_color"

        if love.getVersion() < 12 then
            self._data_mesh_format = {
                { position_name, "float", 4 },
                { velocity_name, "float", 2 },
                { radius_name, "float", 1 }
            }

            self._color_mesh_format = {
                { color_name, "float", 4 }
            }
        else
            self._data_mesh_format = {
                { location = 3, name = position_name, format = "floatvec4" }, -- xy: position, zw: previous position
                { location = 4, name = velocity_name, format = "floatvec2" },
                { location = 5, name = radius_name, format = "float" },
            }

            self._color_mesh_format = {
                { location = 6, name = color_name, format = "floatvec4" }
            }
        end

        self:_initialize_instance_mesh()

        -- data and color mesh are separate, as only the data mesh changes every
        -- frame, uploading the same color every frame to vram is suboptimal

        if self._use_instancing then
            self:_update_data_mesh()
            self:_update_color_mesh()
        end
    end

    self._white_canvas = nil -- love.Canvas
    self._yolk_canvas = nil -- love.Canvas

    self._last_white_env = nil -- cf. _step
    self._last_yolk_env = nil

    do -- texture format needs to have non [0, 1] range, find first available on this machine
        local available_formats
        if love.getVersion() >= 12 then
            available_formats = love.graphics.getTextureFormats({
                canvas = true
            })
        else
            available_formats = love.graphics.getCanvasFormats()
        end

        local texture_format = nil
        for _, format in ipairs({
            "rgba32f",
            "rgba16f",
            "rgba8"
        }) do
            if available_formats[format] == true then
                texture_format = format
                break
            end
        end

        self._render_texture_format = texture_format
    end
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
            self:_error(_FATAL, "In SimulationHandler._initialize_shader: unable to create shader at `", path, "`: ", shader_or_error)
        else
            return shader_or_error
        end
    end

    self._particle_texture_shader = new_shader(self._settings.particle_texture_shader_path)
    self._threshold_shader = new_shader(self._settings.threshold_shader_path)
    self._outline_shader = new_shader(self._settings.outline_shader_path)
    self._instanced_draw_shader = new_shader(self._settings.instanced_draw_shader_path)

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
        settings.white.max_radius,
        settings.yolk.max_radius
    ) * settings.particle_texture_resolution_factor

    local padding = self._settings.particle_texture_padding -- px

    -- create canvas, transparent outer padding so derivative on borders is 0
    local canvas_width = (radius + padding) * 2
    local canvas_height = canvas_width

    self._particle_texture = love.graphics.newCanvas(canvas_width, canvas_height, {
            format = self._render_texture_format, -- first [0, 1] format that has 4 components
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

--- @brief [internal] initialize data related to instanced drawing
function SimulationHandler:_initialize_instance_mesh()
    local new = function()
        -- 5-vertex quad with side length 1 centered at 0, 0
        local x, y, r = 0, 0, 1
        local mesh = love.graphics.newMesh({
            { x    , y    , 0.5, 0.5,  1, 1, 1, 1 },
            { x - r, y - r, 0.0, 0.0,  1, 1, 1, 1 },
            { x + r, y - r, 1.0, 0.0,  1, 1, 1, 1 },
            { x + r, y + r, 1.0, 1.0,  1, 1, 1, 1 },
            { x - r, y + r, 0.0, 1.0,  1, 1, 1, 1 }
        }, "triangles", "static")

        mesh:setVertexMap(
            1, 2, 3,
            1, 3, 4,
            1, 4, 5,
            1, 5, 2
        )
        mesh:setTexture(self._particle_texture)
        return mesh
    end

    -- we need two separate meshes for instance drawing because each
    -- will have their own data mesh attached that holds all the particle data
    self._white_instance_mesh = new()
    self._yolk_instance_mesh = new()
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
local _cell_x_offset = 10 -- spatial hash x coordinate, set in _step
local _cell_y_offset = 11 -- spatial hash y coordinate
local _batch_id_offset = 12 -- batch id
local _r_offset = 13 -- rgba red
local _g_offset = 14 -- rgba green
local _b_offset = 15 -- rgba blue
local _a_offset = 16 -- rgba opacity

local _stride = _a_offset + 1

--- convert particle index to index in shared particle property array
local _particle_i_to_data_offset = function(particle_i)
    return (particle_i - 1) * _stride + 1 -- 1-based
end

--- @brief [internal]
function SimulationHandler:_update_data_mesh()
    local function update_data_mesh(particles, n_particles, instance_mesh, mesh_data, mesh)
        if n_particles == 0 then return nil end
        local before = #mesh_data
        
        -- update mesh data
        for particle_i = 1, n_particles do
            local current = mesh_data[particle_i]
            if current == nil then
                current = {}
                mesh_data[particle_i] = current
            end

            local i = _particle_i_to_data_offset(particle_i)
            current[1] = particles[i + _x_offset]
            current[2] = particles[i + _y_offset]
            current[3] = particles[i + _previous_x_offset]
            current[4] = particles[i + _previous_y_offset]

            current[5] = particles[i + _velocity_x_offset]
            current[6] = particles[i + _velocity_y_offset]

            current[7] = particles[i + _radius_offset]
        end
        
        while #mesh_data > n_particles do
            table.remove(mesh_data, #mesh_data)
        end
        
        local after = #mesh_data
        
        if mesh == nil or before ~= after then
            -- if resized, reallocate mesh
            local data_mesh = love.graphics.newMesh(
                self._data_mesh_format,
                mesh_data,
                "triangles", -- unused, this mesh will never be drawn
                "stream"
            )

            -- attach for rendering
            if love.getVersion() >= 12 then
                for _, entry in ipairs(self._data_mesh_format) do
                    instance_mesh:attachAttribute(entry.name, data_mesh, "perinstance")
                end
            else
                for i, entry in ipairs(self._data_mesh_format) do
                    instance_mesh:attachAttribute(entry[i], data_mesh, "perinstance")
                end
            end

            return data_mesh
        else
            -- else upload vertex data
            mesh:setVertices(mesh_data)
            return mesh
        end
    end

    self._white_data_mesh = update_data_mesh(
        self._white_data,
        self._total_n_white_particles,
        self._white_instance_mesh,
        self._white_data_mesh_data,
        self._white_data_mesh
    )

    self._yolk_data_mesh = update_data_mesh(
        self._yolk_data,
        self._total_n_yolk_particles,
        self._yolk_instance_mesh,
        self._yolk_data_mesh_data,
        self._yolk_data_mesh
    )
end

--- @brief [internal]
function SimulationHandler:_update_color_mesh()
    local function update_color_mesh(particles, n_particles, instance_mesh, mesh_data, mesh)
        if n_particles == 0 then return nil end
        local before = #mesh_data

        for particle_i = 1, n_particles do
            local current = mesh_data[particle_i]
            if current == nil then
                current = {}
                mesh_data[particle_i] = current
            end

            local i = _particle_i_to_data_offset(particle_i)
            current[1] = particles[i + _r_offset]
            current[2] = particles[i + _g_offset]
            current[3] = particles[i + _b_offset]
            current[4] = particles[i + _a_offset]
        end

        while #mesh_data > n_particles do
            table.remove(mesh_data, #mesh_data)
        end

        local after = #mesh_data

        if mesh == nil or before ~= after then
            -- (re)allocated
            local color_data_mesh = love.graphics.newMesh(
                self._color_mesh_format,
                mesh_data,
                "triangles", -- unused
                "stream"
            )

            -- attach
            if love.getVersion() >= 12 then
                for _, entry in ipairs(self._color_mesh_format) do
                    instance_mesh:attachAttribute(entry.name, color_data_mesh, "perinstance")
                end
            else
                for i, entry in ipairs(self._color_mesh_format) do
                    instance_mesh:attachAttribute(entry[i], color_data_mesh, "perinstance")
                end
            end

            return color_data_mesh
        else
            -- else upload vertex data
            mesh:setVertices(mesh_data)
            return mesh
        end
    end

    self._white_color_data_mesh = update_color_mesh(
        self._white_data,
        self._total_n_white_particles,
        self._white_instance_mesh,
        self._white_color_data_mesh_data,
        self._white_color_data_mesh
    )

    self._yolk_color_data_mesh = update_color_mesh(
        self._yolk_data,
        self._total_n_yolk_particles,
        self._yolk_instance_mesh,
        self._yolk_color_data_mesh_data,
        self._yolk_data_mesh
    )
end

--- @brief [internal] create a new particle batch
function SimulationHandler:_new_batch(
    center_x, center_y,
    white_x_radius, white_y_radius, white_n_particles, white_color,
    yolk_x_radius, yolk_y_radius, yolk_n_particles, yolk_color
)
    local batch = {
        white_particle_indices = {},
        yolk_particle_indices = {},
        white_radius = math.max(white_x_radius, white_y_radius),
        yolk_radius = math.max(yolk_x_radius, yolk_y_radius),
        white_color = white_color,
        yolk_color = yolk_color,
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
        local value
        repeat
            value = love.math.randomNormal(0.25, 0.5)
        until value >= 0 and value <= 1
        return value
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

    -- instead of randomizing masses, precompute them to be in a gaussian-like distribution
    -- where each value is represented in the interval
    local get_mass = function(i, n)
        local t = (i - 1) / n
        local variance = self._settings.mass_distribution_variance
        local butterworth = 1 / (1 + (variance * (t - 0.5))^4)
        return butterworth
    end

    -- add particle data to the batch particle property buffer
    local add_particle = function(
        array, settings,
        x_radius, y_radius,
        particle_i, n_particles,
        color, batch_id
    )
        -- generate position
        local dx, dy = fibonacci_spiral(particle_i, n_particles, x_radius, y_radius)
        local x = center_x + dx
        local y = center_y + dy

        -- mass and radius use the same interpolation factor, since volume and mass are correlated
        -- we could compute mass as a function of radius, but being able to choose the mass distribution
        -- manually gives more freedom when fine-tuning the simulation
        local t = get_mass(particle_i, n_particles)
        local mass = math.mix(
            settings.min_mass,
            settings.max_mass,
            t
        )

        local radius = math.mix(settings.min_radius, settings.max_radius, t)

        local i = #array + 1
        array[i + _x_offset] = x
        array[i + _y_offset] = y
        array[i + _z_offset] = 0
        array[i + _velocity_x_offset] = 0
        array[i + _velocity_y_offset] = 0
        array[i + _previous_x_offset] = x
        array[i + _previous_y_offset] = y
        array[i + _radius_offset] = radius
        array[i + _mass_offset] = mass
        array[i + _inverse_mass_offset] = 1 / mass
        array[i + _cell_x_offset] = -math.huge
        array[i + _cell_y_offset] = -math.huge
        array[i + _batch_id_offset] = batch_id
        array[i + _r_offset] = color[1]
        array[i + _g_offset] = color[2]
        array[i + _b_offset] = color[3]
        array[i + _a_offset] = color[4]

        self._max_radius = math.max(self._max_radius, radius)
        return i
    end

    local batch_id = self._current_batch_id
    self._current_batch_id = self._current_batch_id + 1

    for i = 1, white_n_particles do
        table.insert(batch.white_particle_indices, add_particle(
            self._white_data,
            self._settings.white,
            white_x_radius, white_y_radius,
            i, white_n_particles,
            batch.white_color,
            batch_id
        ))
    end

    for i = 1, yolk_n_particles do
        table.insert(batch.yolk_particle_indices, add_particle(
            self._yolk_data,
            self._settings.yolk,
            yolk_x_radius, yolk_y_radius,
            i, yolk_n_particles,
            batch.yolk_color,
            batch_id
        ))
    end

    batch.n_white_particles = white_n_particles
    batch.n_yolk_particles = yolk_n_particles

    if self._use_instancing then
        self:_update_data_mesh()
        self:_update_color_mesh()
    end

    return batch_id, batch
end

--- @brief [internal] remove particle data from shared array
function SimulationHandler:_remove(white_indices, yolk_indices)
    local function remove_particles(indices, data, list_name)
        if not indices or #indices == 0 then return end

        local stride = _stride
        local total_particles = #data / stride

        -- mark particles to remove
        local remove = {}
        for _, base in ipairs(indices) do
            local p = math.floor((base - 1) / stride) + 1
            remove[p] = true
        end

        -- compute new index for each particle (prefix sum)
        local new_index = {}
        local write = 0
        for read = 1, total_particles do
            if not remove[read] then
                write = write + 1
                new_index[read] = write
            end
        end

        -- compact particle data
        for read = 1, total_particles do
            local write_i = new_index[read]
            if write_i and write_i ~= read then
                local src = (read  - 1) * stride + 1
                local dst = (write_i - 1) * stride + 1
                for o = 0, stride - 1 do
                    data[dst + o] = data[src + o]
                end
            end
        end

        -- truncate array (only table.remove usage)
        for i = write * stride + 1, #data do
            data[i] = nil
        end

        -- update only affected batches
        for _, batch in pairs(self._batch_id_to_batch) do
            local list = batch[list_name]
            if list then
                local n = #list
                local w = 1
                for r = 1, n do
                    local old_base = list[r]
                    local old_p = math.floor((old_base - 1) / stride) + 1
                    local new_p = new_index[old_p]
                    if new_p then
                        list[w] = (new_p - 1) * stride + 1
                        w = w + 1
                    end
                end
                for i = w, n do list[i] = nil end
            end
        end
    end

    remove_particles(white_indices, self._white_data, "white_particle_indices")
    remove_particles(yolk_indices,  self._yolk_data,  "yolk_particle_indices")

    if self._use_instancing then
        self:_update_data_mesh()
        self:_update_color_mesh()
    end
end

--- @brief [internal]
function SimulationHandler:_update_particle_color(batch, yolk_or_white)
    local particles, indices, color
    if yolk_or_white == true then
        particles = self._yolk_data
        indices = batch.yolk_particle_indices
        color = batch.yolk_color
    elseif yolk_or_white == false then
        particles = self._white_data
        indices = batch.white_particle_indices
        color = batch.white_color
    end

    local r, g, b, a = (unpack or table.unpack)(color)
    for _, particle_i in ipairs(indices) do
        local i = _particle_i_to_data_offset(particle_i)
        particles[i + _r_offset] = r
        particles[i + _g_offset] = g
        particles[i + _b_offset] = b
        particles[i + _a_offset] = a
    end
end

-- ### STEP HELPERS ### --
do
    -- table.clear, fallback implementations for non luajit
    pcall(require, "table.clear")
    if not table.clear then
        function table.clear(t)
            for key in pairs(t) do
                t[key] = nil
            end
            return t
        end
    end

    --- convert settings strength to XPBD compliance parameters
    local function _strength_to_compliance(strength, sub_step_delta)
        local alpha = 1 - math.clamp(strength, 0, 1)
        local alpha_per_substep = alpha / (sub_step_delta^2)
        return alpha_per_substep
    end

    --- setup environments for yolks and white separately
    local _create_environment = function(current_env)
        if current_env == nil then
            -- create new environment
            return {
                particles = {}, -- Table<Number>, particle properties stored inline
                collided = {}, -- Set<Number> particle pair hash

                spatial_hash = {}, -- Table<Number, Table<Number>> particle cell hash to list of particles
                batch_id_to_follow_x = {}, -- Table<Number, Number>
                batch_id_to_follow_y = {}, -- Table<Number, Number>
                batch_id_to_radius = {},

                damping = 1, -- overridden in _step

                min_x = math.huge, -- particle position bounds, px
                min_y = math.huge,
                max_x = -math.huge,
                max_y = -math.huge,

                n_particles = 0,

                center_of_mass_x = 0, -- set in post-solve, px
                center_of_mass_y = 0,
                centroid_x = 0,
                centroid_y = 0,
            }
        else
            -- if old env present, keep allocated to keep gc / allocation pressure low
            local env = current_env

            -- reset tables
            table.clear(env.spatial_hash)
            table.clear(env.collided)
            table.clear(env.batch_id_to_follow_x)
            table.clear(env.batch_id_to_follow_y)

            -- reset variables
            env.min_x = math.huge
            env.min_y = math.huge
            env.max_x = -math.huge
            env.max_y = -math.huge
            env.centroid_x = 0
            env.centroid_y = 0

            return env
        end
    end

    --- pre solve: integrate velocity and update last position
    local _pre_solve = function(particles, n_particles, damping, delta)
        for particle_i = 1, n_particles do
            local i = _particle_i_to_data_offset(particle_i)
            local x_i = i + _x_offset
            local y_i = i + _y_offset
            local previous_x_i = i + _previous_x_offset
            local previous_y_i = i + _previous_y_offset
            local velocity_x_i = i + _velocity_x_offset
            local velocity_y_i = i + _velocity_y_offset

            local x, y = particles[x_i], particles[y_i]

            particles[previous_x_i] = x
            particles[previous_y_i] = y

            local velocity_x = particles[velocity_x_i] * damping
            local velocity_y = particles[velocity_y_i] * damping

            particles[velocity_x_i] = velocity_x
            particles[velocity_y_i] = velocity_y

            particles[x_i] = x + delta * velocity_x
            particles[y_i] = y + delta * velocity_y
        end
    end

    --- make particles move towards target
    local _solve_follow_constraint = function(
        particles, n_particles,
        batch_id_to_radius, batch_id_to_follow_x, batch_id_to_follow_y,
        compliance
    )
        for particle_i = 1, n_particles do
            local i = _particle_i_to_data_offset(particle_i)
            local x_i = i + _x_offset
            local y_i = i + _y_offset
            local inverse_mass_i = i + _inverse_mass_offset
            local batch_id_i = i + _batch_id_offset
            local radius_i = i + _radius_offset

            local batch_id = particles[batch_id_i]
            local follow_x = batch_id_to_follow_x[batch_id]
            local follow_y = batch_id_to_follow_y[batch_id]

            local x, y = particles[x_i], particles[y_i]
            local current_distance = math.distance(x, y, follow_x, follow_y)
            local target_distance = batch_id_to_radius[batch_id]

            -- XPBD: enforce distance to anchor to be 0
            local inverse_mass = particles[inverse_mass_i]
            if inverse_mass > math.eps and current_distance > target_distance then
                local dx, dy = math.normalize(follow_x - x, follow_y - y)

                local constraint_violation = current_distance - target_distance
                local correction = constraint_violation / (inverse_mass + compliance)

                local x_correction = dx * correction * inverse_mass
                local y_correction = dy * correction * inverse_mass

                particles[x_i] = particles[x_i] + x_correction
                particles[y_i] = particles[y_i] + y_correction
            end
        end
    end

    --- szudzik's pairing function, converts x, y integer index to hash
    local _xy_to_hash = function(x, y)
        local a = x >= 0 and (x * 2) or (-x * 2 - 1)
        local b = y >= 0 and (y * 2) or (-y * 2 - 1)

        if a >= b then
            return a * a + a + b
        else
            return b * b + a
        end
    end

    --- repopulate spatial hash for later positional queries
    local _rebuild_spatial_hash = function(particles, n_particles, spatial_hash, spatial_hash_cell_radius)
        for particle_i = 1, n_particles do
            local i = _particle_i_to_data_offset(particle_i)
            local x = i + _x_offset
            local y = i + _y_offset
            local hash_cell_x = i + _cell_x_offset
            local hash_cell_y = i + _cell_y_offset

            local cell_x = math.floor(particles[x] / spatial_hash_cell_radius)
            local cell_y = math.floor(particles[y] / spatial_hash_cell_radius)

            -- store in particle data for later access
            particles[hash_cell_x] = cell_x
            particles[hash_cell_y] = cell_y

            -- convert to hash, then store in that cell
            local hash = _xy_to_hash(cell_x, cell_y)
            local entry = spatial_hash[hash]
            if entry == nil then
                entry = {}
                spatial_hash[hash] = entry
            end

            table.insert(entry, particle_i)
        end
    end

    -- XPBD: enforce distance between two particles to be a specific value
    local function _enforce_distance(
        ax, ay, bx, by,
        inverse_mass_a, inverse_mass_b,
        target_distance,
        compliance
    )
        local dx = bx - ax
        local dy = by - ay

        local current_distance = math.magnitude(dx, dy)
        dx, dy = math.normalize(dx, dy)

        local constraint_violation = current_distance - target_distance

        local mass_sum = inverse_mass_a + inverse_mass_b

        local correction = -constraint_violation / (mass_sum + compliance)

        local max_correction = math.abs(constraint_violation)
        correction = math.clamp(correction, -max_correction, max_correction)

        local a_correction_x = -dx * correction * inverse_mass_a
        local a_correction_y = -dy * correction * inverse_mass_a

        local b_correction_x =  dx * correction * inverse_mass_b
        local b_correction_y =  dy * correction * inverse_mass_b

        return a_correction_x, a_correction_y, b_correction_x, b_correction_y
    end

    --- enforce collision and cohesion
    local function _solve_collision(
        particles, n_particles,
        spatial_hash, collided,
        collision_overlap_factor, collision_compliance,
        cohesion_interaction_distance_factor, cohesion_compliance,
        max_n_collisions
    )
        local n_collided = 0

        for self_particle_i = 1, n_particles do
            local self_i = _particle_i_to_data_offset(self_particle_i)
            local self_x_i = self_i + _x_offset
            local self_y_i = self_i + _y_offset

            local self_inverse_mass = particles[self_i + _inverse_mass_offset]
            local self_radius = particles[self_i + _radius_offset]
            local self_batch_id = particles[self_i + _batch_id_offset]

            local cell_x = particles[self_i + _cell_x_offset]
            local cell_y = particles[self_i + _cell_y_offset]

            for x_offset = -1, 1 do
                for y_offset = -1, 1 do
                    local spatial_hash_hash = _xy_to_hash(
                        cell_x + x_offset,
                        cell_y + y_offset
                    )

                    local entry = spatial_hash[spatial_hash_hash]
                    if entry == nil then goto next_index end

                    for _, other_particle_i in ipairs(entry) do

                        -- avoid collision with self
                        if self_particle_i == other_particle_i then goto next_pair end

                        -- only collide each unique pair once
                        local pair_hash = _xy_to_hash(
                            math.min(self_particle_i, other_particle_i),
                            math.max(self_particle_i, other_particle_i)
                        )

                        if collided[pair_hash] == true then goto next_pair end
                        collided[pair_hash] = true

                        local other_i = _particle_i_to_data_offset(other_particle_i)
                        local other_x_i = other_i + _x_offset
                        local other_y_i = other_i + _y_offset

                        local other_inverse_mass = particles[other_i + _inverse_mass_offset]
                        local other_radius = particles[other_i + _radius_offset]
                        local other_batch_id = particles[other_i + _batch_id_offset]

                        -- degenerate particle data
                        if self_inverse_mass + other_inverse_mass < math.eps then goto next_pair end

                        do -- cohesion: move particles in the same batch towards each other
                            local self_x, self_y, other_x, other_y =
                            particles[self_x_i],  particles[self_y_i],
                            particles[other_x_i],  particles[other_y_i]

                            local interaction_distance
                            if self_batch_id == other_batch_id then
                                interaction_distance = 0
                            else
                                interaction_distance = cohesion_interaction_distance_factor * (self_radius + other_radius)
                            end

                            if self_batch_id ~= other_batch_id and
                                math.squared_distance(self_x, self_y, other_x, other_y) <= interaction_distance^2
                            then
                                local self_correction_x, self_correction_y,
                                other_correction_x, other_correction_y = _enforce_distance(
                                    self_x, self_y, other_x, other_y,
                                    self_inverse_mass, other_inverse_mass,
                                    interaction_distance, cohesion_compliance
                                )

                                particles[self_x_i] = self_x + self_correction_x
                                particles[self_y_i] = self_y + self_correction_y
                                particles[other_x_i] = other_x + other_correction_x
                                particles[other_y_i] = other_y + other_correction_y
                            end
                        end

                        do -- collision: enforce distance between particles to be larger than minimum
                            local min_distance = collision_overlap_factor * (self_radius + other_radius)

                            local self_x, self_y, other_x, other_y =
                                particles[self_x_i],  particles[self_y_i],
                                particles[other_x_i],  particles[other_y_i]

                            local distance = math.squared_distance(self_x, self_y, other_x, other_y)
                            -- use squared distance, slightly more performant

                            if distance <= min_distance^2 then
                                local self_correction_x, self_correction_y,
                                other_correction_x, other_correction_y = _enforce_distance(
                                    self_x, self_y, other_x, other_y,
                                    self_inverse_mass, other_inverse_mass,
                                    min_distance, collision_compliance
                                )

                                particles[self_x_i] = self_x + self_correction_x
                                particles[self_y_i] = self_y + self_correction_y
                                particles[other_x_i] = other_x + other_correction_x
                                particles[other_y_i] = other_y + other_correction_y
                            end
                        end

                        -- emergency safety check, if too many particles cluster together this avoids slowdown
                        n_collided = n_collided + 1
                        if n_collided >= max_n_collisions then return end

                        ::next_pair::
                    end
                    ::next_index::
                end
            end
        end
    end

    -- Replace the existing _post_solve with this version.
    local function _post_solve(particles, n_particles, delta)
        local min_x, min_y = math.huge, math.huge
        local max_x, max_y = -math.huge, -math.huge
        local centroid_x, centroid_y = 0, 0

        local max_velocity = 0
        local max_radius = 0

        for particle_i = 1, n_particles do
            local i = _particle_i_to_data_offset(particle_i)
            local x_i = i + _x_offset
            local y_i = i + _y_offset
            local previous_x_i = i + _previous_x_offset
            local previous_y_i = i + _previous_y_offset
            local velocity_x_i = i + _velocity_x_offset
            local velocity_y_i = i + _velocity_y_offset
            local radius_i = i + _radius_offset

            local x = particles[x_i]
            local y = particles[y_i]

            local velocity_x = (x - particles[previous_x_i]) / delta
            local velocity_y = (y - particles[previous_y_i]) / delta
            particles[velocity_x_i] = velocity_x
            particles[velocity_y_i] = velocity_y

            local velocity_magnitude = math.magnitude(velocity_x, velocity_y)
            if velocity_magnitude > max_velocity then
                max_velocity = velocity_magnitude
            end

            centroid_x = centroid_x + x
            centroid_y = centroid_y + y

            -- log AABB including particle radius
            local r = particles[radius_i]
            if r > max_radius then max_radius = r end
            min_x = math.min(min_x, x - r)
            min_y = math.min(min_y, y - r)
            max_x = math.max(max_x, x + r)
            max_y = math.max(max_y, y + r)
        end

        if n_particles > 0 then
            centroid_x = centroid_x / n_particles
            centroid_y = centroid_y / n_particles
        end

        return min_x, min_y, max_x, max_y, centroid_x, centroid_y, max_radius, max_velocity
    end

    --- @brief [internal]
    function SimulationHandler:_step(delta)
        local sim_settings = self._settings
        local n_sub_steps = sim_settings.n_sub_steps
        local n_collision_steps = self._settings.n_collision_steps
        local sub_delta = delta / n_sub_steps

        local white_settings = sim_settings.white
        local yolk_settings = sim_settings.yolk

        -- setup environments for yolk / white separately
        local function update_environment(old_env, phase_settings, particles, n_particles)
            local env = _create_environment(old_env)
            env.particles = particles
            env.n_particles = n_particles

            -- robust collision budget (ensure a reasonable minimum to avoid early exits)
            local fraction = sim_settings.max_n_collision_fraction or 0.4
            env.max_n_collisions = math.max(fraction * env.n_particles * env.n_particles, env.n_particles * 32)

            -- compute spatial hash cell radius to cover both collision and cohesion interaction radii
            local max_factor = math.max(
                phase_settings.collision_overlap_factor or 1,
                phase_settings.cohesion_interaction_distance_factor or 1
            )
            env.spatial_hash_cell_radius = math.max(1, self._max_radius * max_factor)

            -- precompute batch id to follow position for faster access
            for batch_id, batch in pairs(self._batch_id_to_batch) do
                env.batch_id_to_follow_x[batch_id] = batch.target_x
                env.batch_id_to_follow_y[batch_id] = batch.target_y
            end

            env.damping = 1 - math.clamp(phase_settings.damping or 0, 0, 1)

            env.follow_compliance = _strength_to_compliance(phase_settings.follow_strength, sub_delta)
            env.collision_compliance = _strength_to_compliance(phase_settings.collision_strength, sub_delta)
            env.cohesion_compliance = _strength_to_compliance(phase_settings.cohesion_strength, sub_delta)
            return env
        end

        local white_env = update_environment(
            self._last_white_env, white_settings,
            self._white_data, self._total_n_white_particles
        )

        local yolk_env = update_environment(
            self._last_yolk_env, yolk_settings,
            self._yolk_data,  self._total_n_yolk_particles
        )

        -- update radii
        for batch_id, batch in pairs(self._batch_id_to_batch) do
            white_env.batch_id_to_radius[batch_id] = math.sqrt(batch.white_radius)
            yolk_env.batch_id_to_radius[batch_id] = math.sqrt(batch.yolk_radius)
        end

        for sub_step_i = 1, n_sub_steps do
            _pre_solve(
                white_env.particles,
                white_env.n_particles,
                white_env.damping,
                sub_delta
            )

            _pre_solve(
                yolk_env.particles,
                yolk_env.n_particles,
                yolk_env.damping,
                sub_delta
            )

            _solve_follow_constraint(
                white_env.particles,
                white_env.n_particles,
                white_env.batch_id_to_radius,
                white_env.batch_id_to_follow_x,
                white_env.batch_id_to_follow_y,
                white_env.follow_compliance
            )

            _solve_follow_constraint(
                yolk_env.particles,
                yolk_env.n_particles,
                yolk_env.batch_id_to_radius,
                yolk_env.batch_id_to_follow_x,
                yolk_env.batch_id_to_follow_y,
                yolk_env.follow_compliance
            )

            for collision_i = 1, n_collision_steps do
                _rebuild_spatial_hash(
                    white_env.particles,
                    white_env.n_particles,
                    white_env.spatial_hash,
                    white_env.spatial_hash_cell_radius
                )

                _rebuild_spatial_hash(
                    yolk_env.particles,
                    yolk_env.n_particles,
                    yolk_env.spatial_hash,
                    yolk_env.spatial_hash_cell_radius
                )

                _solve_collision(
                    white_env.particles,
                    white_env.n_particles,
                    white_env.spatial_hash,
                    white_env.collided,
                    white_settings.collision_overlap_factor,
                    white_env.collision_compliance,
                    white_settings.cohesion_interaction_distance_factor,
                    white_env.cohesion_compliance,
                    white_env.max_n_collisions
                )

                _solve_collision(
                    yolk_env.particles,
                    yolk_env.n_particles,
                    yolk_env.spatial_hash,
                    yolk_env.collided,
                    yolk_settings.collision_overlap_factor,
                    yolk_env.collision_compliance,
                    yolk_settings.cohesion_interaction_distance_factor,
                    yolk_env.cohesion_compliance,
                    yolk_env.max_n_collisions
                )

                if collision_i < n_collision_steps then
                    -- clear afeter each pass to avoid double counting
                    table.clear(white_env.spatial_hash)
                    table.clear(white_env.collided)
                    table.clear(yolk_env.spatial_hash)
                    table.clear(yolk_env.collided)
                end
            end

            white_env.min_x, white_env.min_y,
            white_env.max_x, white_env.max_y,
            white_env.centroid_x, white_env.centroid_y,
            white_env.max_radius, white_env.max_velocity = _post_solve(
                white_env.particles,
                white_env.n_particles,
                sub_delta
            )

            yolk_env.min_x, yolk_env.min_y,
            yolk_env.max_x, yolk_env.max_y,
            yolk_env.centroid_x, yolk_env.centroid_y,
            yolk_env.max_radius, yolk_env.max_velocity = _post_solve(
                yolk_env.particles,
                yolk_env.n_particles,
                sub_delta
            )
        end -- sub-steps

        -- after solver, resize render textures if necessary
        local function resize_canvas_maybe(canvas, env)
            if env.n_particles == 0 then
                return canvas
            end

            local current_w, current_h = 0, 0
            if canvas ~= nil then
                current_w, current_h = canvas:getDimensions()
            end

            -- compute canvas padding
            local padding = 3 + env.max_radius * self._settings.texture_scale * (1 + self._settings.motion_blur_multiplier * math.max(1, env.max_velocity) * self._settings.step_delta)

            -- Required canvas size (ceil to integers)
            local new_w = math.ceil((env.max_x - env.min_x) + 2 * padding)
            local new_h = math.ceil((env.max_y - env.min_y) + 2 * padding)

            if new_w > current_w or new_h > current_h then
                local new_canvas = love.graphics.newCanvas(
                    math.max(new_w, current_w),
                    math.max(new_h, current_h),
                    {
                        msaa = self._settings.canvas_msaa,
                        format = self._render_texture_format
                    }
                )
                new_canvas:setFilter("linear", "linear")

                if canvas ~= nil then
                    canvas:release() -- free old as early as possible, uses vram
                end
                return new_canvas
            else
                return canvas
            end
        end

        self._white_canvas = resize_canvas_maybe(self._white_canvas, white_env)
        self._yolk_canvas = resize_canvas_maybe(self._yolk_canvas, yolk_env)

        -- keep env of last step
        self._last_white_env = white_env
        self._last_yolk_env = yolk_env

        self._canvases_need_update = true
    end
end -- step helpers

do
    --- update a love shader uniform with error handling
    local _safe_send = function(shader, uniform, value)
        local success, error_maybe = pcall(shader.send, shader, uniform, value)
        if not success then
            SimulationHandler:_error(false, "In SimulationHandler._draw: ", error_maybe)
        end
    end

    --- @brief [internal] update canvases with particle data
    function SimulationHandler:_update_canvases()
        if self._canvases_need_update == false
            or self._yolk_canvas == nil
            or self._white_canvas == nil
        then return end

        local draw_particles
        if not self._use_instancing then
            draw_particles = function(env, _)
                love.graphics.push()
                love.graphics.translate(-env.centroid_x, -env.centroid_y)

                local particles = env.particles
                local texture_scale = self._settings.texture_scale
                local texture_w, texture_h = self._particle_texture:getDimensions()
                for particle_i = 1, env.n_particles do
                    local i = _particle_i_to_data_offset(particle_i)
                    local radius = particles[i + _radius_offset]
                    local x = particles[i + _x_offset]
                    local y = particles[i + _y_offset]
                    local velocity_x = particles[i + _velocity_x_offset]
                    local velocity_y = particles[i + _velocity_y_offset]

                    local velocity_angle = math.atan2(velocity_y, velocity_x)
                    local base_scale = radius * texture_scale
                    local smear_amount = 1 + math.magnitude(velocity_x, velocity_y) * self._settings.motion_blur_multiplier

                    local scale_x = base_scale * smear_amount
                    local scale_y = base_scale

                    -- frame interpolation, since sim runs at fixed fps
                    local t = self._interpolation_alpha
                    local predicted_x = math.mix(particles[i + _previous_x_offset], x, t)
                    local predicted_y = math.mix(particles[i + _previous_y_offset], y, t)

                    local alpha = particles[i + _a_offset]
                    love.graphics.setColor(
                        particles[i + _r_offset] * alpha,
                        particles[i + _g_offset] * alpha,
                        particles[i + _b_offset] * alpha,
                        particles[i + _a_offset]
                    )

                    love.graphics.draw(self._particle_texture,
                        predicted_x, predicted_y,
                        velocity_angle,
                        scale_x / texture_w * 2, scale_y / texture_w * 2,
                        0.5 * texture_w, 0.5 * texture_h
                    )
                end

                love.graphics.pop()
            end
        else
            draw_particles = function(env, instance_mesh)
                love.graphics.push()
                love.graphics.translate(-env.centroid_x, -env.centroid_y)
                love.graphics.setColor(1, 1, 1, 1)
                love.graphics.drawInstanced(instance_mesh, env.n_particles)
                love.graphics.pop()
            end
        end

        love.graphics.push("all")
        love.graphics.reset()
        love.graphics.setBlendMode("screen", "premultiplied")

        if self._use_instancing then
            love.graphics.setShader(self._instanced_draw_shader)
            _safe_send(self._instanced_draw_shader, "interpolation_alpha", self._interpolation_alpha)
            _safe_send(self._instanced_draw_shader, "smear_multiplier", self._settings.motion_blur_multiplier)
            _safe_send(self._instanced_draw_shader, "texture_scale", self._settings.texture_scale)
        else
            love.graphics.setShader(nil)
        end

        do -- egg white
            local canvas = self._white_canvas
            local canvas_width, canvas_height = canvas:getDimensions()
            love.graphics.setCanvas(canvas)
            love.graphics.clear(0, 0, 0, 0)

            love.graphics.push()
            love.graphics.translate(canvas_width / 2, canvas_height / 2)
            draw_particles(self._last_white_env, self._white_instance_mesh)
            love.graphics.pop()
        end

        do -- egg yolk
            local canvas = self._yolk_canvas
            local canvas_width, canvas_height = canvas:getDimensions()
            love.graphics.setCanvas(canvas)
            love.graphics.clear(0, 0, 0, 0)

            love.graphics.push()
            love.graphics.translate(canvas_width / 2, canvas_height / 2)
            draw_particles(self._last_yolk_env, self._yolk_instance_mesh)
            love.graphics.pop()
        end

        love.graphics.pop() -- all
        self._canvases_need_update = false
    end

    --- @brief [internal] composite canvases to final image
    function SimulationHandler:_draw_canvases()
        if self._white_canvas == nil or self._yolk_canvas == nil then return end

        love.graphics.push("all")
        love.graphics.setBlendMode("alpha", "premultiplied")

        -- respects setColor before SimulationHandler.draw, premultiply alpha
        local r, g, b, a = love.graphics.getColor()
        love.graphics.setColor(
            r * a,
            g * a,
            b * a,
            a * a
        )

        love.graphics.setShader(self._threshold_shader)
        _safe_send(self._threshold_shader, "threshold", self._settings.threshold_shader_threshold)
        _safe_send(self._threshold_shader, "smoothness", self._settings.threshold_shader_smoothness)

        local draw_canvas = function(canvas, env)
            local canvas_width, canvas_height = canvas:getDimensions()
            local canvas_x, canvas_y = env.centroid_x - 0.5 * canvas_width,
            env.centroid_y - 0.5 * canvas_height
            love.graphics.draw(canvas, canvas_x, canvas_y)
        end

        draw_canvas(self._white_canvas, self._last_white_env)
        draw_canvas(self._yolk_canvas, self._last_yolk_env)

        love.graphics.setShader(nil)
        love.graphics.pop()
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

    message = table.concat(message, " ") .. "\n"

    -- write to error stream and flush and print to console immediately
    if is_fatal then
        error(message)
    else
        io.stderr:write(message .. "\n")
        io.stderr:flush()
    end
end

--- @brief [internal] assert function arguments to be of a specific type
function SimulationHandler:_assert(...)
    local should_exit = true

    local n = select("#", ...)
    if n % 2 ~= 0 then
        self:_error(_FATAL, "In SimulationHandler._assert: number of arguments is not a multiple of 2")
        return should_exit
    end

    for i = 1, n, 2 do
        local instance = select(i + 0, ...)
        local instance_type = select(i + 1, ...)
        if not type(instance) == instance_type then
            self:_error(_FATAL, "for argument #", i, ": expected `", instance_type, "`, got `", instance_type, "`")
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