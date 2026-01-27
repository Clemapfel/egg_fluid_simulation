# XPBD-based Raw Egg Fluid Simulation

Author: C. Cords (github.com/clemapfel)

## General Usage

This class handles simulation of a number of viscous fluid batches, tuned to look like raw eggs. Each batch is made out of a number egg white and egg yolk particles, henceforth called "white" and "yolk".

To initialize the simulation, we instance the object like so

```lua
-- in global scope
local SimulationHandler = require "egg_fluid_simulation.simulation_handler"
local handler = SimulationHandler()
```

where the require path changes depending on the `shader_path_prefix` value at the top of this file. This value needs to be set to notify the library of where the file is located, such that it can load auxiliary files such as shader. 

For example, if the simulation handler is `/common/simulation/simulation_handler.lua` relative to the project root, then `shader_path_prefix` should be

```lua
local shader_path_prefix = "common/simulation"
```

Note that there should be no prefix `/`, no `/` at the end, and that is uses slashes, not `.`

To create a batch, we use `add`

```lua
local x, y = -- ...
local batch_id = handler:add(
    x,  -- x position of the initial batch center
    y,  -- y position
    50, -- radius of the white, in pixels
    15  -- radius of the yolk, in pixels
)
```

`add` returns a batch id. This is a number that we will need when referring to this specific batch later on. For example, to remove a batch at any time, we call

```lua
handler:remove(batch_id)
```

To control the position of a batch, we use `set_target_position`. This does not instantly update the batches location, rather it will now move towards that location with a speed dependend on the simulation paramters, which will be detailed below.

```lua
local target_x, target_y = -- ...
handler:set_target_position(
    batch_id,
    target_x, -- new target x position, in pixels
    target_y  -- new y position
)
```

To get the current position of a batch, we use `get_position`. This returns the average position of all particles in a batch, given an estimate of the batches center.

After having added our batch, we need to step the simulation in love.update

```lua
love.update = function(delta)
    handler:update(delta)
end
```

To draw all eggs, we use `draw`

```lua
love.draw = function()
    handler:draw()
end
```

The handler can hold any number of batches and is highly performant, though performance may degrade if multiple batches all **occupy the same space**. Batches have a fixed number of particles, the larger the egg, the more particles it will hold. Moving particles is cheap, but particle-particle interactions such as collision and cohesion get expensive if too many particles are too close, for example if 100 particles occupy the same space, the handler will have to resolve 100^2 = 1000 collisions. It is therefore best to keep batches spread out across the screen, only making them overlap if absolutely necessary.

Further generally useful functions include:

+ `get_target_position`, which returns the value set by `set_target_position`
+ `list_ids`, which lists all valid batch ids, in case we loose the id returned by `add`

## Simulation Parameters

The simulation uses a number of parameters that decide the motion and properties of the eggs. The solver can be highly sensitive to changes in parameters, so it is recommended to change them with caution, as an ill-chosen set of parameters can lead to instability, usually resulting in jitter, or particles overshooting and exploding away instead of behaving like a fluid.

To overwrite a parameter, we use `set_white_config` and `set_yolk_config`, both take the same set of parameter names, but the values of the parameters are separate for the yolk and white. Parameters are applied immedaitely upone the next simulation step.

### Damping

Unit: fraction in [0, 1]
Recommended Range: 0.05 - 0.2

Damping determines how fast velocities decay. Higher damping causes the fluid to move more sluggishly and have less jitter. At very low damping (< 0.05), the simulation will become unstable and rarely find a steady state. This may be desired if the egg should be highly fluid and "swirly".

```lua
handler:set_white_config({
    damping = 0.1
})
```

### Mass Distribution

Unit: unitless
Recommended Range: >=1

When a particle is generated, it will get a mass according to a realistic mass distribution. The exact range of these mass is determined by the `min_mass` and `max_mass` property. A wider gap between the minimum and maximum will mean that particles spread out more when moving, as heavier particles move slower and have more inertia than light particles.

