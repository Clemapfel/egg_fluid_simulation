local shader_path_prefix = "egg_fluid_simulation"
-- path prefix, uses / instead of ., change this depending on where the library is located
-- for example, if this file is in /common/simulation/simulation_handler replace this
-- with `common/simulation_handler`

require(string.gsub(shader_path_prefix .. "/math", "[/\\]", "."))
local log = require(shader_path_prefix .. "/log", "[/\\]", ".")

--- @class SimulationHandler
local SimulationHandler = {}
setmetatable(SimulationHandler, {
    __call = function(...)
        return SimulationHandler.new(...)
    end
})

--- @brief add a new batch to the simulation
--- @param x number x position, px
--- @param y number y position, px
--- @param white_radius number? radius of the egg white, px
--- @param yolk_radius number? radius of egg yolk, px
--- @param white_color table? color in rgba format, components in [0, 1]
--- @param yolk_color table? color in rgba format, components in [0, 1]
--- @return number integer id of the new batch
function SimulationHandler:add(x, y, white_radius, yolk_radius, white_color, yolk_color)
    if white_radius == nil then white_radius = 50 end
    if yolk_radius == nil then
        yolk_radius = white_radius * (10 / 50)
        -- fraction experimentally determined to look nice
    end
    
    white_color = white_color or self._white_config.color
    yolk_color = yolk_color or self._yolk_config.color

    log.assert(
        x, "number",
        y, "number",
        white_radius, "number",
        yolk_radius, "number",
        white_color, "table",
        yolk_color, "table"
    )
    
    if white_radius <= 0 then 
        log.error( "In SimulationHandler.add: white radius cannot be 0 or negative")
    end

    if yolk_radius <= 0 then
        log.error( "In SimulationHandler.add: yolk radius cannot be 0 or negative")
    end

    do -- assert color
        local component_names = { "r", "g", "b", "a" }
        local which = {
            white = white_color,
            yolk = yolk_color
        }

        for name, color in pairs(which) do
            for i, component_name in ipairs(component_names) do
                if type(color[i]) ~= "number" or math.is_nan(color[i]) then
                    log.error("In SimulationHandler.add: ", name, " color component `", component_name, "` is not a number")
                    return
                end

                if color[i] < 0 or color[i] > 1 then
                    log.warning("In SimulationHandler.add: ", name, " color component `", component_name, "` is outside of [0, 1]")
                end

                color[i] = math.clamp(color[i], 0, 1)
            end
        end
    end

    local white_area = math.pi * white_radius^2 -- area of a circle = pi * r^2
    local white_n_particles = math.max(5, math.ceil(self._particle_density * white_area))

    local yolk_area = math.pi * yolk_radius^2
    local yolk_n_particles = math.max(5, math.ceil(self._particle_density * yolk_area))

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
    log.assert(batch_id, "number")

    local batch = self._batch_id_to_batch[batch_id]
    if batch == nil then
        log.warning("In SimulationHandler.remove: no batch with id `", batch_id, "`")
        return
    end

    self._batch_id_to_batch[batch_id] = nil
    self._n_batches = self._n_batches - 1
    self._total_n_white_particles = self._total_n_white_particles - batch.n_white_particles
    self._total_n_yolk_particles = self._total_n_yolk_particles - batch.n_yolk_particles

    self:_remove(batch.white_particle_indices, batch.yolk_particle_indices)
end

--- @brief draw all batches
--- @return nil
function SimulationHandler:draw()
    self:_update_canvases()
    self:_draw_canvases()
end

--- @brief update all batches
--- @param step_delta number fixed timestep, seconds
--- @param n_substeps number number of solver iterations per step, integer
--- @param n_collision_steps number number of collision sub steps per iteration step, integer
function SimulationHandler:update(delta, step_delta, n_substeps, n_collision_steps)
    if step_delta == nil then step_delta = 1 / 60 end
    if n_substeps == nil then n_substeps = 2 end
    if n_collision_steps == nil then n_collision_steps = 3 end

    log.assert(
        delta, "number",
        step_delta, "number",
        n_substeps, "number",
        n_collision_steps, "number"
    )

    -- catch floats instead of ints
    n_substeps = math.ceil(n_substeps)
    n_collision_steps = math.ceil(n_collision_steps)

    if step_delta < 0 or math.is_nan(step_delta) then
        log.error("In SimulationHandler.update: `step_delta` is not a number > 0")
        return
    end

    if n_substeps < 1 or math.is_nan(n_substeps) then
        log.error("In SimulationHandler.update: `n_substeps` is not a number > 0")
        return
    end

    if n_collision_steps < 1 or math.is_nan(n_collision_steps) then
        log.error("In SimulationHandler.update: `n_collision_steps` is not a number > 0")
        return
    end

    -- accumulate delta time, run sim at fixed framerate for better stability
    self._elapsed = self._elapsed + delta
    local step = step_delta
    local n_steps = 0
    local max_n_steps = math.max(4, 4 * math.ceil((1 / 60) / step_delta))
    while self._elapsed >= step do
        self:_step(step, n_substeps, n_collision_steps)
        self._elapsed = self._elapsed - step

        -- safety check to prevent death spiral
        n_steps = n_steps + 1
        if n_steps > max_n_steps then
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

