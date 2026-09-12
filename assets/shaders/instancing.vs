#version 330
layout(location = 0) in vec3 vertexPosition;
layout(location = 1) in vec2 vertexTexCoord;
layout(location = 2) in vec3 vertexNormal;
layout(location = 8) in vec4 instancePositionScale;
layout(location = 9) in vec4 instanceVariation;
uniform mat4 mvp;
uniform mat4 lightVP;
uniform float time;
out vec2 fragTexCoord;
out vec3 fragNormal;
out vec3 fragPosition;
out vec4 shadowPosition;
out float fragTint;
void main() {
    float c = cos(instanceVariation.x), s = sin(instanceVariation.x);
    mat3 rotation = mat3(c, 0, -s, 0, 1, 0, s, 0, c);
    vec3 local = vertexPosition * instancePositionScale.w;
    float height = max(local.y, 0.0);
    local.x += sin(time * 1.7 + instanceVariation.w + height * 0.6) * instanceVariation.z * height * 0.035;
    fragPosition = rotation * local + instancePositionScale.xyz;
    fragNormal = rotation * vertexNormal;
    fragTexCoord = vertexTexCoord;
    fragTint = instanceVariation.y;
    shadowPosition = lightVP * vec4(fragPosition, 1.0);
    gl_Position = mvp * vec4(fragPosition, 1.0);
}
