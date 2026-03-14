//
//  MultiCameraPreview.m
//  camerawesome
//
//  Created by Dimitri Dessus on 28/03/2023.
//

#import "MultiCameraPreview.h"

@implementation MultiCameraPreview

- (instancetype)initWithSensors:(NSArray<PigeonSensor *> *)sensors
              mirrorFrontCamera:(BOOL)mirrorFrontCamera
           enablePhysicalButton:(BOOL)enablePhysicalButton
                aspectRatioMode:(AspectRatio)aspectRatioMode
                    captureMode:(CaptureModes)captureMode
                  dispatchQueue:(dispatch_queue_t)dispatchQueue {
  if (self = [super init]) {
    _dispatchQueue = dispatchQueue;
    
    _textures = [NSMutableArray new];
    _devices = [NSMutableArray new];
    
    _aspectRatio = aspectRatioMode;
    _mirrorFrontCamera = mirrorFrontCamera;
    
    _motionController = [[MotionController alloc] init];
    _locationController = [[LocationController alloc] init];
    _physicalButtonController = [[PhysicalButtonController alloc] init];
    
    if (enablePhysicalButton) {
      [_physicalButtonController startListening];
    }
    
    [_motionController startMotionDetection];
    
    [self configInitialSession:sensors];
  }
  
  return self;
}

/// Set orientation stream Flutter sink
- (void)setOrientationEventSink:(FlutterEventSink)orientationEventSink {
  if (_motionController != nil) {
    [_motionController setOrientationEventSink:orientationEventSink];
  }
}

/// Set physical button Flutter sink
- (void)setPhysicalButtonEventSink:(FlutterEventSink)physicalButtonEventSink {
  if (_physicalButtonController != nil) {
    [_physicalButtonController setPhysicalButtonEventSink:physicalButtonEventSink];
  }
}

- (void)dispose {
  [self stop];
  [self cleanSession];
}

- (void)stop {
  [self.cameraSession stopRunning];
}

- (void)cleanSession {
  [self.cameraSession beginConfiguration];
  
  for (CameraDeviceInfo *camera in self.devices) {
    [self.cameraSession removeConnection:camera.captureConnection];
    [self.cameraSession removeInput:camera.deviceInput];
    [self.cameraSession removeOutput:camera.videoDataOutput];
  }
  
  [self.devices removeAllObjects];
}

// Get max zoom level
- (CGFloat)getMaxZoom {
  CGFloat maxZoom = self.devices.firstObject.device.activeFormat.videoMaxZoomFactor;
  // Not sure why on iPhone 14 Pro, zoom at 90 not working, so let's block to 50 which is very high
  return maxZoom > 50.0 ? 50.0 : maxZoom;
}

/// Set zoom level
- (void)setZoom:(float)value error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  AVCaptureDevice *mainDevice = self.devices.firstObject.device;
  
  CGFloat maxZoom = [self getMaxZoom];
  CGFloat scaledZoom = value * (maxZoom - 1.0f) + 1.0f;
  
  NSError *zoomError;
  if ([mainDevice lockForConfiguration:&zoomError]) {
    mainDevice.videoZoomFactor = scaledZoom;
    [mainDevice unlockForConfiguration];
  } else {
    *error = [FlutterError errorWithCode:@"ZOOM_NOT_SET" message:@"can't set the zoom value" details:[zoomError localizedDescription]];
  }
}

- (void)focusOnPoint:(CGPoint)position preview:(CGSize)preview error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  AVCaptureDevice *mainDevice = self.devices.firstObject.device;
  NSError *lockError;
  if ([mainDevice isFocusModeSupported:AVCaptureFocusModeAutoFocus] && [mainDevice isFocusPointOfInterestSupported]) {
    if ([mainDevice lockForConfiguration:&lockError]) {
      if (lockError != nil) {
        *error = [FlutterError errorWithCode:@"FOCUS_ERROR" message:@"impossible to set focus point" details:@""];
        return;
      }
      
      [mainDevice setFocusPointOfInterest:position];
      [mainDevice setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
      
      [mainDevice unlockForConfiguration];
    }
  }
}

