//
//  ShaderTypes.h
//  Starfield Simulation
//
//  Created by Jacques Driessen on 22/12/2020.
//

//
//  Header containing types and enum constants shared between Metal shaders and C/ObjC source
//
#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>


// Buffer index values shared between shader and C code to ensure Metal shader buffer inputs match
//   Metal API buffer set calls
typedef enum BufferIndices {
    kBufferIndexMeshPositions    = 0
} BufferIndices;

// Attribute index values shared between shader and C code to ensure Metal shader vertex
//   attribute indices match the Metal API vertex descriptor attribute indices
typedef enum VertexAttributes {
    kVertexAttributePosition  = 0,
    kVertexAttributeTexcoord  = 1
} VertexAttributes;

// Texture index values shared between shader and C code to ensure Metal shader texture indices
//   match indices of Metal API texture set calls
typedef enum TextureIndices {
    kTextureIndexColor    = 0,
    kTextureIndexY        = 1,
    kTextureIndexCbCr     = 2,
    kTextureIndexDayLight = 3
} TextureIndices;

// Structure shared between shader and C code to ensure the layout of shared uniform data accessed in
//    Metal shaders matches the layout of uniform data set in C code
typedef struct {
    // Camera Uniforms
//    matrix_float4x4 projectionMatrix;
    matrix_float4x4 viewMatrix;
    matrix_float4x4 sharedMatrix;
    float           starSize;
} SharedUniforms;

typedef enum StarRenderBufferIndex
{
    starRenderBufferIndexPositions1 = 0,
    starRenderBufferIndexPositions2 = 1,
    starRenderBufferIndexInterpolation = 2,
    starRenderBufferIndexColors   = 3,
    starRenderBufferIndexSharedUniforms = 4,
} StarRenderBufferIndex;

typedef enum StarTextureIndex
{
    starTextureIndexColorMap = 0,
    starTextureIndexFalseColour = 1,
    starTextureIndexPartitioner = 2
} StarTextureIndex;

typedef struct {
    vector_float4 position;
    vector_float4 color;
} InteractiveVertex;



#endif /* ShaderTypes_h */
