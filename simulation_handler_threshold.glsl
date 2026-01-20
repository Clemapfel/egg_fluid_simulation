#ifdef PIXEL

uniform float threshold = 0.5;
uniform float smoothness = 0.01;
uniform bool use_particle_color = true;

vec4 effect(vec4 color, sampler2D tex, vec2 texture_coordinates, vec2 frag_position) {
    vec4 data = texture(tex, texture_coordinates);
    float value = smoothstep(
        threshold - smoothness,
        threshold + smoothness,
        data.a
    );

    if (use_particle_color)
        return vec4(data.rgb * value, value) * color;
    else
        return vec4(value) * color;
}

#endif