- (void)setExifPreferencesGPSLocation:(bool)gpsLocation completion:(void(^)(NSNumber *_Nullable, FlutterError *_Nullable))completion {
  _saveGPSLocation = gpsLocation;
  
  if (_saveGPSLocation) {
    [_locationController requestWhenInUseAuthorizationOnGranted:^{
      completion(@(YES), nil);
    } declined:^{
      completion(@(NO), nil);
    }];
  } else {
    completion(@(YES), nil);
  }
}

- (void)setMirrorFrontCamera:(bool)value error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  _mirrorFrontCamera = value;
}

- (void)setBrightness:(NSNumber *)brightness error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  AVCaptureDevice *mainDevice = self.devices.firstObject.device;
  NSError *brightnessError = nil;
  if ([mainDevice lockForConfiguration:&brightnessError]) {
    AVCaptureExposureMode exposureMode = AVCaptureExposureModeContinuousAutoExposure;
    if ([mainDevice isExposureModeSupported:exposureMode]) {
      [mainDevice setExposureMode:exposureMode];
    }
    
    CGFloat minExposureTargetBias = mainDevice.minExposureTargetBias;
    CGFloat maxExposureTargetBias = mainDevice.maxExposureTargetBias;
    
    CGFloat exposureTargetBias = minExposureTargetBias + (maxExposureTargetBias - minExposureTargetBias) * [brightness floatValue];
    exposureTargetBias = MAX(minExposureTargetBias, MIN(maxExposureTargetBias, exposureTargetBias));
    
    [mainDevice setExposureTargetBias:exposureTargetBias completionHandler:nil];
    [mainDevice unlockForConfiguration];
  } else {
    *error = [FlutterError errorWithCode:@"BRIGHTNESS_NOT_SET" message:@"can't set the brightness value" details:[brightnessError localizedDescription]];
  }
}

/// Set flash mode
- (void)setFlashMode:(CameraFlashMode)flashMode error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  AVCaptureDevice *mainDevice = self.devices.firstObject.device;
  
  if (![mainDevice hasFlash]) {
    *error = [FlutterError errorWithCode:@"FLASH_UNSUPPORTED" message:@"flash is not supported on this device" details:@""];
    return;
  }
  
  if (mainDevice.position == AVCaptureDevicePositionFront) {
    *error = [FlutterError errorWithCode:@"FLASH_UNSUPPORTED" message:@"can't set flash for portrait mode" details:@""];
    return;
  }
  
  NSError *lockError;
  [self.devices.firstObject.device lockForConfiguration:&lockError];
  if (lockError != nil) {
    *error = [FlutterError errorWithCode:@"FLASH_ERROR" message:@"impossible to change configuration" details:@""];
    return;
  }
  
  switch (flashMode) {
    case None:
      _torchMode = AVCaptureTorchModeOff;
      _flashMode = AVCaptureFlashModeOff;
      break;
    case On:
      _torchMode = AVCaptureTorchModeOff;
      _flashMode = AVCaptureFlashModeOn;
      break;
    case Auto:
      _torchMode = AVCaptureTorchModeAuto;
      _flashMode = AVCaptureFlashModeAuto;
      break;
    case Always:
      _torchMode = AVCaptureTorchModeOn;
      _flashMode = AVCaptureFlashModeOn;
      break;
    default:
      _torchMode = AVCaptureTorchModeAuto;
      _flashMode = AVCaptureFlashModeAuto;
      break;
  }
  
  [mainDevice setTorchMode:_torchMode];
  [mainDevice unlockForConfiguration];
}

- (void)refresh {
  if ([self.cameraSession isRunning]) {
    [self.cameraSession stopRunning];
  }
  dispatch_async(_dispatchQueue, ^{
    [self.cameraSession startRunning];
  });
}

- (void)configInitialSession:(NSArray<PigeonSensor *> *)sensors {  
  self.cameraSession = [[AVCaptureMultiCamSession alloc] init];
  
  for (int i = 0; i < [sensors count]; i++) {
    CameraPreviewTexture *previewTexture = [[CameraPreviewTexture alloc] init];
    [self.textures addObject:previewTexture];
  }
  
  [self setSensors:sensors];
  
  [self.cameraSession commitConfiguration];
}

