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
    // temp - no acceleration
    // return float3(0.0f, 0.0f, 0.0f);
}

kernel void NBodySimulation(device float4*           newPosition       [[ buffer(starComputeBufferIndexNewPosition) ]],
                            device float4*           newVelocity       [[ buffer(starComputeBufferIndexNewVelocity) ]],
                            device float4*           oldPosition       [[ buffer(starComputeBufferIndexOldPosition) ]],
                            device float4*           oldVelocity       [[ buffer(starComputeBufferIndexOldVelocity) ]],
                            constant StarSimParams & params            [[ buffer(starComputeBufferIndexParams)      ]],
                            constant StarBlock & block                 [[ buffer(starComputeBufferIndexBlock)       ]],
                            threadgroup float4     * sharedPosition    [[ threadgroup(0)                            ]],
                            const uint               threadInGrid      [[ thread_position_in_grid                   ]],
                            const uint               threadInGroup     [[ thread_position_in_threadgroup            ]],
                            const uint               numThreadsInGroup [[ threads_per_threadgroup                   ]])
{
    float4 currentPosition = oldPosition[threadInGrid];
    float4 currentVelocity = oldVelocity[threadInGrid];

    if (threadInGrid >= block.begin && threadInGrid < block.end) { // smarter approach would be to not call the gpu at all for stuff we don't need to calculate

        float3 acceleration = 0.0f;
        uint i, j;
        
        const float softeningSqr = params.softeningSqr;
        
        const uint split = params.split;
        
        bool partition = (threadInGrid < split) ? 0 : 1;
        const uint particles = (threadInGrid < split) ? split : params.numBodies - split;
            
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
         
        currentVelocity.xyz += acceleration * params.timestep;
        currentVelocity.xyz *= params.damping;
        currentPosition.xyz += currentVelocity.xyz * params.timestep;
        newPosition[threadInGrid] = currentPosition;
        newVelocity[threadInGrid] = currentVelocity;
    }
} // NBodyIntegrateSystem

