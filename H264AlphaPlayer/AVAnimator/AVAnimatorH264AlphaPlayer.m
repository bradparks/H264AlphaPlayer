//
//  AVAnimatorH264AlphaPlayer.m
//
//  Created by Moses DeJong on 2/27/16.
//
//  License terms defined in License.txt.

#import "AVAnimatorH264AlphaPlayer.h"

#if defined(HAS_AVASSET_READ_COREVIDEO_BUFFER_AS_TEXTURE)

#import <QuartzCore/QuartzCore.h>

#include <OpenGLES/ES2/gl.h>
#include <OpenGLES/ES2/glext.h>

#import "CGFrameBuffer.h"

#import "AVFrameDecoder.h"

#import "AVAnimatorMedia.h"

#import "AVFrame.h"

#import "AVFileUtil.h"

#import <mach/mach.h>

#if __has_feature(objc_arc)
#else
#import "AutoPropertyRelease.h"
#endif // objc_arc

// private properties declaration for AVAnimatorOpenGLView class
//#include "AVAnimatorH264AlphaPlayerPrivate.h"

// private method in Media class
#include "AVAnimatorMediaPrivate.h"

#import <QuartzCore/CAEAGLLayer.h>

// Trivial vertex and fragment shaders

static
const GLchar *vertShaderCstr =
"attribute vec4 position; attribute mediump vec4 textureCoordinate;"
"varying mediump vec2 coordinate;"
"void main()"
"{"
"	gl_Position = position;"
"	coordinate = textureCoordinate.xy;"
"}";

static
const GLchar *fragShaderCstr =
"varying highp vec2 coordinate;"
"uniform sampler2D videoframe;"
"void main()"
"{"
"	gl_FragColor = texture2D(videoframe, coordinate);"
"}";

enum {
  ATTRIB_VERTEX,
  ATTRIB_TEXTUREPOSITON,
  NUM_ATTRIBUTES
};

// class declaration for AVAnimatorOpenGLView

@interface AVAnimatorH264AlphaPlayer () {
@private
	CGSize m_renderSize;
  
	int renderBufferWidth;
	int renderBufferHeight;
  
  GLuint passThroughProgram;
  
  // A texture cache ref is an opaque type that contains a specific
  // textured cache.
  CVOpenGLESTextureCacheRef textureCacheRef;
  
  BOOL didSetupOpenGLMembers;
}

@property (nonatomic, assign) CGSize renderSize;

@property (nonatomic, assign) int currentFrame;

@property (nonatomic, retain) AVFrame *rgbFrame;
@property (nonatomic, retain) AVFrame *alphaFrame;

@property (nonatomic, retain) NSTimer *animatorPrepTimer;

@end

// class AVAnimatorH264AlphaPlayer

@implementation AVAnimatorH264AlphaPlayer

// public properties

@synthesize renderSize = m_renderSize;
@synthesize rgbFrame = m_rgbFrame;
@synthesize alphaFrame = m_alphaFrame;
@synthesize assetFilename = m_assetFilename;
@synthesize frameDecoder = m_frameDecoder;
@synthesize animatorPrepTimer = m_animatorPrepTimer;
@synthesize currentFrame = m_currentFrame;

- (void) dealloc {
	// Explicitly release image inside the imageView, the
	// goal here is to get the imageView to drop the
	// ref to the CoreGraphics image and avoid a memory
	// leak. This should not be needed, but it is.
  
	self.rgbFrame = nil;
	self.alphaFrame = nil;
  self.frameDecoder = nil;
  
  if (self.animatorPrepTimer != nil) {
    [self.animatorPrepTimer invalidate];
  }
  
  // Dealloc OpenGL stuff
	
  if (passThroughProgram) {
    glDeleteProgram(passThroughProgram);
    passThroughProgram = 0;
  }
	
  if (textureCacheRef) {
    CFRelease(textureCacheRef);
    textureCacheRef = 0;
  }
  
#if __has_feature(objc_arc)
#else
  [AutoPropertyRelease releaseProperties:self thisClass:AVAnimatorH264AlphaPlayer.class];
  [super dealloc];
#endif // objc_arc
}

// static ctor

