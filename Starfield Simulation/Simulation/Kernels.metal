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
    float3 r = vsPosition.xyz - oldPosition.xyz; // how does this not crash for "when it's the particle that you are yourself.
    
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
                            constant int &  _partitions                [[ buffer(starComputeBufferIndexPartitions)  ]],
                            constant int & pass                        [[ buffer(starComputeBufferIndexPass)        ]],
                            threadgroup float4     * sharedPosition    [[ threadgroup(0)                            ]],
                            const uint               threadInGrid      [[ thread_position_in_grid                   ]],
                            const uint               threadInGroup     [[ thread_position_in_threadgroup            ]],
                            const uint               numThreadsInGroup [[ threads_per_threadgroup                   ]])
{
    const uint partitions = params.numBodies / 16384; // could make this dynamic, for now depend on # particles. baseline for this was 16384 particles.
    
    //block.collide? 1 : _partitions; // const uint split = block.collide? params.numBodies : block.split;

    float interaction_multiplier = float(partitions) / ( block.collide? float(1) : float(_partitions)); // As w are cheating (only calculating 1 / partitions each pass), in collide mode it's easy, multiply by partitions (*16), in the other mode, we need to account for the partitions the calculating thinks we have (in case of == partitions, don't need to do anything).

    if (pass == 0 || (block.collide == false && _partitions > 1)) // if no collissions, in principle only execute the "kernel where things only interact in the partition, however if 1 partition, can still alternate between things and make it more real (otherwise we would create a galaxy that will eventually split up in partitions, maybe something smart we can do to have that for different partition sizes but this is just for fun :-).
    {
        // mode 1
        const uint threadGlobal = threadInGrid + block.begin;
        float4 currentPosition = oldPosition[threadGlobal];
        float4 currentVelocity = oldVelocity[threadGlobal];

        float3 acceleration = 0.0f;
        uint i, j;
        
        const float softeningSqr = params.softeningSqr;
       
        int partition = threadGlobal / (params.numBodies / partitions); // this should not be a bool right? bool partition = (threadGlobal < split) ? 0 : 1;
        const uint particles = params.numBodies / partitions; // const uint particles = (threadGlobal < split) ? split : params.numBodies - split;
            
        // For each particle / body
        uint sourcePosition = threadInGroup + (partition * particles); // uint sourcePosition = threadInGroup + (partition * split);

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
        currentVelocity.xyz += params.gravity * acceleration * params.timestep * interaction_multiplier;
        currentVelocity.xyz *= params.damping; // this is tricky, assumption it's semi stationary.
        
        currentPosition.xyz += currentVelocity.xyz * params.timestep; // don't think we want this here, if things become slower, need to account elsewhere * interaction_multiplier;
        currentPosition.xyz *= params.squeeze; // squeeze space.
        
        // tracking
        currentVelocity.xyz -= tracking.velocity.xyz;
        currentPosition.xyz -= tracking.position.xyz;
        
        newPosition[threadGlobal] = currentPosition;
        newVelocity[threadGlobal] = currentVelocity;
    } else {
    
        // mode 2
        const uint threadGlobal = threadInGrid + block.begin;
        float4 currentPosition = oldPosition[threadGlobal];
        float4 currentVelocity = oldVelocity[threadGlobal];
        
        float3 acceleration = 0.0f;
        uint i, j;
        
        const float softeningSqr = params.softeningSqr;
        
        int partition = threadGlobal / (params.numBodies / partitions); // this should not be a bool right? bool partition = (threadGlobal < split) ? 0 : 1;
        const uint particles = params.numBodies / partitions; // const uint particles = (threadGlobal < split) ? split : params.numBodies - split;
        
        // For each particle / body
        uint sourcePosition = partition*threadInGroup; // uint sourcePosition = threadInGroup + (partition * split);
        
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
            
            sourcePosition += 1;
        } // for
        
        if (oldPosition[threadGlobal].w < 0) { // allow for negative mass, so we can "push things away"
            acceleration = - acceleration;
        }
        
        //simulation
        currentVelocity.xyz += params.gravity * acceleration * params.timestep * interaction_multiplier;
        currentVelocity.xyz *= params.damping; // this is tricky, assumption it's semi stationary.
        
        currentPosition.xyz += currentVelocity.xyz * params.timestep; // don't think we want this here, if things become slower, need to account elsewhere * interaction_multiplier;
        
        currentPosition.xyz *= params.squeeze; // squeeze space.
        
        // tracking
        //currentVelocity.xyz -= tracking.velocity.xyz;
        //currentPosition.xyz -= tracking.position.xyz;
        
        newPosition[threadGlobal] = currentPosition;
        newVelocity[threadGlobal] = currentVelocity;
    }

} // NBodyIntegrateSystem


