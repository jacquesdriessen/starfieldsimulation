//
//  Shaders.metal
//  Starfield Simulation
//
//  Created by Jacques Driessen on 22/12/2020.
//

#include <metal_stdlib>
#include <simd/simd.h>

// Include header shared between this Metal shader code and C code executing Metal API commands
#import "ShaderTypes.h"

using namespace metal;

typedef struct {
    float2 position [[attribute(kVertexAttributePosition)]];
    float2 texCoord [[attribute(kVertexAttributeTexcoord)]];
} ImageVertex;


typedef struct {
    float4 position [[position]];
    float2 texCoord;
} ImageColorInOut;


// Captured image vertex function
vertex ImageColorInOut capturedImageVertexTransform(ImageVertex in [[stage_in]]) {
    ImageColorInOut out;
    
    // Pass through the image vertex's position
    out.position = float4(in.position, 0.0, 1.0);
    
    // Pass through the texture coordinate
    out.texCoord = in.texCoord;
    
    return out;
}

// Captured image fragment function
fragment float4 capturedImageFragmentShader(ImageColorInOut in [[stage_in]],
                                            texture2d<float, access::sample> capturedImageTextureY [[ texture(kTextureIndexY) ]],
                                            texture2d<float, access::sample> capturedImageTextureCbCr [[ texture(kTextureIndexCbCr) ]]) {
    
    constexpr sampler colorSampler(mip_filter::linear,
                                   mag_filter::linear,
                                   min_filter::linear);
    
    const float4x4 ycbcrToRGBTransform = float4x4(
        float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
        float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
        float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
        float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f)
    );
    
    // Sample Y and CbCr textures to get the YCbCr color at the given texture coordinate
    float4 ycbcr = float4(capturedImageTextureY.sample(colorSampler, in.texCoord).r,
                          capturedImageTextureCbCr.sample(colorSampler, in.texCoord).rg, 1.0);
    
    // Return converted RGB color
    return ycbcrToRGBTransform * ycbcr;
}