+ (AVAnimatorH264AlphaPlayer*) aVAnimatorH264AlphaPlayer
{
  UIScreen *screen = [UIScreen mainScreen];
#if defined(TARGET_OS_TV)
  CGRect rect = screen.bounds;
#else
  CGRect rect = screen.applicationFrame;
#endif // TARGET_OS_TV
  return [AVAnimatorH264AlphaPlayer aVAnimatorH264AlphaPlayerWithFrame:rect];
}

+ (AVAnimatorH264AlphaPlayer*) aVAnimatorH264AlphaPlayerWithFrame:(CGRect)viewFrame
{
  AVAnimatorH264AlphaPlayer *obj = [[AVAnimatorH264AlphaPlayer alloc] initWithFrame:viewFrame];
#if __has_feature(objc_arc)
  return obj;
#else
  return [obj autorelease];
#endif // objc_arc
}

// Get EAGLContext with static method since the self reference is not setup yet

+ (EAGLContext*) genericInitEAGLContext1
{
  EAGLContext *context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
  
#if __has_feature(objc_arc)
#else
  context = [context autorelease];
#endif // objc_arc
  
  if (!context || ![EAGLContext setCurrentContext:context]) {
    NSLog(@"Problem with init of OpenGL ES2 context.");
    
    return nil;
  }
  
  return context;
}

// This init method is invoked after the self reference is valid.

- (void) genericInitEAGLContext2:(EAGLContext*)context
{
  // Defaults for opacity related properties. We expect the view to be
  // fully opaque since the image renders all the pixels in the view.
  // Unless in 32bpp mode, in that case pixels can be partially transparent.
  
  // Set GLKView.context
  self.context = context;

  // FIXME: The opaque flag should be set to FALSE
  self.opaque = TRUE;
  self.clearsContextBeforeDrawing = FALSE;
  self.backgroundColor = nil;
  
  // Use 2x scale factor on Retina displays.
  self.contentScaleFactor = [[UIScreen mainScreen] scale];
  
  self.enableSetNeedsDisplay = YES;
  
  self->passThroughProgram = 0;
  self->textureCacheRef = NULL;
  
  self->didSetupOpenGLMembers = FALSE;
  
  return;
}

- (id) initWithFrame:(CGRect)frame
{
  EAGLContext *context = [self.class genericInitEAGLContext1];
  
  if (context == nil) {
    return nil;
  }
  
  if ((self = [super initWithFrame:frame])) {
    [self genericInitEAGLContext2:context];
  }
  
  return self;
}

- (void) awakeFromNib
{
  [super awakeFromNib];
  
  EAGLContext *context = [self.class genericInitEAGLContext1];
  
  if (context) {
    [self genericInitEAGLContext2:context];
  }
}

// Setup OpenGL objects and ids that need to be created only once, the first time
// the view is being rendered. Any OpenGL state that only needs to be set once
// for this context can be set here as long as it will not change from one render
// to the next.

- (BOOL) setupOpenGLMembers
{
//	BOOL success = YES;
//	
//	glDisable(GL_DEPTH_TEST);
 
  BOOL worked;
  
  //  Create a new CVOpenGLESTexture cache
  CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, self.context, NULL, &self->textureCacheRef);
  if (err) {
    NSLog(@"Error at CVOpenGLESTextureCacheCreate %d", err);
    worked = FALSE;
  } else {
    worked = TRUE;
  }
  
  if (worked) {
    worked = [self compileShaders];
  }
  return worked;
}


