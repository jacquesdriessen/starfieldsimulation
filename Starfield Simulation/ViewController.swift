//
//  ViewController.swift
//  Starfield Simulation
//
//  Created by Jacques Driessen on 22/12/2020.
//

import Metal
import MetalKit
import ARKit

// get some global variables as otherwise we just passing things around
var partitions = 1

@IBDesignable class MyButton: UIButton
{
    override func layoutSubviews() {
        super.layoutSubviews()
        
        layer.cornerRadius = 10
        clipsToBounds = true
        backgroundColor = .systemGray
    }
}

@IBDesignable class MyStepper: UIStepper
{
    override func layoutSubviews() {
        super.layoutSubviews()
        value = 0
        minimumValue = -1
        maximumValue = 1
        stepValue = 1
        wraps = false
        autorepeat = true
        backgroundColor = .systemGray
    }
    
    func direction() -> Int {
        let _direction = value
        value = 0 // reset.
        
        return Int(_direction)
    }
}

@IBDesignable class MyStepperLabel: UILabel
{
    override func layoutSubviews() {
        super.layoutSubviews()
        textColor = .white
    }
}

@IBDesignable class MyStepperWrapper: UIStackView
{
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = 10
        backgroundColor = .black
        alignment = .center
        distribution = .fillEqually
    }
}

@IBDesignable class MyStackView: UIStackView
{
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = 10
    }
}

extension MTKView : RenderDestinationProvider {
}

class ViewController: UIViewController, MTKViewDelegate, ARSessionDelegate, UIPickerViewDelegate, UIPickerViewDataSource {

    var _view: MTKView!
    var session: ARSession!
    var renderer: Renderer!
    var _simulation: StarSimulation!
    
    var _simulationTime: CFAbsoluteTime!
    
    var _computeDevice: MTLDevice!
    
    var _commandQueue: MTLCommandQueue!
    
    var _config: SimulationConfig!
    
    var _terminateAllSimulations = false
    
    var pinch : CGFloat = 0
    
    var horizontalPan = false
    var verticalPan = false
    
    var fadeIn = false // controls the fade direction
    var alpha: CGFloat = 1
    
    var blackHoleMode: Bool = false
    var fingerScreenCoordinates: CGPoint = CGPoint(x: 0,y: 0)
    var fingerCoordinates: vector_float2 = vector_float2(0,0)
    var fingerWorldCoordinates: vector_float4 = vector_float4(0,0,0,0) // can't get these right

    @IBAction func arStepperValueChanged(_ sender: MyStepper) {
        showUI()
        sender.direction() == 1 ? renderer.increaseCameraExposure() : renderer.decreaseCameraExposure()
    }
 
    @IBAction func starSizeStepperValueChanged(_ sender: MyStepper) {
        showUI()
        sender.direction() == 1 ? renderer.increaseStarSize() : renderer.decreaseStarSize()
    }
    @IBAction func simulationStepperValueChanged(_ sender: MyStepper) {
        showUI()
        // disable false colour mode as going to next simulation
        renderer.disableFalseColours()
        sender.direction() == 1 ? _simulation.nextmodel(semaphore: renderer.inFlightSemaphore) : _simulation.previousmodel(semaphore: renderer.inFlightSemaphore) // semaphore to make sure we are not processing stuff on the gpu before we modify data.
        // reset everything else
        collisionsLabel.text = "Collisions: Off"
        gravityStepper.value = 100
        gravityLabel.text = "Gravity: 100%"
        timeStepper.value = 100
        timeLabel.text = "Time: 100%"
        TrackingPicker.selectRow(0, inComponent: 0, animated: true)
    }
    
    @IBOutlet weak var collisionsLabel: MyStepperLabel!
    
    @IBAction func collisionsStepperValueChanged(_ sender: MyStepper) {
      showUI()
        if sender.direction() == 1 {
            _simulation.collide(semaphore: renderer.inFlightSemaphore)
            collisionsLabel.text = "Collisions: On"
        } else {
            _simulation.leaveAlone(semaphore: renderer.inFlightSemaphore) // semaphore to make sure we are not processing stuff on the gpu before we modify data.
            collisionsLabel.text = "Collisions: Off"
        }
    }
    
    @IBOutlet weak var gravityLabel: MyStepperLabel!
    @IBOutlet weak var gravityStepper: UIStepper!
    @IBAction func gravityStepperValueChanged(_ sender: UIStepper) {
        showUI()
        gravityLabel.text = "Gravity: " + String (Int(sender.value)) + "%"
        _simulation.gravity = Float(sender.value)
    }
    
    @IBOutlet weak var timeLabel: MyStepperLabel!
    @IBOutlet weak var timeStepper: UIStepper!
    @IBAction func timeStepperValueChanged(_ sender: UIStepper) {
        showUI()
        timeLabel.text = "Time: " + String (Int(sender.value)) + "%"
        _simulation.speed = Float(sender.value)
    }
    