/*
typedef struct {
    float3 position [[attribute(kVertexAttributePosition)]];
    float2 texCoord [[attribute(kVertexAttributeTexcoord)]];
    half3 normal    [[attribute(kVertexAttributeNormal)]];
} Vertex;


typedef struct {
    float4 position [[position]];
    float4 color;
    half3  eyePosition;
    half3  normal;
    float  pointSize [[point_size]];
} ColorInOut;


// Anchor geometry vertex function
vertex ColorInOut anchorGeometryVertexTransform(Vertex in [[stage_in]],
                                                constant SharedUniforms &sharedUniforms [[ buffer(kBufferIndexSharedUniforms) ]],
                                                constant InstanceUniforms *instanceUniforms [[ buffer(kBufferIndexInstanceUniforms) ]],
                                                ushort vid [[vertex_id]],
                                                ushort iid [[instance_id]]) {
    ColorInOut out;
    
    // Make position a float4 to perform 4x4 matrix math on it
    //float4 position = float4(0.0, 0.0, 0.0, 1.0);
    
    float4 position = float4(in.position, 1.0);
    
    float4x4 modelMatrix = instanceUniforms[iid].modelMatrix;
    float4x4 modelViewMatrix = sharedUniforms.viewMatrix * modelMatrix;
    
    // Calculate the position of our vertex in clip space and output for clipping and rasterization
    out.position = sharedUniforms.projectionMatrix * modelViewMatrix * position;
    
    // Color each face a different color
    ushort colorID = vid / 4 % 6;
    out.color = colorID == 0 ? float4(0.0, 1.0, 0.0, 1.0) // Right face
              : colorID == 1 ? float4(1.0, 0.0, 0.0, 1.0) // Left face
              : colorID == 2 ? float4(0.0, 0.0, 1.0, 1.0) // Top face
              : colorID == 3 ? float4(1.0, 0.5, 0.0, 1.0) // Bottom face
              : colorID == 4 ? float4(1.0, 1.0, 0.0, 1.0) // Back face
              : float4(1.0, 1.0, 1.0, 1.0); // Front face
    
    // Calculate the position of our vertex in eye space
    out.eyePosition = half3((modelViewMatrix * position).xyz);
    
    // Rotate our normals to world coordinates
    float4 normal = modelMatrix * float4(in.normal.x, in.normal.y, in.normal.z, 0.0f);
    out.normal = normalize(half3(normal.xyz));
    
 //   out.pointSize = 10.0;
    return out;
}

// Anchor geometry fragment function
fragment float4 anchorGeometryFragmentLighting(ColorInOut in [[stage_in]],
                                               constant SharedUniforms &uniforms [[ buffer(kBufferIndexSharedUniforms) ]]) {
    
    float3 normal = float3(in.normal);
    
    // Calculate the contribution of the directional light as a sum of diffuse and specular terms
    float3 directionalContribution = float3(0);
    {
        // Light falls off based on how closely aligned the surface normal is to the light direction
        float nDotL = saturate(dot(normal, -uniforms.directionalLightDirection));
        
        // The diffuse term is then the product of the light color, the surface material
        // reflectance, and the falloff
        float3 diffuseTerm = uniforms.directionalLightColor * nDotL;
        
        // Apply specular lighting...
        
        // 1) Calculate the halfway vector between the light direction and the direction they eye is looking
        float3 halfwayVector = normalize(-uniforms.directionalLightDirection - float3(in.eyePosition));
        
        // 2) Calculate the reflection angle between our reflection vector and the eye's direction
        float reflectionAngle = saturate(dot(normal, halfwayVector));
        
        // 3) Calculate the specular intensity by multiplying our reflection angle with our object's
        //    shininess
        float specularIntensity = saturate(powr(reflectionAngle, uniforms.materialShininess));
        
        // 4) Obtain the specular term by multiplying the intensity by our light's color
        float3 specularTerm = uniforms.directionalLightColor * specularIntensity;
        
        // Calculate total contribution from this light is the sum of the diffuse and specular values
        directionalContribution = diffuseTerm + specularTerm;
    }
    
    // The ambient contribution, which is an approximation for global, indirect lighting, is
    // the product of the ambient light intensity multiplied by the material's reflectance
    float3 ambientContribution = uniforms.ambientLightColor;
    
    // Now that we have the contributions our light sources in the scene, we sum them together
    // to get the fragment's lighting value
    float3 lightContributions = ambientContribution + directionalContribution;
    
    // We compute the final color by multiplying the sample from our color maps by the fragment's
    // lighting value
    float3 color = in.color.rgb * lightContributions;
    
    // We use the color we just computed and the alpha channel of our
    // colorMap for this fragment's alpha value
    return float4(color, in.color.w);
}
*/

typedef struct
{
    float4 position [[position]];
    float  pointSize [[point_size]];
    half3  eyePosition;
    half4  color;
    half3  normal;
    float  radius;
} StarColorInOut;


// Star geometry vertex function
vertex StarColorInOut starVertexShader(
                                   uint                    vertexID  [[ vertex_id ]],
                                   const device float4*    positions  [[ buffer(starRenderBufferIndexPositions) ]],
                                   const device uchar4*    color     [[ buffer(starRenderBufferIndexColors)    ]],
                                   constant StarUniforms & uniforms  [[ buffer(starRenderBufferIndexUniforms)  ]],
                                   constant SharedUniforms &sharedUniforms [[ buffer(kBufferIndexSharedUniforms) ]])
/*
                                   Vertex in [[stage_in]],
                                   constant InstanceUniforms *instanceUniforms [[ buffer(kBufferIndexInstanceUniforms) ]],
                                   ushort vid [[vertex_id]],
                                   ushort iid [[instance_id]])
*/
{
    StarColorInOut out;
    
    // Make position a float4 to perform 4x4 matrix math on it
    float4 position = float4(positions[vertexID].xyz, 1.0); // as positions.w also holds the radius - need to set .w explicitly to 1 as otherwise it will be used in multiplication.
    
  //  float4x4 modelMatrix = instanceUniforms[iid].modelMatrix;
    float4x4 modelViewMatrix = sharedUniforms.viewMatrix; // * modelMatrix;
    
    // Calculate the position of our vertex in clip space and output for clipping and rasterization
    out.position = sharedUniforms.projectionMatrix * modelViewMatrix * position;
    
    // Calculate the position of our vertex in eye space
    out.eyePosition = half3((modelViewMatrix * position).xyz);
    
    // Rotate our normals to world coordinates
    //float4 normal = /*modelMatrix */ float4(1.0f, 1.0f, 1.0f, 0.0f);
  /*  float4 normal = float4(position.x, position.y, position.z, 0.0f);
    out.normal = normalize(half3(normal.xyz));
*/
    out.color = half4(color[vertexID]) / 255.0h;

    out.radius = positions[vertexID].w; //positions[vertexID].w holds radius of the star
    
    out.pointSize = out.radius * 100.0 / distance((modelViewMatrix * position).xyz, out.position.xyz);
    
    
    return out;
}