// Generate a random float in the range [0.0f, 1.0f] using x, y, and z (based on the xor128 algorithm)
float random(thread int3 &seed)
{
    int local_seed = seed.x + seed.y * 57 + seed.z * 241;
    local_seed = (local_seed<< 13) ^ local_seed;
    
    seed.x += 1;
    
    return (( 1.0 - ( (local_seed * (local_seed * local_seed * 15731 + 789221) + 1376312589) & 2147483647) / 1073741824.0f) + 1.0f) / 2.0f;
}

float random(float minimum, float maximum, thread int3 &seed)
{
    return minimum + random(seed) * (maximum - minimum);
}

float3 random_vector (float minimum, float maximum, thread int3 &seed)
{
    float r = random(minimum, maximum, seed);
    float theta = random(0, M_PI_F, seed);
    float phi = random(0, 2*M_PI_F, seed);
    
    return float3(r * sin(theta) * cos(phi), r * sin(theta) * sin(phi), r * cos(theta));
}

float3 random_normalized_vector (thread int3 &seed)
{
    return random_vector(1, 1, seed);
}

kernel void createGalaxy    (device float4* position1 [[ buffer(0) ]],
                             device float4* velocity1 [[ buffer(1) ]],
                             device float4* position2 [[ buffer(2) ]],
                             device float4* velocity2 [[ buffer(3) ]],
                             device float4* position3 [[ buffer(4) ]],
                             device float4* velocity3 [[ buffer(5) ]],
                             constant float & clusterScale [[ buffer(6) ]],
                             constant float & velocityScale [[ buffer(7) ]],
                             constant uint & first [[ buffer(8) ]],
                             constant uint & last  [[ buffer(9) ]],
                             constant float4x4 & positionTransform [[ buffer(10) ]],
                             constant float4x4 & velocityTransform [[ buffer(11) ]],
                             constant float4 & axis [[ buffer(12) ]],
                             constant float & flatten [[ buffer(13) ]],
                             constant float & prescale [[ buffer(14) ]],
                             constant float & vrescale [[ buffer(15) ]],
                             constant float & vrandomness [[ buffer(16) ]],
                             constant float & squeeze [[ buffer(17) ]],
                             constant uint & randomSeed [[ buffer(18) ]],
                             constant float & rscale [[ buffer(19) ]],
                             threadgroup float * totalMass [[ threadgroup(0)  ]],
                             const uint threadInGrid [[ thread_position_in_grid ]],
                             const uint threadInGroup [[ thread_position_in_threadgroup ]],
                             const uint numThreadsInGroup [[ threads_per_threadgroup ]])
{
    // idea, just have as many threads as we can, and have each of those "work on 1/threads" of the workload, not all threads may need to do work, e.g. if last-first < number of threads, we have a lot of threads doing nothing, if last - first not complete a multiple of the number of threads, the last thread will be finished faster.
    
    uint blockSize = 1 + ((last - first - 1) / numThreadsInGroup);
 
    uint start = threadInGroup * blockSize + first;
    uint end = min((threadInGroup + 1) * blockSize + first - 1, last);
    
    if (start > last) {
        return; // nothing to do
    }
    
    // generic bit
    float pscale = clusterScale * prescale;
    float vscale = velocityScale * pscale * vrescale;
    float inner = 2.5 * pscale;
    float outer = 4.0 * pscale;
    totalMass[threadInGroup] = 0;
    float inverseSqueeze = 1/squeeze;
    
    float3 main_axis = float3(0.0f, 0.0f, 1.0f);
    
    for (uint i=first; i<=end; i++) {
        float4 position = float4(0,0,0,1); // last = 1 so it's matrix transformable
        float4 velocity = float4(0,0,0,1);

        int3 seed = int3(randomSeed, i, threadInGroup);
        
        float3 nrpos = random_normalized_vector(seed);
        float3 rpos = abs(random_normalized_vector(seed));
        
        position.xyz = nrpos * (inner + ((outer-inner) * rpos));
        float radius = rscale / random(0.465, 1, seed); //random(1, 2.15, seed); // 1 / random(0.465, 1, seed); could use something more "real" here.
        totalMass[threadInGroup] += radius * radius * radius /* power of three */;

        float3 my_axis = main_axis;
        float scalar = dot(nrpos, my_axis);
        
        if ((1 - scalar) < 0.000001) { // not entirely sure what this is for.
            my_axis.x = nrpos.y;
            my_axis.y = nrpos.x;
            
            my_axis = normalize(my_axis);
        }
        
        position.z *= flatten; // flatten galaxy
        
        velocity.xyz = cross(normalize(position.xyz), my_axis);
        
        velocity.xyz += vrandomness * dot(velocity.xyz, random_normalized_vector(seed));
        
        velocity.xyz *= vscale;
        
        velocity.x *= squeeze;
        velocity.y *= inverseSqueeze;
        
        if ((1 - scalar) < 0.5) {
            // squeeze - create a bar in the middle to make for a better start.
            position.y *= inverseSqueeze;
        }
        
        //position.xyz = pscale * random_normalized_vector(seed);

        /*
        // simple "round" galaxy, for testing, maybe should have "types".
        position.x = random(-1.0f, 1.0f, seed);
        position.y = random(-1.0f, 1.0f, seed);
        position.z = random(-1.0f, 1.0f, seed);
        position.xyz = pscale * normalize(position.xyz);
        velocity = 0;
        */

        /*
        // simple "round" galaxy, created another way, all on the outside V2, for testing, maybe should have "types".
        position.xyz = random_vector(pscale, pscale, seed);
        velocity = 0;
        */
        /*
        // last test, should also create the same
        position.xyz = pscale * random_normalized_vector(seed);
        velocity = 0;
        */

        position = positionTransform * position;
        velocity = velocityTransform * velocity;
        
        position.w = radius; // waited until here because otherwise this would affect our transformation.
        
        
        // copy results to all three buffers
        position1[i] = position;
        position2[i] = position;
        position3[i] = position;
        
        velocity1[i] = velocity;
        velocity2[i] = velocity;
        velocity3[i] = velocity;

    }
    
    // @this point each thread has the total mass in totalMass[threadInGroup], as thread zero will always have the longest runtime, have that thread calculate the total mass
    // removed, either this is wrong, or the cpu code got different results, removed.
    /*
    if (threadInGroup == 0) {
        float blackHoleMass = 0;
        for (uint i = 0; i < numThreadsInGroup; i++)
            blackHoleMass += totalMass[i];
        
        // create black Hole
        position1[first].xyz = 0;
        position1[first].w = pow (0.0025 * 65000, 0.33333333); // 3d root of 1/400 of the total mass.
        velocity1[first].xyz = 0;
        
        //copy to the other buffers;
        position2[first] = position1[first];
        position3[first] = position1[first];
        
        velocity2[first] = velocity1[first];
        velocity3[first] = velocity1[first];

    }
    
    // how do we calculate the real total mass, + we need to deal with the black hole stuff outside of this I would say, unless there is a smart way! fencing I believe.
    */
    return;
}