- (void)renderWithSquareVertices:(const GLfloat*)squareVertices textureVertices:(const GLfloat*)textureVertices
{
  // Use shader program.
  glUseProgram(passThroughProgram);
  
  // Update attribute values.
	glVertexAttribPointer(ATTRIB_VERTEX, 2, GL_FLOAT, 0, 0, squareVertices);
	glEnableVertexAttribArray(ATTRIB_VERTEX);
	glVertexAttribPointer(ATTRIB_TEXTUREPOSITON, 2, GL_FLOAT, 0, 0, textureVertices);
	glEnableVertexAttribArray(ATTRIB_TEXTUREPOSITON);
  
  // Update uniform values if there are any
  
  // Validate program before drawing. This is a good check, but only really necessary in a debug build.
  // DEBUG macro must be defined in your debug configurations if that's not already the case.
#if defined(DEBUG)
  [self validateProgram:passThroughProgram];
#endif
	
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

- (CGRect)textureSamplingRectForCroppingTextureWithAspectRatio:(CGSize)textureAspectRatio toAspectRatio:(CGSize)croppingAspectRatio
{
	CGRect normalizedSamplingRect = CGRectZero;
	CGSize cropScaleAmount = CGSizeMake(croppingAspectRatio.width / textureAspectRatio.width, croppingAspectRatio.height / textureAspectRatio.height);
	CGFloat maxScale = fmax(cropScaleAmount.width, cropScaleAmount.height);
	CGSize scaledTextureSize = CGSizeMake(textureAspectRatio.width * maxScale, textureAspectRatio.height * maxScale);
	
	if ( cropScaleAmount.height > cropScaleAmount.width ) {
		normalizedSamplingRect.size.width = croppingAspectRatio.width / scaledTextureSize.width;
		normalizedSamplingRect.size.height = 1.0;
	}
	else {
		normalizedSamplingRect.size.height = croppingAspectRatio.height / scaledTextureSize.height;
		normalizedSamplingRect.size.width = 1.0;
	}
	// Center crop
	normalizedSamplingRect.origin.x = (1.0 - normalizedSamplingRect.size.width)/2.0;
	normalizedSamplingRect.origin.y = (1.0 - normalizedSamplingRect.size.height)/2.0;
	
	return normalizedSamplingRect;
}

// Given an AVFrame object, map the pixels into a texture ref

- (void) displayFrame
{
  AVFrame *rgbFrame = self.rgbFrame;
  NSAssert(rgbFrame.isDuplicate == FALSE, @"a duplicate frame should not cause a display update");
  
  AVFrame *alphaFrame = self.alphaFrame;
  NSAssert(alphaFrame.isDuplicate == FALSE, @"a duplicate frame should not cause a display update");
  
  //NSLog(@"displayFrame %@", frame);
  
  CVImageBufferRef cvImageBufferRef = NULL;

	size_t frameWidth;
	size_t frameHeight;
  
  size_t bytesPerRow;
  
  // This OpenGL player view is only useful when decoding CoreVideo frames, it is possible
  // that a misconfiguration could result in a normal AVFrame that contains a UIImage
  // getting passed to an OpenGL view. Simply assert here in that case instead of attempting
  // to support the non-optimal case since that would just cover up a configuration error
  // anyway.
  
  if (rgbFrame.cvBufferRef == NULL) {
    NSAssert(FALSE, @"AVFrame delivered to AVAnimatorOpenGLView does not contain a CoreVideo pixel buffer");
  }
  if (alphaFrame.cvBufferRef == NULL) {
    NSAssert(FALSE, @"AVFrame delivered to AVAnimatorOpenGLView does not contain a CoreVideo pixel buffer");
  }

  cvImageBufferRef = rgbFrame.cvBufferRef;
  
  frameWidth = CVPixelBufferGetWidth(cvImageBufferRef);
  frameHeight = CVPixelBufferGetHeight(cvImageBufferRef);
  bytesPerRow = CVPixelBufferGetBytesPerRow(cvImageBufferRef);
  
  if (self->textureCacheRef == NULL) {
    // This should not actually happen, but no specific way to deal with an error here
    return;
  }
	
  // Allocate a "texture ref" object that wraps around the existing memory allocated and written
  // by CoreVideo. As far as OpenGL is concerned, this is a new texture, but the memory that
  // backs the texture has already been fully written to at this point. The OpenGL id for the
  // texture changes from one frame to the next and CoreVideo keeps track of the specific
  // buffer used when the frame was decoded.

  CVOpenGLESTextureRef textureRef = NULL;
  
  CVReturn err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                              self->textureCacheRef,
                                                              cvImageBufferRef,
                                                              (CFDictionaryRef) NULL,
                                                              GL_TEXTURE_2D, // not GL_RENDERBUFFER
                                                              GL_RGBA,
                                                              (GLsizei)frameWidth,
                                                              (GLsizei)frameHeight,
                                                              GL_BGRA,
                                                              GL_UNSIGNED_BYTE,
                                                              0,
                                                              &textureRef);

  if (textureRef == NULL) {
    NSLog(@"CVOpenGLESTextureCacheCreateTextureFromImage failed and returned NULL (error: %d)", err);
    return;
  }
  
  if (err) {
    if (textureRef) {
      CFRelease(textureRef);
    }
    NSLog(@"CVOpenGLESTextureCacheCreateTextureFromImage failed (error: %d)", err);
    return;
  }
  
  // Bind texture, OpenGL already knows about the texture but it could have been created
  // in another thread and it has to be bound in this context in order to sync the
  // texture for use with this OpenGL context. The next logging line can be uncommented
  // to see the actual texture id used internally by OpenGL.
  
  //NSLog(@"bind OpenGL texture %d", CVOpenGLESTextureGetName(textureRef));
  
  glBindTexture(CVOpenGLESTextureGetTarget(textureRef), CVOpenGLESTextureGetName(textureRef));
  
  // Set texture parameters
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	
  static const GLfloat squareVertices[] = {
    -1.0f, -1.0f,
    1.0f, -1.0f,
    -1.0f,  1.0f,
    1.0f,  1.0f,
  };
  
	// The texture vertices are set up such that we flip the texture vertically.
	// This is so that our top left origin buffers match OpenGL's bottom left texture coordinate system.
	CGRect textureSamplingRect = [self textureSamplingRectForCroppingTextureWithAspectRatio:CGSizeMake(frameWidth, frameHeight) toAspectRatio:self.bounds.size];
	GLfloat textureVertices[] = {
		CGRectGetMinX(textureSamplingRect), CGRectGetMaxY(textureSamplingRect),
		CGRectGetMaxX(textureSamplingRect), CGRectGetMaxY(textureSamplingRect),
		CGRectGetMinX(textureSamplingRect), CGRectGetMinY(textureSamplingRect),
		CGRectGetMaxX(textureSamplingRect), CGRectGetMinY(textureSamplingRect),
	};
	
  // Draw the texture on the screen with OpenGL ES 2
  [self renderWithSquareVertices:squareVertices textureVertices:textureVertices];
  
  // Flush the CVOpenGLESTexture cache and release the texture.
  // This logic does not deallocate the "texture", it just deallocates the
  // CoreVideo object wrapper for the texture.
  
  CVOpenGLESTextureCacheFlush(self->textureCacheRef, 0);
  CFRelease(textureRef);
}

