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
    
    float s = vsPosition.w * invDist;
    
    return r * s * s * s;
    // temp - no acceleration
    // return float3(0.0f, 0.0f, 0.0f);
}

kernel void NBodySimulation(device float4*           newPosition       [[ buffer(starComputeBufferIndexNewPosition) ]],
                            device float4*           newVelocity       [[ buffer(starComputeBufferIndexNewVelocity) ]],
                            device float4*           oldPosition       [[ buffer(starComputeBufferIndexOldPosition) ]],
                            device float4*           oldVelocity       [[ buffer(starComputeBufferIndexOldVelocity) ]],
                            constant StarSimParams & params            [[ buffer(starComputeBufferIndexParams)      ]],
                            threadgroup float4     * sharedPosition    [[ threadgroup(0)                            ]],
                            const uint               threadInGrid      [[ thread_position_in_grid                   ]],
                            const uint               threadInGroup     [[ thread_position_in_threadgroup            ]],
                            const uint               numThreadsInGroup [[ threads_per_threadgroup                   ]])
{
    
    float4 currentPosition = oldPosition[threadInGrid];
    float3 acceleration = 0.0f;
    uint i, j;
    
    const float softeningSqr = params.softeningSqr;
    
    uint sourcePosition = threadInGroup;
    
    // For each particle / body
    for(i = 0; i < params.numBodies; i += numThreadsInGroup)
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
    
    float4 currentVelocity = oldVelocity[threadInGrid];
    
    currentVelocity.xyz += acceleration * params.timestep;
    currentVelocity.xyz *= params.damping;
    currentPosition.xyz += currentVelocity.xyz * params.timestep;
    
    newPosition[threadInGrid] = currentPosition;
    newVelocity[threadInGrid] = currentVelocity;
} // NBodyIntegrateSystem