- (void)setSensors:(NSArray<PigeonSensor *> *)sensors {
  [self cleanSession];
  
  _sensors = sensors;
  
  for (int i = 0; i < [sensors count]; i++) {
    PigeonSensor *sensor = sensors[i];
    [self addSensor:sensor withIndex:i];
  }
  
  [self.cameraSession commitConfiguration];
}

- (void)start {
  dispatch_async(_dispatchQueue, ^{
    [self.cameraSession startRunning];
  });
}

- (CGSize)getEffectivPreviewSize {
  // TODO
  return CGSizeMake(1920, 1080);
}

- (BOOL)addSensor:(PigeonSensor *)sensor withIndex:(int)index {
  AVCaptureDevice *device = [self selectAvailableCamera:sensor];;
  
  if (device == nil) {
    return NO;
  }
  
  NSError *error = nil;
  AVCaptureDeviceInput *deviceInput = [[AVCaptureDeviceInput alloc] initWithDevice:device error:&error];
  if (![self.cameraSession canAddInput:deviceInput]) {
    return NO;
  }
  [self.cameraSession addInputWithNoConnections:deviceInput];
  
  AVCaptureVideoDataOutput *videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
  videoDataOutput.videoSettings = @{(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};
  [videoDataOutput setSampleBufferDelegate:self queue:self.dispatchQueue];
  
  if (![self.cameraSession canAddOutput:videoDataOutput]) {
    return NO;
  }
  [self.cameraSession addOutputWithNoConnections:videoDataOutput];
  
  AVCaptureInputPort *port = [[deviceInput portsWithMediaType:AVMediaTypeVideo
                                             sourceDeviceType:device.deviceType
                                         sourceDevicePosition:device.position] firstObject];
  AVCaptureConnection *captureConnection = [[AVCaptureConnection alloc] initWithInputPorts:@[port] output:videoDataOutput];
  
  if (![self.cameraSession canAddConnection:captureConnection]) {
    return NO;
  }
  [self.cameraSession addConnection:captureConnection];
  
  [captureConnection setVideoOrientation:AVCaptureVideoOrientationPortrait];
  [captureConnection setAutomaticallyAdjustsVideoMirroring:NO];
  [captureConnection setVideoMirrored:sensor.position == PigeonSensorPositionFront];
  
  // Creating photo output
  AVCapturePhotoOutput *capturePhotoOutput = [AVCapturePhotoOutput new];
  [capturePhotoOutput setHighResolutionCaptureEnabled:YES];
  [self.cameraSession addOutput:capturePhotoOutput];
  
  // move this all this in the cameradevice object
  CameraDeviceInfo *cameraDevice = [[CameraDeviceInfo alloc] init];
  cameraDevice.captureConnection = captureConnection;
  cameraDevice.deviceInput = deviceInput;
  cameraDevice.videoDataOutput = videoDataOutput;
  cameraDevice.device = device;
  cameraDevice.capturePhotoOutput = capturePhotoOutput;
  
  [_devices addObject:cameraDevice];
  
  return YES;
}

/// Get the first available camera on device (front or rear)
- (AVCaptureDevice *)selectAvailableCamera:(PigeonSensor *)sensor {
  if (sensor.deviceId != nil) {
    return [AVCaptureDevice deviceWithUniqueID:sensor.deviceId];
  }
  
  // TODO: add dual & triple camera
  NSArray<AVCaptureDevice *> *devices = [[NSArray alloc] init];
  AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeBuiltInTelephotoCamera, AVCaptureDeviceTypeBuiltInUltraWideCamera, ]
                                                                                                             mediaType:AVMediaTypeVideo
                                                                                                              position:AVCaptureDevicePositionUnspecified];
  devices = discoverySession.devices;
  
  for (AVCaptureDevice *device in devices) {
    if (sensor.type != PigeonSensorTypeUnknown) {
      AVCaptureDeviceType deviceType = [SensorUtils deviceTypeFromSensorType:sensor.type];
      if ([device deviceType] == deviceType) {
        return [AVCaptureDevice deviceWithUniqueID:[device uniqueID]];
      }
    } else if (sensor.position != PigeonSensorPositionUnknown) {
      NSInteger cameraType = (sensor.position == PigeonSensorPositionFront) ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
      if ([device position] == cameraType) {
        return [AVCaptureDevice deviceWithUniqueID:[device uniqueID]];
      }
    }
  }
  return nil;
}