// drawRect from UIView, this method is invoked because this view extends GLKView

- (void)drawRect:(CGRect)rect
{
  NSLog(@"drawRect %dx%d", (int)rect.size.width, (int)rect.size.height);
  
  if (didSetupOpenGLMembers == FALSE) {
    didSetupOpenGLMembers = TRUE;
    BOOL worked = [self setupOpenGLMembers];
    NSAssert(worked, @"setupOpenGLMembers failed");
  }
  
  if (self.rgbFrame != nil && self.alphaFrame != nil) {
    [self displayFrame];
  } else {
    glClearColor(0.0, 0.0, 0.0, 1.0);
    glClear(GL_COLOR_BUFFER_BIT);
  }
  return;
}

#pragma mark -  OpenGL ES 2 shader compilation

// Compile OpenGL "shader" program, these shaders just pass the data through
// without doing anything special.

- (BOOL)compileShaders
{
  GLuint vertShader, fragShader;
  
  // Create shader program.
  passThroughProgram = glCreateProgram();

  if (passThroughProgram == 0) {
    NSLog(@"Failed to create vertex/fragment shader program");
    return FALSE;
  }
  
  // Create and compile vertex shader.
  NSString *vertShaderStr = [NSString stringWithUTF8String:vertShaderCstr];
  if (![self compileShader:&vertShader type:GL_VERTEX_SHADER source:vertShaderStr]) {
    NSLog(@"Failed to compile vertex shader");
    return FALSE;
  }
  
  // Create and compile fragment shader.
  NSString *fragShaderStr = [NSString stringWithUTF8String:fragShaderCstr];
  if (![self compileShader:&fragShader type:GL_FRAGMENT_SHADER source:fragShaderStr]) {
    NSLog(@"Failed to compile fragment shader");
    return FALSE;
  }
  
  // Attach vertex shader to program.
  glAttachShader(passThroughProgram, vertShader);
  
  // Attach fragment shader to program.
  glAttachShader(passThroughProgram, fragShader);
  
  // Bind attribute offset to name.
  // This needs to be done prior to linking.
  glBindAttribLocation(passThroughProgram, ATTRIB_VERTEX, "position");
  glBindAttribLocation(passThroughProgram, ATTRIB_TEXTUREPOSITON, "textureCoordinate");
  
  // Link program.
  if (![self linkProgram:passThroughProgram]) {
    NSLog(@"Failed to link program: %d", passThroughProgram);
    
    if (vertShader) {
      glDeleteShader(vertShader);
      vertShader = 0;
    }
    if (fragShader) {
      glDeleteShader(fragShader);
      fragShader = 0;
    }
    if (passThroughProgram) {
      glDeleteProgram(passThroughProgram);
      passThroughProgram = 0;
    }
    
    return NO;
  }
  
  // Link textures to named textures variables in the shader program
	//uniforms[UNIFORM_INDEXES] = glGetUniformLocation(passThroughProgram, "indexes");
  
  // Release vertex and fragment shaders.
  if (vertShader) {
    glDetachShader(passThroughProgram, vertShader);
    glDeleteShader(vertShader);
  }
  if (fragShader) {
    glDetachShader(passThroughProgram, fragShader);
    glDeleteShader(fragShader);
  }
  
  return YES;
}

