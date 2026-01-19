#pragma language glsl3

#ifdef VERTEX

layout (location = 3) in vec4 particle_position; // xy: current xy, zw: last frame xy
layout (location = 4) in vec2 particle_velocity;
layout (location = 5) in float particle_radius;
layout (location = 6) in vec4 particle_color;

uniform float interpolation_alpha;
uniform float smear_multiplier;
uniform float texture_scale;

varying vec4 color_override;

vec4 position(mat4 transform_projection, vec4 vertex_position) {
    // instance mesh is centered at 0, with radius of 1
    // scale mesh to radius size and offset to position

    vec2 current_position = particle_position.xy;
    vec2 previous_position = particle_position.zw;

    vec2 xy = vertex_position.xy;
    float velocity_angle = atan(particle_velocity.y, particle_velocity.x);

    float base_scale = particle_radius * texture_scale;
    float smear_amount = 1.0 + length(particle_velocity) * smear_multiplier;

    vec2 scale = vec2(base_scale * smear_amount, base_scale);
    float cos_angle = cos(velocity_angle);
    float sin_angle = sin(velocity_angle);

    vec2 scaled_vertex = xy * scale;

    vec2 rotated_vertex = vec2(
        scaled_vertex.x * cos_angle - scaled_vertex.y * sin_angle,
        scaled_vertex.x * sin_angle + scaled_vertex.y * cos_angle
    );

    vec2 offset = mix(previous_position, current_position, interpolation_alpha);
    vertex_position.xy = rotated_vertex + offset;

    color_override = particle_color;

    return transform_projection * vertex_position;
}

#endif

#ifdef PIXEL

varying vec4 color_override;

vec4 effect(vec4 color, sampler2D tex, vec2 texture_coords, vec2 screen_coords) {
    return texture(tex, texture_coords) * color * color_override;
}

#endif
