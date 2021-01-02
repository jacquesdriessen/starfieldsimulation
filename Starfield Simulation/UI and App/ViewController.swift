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
var trackingMatrix = matrix_identity_float4x4
let arEnabled: Bool = true
let testMode: Bool = false //to be able to freeze time / small amount particles
var viewportSize: CGSize = CGSize() // The current viewport size
var commandQueue: MTLCommandQueue!
var fixCamera = matrix_identity_float4x4

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

class ViewController: UIViewController, UIGestureRecognizerDelegate, MTKViewDelegate, ARSessionDelegate, UIPickerViewDelegate, UIPickerViewDataSource {

    var _view: MTKView!
    var session: ARSession!
    var renderer: Renderer!
    var _simulation: StarSimulation!
    
    var _simulationTime: CFAbsoluteTime!
    
    var _computeDevice: MTLDevice!
    
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
    var stickyCamera : Bool = false

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
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(ViewController.handleTap))
        view.addGestureRecognizer(tapGesture)
        tapGesture.numberOfTapsRequired = 1
        tapGesture.delegate = self
  //      tapGesture.require(toFail: doubleTapGesture)
   

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(ViewController.handlePan))
        view.addGestureRecognizer(panGesture)
        panGesture.delegate = self
        // ? needed or not panGesture.require(toFail: tapGesture)

        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(ViewController.handlePinch))
        view.addGestureRecognizer(pinchGesture)
        pinchGesture.delegate = self
        
        let rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(ViewController.handleRotation))
        view.addGestureRecognizer(rotationGesture)
        rotationGesture.delegate = self

        
        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(ViewController.handleLongPress))
        view.addGestureRecognizer(longPressGesture)
        longPressGesture.minimumPressDuration = 0.5
        longPressGesture.delegate = self

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

        if (!testMode) {
        _config = SimulationConfig(damping: 0.999, softeningSqr: 0.128, numBodies: 262144, clusterScale: 0.035, velocityScale: 4000, renderScale: 1, renderBodies: 16 /* not implemented */, simInterval: 1/16*0.0002560, simDuration: 100 /* dont think thtis was implemented */) // can go up this high because of the hack, but takes a long time to "load" a galaxy, maybe something we can do (copying could be done on the GPU?)
        } else {
        // test mode, just a few particles, time frozen.
        _config = SimulationConfig(damping: 0.999, softeningSqr: 0.128, numBodies: 8192, clusterScale: 0.035, velocityScale: 4000, renderScale: 1, renderBodies: 16 /* not implemented */, simInterval: 0, simDuration: 100 /* dont think thtis was implemented */) // can go up this high because of the hack, but takes a long time to "load" a galaxy, maybe something we can do (copying could be done on the GPU?)
        }
        
        // Configure the renderer to draw to the view
        renderer = Renderer(session: session, metalDevice: _view.device!, renderDestination: _view, numBodies: Int(_config.numBodies))

        renderer.setRenderScale(renderScale: _config.renderScale)
        
        _computeDevice = _view.device!
        
        renderer.drawRectResized(size: _view.bounds.size)
        
        print("Starting Simulation")

        commandQueue = renderer.device.makeCommandQueue()

        _simulation = StarSimulation.init(computeDevice: _computeDevice, config: _config)

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
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer.view != nil else {
            return false
        }
        print("hello")
        // define all the simulatenously allowed gestures
        if gestureRecognizer is UIPinchGestureRecognizer &&
            (otherGestureRecognizer is UIRotationGestureRecognizer ||
                otherGestureRecognizer is UIPanGestureRecognizer) {
            return true
        }

        if gestureRecognizer is UIPinchGestureRecognizer &&
            (otherGestureRecognizer is UIRotationGestureRecognizer ||
                otherGestureRecognizer is UIPanGestureRecognizer) {
            return true
        }
        
        if gestureRecognizer is UIPanGestureRecognizer &&
            (otherGestureRecognizer is UIRotationGestureRecognizer ||
                otherGestureRecognizer is UIPinchGestureRecognizer) {
            return true
        }
        
        
        return false;
    }

    
    
    @objc
    func handleTap(gestureRecognizer: UITapGestureRecognizer) -> Bool {
        guard gestureRecognizer.view != nil else {
            return false
        }

        showUI()
        fingerScreenCoordinates = gestureRecognizer.location(in: self.view)

        if (_simulation.halt == true) { // need a different place / method I guess, this is ia hack
            _simulation.halt = false
        }
        
        return true
    }
    
    @objc
    func handleLongPress(gestureRecognizer: UILongPressGestureRecognizer) -> Bool{
        guard gestureRecognizer.view != nil else {
            return false
        }
        
        showUI()
        fingerScreenCoordinates = gestureRecognizer.location(in: self.view)

        if gestureRecognizer.state == .began {
            blackHoleMode = true
            _simulation.interact = true
        }
 
        if gestureRecognizer.state == .ended {
            blackHoleMode = false
            _simulation.interact = false
        }
        
        return true
    }
 
    @objc
    func handlePan(gestureRecognizer: UIPanGestureRecognizer) -> Bool{
        guard gestureRecognizer.view != nil else {
            return false
        }
        
        fingerScreenCoordinates = gestureRecognizer.location(in: self.view)
        
        if gestureRecognizer.state == .began || gestureRecognizer.state == .changed {
            let velocity = gestureRecognizer.velocity

            trackingMatrix = cameraMatrix().inverse * rotationMatrix(rotation: vector_float3(0, -Float(velocity(gestureRecognizer.view!.superview!).x)/32768,-Float(velocity(gestureRecognizer.view!.superview!).y)/32768)) * cameraMatrix() * trackingMatrix //32768 is coincidence.

            if stickyCamera {
                trackingMatrix = cameraMatrix().inverse * fixCamera * trackingMatrix
                
                fixCamera = cameraMatrix()
            }
        }
        
        if gestureRecognizer.state == .began && stickyCamera == false {
            fixCamera = cameraMatrix()
            stickyCamera = true
        }
        
        if gestureRecognizer.state == .ended {
            stickyCamera = false
        }

        return true
    }
    
    @objc
    func handlePinch(gestureRecognizer: UIPinchGestureRecognizer) -> Bool {
        guard gestureRecognizer.view != nil else {
            return false
        }
                
        fingerScreenCoordinates = gestureRecognizer.location(in: self.view)
        
        if gestureRecognizer.state == .began || gestureRecognizer.state == .changed {
            let velocity = Float(gestureRecognizer.velocity)

                trackingMatrix = cameraMatrix().inverse * translationMatrix(translation:vector_float4(0,0,velocity/16,1)) * cameraMatrix() * trackingMatrix

            if stickyCamera {
                trackingMatrix = cameraMatrix().inverse * fixCamera * trackingMatrix

                fixCamera = cameraMatrix()
            }
        }
        
        if gestureRecognizer.state == .began && stickyCamera == false {
            fixCamera = cameraMatrix()
            stickyCamera = true
        }
        
        if gestureRecognizer.state == .ended {
            stickyCamera = false
        }
        
        return true
    }
    
    @objc
    func handleRotation(gestureRecognizer: UIRotationGestureRecognizer) -> Bool {
        guard gestureRecognizer.view != nil else {
            return false
        }
        
        fingerScreenCoordinates = gestureRecognizer.location(in: self.view)
        
        /* idea - but need to think through
        let finger = screenCoordinatesToWorldCoordinates(screenCoordinates: fingerScreenCoordinates)
        let camera = cameraMatrix().columns.3

        let offsetMatrix = translationMatrix(from: finger, to: camera)
        */
        /* another idea, better, but not it, think it through first I guess
        let finger = cameraMatrix() * screenCoordinatesToWorldCoordinates(screenCoordinates: fingerScreenCoordinates)
        let offsetMatrix = translationMatrix(translation: vector_float3(finger.x, finger.y, finger.z))
         */
        
        if gestureRecognizer.state == .began || gestureRecognizer.state == .changed {
            let velocity = gestureRecognizer.velocity

            trackingMatrix = cameraMatrix().inverse * /*offsetMatrix */  rotationMatrix(rotation: vector_float3(-Float(velocity)/35, 0, 0)) * /*offsetMatrix.inverse */ cameraMatrix() * trackingMatrix

            if stickyCamera {
                trackingMatrix = cameraMatrix().inverse * fixCamera * trackingMatrix
                
                fixCamera = cameraMatrix()
            }
        }
        
        if gestureRecognizer.state == .began && stickyCamera == false {
            fixCamera = cameraMatrix()
            stickyCamera = true
        }
        
        if gestureRecognizer.state == .ended {
            stickyCamera = false
        }

        return true
    }

    
    
   
    // MARK: - MTKViewDelegate
    
    // Called whenever view changes orientation or layout is changed
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.drawRectResized(size: size)
    }
    
     func cameraMatrix() -> float4x4 {
        guard let currentFrame = session.currentFrame else {
            return matrix_identity_float4x4
        }

        let camera = (arEnabled ? currentFrame.camera.viewMatrix(for: .landscapeRight) : matrix_identity_float4x4)

        return camera
    }
    
    func projectionMatrix() -> float4x4 {
        guard let currentFrame = session.currentFrame else {
            return matrix_identity_float4x4
        }
        
        let projection = currentFrame.camera.projectionMatrix(for: .landscapeRight, viewportSize: viewportSize, zNear: 0.001, zFar: 1000)
        
        return projection
    }
   
    
    func viewportMatrix() -> float4x4 {
        // https://vitaminac.github.io/Matrices-in-Computer-Graphics/#Viewport-Transformation-Matrix
        let l: Float = 0 // depends on landscaperight etc., figure that out, there should be something for this really.
        let r: Float = Float(viewportSize.width)
        let t: Float = 0
        let b: Float = Float(viewportSize.height)
        
        let col0 = SIMD4<Float>((r-l)/2.0,    0,          0,      0)
        let col1 = SIMD4<Float>(0,            (t-b)/2.0,  0,      0)
        let col2 = SIMD4<Float>(0,            0,          0.5,    0)
        let col3 = SIMD4<Float>((r+l)/2.0,    (t+b)/2,    0.5,    1)
        
        return float4x4(col0, col1, col2, col3)
    }

    func screenCoordinatesToNormalCoordinates(screenCoordinates: CGPoint) -> vector_float2 {
/*
        let x : Float = 1  * ( 2 * Float(screenCoordinates.x) / Float(view.frame.size.width) - 1) // 0.001 is that scaling factor
        let y : Float = -1 * ( 2 * Float(screenCoordinates.y) / Float(view.frame.size.height) - 1) // for whatever reason this is upside down. I think because top left = 0,0 / top bottom = 1 1 in "texture space".

        return vector_float2(0.75 * x, y) // need to figure out why this is, seems like aspect ratio, how do we find out???? */
        
        let centered_x : Float = Float(screenCoordinates.x) - 0.5 * Float(view.frame.size.width)
        let centered_y : Float = Float(screenCoordinates.y) - 0.5 * Float(view.frame.size.height)
        let scaling_x : Float = 2.0 / Float(view.frame.size.width)
        let scaling_y : Float = -2.0 / Float(view.frame.size.height)
        let x: Float = centered_x * scaling_x
        let y: Float = centered_y * scaling_y
        
        return vector_float2(x, y)
    }
    
    func screenCoordinatesToWorldCoordinates(screenCoordinates: CGPoint) -> vector_float4 {
        let forward_transform = projectionMatrix() * (arEnabled ? cameraMatrix() : matrix_identity_float4x4)                  // transformation (<- direction) device3D  <- world
        let inverse_transform = (arEnabled ? cameraMatrix().inverse : matrix_identity_float4x4) * projectionMatrix().inverse     // transformation (<- direction) world     <- device3D
        
        var device_origin_as_viewed_from_camera : vector_float4 = (arEnabled ? cameraMatrix() : matrix_identity_float4x4).columns.3 // how the camera sees it.
        //device_origin_as_viewed_from_camera.x = device_origin_as_viewed_from_camera.x + 1
        let device_origin_world = (arEnabled ? cameraMatrix() : matrix_identity_float4x4) * device_origin_as_viewed_from_camera // world coordinates, as the device sees it.
        let device_origin = projectionMatrix() * device_origin_world

        
        let pointCoordinates = screenCoordinatesToNormalCoordinates(screenCoordinates:screenCoordinates)
        let point = vector_float4(pointCoordinates.x, pointCoordinates.y, device_origin.z, device_origin.w)
        let point_world = projectionMatrix().inverse * point
        let point_world_as_viewed_from_camera = (arEnabled ? cameraMatrix() : matrix_identity_float4x4).inverse * point_world
        
       /* print("point", point)
        print("point world", point_world)
        print("point from camera", point_world_as_viewed_from_camera)
*/
        return point_world_as_viewed_from_camera
        
        /*
         
        
        // this is the world coordinates as "AR" sees them, leave out all the stuff for our trackingmatrix, needs to be handled last step.
        // https://jsantell.com/3d-projection/ to learn about projections.
        // there should be a more straightforward way, but I think this makes sense to me.

        let forward_transform = projectionMatrix() * (arEnabled ? cameraMatrix() : matrix_identity_float4x4)                  // transformation (<- direction) device3D  <- world
        let inverse_transform = (arEnabled ? cameraMatrix().inverse : matrix_identity_float4x4) * projectionMatrix().inverse     // transformation (<- direction) world     <- device3D
                                                                                        // transformation (<- direction) device2D  <- device3D = drop z & w
                                                                                        // transformation (<- direction) device3D  <- device2D is the hard bit, requires knowledge of the device (end of the day 2D) and it's orientation & how it scales to the real world. For the middle of device & world, it's easy.

        
        // where the device is right now.
        let deviceMiddle_world = (arEnabled ? cameraMatrix() : matrix_identity_float4x4).columns.3 // column 3 = position of the camera (or could multiply by (0,0,0,1)
        let deviceMiddle_device3D = cameraMatrix() * deviceMiddle_world
        // where we are on the tablet
        let deviceCoordinates = screenCoordinatesToNormalCoordinates(screenCoordinates:screenCoordinates)
        let deviceCoordinates_device3D = vector_float4(deviceCoordinates.x, deviceCoordinates.y, 0, 0) // This is 2D I know, but need to find away to deal with orientation!!
 //working more or less
    ***    let point = inverse_transform * deviceMiddle_device3D + extractOrientationMatrix(fullmatrix: (arEnabled ? cameraMatrix().inverse : matrix_identity_float4x4)) * inverse_transform * deviceCoordinates_device3D; //  first part is to make sure we do everything compared to where the device, is second is the screen, but need to make sure we correct for the plane of the device (e.g. just the rotation of the camera.
    
           for (0,0,0) first, e.g. basically it's uncollapsed in a sense already.
           have our "device coordinates"s. (x/y plane), but missing y and w, only way to get that is ",
         add our camera position (middle), but then it's in the wrong plane, so really best way to tackle is, invert translate & rotate to our camera coordinates (without projection),
         then translate & rotate back, however then would want this to be "collapsed & projected", so we have proper coordinates & then do all of the inverse transform. The last steps are cancelling out, so technically should be equivalent to just taking the 2D thing, and do the inverse of the camera.
         
         translationMatrix(translation: vector_float3(0,0,-0.05)) *
         ***
        
        let point = (arEnabled ? cameraMatrix().inverse : matrix_identity_float4x4)
            * (deviceMiddle_device3D + 0.01*deviceCoordinates_device3D + vector_float4(0,0,-0.10,0)) // - deviceCoordinates_device3D +
        
        print(deviceMiddle_device3D, deviceCoordinates_device3D, point)
        print(point)
            
        
        
        return point
        */
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
     //   fingerCoordinates = screenCoordinatesToNormalCoordinates(screenCoordinates: fingerScreenCoordinates)
        
        // pass camera position through to simulation, need to be smarter about this.
        if let currentFrame = session.currentFrame {
            _simulation.camera = arEnabled ? currentFrame.camera.transform  : matrix_identity_float4x4 // ad this may break stuff.
        }
               
        if _simulation != nil {
            
            renderer.draw(positionsBuffer1: _simulation.getStablePositionBuffer1(), positionsBuffer2: _simulation.getStablePositionBuffer2(), interpolation: _simulation.getInterpolation(), numBodies: Int(_config.numBodies), inView: _view, finger: fingerWorldCoordinates)
        }
        
        if commandQueue != nil {
            let commandBuffer = commandQueue.makeCommandBuffer()!
            
            commandBuffer.pushDebugGroup("Controller Frame")
            
            _simulation.simulateFrameWithCommandBuffer(commandBuffer: commandBuffer, finger: fingerWorldCoordinates)
            
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
