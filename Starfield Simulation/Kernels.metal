//
//  Kernels.metal
//  Starfield Simulation
//
//  Created by Jacques Driessen on 23/12/2020.
//

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

#import "KernelTypes.h"

static float3 computeAcceleration(const float4 vsPosition,
                                  const float4 oldPosition,
                                  const float  softeningSqr)
{
    float3 r = vsPosition.xyz - oldPosition.xyz;
    
    float distSqr = distance_squared(vsPosition.xyz, oldPosition.xyz);
    
    distSqr += softeningSqr;
    
    float invDist  = rsqrt(distSqr);
    
    float s = vsPosition.w * invDist; // vsPostion equals to radius, assuming mass is radius^3.
    
    return r * s * s * s; // = mass * r (vector) / |r|^3
}

kernel void NBodySimulation(device float4*           newPosition       [[ buffer(starComputeBufferIndexNewPosition) ]],
                            device float4*           newVelocity       [[ buffer(starComputeBufferIndexNewVelocity) ]],
                            device float4*           oldPosition       [[ buffer(starComputeBufferIndexOldPosition) ]],
                            device float4*           oldVelocity       [[ buffer(starComputeBufferIndexOldVelocity) ]],
                            constant StarSimParams & params            [[ buffer(starComputeBufferIndexParams)      ]],
                            constant StarBlock & block                 [[ buffer(starComputeBufferIndexBlock)       ]],
                            constant Tracking & tracking               [[ buffer(starComputeBufferIndexTracking)    ]],
                            threadgroup float4     * sharedPosition    [[ threadgroup(0)                            ]],
                            const uint               threadInGrid      [[ thread_position_in_grid                   ]],
                            const uint               threadInGroup     [[ thread_position_in_threadgroup            ]],
                            const uint               numThreadsInGroup [[ threads_per_threadgroup                   ]])
{
    const uint threadGlobal = threadInGrid + block.begin;
    float4 currentPosition = oldPosition[threadGlobal];
    float4 currentVelocity = oldVelocity[threadGlobal];

    float3 acceleration = 0.0f;
    uint i, j;
    
    const float softeningSqr = params.softeningSqr;
    
    const uint split = block.collide? params.numBodies : block.split;
    
    bool partition = (threadGlobal < split) ? 0 : 1;
    const uint particles = (threadGlobal < split) ? split : params.numBodies - split;
        
    // For each particle / body
    uint sourcePosition = threadInGroup + (partition * split);

    for(i = 0; i < particles; i += numThreadsInGroup)
        {
            // Because sharedPosition uses the threadgroup address space, 'numThreadsInGroup' elements
            // of sharedPosition will be initialized at once (not just one element at lid as it
            // may look like)
            sharedPosition[threadInGroup] = oldPosition[sourcePosition];
            
            j = 0;
            
            while(j < numThreadsInGroup)
            {
                acceleration += computeAcceleration(sharedPosition[j++], currentPosition, softeningSqr);
                acceleration += computeAcceleration(sharedPosition[j++], currentPosition, softeningSqr);
                acceleration += computeAcceleration(sharedPosition[j++], currentPosition, softeningSqr);
                acceleration += computeAcceleration(sharedPosition[j++], currentPosition, softeningSqr);
                acceleration += computeAcceleration(sharedPosition[j++], currentPosition, softeningSqr);
                acceleration += computeAcceleration(sharedPosition[j++], currentPosition, softeningSqr);
                acceleration += computeAcceleration(sharedPosition[j++], currentPosition, softeningSqr);
                acceleration += computeAcceleration(sharedPosition[j++], currentPosition, softeningSqr);
            } // while
            
            sourcePosition += numThreadsInGroup;
        } // for
     
    if (oldPosition[threadGlobal].w < 0) { // allow for negative mass, so we can "push things away"
        acceleration = - acceleration;
    }
    
    //simulation
    currentVelocity.xyz += params.gravity * acceleration * params.timestep;
    currentVelocity.xyz *= params.damping; // this is tricky, assumption it's semi stationary.
    
    currentPosition.xyz += currentVelocity.xyz * params.timestep;
    
    currentPosition.xyz *= params.squeeze; // squeeze space.
    
    // tracking
    currentVelocity.xyz -= tracking.velocity.xyz;
    currentPosition.xyz -= tracking.position.xyz;
    
    newPosition[threadGlobal] = currentPosition;
    newVelocity[threadGlobal] = currentVelocity;

} // NBodyIntegrateSystem

