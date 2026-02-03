-- default white / yolk configs
local outline_thickness = 1
local particle_radius = 4
local base_damping = 0.1
local texture_scale = 12
local base_mass = 1

-- see README.md for a description of the parameters below

local white_config = {
    -- dynamic
    damping = base_damping,

    follow_strength = 1 - 0.004,

    cohesion_strength = 1 - 0.2,
    cohesion_interaction_distance_factor = 2,

    collision_strength = 1 - 0.0025,
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

local yolk_config = {
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

return white_config, yolk_config