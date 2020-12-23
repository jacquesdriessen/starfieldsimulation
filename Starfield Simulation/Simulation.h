//
//  Simulation.h
//  Starfield Simulation
//
//  Created by Jacques Driessen on 22/12/2020.
//

#ifndef Simulation_h
#define Simulation_h

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

// Parameters to perform the N-Body simulation
typedef struct SimulationConfig {
    float          damping;       // Factor for reducing simulation instability
    float          softeningSqr;  // Factor for simulating collisions
    uint32_t       numBodies;     // Number of bodies in the simulations
    float          clusterScale;  // Factor for grouping the initial set of bodies
    float          velocityScale; // Scaling of  each body's speed
    float          renderScale;   // The scale of the viewport to render the results
    NSUInteger     renderBodies;  // Number of bodies to transfer and render for an intermediate update
    float          simInterval;   // The "time" (in "simulation time" units) of each frame of the simulation
    CFAbsoluteTime simDuration;   // The "duration" (in "simulation time" units) for the simulation
} SimulationConfig;



#endif /* Simulation_h */