```lua
handler:set_white_config({
    min_mass = 1,
    max_mass = 1.25
})
```

### Collision Strength

Unit: fraction in [0, 1]
Recommended Range: 0.2 - 1

The solver will try to make it so particles do not overlap. Collision strength regulates how strictly this is enforced, a higher strength means particles are more consistently placed apart. Higher values towards 1 are recommended, as this will keep too many particles from overlapping at the same position, avoided performance degradation.

```lua
handler:set_white_config({
    collision_strength = 1
})
```

### Collision Overlap Factor

Unit: factor
Recommended Range: 1 - 3

Determines how far particles spread out when colliding. Larger factors cause eggs to occupy more space, while the particle count and radius stays constant. The rendering pass relies on particles to overlap partially, so setting an overlap factor that is too high will cause the eggs to cease being rendered as a fluid and simple appear as spread-apart balls.

```lua
handler:set_white_config({
    collision_overlap_factor = 2
})
```

### Follow Strength

Unit: fraction in [0, 1)
Recommend Range: 0.2 - 0.9990

Follow strength determines how quickly a batch approaches its target position. The higher the strength, the faster it will move. Note that follow strength tries to move all particles in a batch to the same target position, then the collision engine will cause them to not overlap. Because of this, high follow strength may result in batches being very "compressed", as all particle as moved towards the target so much, the collision can barely keep them apart, so it may be necessary to adjust `collision_strength` if very high `follow_strength` is desired.

```lua
handler:set_white_config({
    follow_strength = 1 - 10e-3
})
```

### Cohesion Strength

Unit: fraction in [0, 1]
Recommended range: 0.0 - 0.9990

While collision keeps particles apart, cohesion keeps them together. High cohesion strength will result in a more viscous fluid. Cohesions between particles is only applied if both particles are in the same batch. Therefore, higher cohesion will also make it harder for batches to mix.

```lua
handler:set_white_config({
    cohesion_strength = 0.9
})
```

### Cohesion Interaction Distance Factor

Unit: factor
Recommended Range: 1 - 3

For particles `a`, `b`, only when the distance between their center is `cohesion_interaction_distance_factor * (a.radius + b.radius)` many pixels apart, will cohesion be applied. This factor essentially controls how big the neighborhood of each particle within the same batch is. Higher values cause cohesion to be applied more evenly across the batch, but may result in worse performance, as more particle pairs need to be processed.

```lua
handler:set_white_config({
    cohesion_interaction_distance_factor = 2
})
```

### Number of Particles

Unit: unitless count

The simulation will automatically estimate the number of required particles based on the average particle radius, as controlled by `min_radius`, `max_radius`, and the requested area of the white and yolk specified in `add`. We can get the current number of particles for each batch like so:

```lua
local white_n_particles, yolk_n_particles = handler:get_n_particles(batch_id)
```

or, if `batch_id` is nil, it will return the sum total number of particles for all batches, again separately for white and yolk.

We can manually control the number of particles of each batch using two additional optional arguments of `add`:
```lua
handler:add(
    25, 50, -- batch xy
    30, 15, -- batch white radius, batch yolk radius
    nil, nil, -- batch colors (unset, will be kept at default)
    20, -- number of white particles override 
    20  -- number of yolk particles override
)
```

This gives us finer control over how many particles are active in each batch. The simulation can become unstable if the
number of particles is very low (< 5) or very high (> 200). While there is a performance incentive to keep the number of
particles low, for best stability the solver should have at least 15 - 30 particles to work with.

### Step Delta

Unit: seconds
Recommended Range: 1 / 60 or 1 / 120

For numerical stability, the simulation is run at a fixed time step, even though the `delta` argument of `update` can be any number. `step_delta` decides this fixed timestep. We do not set the timestep using `set_*_config`, instead it is an optional parameter of the `update` function.

```lua
handler:update(
    delta,  -- variable delta time
    1 / 60  -- fixed time step
)
```

