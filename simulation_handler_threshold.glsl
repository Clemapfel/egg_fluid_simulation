#ifdef PIXEL

uniform float threshold = 0.5;
uniform float smoothness = 0.05;

float tonemap(float t) {
    return sqrt(t);
}
vec4 effect(vec4 color, Image img, vec2 texture_coordinates, vec2 frag_position) {

    vec4 data = texture(img, texture_coordinates);
    float value = smoothstep(
        threshold - smoothness,
        threshold + smoothness,
        data.r
    );

    return vec4(tonemap(value * data.r)) * color;
}

#endif