- (BOOL)compileShader:(GLuint*)shader
                 type:(GLenum)type
                 source:(NSString*)sourceStr
{
  GLint status;
  const GLchar *source;
  
  source = [sourceStr UTF8String];
  if (!source) {
    NSLog(@"Failed to load vertex shader");
    return NO;
  }
  
  *shader = glCreateShader(type);
  glShaderSource(*shader, 1, &source, NULL);
  glCompileShader(*shader);
  
#if defined(DEBUG)
  GLint logLength;
  glGetShaderiv(*shader, GL_INFO_LOG_LENGTH, &logLength);
  if (logLength > 0) {
    GLchar *log = (GLchar *)malloc(logLength);
    glGetShaderInfoLog(*shader, logLength, &logLength, log);
    NSLog(@"Shader compile log:\n%s", log);
    free(log);
  }
#endif
  
  glGetShaderiv(*shader, GL_COMPILE_STATUS, &status);
  if (status == 0) {
    glDeleteShader(*shader);
    return NO;
  }
  
  return YES;
}

- (BOOL)linkProgram:(GLuint)prog
{
  GLint status;
  glLinkProgram(prog);
  
#if defined(DEBUG)
  GLint logLength;
  glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
  if (logLength > 0) {
    GLchar *log = (GLchar *)malloc(logLength);
    glGetProgramInfoLog(prog, logLength, &logLength, log);
    NSLog(@"Program link log:\n%s", log);
    free(log);
  }
#endif
  
  glGetProgramiv(prog, GL_LINK_STATUS, &status);
  if (status == 0) {
    return NO;
  }
  
  return YES;
}

- (BOOL)validateProgram:(GLuint)prog
{
  GLint logLength, status;
  
  glValidateProgram(prog);
  glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
  if (logLength > 0) {
    GLchar *log = (GLchar *)malloc(logLength);
    glGetProgramInfoLog(prog, logLength, &logLength, log);
    NSLog(@"Program validate log:\n%s", log);
    free(log);
  }
  
  glGetProgramiv(prog, GL_VALIDATE_STATUS, &status);
  if (status == 0) {
    return NO;
  }
  
  return YES;
}

- (void) startAnimator
{
  if (self.rgbFrame == nil || self.alphaFrame == nil) {
    NSAssert(FALSE, @"player must be prepared before startAnimator can be invoked");
  }
}

- (void) stopAnimator
{
  self.rgbFrame = nil;
  self.alphaFrame = nil;
}

// Invoke this method to read from the named asset and being loading initial data

// FIXME: all this CoreVideo texture buffer reading logic needs to be done on a
// background thread.

