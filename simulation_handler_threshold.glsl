#ifdef PIXEL

uniform float threshold = 0.5;
uniform float smoothness = 0.05;

vec4 effect(vec4 color, Image img, vec2 texture_coordinates, vec2 frag_position) {

    vec4 data = texture(img, texture_coordinates);
    float value = smoothstep(
    threshold - smoothness,
    threshold + smoothness,
    data.a
    );

    return vec4(value) * color;
}

#endif

