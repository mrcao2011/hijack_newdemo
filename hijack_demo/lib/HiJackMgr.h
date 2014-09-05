//
//  HiJack.h
//  HiJack Library for easy interaction with a HiJack device. This library has two 
//  main functions, the 'send' function of HiJackMgr and the HiJackDelegate's 
//  receive function. 'send' is used to send a byte to the HiJack, while 'receive' is
//  triggered when the library decodes a message coming from the HiJack device.
//
//  Created by Thomas Schmid on 8/4/11.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "AudioUnit/AudioUnit.h"
#import "aurio_helper.h"
#import "CAStreamBasicDescription.h"
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES1/gl.h>
#import <OpenGLES/ES1/glext.h>
#include <libkern/OSAtomic.h>
#include <CoreFoundation/CFURL.h>
#import "FFTBufferManager.h"

#import "EAGLView.h"
#define SPECTRUM_BAR_WIDTH 4

#ifndef CLAMP
#define CLAMP(min,x,max) (x < min ? min : (x > max ? max : x))
#endif

typedef enum aurioTouchDisplayMode {
	aurioTouchDisplayModeOscilloscopeWaveform,
	aurioTouchDisplayModeOscilloscopeFFT,
	aurioTouchDisplayModeSpectrum
} aurioTouchDisplayMode;

typedef struct SpectrumLinkedTexture {
	GLuint							texName;
	struct SpectrumLinkedTexture	*nextTex;
} SpectrumLinkedTexture;


inline double linearInterp(double valA, double valB, double fract)
{
	return valA + ((valB - valA) * fract);
}

@protocol HiJackDelegate;


@interface HiJackMgr : UIViewController<EAGLViewDelegate>
{
	id <HiJackDelegate>			theDelegate;
	
	AudioUnit					rioUnit;
	AURenderCallbackStruct		inputProc;
	DCRejectionFilter*			dcFilter;
	CAStreamBasicDescription	thruFormat;
	Float64						hwSampleRate;

	UInt8						uartByteTransmit;
	BOOL						mute;
	BOOL						newByte;
	UInt32						maxFPS;
    
    
    
    
    UIImageView*				sampleSizeOverlay;
	UILabel*					sampleSizeText;
    UILabel*                    hzlabelToUpdate;
	UITextField*				textBox;
	UInt8						textBoxByte;
	UISlider*					slider;
	
	SInt32*						fftData;
	NSUInteger					fftLength;
	BOOL						hasNewFFTData;

	int							unitIsRunning;
	
	BOOL						initted_oscilloscope, initted_spectrum;
	UInt32*						texBitBuffer;
	CGRect						spectrumRect;
	
	GLuint						bgTexture;
	GLuint						muteOffTexture, muteOnTexture;
	GLuint						fftOffTexture, fftOnTexture;
	GLuint						sonoTexture;
	
	aurioTouchDisplayMode		displayMode;
	
	
	
	SpectrumLinkedTexture*		firstTex;
	FFTBufferManager*			fftBufferManager;
	
	
	UIEvent*					pinchEvent;
	CGFloat						lastPinchDist;
	
	   
	SystemSoundID				buttonPressSound;
	
	int32_t*					l_fftData;
    
	GLfloat*					oscilLine;
	BOOL						resetOscilLine;
    
    
    
    

    

}
	
- (void) setDelegate:(id <HiJackDelegate>) delegate;
- (id) init;
- (int) send:(UInt8)data;
	
@property (nonatomic, assign)	AudioUnit				rioUnit;
@property (nonatomic, assign)	AURenderCallbackStruct	inputProc;
@property (nonatomic, assign)	int						unitIsRunning;
@property (nonatomic, assign)   UInt8					uartByteTransmit;
@property (nonatomic, assign)   UInt32					maxFPS;
@property (nonatomic, assign)	BOOL					newByte;
@property (nonatomic, assign)	BOOL					mute;
@property (strong, nonatomic) EAGLView*	GLview;
@property (assign)				aurioTouchDisplayMode	displayMode;
@property						FFTBufferManager*		fftBufferManager;
@property (nonatomic,strong)UIImageView*				sampleSizeOverlay;
@property (nonatomic,strong)UILabel*					sampleSizeText;
@property (nonatomic,strong)UILabel*                    hzlabelToUpdate;
@property (nonatomic,strong)UITextField*				textBox;
@property (nonatomic,strong)UISlider*					slider;

@end

	
@protocol HiJackDelegate <NSObject>
	
- (int) receive:(UInt8)data;
	
@end
