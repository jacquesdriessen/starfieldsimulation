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
    starComputeBufferIndexParams      = 4
} StarComputeBufferIndex;

typedef struct StarSimParams
{
    float  timestep;
    float  damping;
    float  softeningSqr;
    unsigned int numBodies;
    unsigned int split;
    unsigned int block_begin;
    unsigned int block_end;
} StarSimParams;


#endif /* KernelTypes_h */