--- @brief update the mutable simulation parameters for the white
--- @param config table table of properties, see the readme for a list of valid properties
function SimulationHandler:set_white_config(config)
    log.assert(config, "table")
    self:_load_config(config, true) -- egg white
end

--- @brief update the mutable simulation parameters for the yolk
--- @param config table table of properties, see the readme for a list of valid properties
function SimulationHandler:set_yolk_config(config)
    log.assert(config, "table")
    self:_load_config(config, false) -- egg yolk
end

--- @brief get current config for the white, contains all keys
--- @return table read-only, writing to this table will not affect the handler
function SimulationHandler:get_white_config()
    return self:_deepcopy(self._white_config)
end

--- @brief get current config for the white, contains all keys
--- @return table read-only, writing to this table will not affect the handler
function SimulationHandler:get_yolk_config()
    return self:_deepcopy(self._yolk_config)
end

--- @brief set the target position a batch should move to
--- @param batch_id number batch id returned by SimulationHandler.add
--- @param x number x coordinate, in px
--- @param y number y coordinate, in px
function SimulationHandler:set_target_position(batch_id, x, y)
    log.assert(batch_id, "number", x, "number", y, "number")

    local batch = self._batch_id_to_batch[batch_id]
    if batch == nil then
        log.warning( "In SimulationHandler.set_target_position: no batch with id `", batch_id, "`")
    else
        batch.target_x = x
        batch.target_y = y
    end
end

--- @brief get the target position a batch should move to
--- @return number, number
function SimulationHandler:get_target_position(batch_id)
    log.assert(batch_id, "number")

    local batch = self._batch_id_to_batch[batch_id]
    if batch == nil then
        log.error( "In SimulationHandler.get_target_position: no batch with id `", batch_id, "`")
        return nil, nil
    else
        return batch.target_x, batch.target_y
    end
end

--- @brief get average of all particle positions of a batch
function SimulationHandler:get_position(batch_id)
    log.assert(batch_id, "number")

    local batch = self._batch_id_to_batch[batch_id]
    if batch == nil then
        log.error( "In SimulationHandler.get_target_position: no batch with id `", batch_id, "`")
        return nil, nil
    else
        if batch.centroid_needs_update then
            self:_update_batch_centroid(batch)
        end

        return batch.centroid_x, batch.centroid_y
    end
end