// Star geometry fragment function
fragment half4 starFragmentShader(StarColorInOut inColor [[stage_in]],
                                   //constant SharedUniforms &uniforms [[ buffer(kBufferIndexSharedUniforms) ]]
                                   texture2d<half>  colorMap [[ texture(starTextureIndexColorMap)  ]],
                                   float2           texcoord [[ point_coord ]]) {
   /*
    float3 normal = float3(in.normal);
    
    // Calculate the contribution of the directional light as a sum of diffuse and specular terms
    float3 directionalContribution = float3(0);
    {
        // Light falls off based on how closely aligned the surface normal is to the light direction
        float nDotL = saturate(dot(normal, -uniforms.directionalLightDirection));
        
        // The diffuse term is then the product of the light color, the surface material
        // reflectance, and the falloff
        float3 diffuseTerm = uniforms.directionalLightColor * nDotL;
        
        // Apply specular lighting...
        
        // 1) Calculate the halfway vector between the light direction and the direction they eye is looking
        float3 halfwayVector = normalize(-uniforms.directionalLightDirection - float3(in.eyePosition));
        
        // 2) Calculate the reflection angle between our reflection vector and the eye's direction
        float reflectionAngle = saturate(dot(normal, halfwayVector));
        
        // 3) Calculate the specular intensity by multiplying our reflection angle with our object's
        //    shininess
        float specularIntensity = saturate(powr(reflectionAngle, uniforms.materialShininess));
        
        // 4) Obtain the specular term by multiplying the intensity by our light's color
        float3 specularTerm = uniforms.directionalLightColor * specularIntensity;
        
        // Calculate total contribution from this light is the sum of the diffuse and specular values
        directionalContribution = diffuseTerm + specularTerm;
    }
    
    // The ambient contribution, which is an approximation for global, indirect lighting, is
    // the product of the ambient light intensity multiplied by the material's reflectance
    float3 ambientContribution = uniforms.ambientLightColor;
    
    // Now that we have the contributions our light sources in the scene, we sum them together
    // to get the fragment's lighting value
    float3 lightContributions = ambientContribution + directionalContribution;
    
    // We compute the final color by multiplying the sample from our color maps by the fragment's
    // lighting value
    float3 color = in.color.rgb * lightContributions;
    
    // We use the color we just computed and the alpha channel of our
    // colorMap for this fragment's alpha value
    return float4(color, in.color.w);
    */
    //return half4(1.0f, 1.0f, 1.0f, 1.0f);
    constexpr sampler linearSampler (mip_filter::none,
                                     mag_filter::linear,
                                     min_filter::linear);
    
    half4 c = colorMap.sample(linearSampler, texcoord);
    
    half4 fragColor = (0.6h + 0.4h * inColor.color) * c.x;
   
    half4 x = half4(0.1h, 0.0h, 0.0h, fragColor.w);
    half4 y = half4(1.0h, 0.7h, 0.3h, fragColor.w);
    half  a = fragColor.w;
    
   // return fragColor * mix(x, y, a);
 /*   if (fragColor.w < 0.7)
        return half4(inColor.color.x, inColor.color.y, inColor.color.z, 1.h);
    else*/
    if (inColor.radius > 2.5) { // black hole is green
        x = half4(.0h, 1.0h, .0h, x.w);
        y = half4(.0h, 1.0h, .0h, y.w);
        fragColor = half4(.0h, 1.0h, .0h, fragColor.w);
    } else if (inColor.radius > 1.5) { // big stars are blue-ish
        fragColor = half4(0.5h * fragColor.x, 0.5h * fragColor.y, 0.5h + 0.5h * fragColor.z, fragColor.w);
        
    } else if (inColor.radius < 1.2) { // small stars are reddish
        fragColor = half4(0.5h + 0.5h * fragColor.x, 0.5h * fragColor.y, 0.5h * fragColor.z, fragColor.w);
    }

     
    return fragColor * mix(x, y, a);
}