    @IBAction func coloursPressed(_ sender: MyButton) {
        renderer.toggleFalseColours(_split: UInt(_simulation.split))
    }
    
    @IBOutlet weak var pinchLabel: UILabel!
    

    let trackingOptions : [String] = ["None", "Red / 1", "Orange / 2", "Middle"]

    @IBOutlet weak var TrackingPicker: UIPickerView!
  
    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return 1
    }
    
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return trackingOptions.count
    }
    
    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        return trackingOptions[row]
     }
    
    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        _simulation.track = row
    }
    
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
            return
        }

        TrackingPicker.delegate = self
        TrackingPicker.dataSource = self

        /*
        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(ViewController.handleDoubleTap(gestureRecognize:)))
        view.addGestureRecognizer(doubleTapGesture)
        doubleTapGesture.numberOfTapsRequired = 2
*/
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(ViewController.handleTap(gestureRecognize:)))
        view.addGestureRecognizer(tapGesture)
        tapGesture.numberOfTapsRequired = 1
  //      tapGesture.require(toFail: doubleTapGesture)
   
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(ViewController.handlePinch(gestureRecognize:)))
        view.addGestureRecognizer(pinchGesture)
        /*
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(ViewController.handlePan(gestureRecognize:)))
        view.addGestureRecognizer(panGesture)
        panGesture.require(toFail: tapGesture)*/

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(ViewController.handleLongPress(gestureRecognize:)))
        view.addGestureRecognizer(longPress)
        longPress.minimumPressDuration = 0.5

   }

    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        beginSimulation()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        let serialQueue = DispatchQueue(label: "com.starfieldsimulation.mySerialQueue")
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
        _config = SimulationConfig(damping: 0.999, softeningSqr: 0.128, numBodies: 32768, clusterScale: 0.035, velocityScale: 4000, renderScale: 1, renderBodies: 16 /* not implemented */, simInterval: 0.0002560, simDuration: 100 /* dont think thtis was implemented */) // also fairly realistic  with these # particles
        
        // Configure the renderer to draw to the view
        renderer = Renderer(session: session, metalDevice: _view.device!, renderDestination: _view, numBodies: Int(_config.numBodies))

        renderer.setRenderScale(renderScale: _config.renderScale)
        
        _computeDevice = _view.device!
        
        renderer.drawRectResized(size: _view.bounds.size)
        
        print("Starting Simulation")
        
        _simulation = StarSimulation.init(computeDevice: _computeDevice, config: _config)

        _commandQueue = renderer.device.makeCommandQueue()
    }
    
    /*
    @objc
    func handleDoubleTap(gestureRecognize: UITapGestureRecognizer) {
        guard gestureRecognize.view != nil else {
            return
        }
        
        
        fingerScreenCoordinates = gestureRecognize.location(in: self.view)

        if gestureRecognize.state == .began {
        }
        
        if gestureRecognize.state == .ended {
         /*   let x = 200*(gestureRecognize.location(in: self.view).x-0.5*view.frame.size.width)/view.frame.size.width // coordinates -100...100
            let y = 200*(gestureRecognize.location(in: self.view).y-0.5*view.frame.size.height)/view.frame.size.height  // coordinates -100...100
            
            if x < -80 && y > 80 { // unambiguous bottom left corner
                renderer.decreaseStarSize()
            } else if x > 80 && y > 80 { // unambiguous bottom right corner
                renderer.increaseStarSize()
            } else if x < -80 && y < -80 { // unambiguous top left corner
                renderer.decreaseCameraExposure()
            } else if x > 80 && y < -80 { // unambiguous top right corner
                renderer.increaseCameraExposure()
            } else */ // tracking mode
                 _simulation.track = (_simulation.track + 1) % 4
            
        }
    }
    */
    
    @objc
    func handleTap(gestureRecognize: UITapGestureRecognizer) {
        guard gestureRecognize.view != nil else {
            return
        }

        showUI()
        fingerScreenCoordinates = gestureRecognize.location(in: self.view)

        if (_simulation.halt == true) { // need a different place / method I guess, this is ia hack
            _simulation.halt = false
        }
    
        /*
        if gestureRecognize.state == .began {
        }
      
        if gestureRecognize.state == .ended {
            let x = 200*(gestureRecognize.location(in: self.view).x-0.5*view.frame.size.width)/view.frame.size.width // coordinates -100...100
            let y = 200*(gestureRecognize.location(in: self.view).y-0.5*view.frame.size.height)/view.frame.size.height  // coordinates -100...100
   /*
            if x < -80 && abs(y) < 50 { // unambiguous left
                // disable false colour mode as going to next simulation
                renderer.disableFalseColours()
                // make sure we are not processing stuff on the gpu before we modify data.
                _simulation.previousmodel(semaphore: renderer.inFlightSemaphore)
            } else if x > 80 && abs(y) < 50 { // unambiguous right
                // disable false colour mode as going to next simulation
                renderer.disableFalseColours()
                // make sure we are not processing stuff on the gpu before we modify data.
                _simulation.nextmodel(semaphore: renderer.inFlightSemaphore)
            } else if y < -80 && abs(x) < 50 { // unambigous top
                // make sure we are not processing stuff on the gpu before we modify data.
                _simulation.collide(semaphore: renderer.inFlightSemaphore)
            } else if y > 80 && abs(x) < 50 { // unambigous bottom
                // make sure we are not processing stuff on the gpu before we modify data.
                _simulation.leaveAlone(semaphore: renderer.inFlightSemaphore)
            } else */if abs(x) < 50 && abs(y) < 50 { // unambigous middle}
                renderer.toggleFalseColours(_split: UInt(_simulation.split))
            } /*else if x < -80 && y > 80 { // unambiguous bottom left corner
                renderer.decreaseStarSize()
            } else if x > 80 && y > 80 { // unambiguous bottom right corner
                renderer.increaseStarSize()
            } else if x < -80 && y < -80 { // unambiguous top left corner
                renderer.decreaseCameraExposure()
            } else if x > 80 && y < -80 { // unambiguous top right corner
                renderer.increaseCameraExposure()
            }*/
        } */
    }
    
    @objc
    func handleLongPress(gestureRecognize: UILongPressGestureRecognizer) {
        guard gestureRecognize.view != nil else {
            return
        }
        
        showUI()
        fingerScreenCoordinates = gestureRecognize.location(in: self.view)

        if gestureRecognize.state == .began {
            blackHoleMode = true
            _simulation.interact = true
        }
 
        if gestureRecognize.state == .ended {
            blackHoleMode = false
            _simulation.interact = false
        }
    }
 

    @objc
    func handlePinch(gestureRecognize: UIPinchGestureRecognizer) {
        guard gestureRecognize.view != nil else {
            return
        }
        
        showUI()
        fingerScreenCoordinates = gestureRecognize.location(in: self.view)

        // WE NEED TO MOVE THIS SOMEWHERE ELSE
        // _simulation.squeeze(_pinch: Float(gestureRecognize.scale))
        
        
        if gestureRecognize.state == .began || gestureRecognize.state == .changed {
            let velocity = Float(gestureRecognize.velocity)

            let direction = extractOrientationMatrix(fullmatrix: cameraMatrix()) * vector_float4(0,0,-1, 1)
            
            _simulation.move(position: 0.5*velocity*direction)
            
            
        }
        
        // Show UI explanation
        if gestureRecognize.state == .began {
            pinchLabel.alpha = 1.0
        }
        
        if gestureRecognize.state == .ended {
            _simulation.squeeze(_pinch:1)
            pinchLabel.alpha = 0
        }
    }
    /*
    @objc
    func handlePan(gestureRecognize: UIPanGestureRecognizer) {
        guard gestureRecognize.view != nil else {
            return

        showUI()
        fingerScreenCoordinates = gestureRecognize.location(in: self.view)

        /*
        let x : Float = Float(200*(gestureRecognize.location(in: self.view).x-0.5*view.frame.size.width)/view.frame.size.width) // coordinates -100...100
        let y : Float = Float(200*(gestureRecognize.location(in: self.view).y-0.5*view.frame.size.height)/view.frame.size.height)  // coordinates -100...100
        
        if horizontalPan {
            /*_simulation.speed = min(max(Float(-200.0),_simulation.speed + 0.01*Float(gestureRecognize.translation(in: gestureRecognize.view!.superview!).x)), Float(200.0)) // keep between -200 and 200% */
            _simulation.speed = 1.5 * x // keep between -150% and + 150%
        }

        if verticalPan {
            _simulation.gravity = 2 * 0.5*(y+100) // keep between 0 and 200%
        }
        
        
        if gestureRecognize.state == .began {

            if (abs(x) < 25) { // only start if we purposely start from the middle
                verticalPan = true
            } else {
                verticalPan = false
            }

            if (abs(y) < 25) { // only start if we purposely start from the middle
                horizontalPan = true
            } else {
                horizontalPan = false
            }
        }
        
        if gestureRecognize.state == .ended {
            horizontalPan = false
            verticalPan = false
        } */
    }
 */
   
    // MARK: - MTKViewDelegate
    
    // Called whenever view changes orientation or layout is changed
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.drawRectResized(size: size)
    }
    
     func cameraMatrix() -> float4x4 {
        guard let currentFrame = session.currentFrame else {
            return matrix_identity_float4x4
        }

        let camera = currentFrame.camera.transform

        return camera
    }
    
    func projectionMatrix() -> float4x4 {
        guard let currentFrame = session.currentFrame else {
            return matrix_identity_float4x4
        }
        
        let projection = currentFrame.camera.projectionMatrix
        
        return projection
    }
    
    func screenCoordinatesToNormalCoordinates(screenCoordinates: CGPoint) -> vector_float2 {
        let x : Float = 1  * ( 2 * Float(screenCoordinates.x) / Float(view.frame.size.width) - 1) // 0.001 is that scaling factor
        let y : Float = -1 * ( 2 * Float(screenCoordinates.y) / Float(view.frame.size.height) - 1) // for whatever reason this is upside down.

        return vector_float2(x,y)
    }
    
    func screenCoordinatesToWorldCoordinates(screenCoordinates: CGPoint) -> vector_float4 {
        // https://jsantell.com/3d-projection/ to learn about projections.
        // there should be a more straightforward way, but I think this makes sense to me.

        let forward_transform = projectionMatrix() * cameraMatrix()                     // transformation (<- direction) device3D  <- world
        let inverse_transform = cameraMatrix().inverse * projectionMatrix().inverse     // transformation (<- direction) world     <- device3D
                                                                                        // transformation (<- direction) device2D  <- device3D = drop z & w
                                                                                        // transformation (<- direction) device3D  <- device2D is the hard bit, requires knowledge of the device (end of the day 2D) and it's orientation & how it scales to the real world. For the middle of device & world, it's easy.

        
        // where the device is right now.
        let deviceMiddle_world = cameraMatrix().columns.3 // column 3 = position of the camera
        let deviceMiddle_device3D = forward_transform * deviceMiddle_world

        // where we are on the tablet
        let deviceCoordinates = screenCoordinatesToNormalCoordinates(screenCoordinates:screenCoordinates)
        let deviceCoordinates_device3D = vector_float4(deviceCoordinates.x, deviceCoordinates.y, 0, 0) // This is 2D I know, but that
        
        let point = inverse_transform * (deviceMiddle_device3D + deviceCoordinates_device3D) //  figure out where we are compared to where the device is

        return point
        
    }

    func setAlphaUI() {
        for v:UIView in view.subviews {
            if v != pinchLabel {
                v.alpha =  min(alpha, CGFloat(1)) // min so we can use alpha > 1 to "show the UI longer" at the start.
            }
        }
    }
    
    func fadeUI() {
        if (fadeIn) {
            if alpha < 1.0 {
                alpha = min(alpha + CGFloat(0.025), CGFloat(1))
                setAlphaUI()
            } else {
                fadeIn = false // fadeout again
            }
            
        } else {
            if alpha > 0 {
                alpha = max(alpha - CGFloat(0.002), CGFloat(0))
                setAlphaUI()
            }
        }
    }
    
    func showUI() {
        fadeIn = true
    }
    
    // Called whenever the view needs to render
    func draw(in view: MTKView) {
        
        // handle fadeIn/Out of UI
        fadeUI()
        
        // handle screen to world for finger
        fingerWorldCoordinates = screenCoordinatesToWorldCoordinates(screenCoordinates: fingerScreenCoordinates)
        fingerCoordinates = screenCoordinatesToNormalCoordinates(screenCoordinates: fingerScreenCoordinates)
        
        // pass camera position through to simulation, need to be smarter about this.
        if let currentFrame = session.currentFrame {
            _simulation.camera = currentFrame.camera.transform
        }
               
        if _simulation != nil {
            
            renderer.draw(positionsBuffer1: _simulation.getStablePositionBuffer1(), positionsBuffer2: _simulation.getStablePositionBuffer2(), interpolation: _simulation.getInterpolation(), numBodies: Int(_config.numBodies), inView: _view, finger: fingerWorldCoordinates)
        }
        
        if _commandQueue != nil {
            let commandBuffer = _commandQueue.makeCommandBuffer()!
            
            commandBuffer.pushDebugGroup("Controller Frame")
            
            _simulation.simulateFrameWithCommandBuffer(commandBuffer: commandBuffer, touch: fingerCoordinates, finger: fingerWorldCoordinates)
            
            commandBuffer.commit()
            commandBuffer.popDebugGroup()
            
            _simulationTime += Double(_config.simInterval)
        }
    }
    
    // MARK: - ARSessionDelegate
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        // Present an error message to the user
        _simulation.halt = true
        print("AR Error")
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        // Inform the user that the session has been interrupted, for example, by presenting an overlay
        _simulation.halt = true
        print("AR Session interrupted")
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        // Reset tracking and/or remove existing anchors if consistent tracking is required
        _simulation.halt = false
        print("AR Session resumed")
    }
}
