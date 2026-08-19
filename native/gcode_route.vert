#version 440

layout(location = 0) in vec3 aStart;
layout(location = 1) in vec3 aEnd;
layout(location = 2) in float aSide;
layout(location = 3) in float aEndParam;

layout(location = 0) out float vWorldZ;
layout(location = 1) out float vEnd;
layout(location = 2) out float vSide;
layout(location = 3) out float vLineLength;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float yawCos;
    float yawSin;
    float pitchCos;
    float pitchSin;
    float scale;
    float centerU;
    float centerV;
    float width;
    float height;
    float lineWidth;
    float dpr;
    float modelCenterX;
    float modelCenterY;
    float modelCenterZ;
    float minZ;
    float explosionProgress;
    float explosionFactor;
    float cutoff;
    float maxZ;
    float cutoffValid;
    float printedR;
    float printedG;
    float printedB;
    float printedA;
    float remainingR;
    float remainingG;
    float remainingB;
    float remainingA;
} ubuf;

out gl_PerVertex { vec4 gl_Position; };

bool finiteFloat(float x) {
    return !(isnan(x) || isinf(x));
}

float displayZ(float z) {
    if (!finiteFloat(z))
        return ubuf.minZ;
    if (!finiteFloat(ubuf.explosionProgress) || ubuf.explosionProgress <= 0.0)
        return z;
    float progress = clamp(ubuf.explosionProgress, 0.0, 1.0);
    float s = 1.0 + progress * ubuf.explosionFactor;
    return ubuf.minZ + (z - ubuf.minZ) * s;
}

vec2 projectPoint(vec3 p) {
    float translated_x = p.x - ubuf.modelCenterX;
    float translated_y = p.y - ubuf.modelCenterY;
    float translated_z = displayZ(p.z) - ubuf.modelCenterZ;
    float rotated_x = translated_x * ubuf.yawCos - translated_y * ubuf.yawSin;
    float rotated_y = translated_x * ubuf.yawSin + translated_y * ubuf.yawCos;
    float pitched_z = rotated_y * ubuf.pitchSin + translated_z * ubuf.pitchCos;
    return vec2(
        ubuf.width * 0.5 + (rotated_x - ubuf.centerU) * ubuf.scale,
        ubuf.height * 0.5 + (-pitched_z - ubuf.centerV) * ubuf.scale);
}

void main()
{
    vec2 p0 = projectPoint(aStart);
    vec2 p1 = projectPoint(aEnd);
    vec2 delta = p1 - p0;
    float lineLen = length(delta);
    vec2 tangent = (lineLen > 1e-6) ? delta / lineLen : vec2(1.0, 0.0);
    vec2 normal = vec2(-tangent.y, tangent.x);

    float dpr = max(ubuf.dpr, 1e-6);
    const float antialiasPx = 0.75;
    float expandPx = ubuf.lineWidth * dpr * 0.5 + antialiasPx;
    float expandItem = expandPx / dpr;
    vec2 pos = mix(p0, p1, aEndParam);
    pos += normal * aSide * expandItem;
    pos += tangent * (aEndParam * 2.0 - 1.0) * expandItem;

    gl_Position = ubuf.qt_Matrix * vec4(pos, 0.0, 1.0);

    float lineLenPx = lineLen * dpr;
    vWorldZ = mix(aStart.z, aEnd.z, aEndParam);
    vEnd = aEndParam * lineLenPx + (aEndParam * 2.0 - 1.0) * expandPx;
    vSide = aSide * expandPx;
    vLineLength = lineLenPx;
}