kernel void createStationaryGalaxy    (device float4* position1 [[ buffer(0) ]],
                             device float4* velocity1 [[ buffer(1) ]],
                             device float4* position2 [[ buffer(2) ]],
                             device float4* velocity2 [[ buffer(3) ]],
                             device float4* position3 [[ buffer(4) ]],
                             device float4* velocity3 [[ buffer(5) ]],
                             constant float & clusterScale [[ buffer(6) ]],
                             constant float & velocityScale [[ buffer(7) ]],
                             constant uint & first [[ buffer(8) ]],
                             constant uint & last  [[ buffer(9) ]],
                             constant float4x4 & positionTransform [[ buffer(10) ]],
                             constant float4x4 & velocityTransform [[ buffer(11) ]],
                             constant float4 & axis [[ buffer(12) ]],
                             constant float & flatten [[ buffer(13) ]],
                             constant float & prescale [[ buffer(14) ]],
                             constant float & vrescale [[ buffer(15) ]],
                             constant float & vrandomness [[ buffer(16) ]],
                             constant float & squeeze [[ buffer(17) ]],
                             constant uint & randomSeed [[ buffer(18) ]],
                             constant float & rscale [[ buffer(19) ]],
                             threadgroup float * totalMass [[ threadgroup(0)  ]],
                             const uint threadInGrid [[ thread_position_in_grid ]],
                             const uint threadInGroup [[ thread_position_in_threadgroup ]],
                             const uint numThreadsInGroup [[ threads_per_threadgroup ]])
{
    // idea, just have as many threads as we can, and have each of those "work on 1/threads" of the workload, not all threads may need to do work, e.g. if last-first < number of threads, we have a lot of threads doing nothing, if last - first not complete a multiple of the number of threads, the last thread will be finished faster.
    
    uint blockSize = 1 + ((last - first - 1) / numThreadsInGroup);
    
    uint start = threadInGroup * blockSize + first;
    uint end = min((threadInGroup + 1) * blockSize + first - 1, last);
    
    if (start > last) {
        return; // nothing to do
    }
    
    // generic bit
    float pscale = clusterScale * prescale;
    float vscale = velocityScale * pscale * vrescale;
    float inner = 2.5 * pscale;
    float outer = 4.0 * pscale;
    totalMass[threadInGroup] = 0;
    float inverseSqueeze = 1/squeeze;
    
    float3 main_axis = float3(0.0f, 0.0f, 1.0f);
    
    for (uint i=first; i<=end; i++) {
        float4 position = float4(0,0,0,1); // last = 1 so it's matrix transformable
        float4 velocity = float4(0,0,0,1);
        
        int3 seed = int3(randomSeed, i, threadInGroup);
        
        float3 nrpos = random_normalized_vector(seed);
        float3 rpos = abs(random_normalized_vector(seed));
        
        position.xyz = nrpos * (inner + ((outer-inner) * rpos));
        float radius = rscale / random(0.465, 1, seed); //random(1, 2.15, seed); // 1 / random(0.465, 1, seed); could use something more "real" here.
        totalMass[threadInGroup] += radius * radius * radius /* power of three */;
        
        float3 my_axis = main_axis;
        float scalar = dot(nrpos, my_axis);
        
        if ((1 - scalar) < 0.000001) { // not entirely sure what this is for.
            my_axis.x = nrpos.y;
            my_axis.y = nrpos.x;
            
            my_axis = normalize(my_axis);
        }
        
        position.z *= flatten; // flatten galaxy
        
        velocity.xyz = 0;/*cross(normalize(position.xyz), my_axis);
        
        velocity.xyz += vrandomness * dot(velocity.xyz, random_normalized_vector(seed));
        
        velocity.xyz *= vscale;
        
        velocity.x *= squeeze;
        velocity.y *= inverseSqueeze;*/
        
        if ((1 - scalar) < 0.5) {
            // squeeze - create a bar in the middle to make for a better start.
            position.y *= inverseSqueeze;
        }
        
        //position.xyz = pscale * random_normalized_vector(seed);
        
        /*
         // simple "round" galaxy, for testing, maybe should have "types".
         position.x = random(-1.0f, 1.0f, seed);
         position.y = random(-1.0f, 1.0f, seed);
         position.z = random(-1.0f, 1.0f, seed);
         position.xyz = pscale * normalize(position.xyz);
         velocity = 0;
         */
        
        /*
         // simple "round" galaxy, created another way, all on the outside V2, for testing, maybe should have "types".
         position.xyz = random_vector(pscale, pscale, seed);
         velocity = 0;
         */
        /*
         // last test, should also create the same
         position.xyz = pscale * random_normalized_vector(seed);
         velocity = 0;
         */
        
        position = positionTransform * position;
        velocity = velocityTransform * velocity;
        
        position.w = radius; // waited until here because otherwise this would affect our transformation.
        
        
        // copy results to all three buffers
        position1[i] = position;
        position2[i] = position;
        position3[i] = position;
        
        velocity1[i] = velocity;
        velocity2[i] = velocity;
        velocity3[i] = velocity;
        
    }
    
    // @this point each thread has the total mass in totalMass[threadInGroup], as thread zero will always have the longest runtime, have that thread calculate the total mass
    // removed, either this is wrong, or the cpu code got different results, removed.
    /*
     if (threadInGroup == 0) {
     float blackHoleMass = 0;
     for (uint i = 0; i < numThreadsInGroup; i++)
     blackHoleMass += totalMass[i];
     
     // create black Hole
     position1[first].xyz = 0;
     position1[first].w = pow (0.0025 * 65000, 0.33333333); // 3d root of 1/400 of the total mass.
     velocity1[first].xyz = 0;
     
     //copy to the other buffers;
     position2[first] = position1[first];
     position3[first] = position1[first];
     
     velocity2[first] = velocity1[first];
     velocity3[first] = velocity1[first];
     
     }
     
     // how do we calculate the real total mass, + we need to deal with the black hole stuff outside of this I would say, unless there is a smart way! fencing I believe.
     */
    return;
}


