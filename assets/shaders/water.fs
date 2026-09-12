#version 330
in vec3 position;
uniform vec3 cameraPosition;
uniform float time;
out vec4 finalColor;
void main() {
    float wave = sin(position.x * 0.44 + time * 0.65) * sin(position.z * 0.36 - time * 0.5);
    vec3 color = mix(vec3(0.24, 0.49, 0.51), vec3(0.33, 0.60, 0.60), wave * 0.5 + 0.5);
    float glint = pow(max(sin(position.x * 1.1 + position.z * 0.7 + time * 0.8), 0.0), 28.0);
    color += glint * 0.025;
    float distance = length(position - cameraPosition);
    float fog = 1.0 - exp(-pow(distance * 0.008, 2.0));
    finalColor = vec4(mix(color, vec3(0.70, 0.80, 0.81), fog), 1.0);
}
