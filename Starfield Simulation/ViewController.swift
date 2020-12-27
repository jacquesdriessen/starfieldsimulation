//
//  ViewController.swift
//  Starfield Simulation
//
//  Created by Jacques Driessen on 22/12/2020.
//

import UIKit
import Metal
import MetalKit
import ARKit

extension MTKView : RenderDestinationProvider {
}

class ViewController: UIViewController, MTKViewDelegate, ARSessionDelegate {
    var _view: MTKView!
    var session: ARSession!
    var renderer: Renderer!
    var _simulation: StarSimulation!
    
    var _simulationTime: CFAbsoluteTime!
    
    var _computeDevice: MTLDevice!
    
    var _commandQueue: MTLCommandQueue!
    
    var _config: SimulationConfig!
    
    var _terminateAllSimulations = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Set the view's delegate
        session = ARSession()
        session.delegate = self
        
        // Set the view to use the default device
        _view = (self.view as! MTKView)
        
        _view.device = MTLCreateSystemDefaultDevice()
        _view.backgroundColor = UIColor.clear
        _view.delegate = self
            
        guard _view.device != nil else {
            print("Metal is not supported on this device")
            return
        }
        
        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(ViewController.handleDoubleTap(gestureRecognize:)))
        view.addGestureRecognizer(doubleTapGesture)
        doubleTapGesture.numberOfTapsRequired = 2

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(ViewController.handleTap(gestureRecognize:)))
        view.addGestureRecognizer(tapGesture)
        tapGesture.numberOfTapsRequired = 1
        tapGesture.require(toFail: doubleTapGesture)
        
        let longPressGesture = UILongPressGestureRecognizer (target: self, action: #selector(ViewController.handleLongPress(gestureRecognize:)))
        view.addGestureRecognizer(longPressGesture)
        longPressGesture.minimumPressDuration = 1
        
        let swipeRightGesture = UISwipeGestureRecognizer(target: self, action: #selector(ViewController.handleSwipe(gestureRecognize:)))
        view.addGestureRecognizer(swipeRightGesture)
        swipeRightGesture.direction = .right

        let swipeLeftGesture = UISwipeGestureRecognizer(target: self, action: #selector(ViewController.handleSwipe(gestureRecognize:)))
        view.addGestureRecognizer(swipeLeftGesture)
        swipeLeftGesture.direction = .left
        
        let swipeUpGesture = UISwipeGestureRecognizer(target: self, action: #selector(ViewController.handleSwipe(gestureRecognize:)))
        view.addGestureRecognizer(swipeUpGesture)
        swipeUpGesture.direction = .up
        
        let swipeDownGesture = UISwipeGestureRecognizer(target: self, action: #selector(ViewController.handleSwipe(gestureRecognize:)))
        view.addGestureRecognizer(swipeDownGesture)
        swipeDownGesture.direction = .down
        
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(ViewController.handlePinch(gestureRecognize:)))
        view.addGestureRecognizer(pinchGesture)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        beginSimulation()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        let serialQueue = DispatchQueue(label: "com.test.mySerialQueue")
        serialQueue.sync {
            _simulation.halt = true
            _terminateAllSimulations = true
        }
    }
        
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Create a session configuration
        let configuration = ARWorldTrackingConfiguration()

        // Run the view's session
        session.run(configuration)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Pause the view's session
        session.pause()
    }
    
    func beginSimulation() {
        _simulationTime = 0
     //   _config = SimulationConfig(damping: 1, softeningSqr: 0.01, numBodies: 16384, clusterScale: 0.05, velocityScale: 25000, renderScale: 20, renderBodies: 16 /* not implemented */, simInterval: 0.0000320, simDuration: 100 /* dont think thtis was implemented */)
     //   _config = SimulationConfig(damping: 1, softeningSqr: 0.08, numBodies: 16384, clusterScale: 0.05, velocityScale: 25000, renderScale: 20, renderBodies: 16 /* not implemented */, simInterval: 0.0000640, simDuration: 100 /* dont think thtis was implemented */) // this is fairly realistic (my opinion)
      //  _config = SimulationConfig(damping: 1, softeningSqr: 2*2*0.16, numBodies: 2*32768, clusterScale: 0.05, velocityScale: 25000, renderScale: 2*40, renderBodies: 16 /* not implemented */, simInterval: 2*2*0.0002560, simDuration: 100 /* dont think thtis was implemented */) // also fairly realistic  with these # particles
        _config = SimulationConfig(damping: 1, softeningSqr: 0.128, numBodies: 32768, clusterScale: 0.035, velocityScale: 4000, renderScale: 1, renderBodies: 16 /* not implemented */, simInterval: 0.0002560, simDuration: 100 /* dont think thtis was implemented */) // also fairly realistic  with these # particles
        
        // Configure the renderer to draw to the view
        renderer = Renderer(session: session, metalDevice: _view.device!, renderDestination: _view, numBodies: Int(_config.numBodies))

        renderer.setRenderScale(renderScale: _config.renderScale)
        
        _computeDevice = _view.device!
        
        renderer.drawRectResized(size: _view.bounds.size)
        
        print("Starting Simulation")
        
        _simulation = StarSimulation.init(computeDevice: _computeDevice, config: _config)

        _commandQueue = renderer.device.makeCommandQueue()
    }

    @objc
    func handleDoubleTap(gestureRecognize: UITapGestureRecognizer) {
        guard gestureRecognize.view != nil else {
            return
        }
        
        if gestureRecognize.state == .ended {
            renderer.nightSkyMode = !renderer.nightSkyMode
        }
    }
    
    @objc
    func handleTap(gestureRecognize: UITapGestureRecognizer) {
        guard gestureRecognize.view != nil else {
            return
        }
        
        if gestureRecognize.state == .ended {
            _simulation.halt = !_simulation.halt // pause
        }
    }

    @objc
    func handleLongPress(gestureRecognize: UILongPressGestureRecognizer) {
        guard gestureRecognize.view != nil else {
            return
        }
        
        _simulation.interact = true
        
        if gestureRecognize.state == .ended {
            _simulation.interact = false
        }
    }

    
    @objc
    func handleSwipe(gestureRecognize: UISwipeGestureRecognizer) {
        guard gestureRecognize.view != nil else {
            return
        }
        if gestureRecognize.state == .ended {
            // make sure we are not processing stuff on the gpu before we modify data.
            let _ = renderer.inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)
            _simulation.initalizeData()
            renderer.inFlightSemaphore.signal()
        }
    }

    @objc
    func handlePinch(gestureRecognize: UIPinchGestureRecognizer) {
        guard gestureRecognize.view != nil else {
            return
        }
        if gestureRecognize.state == .ended {
            switch _simulation.track {
                case 0:
                    _simulation.track = 1
                case 1:
                    _simulation.track = 2
                case 2:
                    _simulation.track = 3
                case 3:
                    _simulation.track = 0
                default:
                    _simulation.track = 0
            }
        }
        
    }

    
    
    
    // MARK: - MTKViewDelegate
    
    // Called whenever view changes orientation or layout is changed
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.drawRectResized(size: size)
    }
    
    // Called whenever the view needs to render
    func draw(in view: MTKView) {
        
        // update position 20cms in front of the camera using the camera's current position, "finger"
        if let currentFrame = session.currentFrame {
            _simulation.camera = currentFrame.camera.transform
        }
               
        if _simulation != nil {
            renderer.draw(positionsBuffer1: _simulation.getStablePositionBuffer1(), positionsBuffer2: _simulation.getStablePositionBuffer2(), interpolation: _simulation.getInterpolation(), numBodies: Int(_config.numBodies), inView: _view)
        }
        
        if _commandQueue != nil {
            let commandBuffer = _commandQueue.makeCommandBuffer()!
            
            commandBuffer.pushDebugGroup("Controller Frame")
            
            _simulation.simulateFrameWithCommandBuffer(commandBuffer: commandBuffer)
            
            commandBuffer.commit()
            commandBuffer.popDebugGroup()
            
            _simulationTime += Double(_config.simInterval)
        }
    }
    
    // MARK: - ARSessionDelegate
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        // Present an error message to the user
        
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        // Inform the user that the session has been interrupted, for example, by presenting an overlay
        
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        // Reset tracking and/or remove existing anchors if consistent tracking is required
        
    }
}