- (void) prepareToAnimate
{
  self.animatorPrepTimer = [NSTimer timerWithTimeInterval: 0.10
                                                   target: self
                                                 selector: @selector(_prepareToAnimateTimer:)
                                                 userInfo: NULL
                                                  repeats: FALSE];
  
  [[NSRunLoop currentRunLoop] addTimer: self.animatorPrepTimer forMode: NSDefaultRunLoopMode];
  
  self.currentFrame = -1;
}

// This timer callback method is invoked after the event loop is up and running in the
// case where prepareToAnimate is invoked as part of the app startup via viewDidLoad.

- (void) _prepareToAnimateTimer:(NSTimer*)timer
{
  AVAssetFrameDecoder *frameDecoder;
  
  frameDecoder = [AVAssetFrameDecoder aVAssetFrameDecoder];
  
  self.frameDecoder = frameDecoder;
  
  // FIXME: deliver AVAnimatorFailedToLoadNotification in fail case
  
  NSAssert(self.assetFilename, @"assetFilename must be defined when prepareToAnimate is invoked");
  
  NSString *assetFullPath = [AVFileUtil getQualifiedFilenameOrResource:self.assetFilename];
  
  BOOL worked;
  worked = [frameDecoder openForReading:assetFullPath];
  
  if (worked == FALSE) {
    NSLog(@"error: cannot open RGB+Alpha mixed asset filename \"%@\"", assetFullPath);
    return;
    //return FALSE;
  }
  
  worked = [frameDecoder allocateDecodeResources];
  
  if (worked == FALSE) {
    NSLog(@"error: cannot allocate RGB+Alpha mixed decode resources for filename \"%@\"", assetFullPath);
    return;
    //    return FALSE;
  }
  
  frameDecoder.produceCoreVideoPixelBuffers = TRUE;
  
  self.currentFrame = 0;
  
  __block int currentFrame = self.currentFrame;
  __block Class c = self.class;
  __block AVAssetFrameDecoder *frameDecoderBlock = frameDecoder;
  __weak AVAnimatorH264AlphaPlayer *weakSelf = self;
  
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    // Execute on background thread with blocks API invocation
    
    AVFrame* rgbFrame;
    AVFrame* alphaFrame;
    
    int nextFrame = [c loadFramesInBackgroundThread:currentFrame
                                       frameDecoder:frameDecoderBlock
                                           rgbFrame:&rgbFrame
                                         alphaFrame:&alphaFrame];
    
    dispatch_sync(dispatch_get_main_queue(), ^{
#if defined(DEBUG)
      NSAssert(rgbFrame, @"rgbFrame");
      NSAssert(alphaFrame, @"alphaFrame");
#endif // DEBUG
      
      __strong typeof(weakSelf) strongSelf = weakSelf;
      
      strongSelf.rgbFrame = rgbFrame;
      strongSelf.alphaFrame = alphaFrame;
      
      strongSelf.currentFrame = nextFrame;

      NSLog(@"set H264AlphaPlayer self.currentFrame to %d", strongSelf.currentFrame);
      
      [strongSelf setNeedsDisplay];
      
      // Deliver AVAnimatorPreparedToAnimateNotification
      
      [[NSNotificationCenter defaultCenter] postNotificationName:AVAnimatorPreparedToAnimateNotification
                                                          object:strongSelf];
    });
  });
  
  return;
}

+ (int) loadFramesInBackgroundThread:(int)currentFrame
                        frameDecoder:(AVAssetFrameDecoder*)frameDecoder
                            rgbFrame:(AVFrame**)rgbFramePtr
                          alphaFrame:(AVFrame**)alphaFramePtr
{
  AVFrame *rgbFrame;
  AVFrame *alphaFrame;
  
  rgbFrame = [frameDecoder advanceToFrame:currentFrame];
  currentFrame++;
  alphaFrame = [frameDecoder advanceToFrame:currentFrame];
  currentFrame++;

  *rgbFramePtr = rgbFrame;
  *alphaFramePtr = alphaFrame;
  
  return currentFrame;
}
                 
@end

#endif // HAS_AVASSET_READ_COREVIDEO_BUFFER_AS_TEXTURE