do
    --- argument assertion helper for set_*_color functions
    local _assert_color = function(scope, r, g, b, a)
        if a == nil then a = 1 end

        log.assert(
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
            log.warning( "In SimulationHandler.", scope, ": color component is outside of [0, 1]")
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
    function SimulationHandler:set_yolk_color(batch_id,
        r, g, b, a,
        outline_r, outline_g, outline_b, outline_a
    )
        log.assert(batch_id, "number")
        r, g, b, a = _assert_color("set_egg_yolk_color", r, g, b, a)

        local config = self._yolk_config
        if outline_r == nil then outline_r = config.outline_color[1] end
        if outline_g == nil then outline_g = config.outline_color[2] end
        if outline_b == nil then outline_b = config.outline_color[3] end
        if outline_a == nil then outline_a = config.outline_color[4] end

        outline_r, outline_g, outline_b, outline_a = _assert_color("set_white_color",
            outline_r, outline_g, outline_b, outline_a
        )

        local batch = self._batch_id_to_batch[batch_id]
        if batch == nil then
            log.warning( "In SimulationHandler.set_egg_yolk_color: no batch with id `", batch_id, "`")
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
    function SimulationHandler:set_white_color(batch_id,
        r, g, b, a,
        outline_r, outline_g, outline_b, outline_a
    )
        log.assert(batch_id, "number")
        r, g, b, a = _assert_color("set_white_color", r, g, b, a)

        local config = self._white_config
        if outline_r == nil then outline_r = config.outline_color[1] end
        if outline_g == nil then outline_g = config.outline_color[2] end
        if outline_b == nil then outline_b = config.outline_color[3] end
        if outline_a == nil then outline_a = config.outline_color[4] end

        outline_r, outline_g, outline_b, outline_a = _assert_color("set_white_color",
            outline_r, outline_g, outline_b, outline_a
        )

        local batch = self._batch_id_to_batch[batch_id]
        if batch == nil then
            log.warning( "In SimulationHandler.set_white_color: no batch with id `", batch_id, "`")
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

--- @brief get total number of particles
--- @return number
function SimulationHandler:get_n_particles(batch_or_nil)
    if batch_or_nil == nil then
        return self._total_n_white_particles + self._total_n_yolk_particles
    else
        local batch = self._batch_id_to_batch[batch_or_nil]
        if batch == nil then
            log.error("In SimulationHandler:get_n_particles: no batch with id `", batch_or_nil, "`")
        end
        return batch.n_white_particles + batch.n_yolk_particles
    end
end

local _type_metatable = { __index = SimulationHandler }

--- @brief create a new simulation handler instance. Usually this function is not called directly, use `instance = SimulationHandler()` instead
--- @return SimulationHandler
function SimulationHandler.new()
    -- sic, no :, self is returned instance, not type
    local self = setmetatable({}, _type_metatable)

    -- default white / yolk configs
    local outline_thickness = 1
    local particle_radius = 4
    local base_damping = 0.1
    local texture_scale = 12
    local base_mass = 1

    -- see README.md for a description of the parameters below

    self._white_config = {
        -- dynamic
        damping = base_damping,

        follow_strength = 1 - 0.004,

        cohesion_strength = 1 - 0.001,
        cohesion_interaction_distance_factor = 3,

        collision_strength = 1,
        collision_overlap_factor = 2,

        color = { 0.961, 0.961, 0.953, 1 },
        outline_color = { 0.973, 0.796, 0.529, 1 },
        outline_thickness = outline_thickness,

        highlight_strength = 0,
        shadow_strength = 1,

        -- static
        min_mass = base_mass,
        max_mass = base_mass * 1.8,

        min_radius = particle_radius,
        max_radius = particle_radius,

        texture_scale = texture_scale,
        motion_blur = 0.0003,
    }

    self._yolk_config = {
        -- dynamic
        damping = base_damping ,

        follow_strength = 1 - 0.004,

        cohesion_strength = 1 - 0.002,
        cohesion_interaction_distance_factor = 3,

        collision_strength = 1 - 0.001,
        collision_overlap_factor = 2,

        color = { 0.969, 0.682, 0.141, 1 },
        outline_color = { 0.984, 0.522, 0.271, 1 },
        outline_thickness = outline_thickness,

        highlight_strength = 1,
        shadow_strength = 0,

        -- static
        min_mass = base_mass,
        max_mass = base_mass * 1.35,

        min_radius = particle_radius,
        max_radius = particle_radius,

        texture_scale = texture_scale,
        motion_blur = 0.0003
    }

    -- immutable properties
    self._particle_texture_shader_path = shader_path_prefix .. "/simulation_handler_particle_texture.glsl"
    self._outline_shader_path = shader_path_prefix .. "/simulation_handler_outline.glsl"
    self._instanced_draw_shader_path = shader_path_prefix .. "/simulation_handler_instanced_draw.glsl"
    self._lighting_shader_path = shader_path_prefix .. "/simulation_handler_lighting.glsl"

    self._thresholding_threshold = 0.3 -- in [0, 1]
    self._thresholding_smoothness = 0.01 -- in [0, threshold_shader_threshold)

    self._mass_distribution_variance = 4 -- unitless, (2 * n) with n >= 1
    self._max_collision_fraction = 0.05 -- fraction
    self._particle_density = 1 / 128 -- particles per px^2
    self._use_particle_color = false -- whether particle rgb should be accumulated for the final image
    self._use_lighting = true -- whether specular highlight and shadows should be drawn

    -- render texture config
    self._canvas_msaa = 4 -- msaa for render textures
    self._particle_texture_padding = 3 -- px
    self._particle_texture_resolution_factor = 4 -- fraction

    self:_reinitialize()
    return self
end

-- ### internals, never call any of the functions below ### --

--- @brief [internal] clear the simulation, useful for debugging
--- @private
function SimulationHandler:_reinitialize()
    -- internal properties
    self._batch_id_to_batch = {} -- Table<Number, Batch>
    self._current_batch_id = 1
    self._n_batches = 0

    -- particle properties are stored inline
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
    self._interpolation_alpha = 0

    self:_initialize_shaders()
    self:_initialize_particle_texture()

    -- instancing is unavailable on certain GL EES
    local supported = love.graphics.getSupported()
    self._use_instancing = supported.instancing == true
        and (supported.glsl3 == true or supported.glsl4 == true)

    if self._use_instancing then
        local position_name = "particle_position"
        local velocity_name = "particle_velocity"
        local radius_name = "particle_radius"
        local color_name = "particle_color"

        assert(love.getVersion() >= 12, "Love v12.0 or later required, mesh data format is incompatible with earlier versions")

        do
            -- default love mesh format
            -- location = 0: VertexPosition
            -- location = 1: VertexTexCoord
            -- location = 2: VertexColor

            local i = 2
            self._data_mesh_format = {
                { location = i+1, name = position_name, format = "floatvec4" }, -- xy: position, zw: previous position
                { location = i+2, name = velocity_name, format = "floatvec2" },
                { location = i+3, name = radius_name, format = "float" },
            }

            -- data and color mesh are separate, as only the data mesh changes every
            -- frame, uploading the same color every frame to vram is suboptimal
            self._color_mesh_format = {
                { location = i+4, name = color_name, format = "floatvec4" }
            }
        end

        self:_initialize_instance_mesh()

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
        available_formats = love.graphics.getTextureFormats({
            canvas = true
        })

        local texture_format = nil
        for _, format in ipairs({
            "rgba8",
            "rgba16f",
            "rgba32f",
        }) do
            if available_formats[format] == true then
                texture_format = format
                break
            end
        end

        self._render_texture_format = texture_format
    end

    -- step once to init environments
    self:_step(0, 1, 1)
end

--- @brief [internal] load and compile necessary shaders
--- @private
function SimulationHandler:_initialize_shaders()
    local new_shader = function(path, defines)
        if defines == nil then defines = {} end
        local success, shader_or_error = pcall(
            love.graphics.newShader,
            path
        )

        if not success then
            log.error( "In SimulationHandler._initialize_shader: unable to create shader at `", path, "`: ", shader_or_error)
            return
        else
            return shader_or_error
        end
    end

    self._particle_texture_shader = new_shader(self._particle_texture_shader_path)
    self._outline_shader = new_shader(self._outline_shader_path)
    self._lighting_shader = new_shader(self._lighting_shader_path)

    self._instanced_draw_shader = new_shader(self._instanced_draw_shader_path)

    -- on vulkan, first use of a shader would cause stutter, so force use here, equivalent to precompiling the shader
    if love.getVersion() >= 12 and love.graphics.getRendererInfo() == "Vulkan" then
        love.graphics.push("all")
        local texture = love.graphics.newCanvas(1, 1)
        love.graphics.setCanvas(texture)
        for _, shader in ipairs({
            self._particle_texture_shader,
            self._lighting_shader,
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
--- @private
function SimulationHandler:_initialize_particle_texture()
    -- create particle texture, this will hold density information
    -- we use the same texture for all particles regardless of size,
    -- instead love.graphics.scale'ing based on particle size,
    -- this way all draws are batched

    local radius = math.max(
        self._white_config.max_radius,
        self._yolk_config.max_radius
    ) * self._particle_texture_resolution_factor

    local padding = self._particle_texture_padding -- px

    -- create canvas, transparent outer padding so derivative on borders is 0
    local canvas_width = (radius + padding) * 2
    local canvas_height = canvas_width

    self._particle_texture = love.graphics.newCanvas(canvas_width, canvas_height, {
            format = self._render_texture_format,
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
--- @private
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


-- particle properties are stored inline, these are the offset
local _x_offset = 0  -- x position, px
local _y_offset = 1  -- y position, px
local _z_offset = 2  -- render priority
local _velocity_x_offset = 3 -- x velocity, px / s
local _velocity_y_offset = 4 -- y velocity, px / s
local _previous_x_offset = 5 -- last sub steps x position, px
local _previous_y_offset = 6 -- last sub steps y position, px
local _radius_offset = 7 -- radius, px
local _mass_distribution_t_offset = 8
local _mass_offset = 9 -- mass, fraction
local _inverse_mass_offset = 10 -- 1 / mass, precomputed for performance
local _cell_x_offset = 11 -- spatial hash x coordinate, set in _step
local _cell_y_offset = 12 -- spatial hash y coordinate
local _batch_id_offset = 13 -- batch id
local _r_offset = 14 -- rgba red
local _g_offset = 15 -- rgba green
local _b_offset = 16 -- rgba blue
local _a_offset = 17 -- rgba opacity
local _last_update_x_offset = 18 -- last whole step x position, px
local _last_update_y_offset = 19 -- last whole step x position, px

local _stride = _last_update_y_offset + 1

--- convert particle index to index in shared particle property array
local _particle_i_to_data_offset = function(particle_i)
    return (particle_i - 1) * _stride + 1 -- 1-based
end

--- @brief [internal] upload vertex data mesh
--- @private
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
            current[3] = particles[i + _last_update_x_offset]
            current[4] = particles[i + _last_update_y_offset]

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
            for _, entry in ipairs(self._data_mesh_format) do
                instance_mesh:attachAttribute(entry.name, data_mesh, "perinstance")
            end

            return data_mesh
        else
            -- else upload vertex data
            mesh:setVertices(mesh_data)
            mesh:flush()
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

--- @brief [internal] upload color mesh data for instanced drawing
--- @private
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
            mesh_data[#mesh_data] = nil
        end

        local after = #mesh_data

        if mesh == nil or before ~= after then
            local color_data_mesh = love.graphics.newMesh(
                self._color_mesh_format,
                mesh_data,
                "triangles", -- unused
                "stream"
            )

            for _, entry in ipairs(self._color_mesh_format) do
                instance_mesh:attachAttribute(entry.name, color_data_mesh, "perinstance")
            end

            return color_data_mesh
        else
            mesh:setVertices(mesh_data)
            mesh:flush()
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
        self._yolk_color_data_mesh
    )
end

--- @brief [internal] create a new particle batch
--- @private
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
        target_y = center_y,
        centroid_x = center_x,
        centroid_y = center_y,
        centroid_needs_update = true
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

    -- instead of pure random mass, mass should always be exactly distributed in gaussian-like curve
    local get_mass = function(i, n)
        local variance = self._mass_distribution_variance
        local function butterworth(t)
            return 1 / (1 + (variance * (t - 0.5))^4)
        end

        -- 2-point gauss-legendre integration, reduces aliasing at low particle counts
        local left = (i - 1) / n
        local right = i / n

        local center = 0.5 * (left + right)
        local half_width = 0.5 * (right - left)

        local t1 = center - half_width / math.sqrt(3)
        local t2 = center + half_width / math.sqrt(3)

        return 0.5 * (butterworth(t1) + butterworth(t2))
    end

    -- add particle data to the batch particle property buffer
    local add_particle = function(
        array, config,
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
            config.min_mass,
            config.max_mass,
            t
        )

        local radius = math.mix(config.min_radius, config.max_radius, t)

        local i = #array + 1
        array[i + _x_offset] = x
        array[i + _y_offset] = y
        array[i + _z_offset] = 0
        array[i + _velocity_x_offset] = 0
        array[i + _velocity_y_offset] = 0
        array[i + _previous_x_offset] = x
        array[i + _previous_y_offset] = y
        array[i + _radius_offset] = radius
        array[i + _mass_distribution_t_offset] = t
        array[i + _mass_offset] = mass
        array[i + _inverse_mass_offset] = 1 / mass
        array[i + _cell_x_offset] = -math.huge
        array[i + _cell_y_offset] = -math.huge
        array[i + _batch_id_offset] = batch_id

        if self._use_particle_color then
            array[i + _r_offset] = color[1]
            array[i + _g_offset] = color[2]
            array[i + _b_offset] = color[3]
            array[i + _a_offset] = color[4]
        else
            array[i + _r_offset] = 1
            array[i + _g_offset] = 1
            array[i + _b_offset] = 1
            array[i + _a_offset] = 1
        end

        array[i + _last_update_x_offset] = x
        array[i + _last_update_y_offset] = y

        self._max_radius = math.max(self._max_radius, radius)
        return i
    end

    local batch_id = self._current_batch_id
    self._current_batch_id = self._current_batch_id + 1

    for i = 1, white_n_particles do
        table.insert(batch.white_particle_indices, add_particle(
            self._white_data,
            self._white_config,
            white_x_radius, white_y_radius,
            i, white_n_particles,
            batch.white_color,
            batch_id
        ))
    end

    for i = 1, yolk_n_particles do
        table.insert(batch.yolk_particle_indices, add_particle(
            self._yolk_data,
            self._yolk_config,
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
--- @private
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
            if list ~= nil then
                local old_count = #list
                local write_pos = 1
                for read_pos = 1, old_count do
                    local old_base_index = list[read_pos]
                    local old_particle_id = math.floor((old_base_index - 1) / stride) + 1
                    local new_particle_id = new_index[old_particle_id]
                    if new_particle_id then
                        list[write_pos] = (new_particle_id - 1) * stride + 1
                        write_pos = write_pos + 1
                    end
                end

                for i = write_pos, old_count do list[i] = nil end
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

--- @brief [internal] write new color for all particles
--- @private
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

--- @brief [internal] recompute batch centroid
--- @private
function SimulationHandler:_update_batch_centroid(batch)
    local x, y = 0, 0
    for _, i in ipairs(batch.white_particle_indices) do
        x = x + self._white_data[i + _x_offset]
        y = y + self._white_data[i + _y_offset]
    end

    for _, i in ipairs(batch.yolk_particle_indices) do
        x = x + self._yolk_data[i + _x_offset]
        y = y + self._yolk_data[i + _y_offset]
    end

    batch.centroid_x = x / (batch.n_white_particles + batch.n_yolk_particles)
    batch.centroid_y = y / (batch.n_white_particles + batch.n_yolk_particles)
end

do
    -- parameter to type and bounds for error handling
    local _valid_config_keys = {
        damping = {
            type = "number",
            min = 0,
            max = 1
        },

        color = {
            type = "color",
        },

        outline_color = {
            type = "color",
        },

        outline_thickness = {
            type = "number",
            min = 0
        },

        collision_strength = {
            type = "number",
            min = 0,
            max = 1
        },

        collision_overlap_factor = {
            type = "number",
            min = 0,
            max = nil
        },

        cohesion_strength = {
            type = "number",
            min = 0,
            max = 1
        },

        cohesion_interaction_distance_factor = {
            type = "number",
            min = 0,
            max = nil
        },

        follow_strength = {
            type = "number",
            min = 0,
            max = 1
        },

        min_radius = {
            type = "number",
            min = 0,
            max = nil
        },

        max_radius = {
            type = "number",
            min = 0,
            max = nil
        },

        min_mass = {
            type = "number",
            min = 0,
            max = nil
        },

        max_mass = {
            type = "number",
            min = 0,
            max = nil
        },

        motion_blur = {
            type = "number",
            min = 0,
            max = 1
        },

        texture_scale = {
            type = "number",
            min = 1,
            max = nil
        },

        highlight_strength = {
            type = "number",
            min = 0,
            max = nil
        },

        shadow_strength = {
            type = "number",
            min = 0,
            max = nil
        }
    }

    --- @brief [internal] override config setting
    --- @private
    function SimulationHandler:_load_config(config, white_or_yolk)
        local error = function(...)
            if white_or_yolk == true then
                log.error("In SimulationHandler.set_white_config: ", ...)
            else
                log.error("In SimulationHandler.set_yolk_config: ", ...)
            end
        end

        local warning = function(...)
            if white_or_yolk == true then
                log.warning("In SimulationHandler.set_white_config: ", ...)
            else
                log.warning("In SimulationHandler.set_yolk_config: ", ...)
            end
        end

        for key, value in pairs(config) do
            local entry = _valid_config_keys[key]
            if entry == nil then
                warning("unrecognized config key `", key, "`, it will be ignored")
                goto ignore
            end

            if entry.type == "color" then
                -- assert value is rgba table
                for i = 1, 4 do
                    local component = value[i]
                    if component == nil or #value > 4 then
                        error("color `", key, "` does not have 4 components")
                        return
                    elseif type(component) ~= "number" or math.is_nan(component) then
                        error("color `", key, "` has a component that is not a number")
                        return
                    elseif component < 0 or component > 1 then
                        warning("color `", key, "` has a component that is outside of [0, 1]")
                    end

                    value[i] = math.clamp(component, 0, 1)
                end
            else
                -- assert type and bounds
                if entry.type ~= nil and type(value) ~= entry.type then
                    error("wrong type for config key `", key, "`, expected `", entry.type, "`, got `", type(value), "`")
                    return
                elseif entry.type ~= nil and entry.type == "number" and math.is_nan(value) then
                    warning("config key `", key, "` is NaN, it will be ignored")
                    goto ignore
                elseif entry.min ~= nil and value < entry.min then
                    warning("config key `", key, "`'s value is `", value, "`, expected a value larger than `", entry.min, "`")
                    value = math.max(value, entry.min)
                elseif entry.max ~= nil and value > entry.max then
                    warning("config key `", key, "`'s value is `", value, "`, expected a value smaller than `", entry.max, "`")
                    value = math.min(value, entry.max)
                end
            end

            if white_or_yolk == true then
                self._white_config[key] = value
            elseif white_or_yolk == false then
                self._yolk_config[key] = value
            end

            ::ignore::
        end
    end
end

-- ### STEP HELPERS ### --
do
    -- table.clear, fallback implementations for non-luajit
    pcall(require, "table.clear")
    if not table.clear then
        function table.clear(t)
            for key in pairs(t) do
                t[key] = nil
            end
            return t
        end
    end

    --- convert config strength to XPBD compliance parameters
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
    local _pre_solve = function(
        particles, n_particles,
        damping, delta,
        should_update_mass, min_mass, max_mass,
        should_update_radius, min_radius, max_radius
    )
        for particle_i = 1, n_particles do
            local i = _particle_i_to_data_offset(particle_i)
            local x_i = i + _x_offset
            local y_i = i + _y_offset
            local velocity_x_i = i + _velocity_x_offset
            local velocity_y_i = i + _velocity_y_offset

            local x, y = particles[x_i], particles[y_i]

            particles[i + _previous_x_offset] = x
            particles[i + _previous_y_offset] = y

            local velocity_x = particles[velocity_x_i] * damping
            local velocity_y = particles[velocity_y_i] * damping

            particles[velocity_x_i] = velocity_x
            particles[velocity_y_i] = velocity_y

            particles[x_i] = x + delta * velocity_x
            particles[y_i] = y + delta * velocity_y

            -- recompute mass / radius from distribution
            local mass_t = particles[i + _mass_distribution_t_offset]
            if should_update_mass then
                local mass = math.mix(min_mass, max_mass, mass_t)
                particles[i + _mass_offset] = mass
                particles[i + _inverse_mass_offset] = 1 / mass
            end

            if should_update_radius then
                particles[i + _radius_offset] = math.mix(min_radius, max_radius, mass_t)
            end
        end
    end

    --- make particles move towards target
    local _solve_follow_constraint = function(
        particles, n_particles,
        batch_id_to_radius, batch_id_to_follow_x, batch_id_to_follow_y,
        compliance, dt
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
            local target_distance = 2 * batch_id_to_radius[batch_id]

            -- XPBD: enforce distance constraint with compliance
            local inverse_mass = particles[inverse_mass_i]
            if inverse_mass > math.eps and current_distance > target_distance then
                local dx, dy = math.normalize(follow_x - x, follow_y - y)

                local constraint_violation = current_distance - target_distance
                local delta_lambda = constraint_violation / (inverse_mass + compliance)

                local x_correction = dx * delta_lambda * inverse_mass
                local y_correction = dy * delta_lambda * inverse_mass

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

        local divisor = (mass_sum + compliance)
        if divisor < math.eps then return 0, 0, 0, 0 end

        local correction = -constraint_violation / divisor

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

                            if self_batch_id == other_batch_id and
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

    --- update true velocity, get aabb and centroid
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

    --- @brief [internal] step the simulation
    --- @private
    function SimulationHandler:_step(delta, n_sub_steps, n_collision_steps)
        local sub_delta = math.max(delta / n_sub_steps, math.eps)

        -- setup environments for yolk / white separately
        local function update_environment(old_env, config, particles, n_particles)
            local env = _create_environment(old_env)
            env.particles = particles
            env.n_particles = n_particles

            if old_env ~= nil then
                env.should_update_mass = config.min_mass ~= old_env.min_mass
                    or config.max_mass ~= old_env.max_mass
                env.should_update_radius = config.min_radius ~= old_env.min_radius
                    or config.max_radius ~= old_env.max_radius
            else
                env.should_update_mass = true
                env.should_update_radius = true
            end

            env.min_mass = config.min_mass
            env.max_mass = config.max_mass
            env.min_radius = config.min_radius
            env.max_radius = config.max_radius

            env.texture_scale = config.texture_scale
            env.motion_blur = config.motion_blur

            -- collision budget, limit maximum number of collisions processed per step
            -- this is to guard against all particles being so close together that the
            -- number of collision explodes
            local fraction = self._max_collision_fraction
            env.max_n_collisions = fraction * env.n_particles^2

            -- compute spatial hash cell radius to cover both collision and cohesion radii
            local max_factor = math.max(
                config.collision_overlap_factor,
                config.cohesion_interaction_distance_factor
            )
            env.spatial_hash_cell_radius = math.max(1, config.max_radius * max_factor)

            -- precompute batch id to follow position for faster access
            for batch_id, batch in pairs(self._batch_id_to_batch) do
                env.batch_id_to_follow_x[batch_id] = batch.target_x
                env.batch_id_to_follow_y[batch_id] = batch.target_y
            end

            env.damping = 1 - math.clamp(config.damping, 0, 1)

            env.follow_compliance = _strength_to_compliance(config.follow_strength, sub_delta)
            env.collision_compliance = _strength_to_compliance(config.collision_strength, sub_delta)
            env.cohesion_compliance = _strength_to_compliance(config.cohesion_strength, sub_delta)
            return env
        end

        local white_config = self._white_config
        local white_env = update_environment(
            self._last_white_env, white_config,
            self._white_data, self._total_n_white_particles
        )

        local yolk_config = self._yolk_config
        local yolk_env = update_environment(
            self._last_yolk_env, yolk_config,
            self._yolk_data,  self._total_n_yolk_particles
        )

        -- update radii
        for batch_id, batch in pairs(self._batch_id_to_batch) do
            white_env.batch_id_to_radius[batch_id] = math.sqrt(batch.white_radius)
            yolk_env.batch_id_to_radius[batch_id] = math.sqrt(batch.yolk_radius)
        end

        -- update pre-step positions for frame interpolation
        local update_last_positions = function(env)
            local particles = env.particles
            local sum_x, sum_y = 0, 0
            for particle_i = 1, env.n_particles do
                local i = _particle_i_to_data_offset(particle_i)
                local x = particles[i + _x_offset]
                local y = particles[i + _y_offset]
                particles[i + _last_update_x_offset] = x
                particles[i + _last_update_y_offset] = y
                sum_x = sum_x + x
                sum_y = sum_y + y
            end

            if env.n_particles > 0 then
                env.last_centroid_x = sum_x / env.n_particles
                env.last_centroid_y = sum_y / env.n_particles
            else
                env.last_centroid_x = 0
                env.last_centroid_y = 0
            end
        end

        update_last_positions(white_env)
        update_last_positions(yolk_env)

        -- step the simulation
        for sub_step_i = 1, n_sub_steps do
            _pre_solve(
                white_env.particles,
                white_env.n_particles,
                white_env.damping,
                sub_delta,
                white_env.should_update_mass,
                white_env.min_mass,
                white_env.max_mass,
                white_env.should_update_radius,
                white_env.min_radius,
                white_env.max_radius
            )

            _pre_solve(
                yolk_env.particles,
                yolk_env.n_particles,
                yolk_env.damping,
                sub_delta,
                yolk_env.should_update_mass,
                yolk_env.min_mass,
                yolk_env.max_mass,
                yolk_env.should_update_radius,
                yolk_env.min_radius,
                yolk_env.max_radius
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
                    white_config.collision_overlap_factor,
                    white_env.collision_compliance,
                    white_config.cohesion_interaction_distance_factor,
                    white_env.cohesion_compliance,
                    white_env.max_n_collisions
                )

                _solve_collision(
                    yolk_env.particles,
                    yolk_env.n_particles,
                    yolk_env.spatial_hash,
                    yolk_env.collided,
                    yolk_config.collision_overlap_factor,
                    yolk_env.collision_compliance,
                    yolk_config.cohesion_interaction_distance_factor,
                    yolk_env.cohesion_compliance,
                    yolk_env.max_n_collisions
                )

                if collision_i < n_collision_steps then
                    -- clear after each pass to avoid double counting
                    -- do not clear on last, already done in _update_environment
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
            local padding = env.max_radius * env.texture_scale
                * (1 +  math.max(1, env.max_velocity) * env.motion_blur)

            local new_w = math.ceil((env.max_x - env.min_x) + 2 * padding)
            local new_h = math.ceil((env.max_y - env.min_y) + 2 * padding)

            -- safety check, so canvases isn't unbounded on instable behavior
            new_w = math.min(new_w, 2560)
            new_h = math.min(new_h, 2560)

            -- reallocate if canvases needs to grow
            if new_w > current_w or new_h > current_h then
                local new_canvas = love.graphics.newCanvas(
                    math.max(new_w, current_w),
                    math.max(new_h, current_h),
                    {
                        msaa = self._canvas_msaa,
                        format = self._render_texture_format
                    }
                )
                new_canvas:setFilter("linear", "linear")

                if canvas ~= nil then
                    canvas:release() -- free old as early as possible, uses a lot of vram
                end
                return new_canvas
            else
                return canvas
            end
        end

        self._white_canvas = resize_canvas_maybe(self._white_canvas, white_env)
        self._yolk_canvas  = resize_canvas_maybe(self._yolk_canvas,  yolk_env)

        -- keep env of last step
        self._last_white_env = white_env
        self._last_yolk_env  = yolk_env

        self._canvases_need_update = true

        for _, batch in pairs(self._batch_id_to_batch) do
            batch.centroid_needs_update = true
        end
    end
end -- step helpers

do
    --- @brief [internal] update canvases with particle data
    --- @private
    function SimulationHandler:_update_canvases()
        if self._canvases_need_update == false
            or self._yolk_canvas == nil
            or self._white_canvas == nil
        then return end

        local t = self._interpolation_alpha

        local draw_particles
        if not self._use_instancing then
            draw_particles = function(env, _)
                -- interpolate centroid to match particle interpolation
                local cx = math.mix(env.last_centroid_x or env.centroid_x, env.centroid_x, t)
                local cy = math.mix(env.last_centroid_y or env.centroid_y, env.centroid_y, t)

                love.graphics.push()
                love.graphics.translate(-cx, -cy)

                local particles = env.particles
                local texture_scale = env.texture_scale
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
                    local smear_amount = 1 + math.magnitude(velocity_x, velocity_y) * env.motion_blur

                    local scale_x = base_scale * smear_amount
                    local scale_y = base_scale

                    -- frame interpolation
                    local predicted_x = math.mix(particles[i + _last_update_x_offset], x, t)
                    local predicted_y = math.mix(particles[i + _last_update_y_offset], y, t)

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
                -- frame interpolation for the centroid
                local predicted_centroid_x = math.mix(env.last_centroid_x or env.centroid_x, env.centroid_x, t)
                local predicted_centroid_y = math.mix(env.last_centroid_y or env.centroid_y, env.centroid_y, t)

                love.graphics.push()
                love.graphics.translate(-predicted_centroid_x, -predicted_centroid_y)
                love.graphics.setColor(1, 1, 1, 1)
                love.graphics.drawInstanced(instance_mesh, env.n_particles)
                love.graphics.pop()
            end
        end

        love.graphics.push("all")
        love.graphics.reset()

        -- alpha is accumulated by additive blending, then normalized to 0, 1 automatically
        love.graphics.setBlendMode("screen", "premultiplied")

        if self._use_instancing then
            love.graphics.setShader(self._instanced_draw_shader)
            self._instanced_draw_shader:send("interpolation_alpha", t)
        else
            love.graphics.setShader(nil)
        end

        do -- egg white
            local canvas = self._white_canvas
            local canvas_width, canvas_height = canvas:getDimensions()
            local env = self._last_white_env
            self._instanced_draw_shader:send("motion_blur", env.motion_blur)
            self._instanced_draw_shader:send("texture_scale", env.texture_scale)
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
            local env = self._last_yolk_env
            self._instanced_draw_shader:send("motion_blur", env.motion_blur)
            self._instanced_draw_shader:send("texture_scale", env.texture_scale)

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
    --- @private
    function SimulationHandler:_draw_canvases()
        if self._white_canvas == nil or self._yolk_canvas == nil then return end

        love.graphics.push("all")
        love.graphics.setBlendMode("alpha", "alphamultiply")

        -- reuse threshold parameters
        self._outline_shader:send("threshold", self._thresholding_threshold)

        self._lighting_shader:send("threshold", self._thresholding_threshold)
        self._lighting_shader:send("smoothness", self._thresholding_smoothness)
        self._lighting_shader:send("use_particle_color", self._use_particle_color)

        local draw_canvas = function(canvas, env, config)
            local canvas_width, canvas_height = canvas:getDimensions()
            local canvas_x = env.centroid_x - 0.5 * canvas_width
            local canvas_y = env.centroid_y - 0.5 * canvas_height

            local color = config.color
            local outline_color = config.outline_color
            local outline_thickness = config.outline_thickness

            if outline_thickness > 0 then
                love.graphics.setShader(self._outline_shader)
                self._outline_shader:send("outline_thickness", outline_thickness)
                love.graphics.setColor(outline_color)
                love.graphics.draw(canvas, canvas_x, canvas_y)

                if self._use_particle_color then
                    love.graphics.setColor(1, 1, 1, 1)
                else
                    love.graphics.setColor(color)
                end
            end

            love.graphics.setShader(self._lighting_shader)

            self._lighting_shader:send("highlight_strength", config.highlight_strength)
            self._lighting_shader:send("use_highlight",
                config.highlight_strength > 0 and self._use_lighting
            )

            self._lighting_shader:send("shadow_strength", config.shadow_strength)
            self._lighting_shader:send("use_shadow",
                config.shadow_strength > 0 and self._use_lighting
            )

            love.graphics.draw(canvas, canvas_x, canvas_y)

            love.graphics.setShader(nil)
        end

        draw_canvas(self._white_canvas,
            self._last_white_env,
            self._white_config
        )

        draw_canvas(self._yolk_canvas,
            self._last_yolk_env,
            self._yolk_config
        )

        love.graphics.setShader(nil)
        love.graphics.pop()
    end
end

--- @brief [internal] utility function that deepcopies a non-looping table
--- @private
function SimulationHandler:_deepcopy(t)
    local function _deepcopy_inner(original, seen)
        if type(original) ~= 'table' then
            return original
        end

        if seen[original] then
            error("In deepcopy: table `" .. tostring(original) .. "` is recursive, it cannot be deepcopied")
            return {}
        end

        local copy = {}

        seen[original] = copy
        for k, v in pairs(original) do
            copy[_deepcopy_inner(k, seen)] = _deepcopy_inner(v, seen)
        end
        seen[original] = nil

        return copy
    end

    if type(t) ~= "table" then return t end
    return _deepcopy_inner(t, {})
end

-- return type, invoking the type returns an instance: `local instance = SimulationHandler()`
return SimulationHandler