### Number of Sub Steps

Unit: count, unsigned integer
Recommended Range: >= 2

For more stable behavior, the simulation will run a number of sub steps per `update`. The higher the sub step count, the higher quality the simulation will be, though of course each sub step adds a performance penalty. Therefore a balance has to be found between simulation quality and runtime performance when choosing this paramter.

Like `step_delta`, `n_sub_steps` is an optional argument of `update`

```lua
handler:update(
    delta,  -- variable delta time
    1 / 60, -- fixed time step
    2       -- n sub steps
)
```

### Number of Collision Steps

Unit: count, unsigned integer
Recommended Range: 1 - 3

As particle-particle interactions cause most of the instability in an ill-tuned simulation, the solve will run through the collision routine a number of times per *sub* step, not per step. For example, if we have 4 sub steps and 3 collision steps, the collision routine will be run 4 * 3 = 12 times per step. It is therefore recommended to keep the number of sub steps and collision steps as low as is acceptable.

Like `n_sub_steps`, `n_collision_steps` is an optional argument of `update`

```lua
handler:update(
    delta,  -- variable delta time
    1 / 60, -- fixed time step
    2,      -- n sub steps
    3       -- n collision steps
)
```

### Texture Scale

Unit: factor
Recommended Range: 5 - 15

While not affecting the motion of particles, `texture_scale` is a critical parameter for how the eggs are drawn. The larger `texture_scale`, the more "round" and even the contour of an egg will be. At low texture scales, the particles will appear as separate circles, breaking the illusion of a coherent fluid. Larger texture scale means more pixels need to be drawn to accumulate the final egg shape, which affects drawing performance.

```lua
handler:set_white_config({
    texture_scale = 11.5
})
```

### Radius Distribution

Unit: pixels
Recommend Range: 1 - 5

This is the base size of each particle, which will later be multiplied by the texture scale to draw the final image for each particle. Increasing this will cause the entire egg to appear larger in area, while maintaining the number of particles. Changing a particles radius will also multiply with `cohesion_interaction_distance_factor` and `collision_overlap_factor`, so care should be taken to tune these parameters as a whole, instead of just increasing radius.

```lua
handler:set_white_config({
    min_radius = 1,
    max_radius = 3
})
```

### Motion Blur

Unit: factor per pixel per second
Recommended Range: 0 - 0.001

Also only affecting how eggs are drawn, `motion_blur` will determine how much eggs stretch when moving quickly. This is also commonly known as "smear frames" in traditional animation. The exact value of `motion_blur` is a factor that is multiplied with the particle velocity magnitude, which is measured in pixels per second.

```lua
handler:set_white_config({
    motion_blur = 0.0005
})
```

### Color, Outline Color

Unit: rgba, components in [0, 1]

Sets the color of the yolk or white, this will be the base color used for drawing. Lighting is applied on top. Both the base color and outline color can be chosen separately.

```lua
handler:set_white_config({
    color = { 1, 0.9, 1, 1 }, -- base color
    outline_color = { 0.33, 0.25, 0.33, 1 } -- outline color
})
```

### Outline Thickness

Type: dynamic
Unit: factor, >= 0

Multiplies the default outline thickness by this factor, meaning 2 makes the outline twice as thick, 0.5 half as thick. A value of 0 will prevent outlines from being drawn. 

```lua
handler:set_white_config({
    outline_thickness = 1
})
```

### Shadows, Highlights

Type: dynamic
Unit: factor, >= 0

The rendered draws heightmap based specular highlights and shadows on top of the egg. `shadow_strength` and `highlight_strength` determine whether and how much lighting is applied on top of the yolk or white. A strength of 0 means that that part of the lighting is bypassed entirely, a strength of 1 is the default, a strength of 2 means the highlight or shadow is twice as intense.

```lua
handler:set_white_config({
    shadow_strength = 1,
    highlight_strength = 0 -- no higlights
})
```