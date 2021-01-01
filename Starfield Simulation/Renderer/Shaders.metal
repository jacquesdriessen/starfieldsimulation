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
                                            texture2d<float, access::sample> capturedImageTextureCbCr [[ texture(kTextureIndexCbCr) ]],
                                            constant float & daylight  [[ buffer(kTextureIndexDayLight)]]) {
    
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
    return daylight*ycbcrToRGBTransform * ycbcr;
}

typedef struct
{
    float4 position [[position]];
    float  pointSize [[point_size]];
 //   half3  eyePosition;
    half4  color;
    float  radius;
    uint   vertexID;
} StarColorInOut;


// Star geometry vertex function
vertex StarColorInOut starVertexShader(
                                   uint                         vertexID  [[ vertex_id ]],
                                   const device float4*         positions1  [[ buffer(starRenderBufferIndexPositions1) ]],
                                   const device float4*         positions2  [[ buffer(starRenderBufferIndexPositions2) ]],
                                   const device float &         interpolation  [[ buffer(starRenderBufferIndexInterpolation) ]],
                                   const device uchar4*         color     [[ buffer(starRenderBufferIndexColors)    ]],
                                   constant SharedUniforms &    sharedUniforms [[ buffer(starRenderBufferIndexSharedUniforms) ]])

{
    StarColorInOut out;
    
    // Make position a float4 to perform 4x4 matrix math on it
    float4 position = (1.0-interpolation)*float4(positions1[vertexID].xyz, 1.0) + interpolation*float4(positions2[vertexID].xyz, 1.0); // (1) interpolates as we can do less computation than we need to do rendering
    
  //  float4x4 modelMatrix = instanceUniforms[iid].modelMatrix; // in case we have 3d stars, this can have things like rotation in it.
    //  float4x4 modelMatrix = instanceUniforms[iid].modelMatrix;
      float4x4 modelViewMatrix = sharedUniforms.viewMatrix; // * modelMatrix;
    
    // Calculate the position of our vertex in clip space and output for clipping and rasterization
    out.position = sharedUniforms.sharedMatrix * position;// sharedUniforms.projectionMatrix * modelViewMatrix * position;
    
    
    // Calculate the position of our vertex in eye space
   // out.eyePosition = half3((modelViewMatrix * position).xyz);
    
    out.color = half4(color[vertexID]) / 255.0h;
//// do we need both???? probably  yes, one how big it looks, the other the mass.
    out.radius = abs(positions1[vertexID].w); //positions[vertexID].w holds radius of the star, if negative, just means negative mass, not radius!!
    
    out.pointSize = out.radius * sharedUniforms.starSize / distance((modelViewMatrix * position).xyz, out.position.xyz); // NEED CHECK WITH ALL THE NON AR STUFF STILL OK?
    
    out.vertexID = vertexID;
    
    return out;
}

// Star geometry fragment function
fragment half4 starFragmentShader(StarColorInOut inColor [[stage_in]],
                                  texture2d<half>  colorMap [[ texture(starTextureIndexColorMap)  ]],
                                  constant bool &  falseColour [[ buffer(starTextureIndexFalseColour)]],
                                  constant float &  partitioner [[ buffer(starTextureIndexPartitioner)]],
                                  float2           texcoord [[ point_coord ]]) {
    constexpr sampler linearSampler (mip_filter::none,
                                     mag_filter::linear,
                                     min_filter::linear);
    
    half4 c = colorMap.sample(linearSampler, texcoord);
    
    half4 fragColor = (0.6h + 0.4h * inColor.color) * c.x;
   
    half4 x = half4(0.1h, 0.0h, 0.0h, fragColor.w);
    half4 y = half4(1.0h, 0.7h, 0.3h, fragColor.w);
    half  a = fragColor.w;

    if (inColor.radius > 10) { // this is when we interact, don't show.... actually that's the whole point right?, so show in bright yellow.
          fragColor = half4(1.0h, 1.0h, .0h, fragColor.w);
    } else if (inColor.radius > 2.5) { // black hole is green
        fragColor = half4(.0h, 1.0h, .0h, fragColor.w);
    } else if (falseColour) {
        float angle = M_PI_F * float(inColor.vertexID) * partitioner;
        float phase = 1.0/3.0 * M_PI_F;
        float r = cos(angle);
        float g = cos(angle + phase );
        float b = cos(angle + 2*phase );
        float rr = r*r;
        float gg = g*g;
        float bb = b*b;
        
        //x = half4(rr, gg, bb, 1.0h);
        //y = half4(rr, gg, bb, 1.0h);
        fragColor = half4(rr, gg, bb, fragColor.w);
    }
    else if (inColor.radius > 1.5) { // big stars are blue-ish
        fragColor = half4(0.5h * fragColor.x, 0.5h * fragColor.y, 0.5h + 0.5h * fragColor.z, fragColor.w);
        
    } else if (inColor.radius < 1.2) { // small stars are reddish
        fragColor = half4(0.5h + 0.5h * fragColor.x, 0.5h * fragColor.y, 0.5h * fragColor.z, fragColor.w);
    }
        
    return fragColor * mix(x, y, a);
        
}


typedef struct
{
    float4 position [[position]];
    half4 color;
} InteractiveInOut;

vertex InteractiveInOut interactiveVertexShader(const device InteractiveVertex *vertices [[buffer(0)]],
                                                constant SharedUniforms &    sharedUniforms [[ buffer(1) ]],
                                                uint vertexID  [[ vertex_id ]]
                                                )
                                       
{
    InteractiveVertex in = vertices[vertexID];
    InteractiveInOut out;
    
    float4 position = float4(in.position.xyz, 1);
    
    //  float4x4 modelMatrix = instanceUniforms[iid].modelMatrix;
  //  float4x4 modelViewMatrix = sharedUniforms.viewMatrix; // * modelMatrix;
    
    // Calculate the position of our vertex in clip space and output for clipping and rasterization
    out.position = sharedUniforms.sharedMatrix * position;// sharedUniforms.projectionMatrix * modelViewMatrix * position;

    out.color = half4(in.color);
    
    return out;
}



fragment half4 interactiveFragmentShader(InteractiveInOut interpolatedIn [[stage_in]]) {
    return half4(interpolatedIn.color.xyz, 1);
}