- (void)setAspectRatio:(AspectRatio)ratio {
  _aspectRatio = ratio;
}

- (void)setPreviewSize:(CGSize)previewSize error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  // TODO:
}

- (void)takePhotoSensors:(nonnull NSArray<PigeonSensor *> *)sensors paths:(nonnull NSArray<NSString *> *)paths completion:(nonnull void (^)(NSNumber * _Nullable, FlutterError * _Nullable))completion {
  for (int i = 0; i < [sensors count]; i++) {
    PigeonSensor *sensor = [sensors objectAtIndex:i];
    NSString *path = [paths objectAtIndex:i];
    
    // TODO: take pictures for each sensors
    CameraPictureController *cameraPicture = [[CameraPictureController alloc] initWithPath:path
                                                                               orientation:_motionController.deviceOrientation
                                                                            sensorPosition:sensor.position
                                                                           saveGPSLocation:_saveGPSLocation
                                                                         mirrorFrontCamera:_mirrorFrontCamera
                                                                               aspectRatio:_aspectRatio
                                                                                completion:completion
                                                                                  callback:^{
      // If flash mode is always on, restore it back after photo is taken
      if (self->_torchMode == AVCaptureTorchModeOn) {
        [self->_devices.firstObject.device lockForConfiguration:nil];
        [self->_devices.firstObject.device setTorchMode:AVCaptureTorchModeOn];
        [self->_devices.firstObject.device unlockForConfiguration];
      }
      
      completion(@(YES), nil);
    }];
    
    // Create settings instance
    AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
    [settings setHighResolutionPhotoEnabled:YES];
    [self.devices[i].capturePhotoOutput setPhotoSettingsForSceneMonitoring:settings];
    
    [self.devices[i].capturePhotoOutput capturePhotoWithSettings:settings
                                                        delegate:cameraPicture];
  }
}

#pragma mark - Manual Exposure Control

- (void)setManualExposureMode:(BOOL)manual error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  AVCaptureDevice *mainDevice = self.devices.firstObject.device;
  if (mainDevice == nil) {
    *error = [FlutterError errorWithCode:@"NO_CAMERA" message:@"Camera not initialized" details:nil];
    return;
  }
  NSError *lockError;
  if ([mainDevice lockForConfiguration:&lockError]) {
    if (manual) {
      if ([mainDevice isExposureModeSupported:AVCaptureExposureModeCustom]) {
        [mainDevice setExposureMode:AVCaptureExposureModeCustom];
      } else {
        [mainDevice unlockForConfiguration];
        *error = [FlutterError errorWithCode:@"EXPOSURE_UNSUPPORTED" message:@"Custom exposure mode not supported" details:nil];
        return;
      }
    } else {
      if ([mainDevice isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
        [mainDevice setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
      }
    }
    [mainDevice unlockForConfiguration];
  } else {
    *error = [FlutterError errorWithCode:@"LOCK_ERROR" message:@"Cannot lock device" details:[lockError localizedDescription]];
  }
}

- (void)setIso:(double)iso error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  AVCaptureDevice *mainDevice = self.devices.firstObject.device;
  NSError *lockError;
  if ([mainDevice lockForConfiguration:&lockError]) {
    float clampedIso = MAX(mainDevice.activeFormat.minISO,
                           MIN(mainDevice.activeFormat.maxISO, (float)iso));
    [mainDevice setExposureModeCustomWithDuration:AVCaptureExposureDurationCurrent
                                              ISO:clampedIso
                                completionHandler:nil];
    [mainDevice unlockForConfiguration];
  } else {
    *error = [FlutterError errorWithCode:@"LOCK_ERROR" message:@"Cannot lock device" details:[lockError localizedDescription]];
  }
}

