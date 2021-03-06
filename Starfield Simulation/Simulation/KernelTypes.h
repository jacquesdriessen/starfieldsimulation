//
//  KernelTypes.h
//  Starfield Simulation
//
//  Created by Jacques Driessen on 23/12/2020.
//

#ifndef KernelTypes_h
#define KernelTypes_h

typedef enum StarComputeBufferIndex
{
    starComputeBufferIndexOldPosition = 0,
    starComputeBufferIndexOldVelocity = 1,
    starComputeBufferIndexNewPosition = 2,
    starComputeBufferIndexNewVelocity = 3,
    starComputeBufferIndexParams      = 4,
    starComputeBufferIndexBlock       = 5,
    starComputeBufferIndexTracking    = 6,
    starComputeBufferIndexPartitions  = 7,
    starComputeBufferIndexPass        = 8
} StarComputeBufferIndex;

typedef struct StarSimParams
{
    float           timestep;
    float           damping;
    float           softeningSqr;
    unsigned int    numBodies;
    float           gravity;
    float           squeeze;
} StarSimParams;

typedef struct StarBlock
{
    unsigned int    begin;
    unsigned int    split;
    bool            collide;
} StarBlock;

typedef struct SpecatorMovement
{
    vector_float4 position;
    vector_float4 velocity;
} Tracking;

#endif /* KernelTypes_h */