- (void)setExposureDuration:(int64_t)durationNs error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  AVCaptureDevice *mainDevice = self.devices.firstObject.device;
  NSError *lockError;
  if ([mainDevice lockForConfiguration:&lockError]) {
    CMTime duration = CMTimeMake(durationNs, 1000000000);
    CMTime minDuration = mainDevice.activeFormat.minExposureDuration;
    CMTime maxDuration = mainDevice.activeFormat.maxExposureDuration;
    if (CMTimeCompare(duration, minDuration) < 0) duration = minDuration;
    if (CMTimeCompare(duration, maxDuration) > 0) duration = maxDuration;
    [mainDevice setExposureModeCustomWithDuration:duration
                                              ISO:AVCaptureISOCurrent
                                completionHandler:nil];
    [mainDevice unlockForConfiguration];
  } else {
    *error = [FlutterError errorWithCode:@"LOCK_ERROR" message:@"Cannot lock device" details:[lockError localizedDescription]];
  }
}

- (void)setManualExposureIso:(double)iso durationNs:(int64_t)durationNs error:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  AVCaptureDevice *mainDevice = self.devices.firstObject.device;
  NSError *lockError;
  if ([mainDevice lockForConfiguration:&lockError]) {
    if (![mainDevice isExposureModeSupported:AVCaptureExposureModeCustom]) {
      [mainDevice unlockForConfiguration];
      *error = [FlutterError errorWithCode:@"EXPOSURE_UNSUPPORTED" message:@"Custom exposure mode not supported" details:nil];
      return;
    }
    float clampedIso = MAX(mainDevice.activeFormat.minISO,
                           MIN(mainDevice.activeFormat.maxISO, (float)iso));
    CMTime duration = CMTimeMake(durationNs, 1000000000);
    CMTime minDuration = mainDevice.activeFormat.minExposureDuration;
    CMTime maxDuration = mainDevice.activeFormat.maxExposureDuration;
    if (CMTimeCompare(duration, minDuration) < 0) duration = minDuration;
    if (CMTimeCompare(duration, maxDuration) > 0) duration = maxDuration;
    [mainDevice setExposureMode:AVCaptureExposureModeCustom];
    [mainDevice setExposureModeCustomWithDuration:duration
                                              ISO:clampedIso
                                completionHandler:nil];
    [mainDevice unlockForConfiguration];
  } else {
    *error = [FlutterError errorWithCode:@"LOCK_ERROR" message:@"Cannot lock device" details:[lockError localizedDescription]];
  }
}

- (NSDictionary *)getExposureRangeWithError:(FlutterError * _Nullable __autoreleasing * _Nonnull)error {
  AVCaptureDevice *mainDevice = self.devices.firstObject.device;
  if (mainDevice == nil) {
    *error = [FlutterError errorWithCode:@"NO_CAMERA" message:@"Camera not initialized" details:nil];
    return nil;
  }
  CMTime minDuration = mainDevice.activeFormat.minExposureDuration;
  CMTime maxDuration = mainDevice.activeFormat.maxExposureDuration;
  int64_t minDurationNs = (int64_t)(CMTimeGetSeconds(minDuration) * 1000000000.0);
  int64_t maxDurationNs = (int64_t)(CMTimeGetSeconds(maxDuration) * 1000000000.0);
  return @{
    @"minIso": @((double)mainDevice.activeFormat.minISO),
    @"maxIso": @((double)mainDevice.activeFormat.maxISO),
    @"minExposureDurationNs": @(minDurationNs),
    @"maxExposureDurationNs": @(maxDurationNs),
    @"currentIso": @((double)mainDevice.ISO),
    @"currentExposureDurationNs": @((int64_t)(CMTimeGetSeconds(mainDevice.exposureDuration) * 1000000000.0)),
  };
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
  int index = 0;
  for (CameraDeviceInfo *device in _devices) {
    if (device.videoDataOutput == output) {
      [_textures[index] updateBuffer:sampleBuffer];
      if (_onPreviewFrameAvailable) {
        _onPreviewFrameAvailable(@(index));
      }
    }
    
    index++;
  }
}

@end
