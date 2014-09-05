//
//  HiJackMgr.m
//  HiJack
//
//  Created by Thomas Schmid on 8/4/11.
//


#import "HiJackMgr.h"
#import "AudioUnit/AudioUnit.h"
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import "CAXException.h"
#import "aurio_helper.h"
#import "mo_audio.h"
#import "FFTHelper.h"
// value, a, r, g, b
GLfloat colorLevels[] = {
    0., 1., 0., 0., 0.,
    .333, 1., .7, 0., 0.,
    .667, 1., 0., 0., 1.,
    1., 1., 0., 1., 1.,
};


enum uart_state {
	STARTBIT = 0,
	SAMEBIT  = 1,
	NEXTBIT  = 2,
	STOPBIT  = 3,
	STARTBIT_FALL = 4,
	DECODE   = 5,
};

#define fc 1200
#define df 100
#define T (1/df)
#define N (SInt32)(T * THIS->hwSampleRate)
#define THRESHOLD 0 // threshold used to detect start bit
#define HIGHFREQ 1378.125 // baud rate. best to take a divisible number for 44.1kS/s
#define SAMPLESPERBIT 32 // (44100 / HIGHFREQ)  // how many samples per UART bit
//#define SAMPLESPERBIT 5 // (44100 / HIGHFREQ)  // how many samples per UART bit
//#define HIGHFREQ (44100 / SAMPLESPERBIT) // baud rate. best to take a divisible number for 44.1kS/s
#define LOWFREQ (HIGHFREQ / 2)
#define SHORT (SAMPLESPERBIT/2 + SAMPLESPERBIT/4) // 
#define LONG (SAMPLESPERBIT + SAMPLESPERBIT/2)    //
#define NUMSTOPBITS 100 // number of stop bits to send before sending next value.
//#define NUMSTOPBITS 10 // number of stop bits to send before sending next value.
#define AMPLITUDE (1<<24)

//#define DEBUG // verbose output about the bits and symbols
//#define DEBUG2 // output the byte values encoded
//#define DEBUGWAVE // enables output of the waveform after the 10th byte is sent. CAREFUL!!! Usually overloads debug output
#define DECDEBUGBYTE // output the received byte only
#define DECDEBUG // output for decoding debugging
//#define DECDEBUG2 // verbose decoding output
#define SAMPLE_RATE 44100  //22050 //44100
#define FRAMESIZE  512
#define NUMCHANNELS 2

#define kOutputBus 0
#define kInputBus 1

/// Nyquist Maximum Frequency
const Float32 NyquistMaxFreq = SAMPLE_RATE/2.0;

/// caculates HZ value for specified index from a FFT bins vector
Float32 frequencyHerzValue(long frequencyIndex, long fftVectorSize, Float32 nyquistFrequency ) {
    return ((Float32)frequencyIndex/(Float32)fftVectorSize) * nyquistFrequency;
}



// The Main FFT Helper
FFTHelperRef *fftConverter = NULL;

//Accumulator Buffer=====================

const UInt32 accumulatorDataLenght = 131072;  //16384; //32768; 65536; 131072;
UInt32 accumulatorFillIndex = 0;
Float32 *dataAccumulator = nil;
static void initializeAccumulator() {
    dataAccumulator = (Float32*) malloc(sizeof(Float32)*accumulatorDataLenght);
    accumulatorFillIndex = 0;
}
static void destroyAccumulator() {
    if (dataAccumulator!=NULL) {
        free(dataAccumulator);
        dataAccumulator = NULL;
    }
    accumulatorFillIndex = 0;
}

static BOOL accumulateFrames(Float32 *frames, UInt32 lenght) { //returned YES if full, NO otherwise.
    //    float zero = 0.0;
    //    vDSP_vsmul(frames, 1, &zero, frames, 1, lenght);
    
    if (accumulatorFillIndex>=accumulatorDataLenght) { return YES; } else {
        memmove(dataAccumulator+accumulatorFillIndex, frames, sizeof(Float32)*lenght);
        accumulatorFillIndex = accumulatorFillIndex+lenght;
        if (accumulatorFillIndex>=accumulatorDataLenght) { return YES; }
    }
    return NO;
}

static void emptyAccumulator() {
    accumulatorFillIndex = 0;
    memset(dataAccumulator, 0, sizeof(Float32)*accumulatorDataLenght);
}
//=======================================


//==========================Window Buffer
const UInt32 windowLength = accumulatorDataLenght;
Float32 *windowBuffer= NULL;
//=======================================



/// max value from vector with value index (using Accelerate Framework)
static Float32 vectorMaxValueACC32_index(Float32 *vector, unsigned long size, long step, unsigned long *outIndex) {
    Float32 maxVal;
    vDSP_maxvi(vector, step, &maxVal, outIndex, size);
    return maxVal;
}




///returns HZ of the strongest frequency.
static Float32 strongestFrequencyHZ(Float32 *buffer, FFTHelperRef *fftHelper, UInt32 frameSize, Float32 *freqValue) {
    Float32 *fftData = computeFFT(fftHelper, buffer, frameSize);
    fftData[0] = 0.0;
    unsigned long length = frameSize/2.0;
    Float32 max = 0;
    unsigned long maxIndex = 0;
    max = vectorMaxValueACC32_index(fftData, length, 1, &maxIndex);
    if (freqValue!=NULL) { *freqValue = max; }
    Float32 HZ = frequencyHerzValue(maxIndex, length, NyquistMaxFreq);
    return HZ;
}




//-----------------------------------------------------------------------------
// name: convertFromUser()
// desc: convert from user data (stereo)
//-----------------------------------------------------------------------------
void convertFromUser( AudioBufferList * inData, Float32 * buffy, UInt32 numFrames )
{
    // make sure there are exactly two channels
    assert( inData->mNumberBuffers == MoAudio::m_numChannels );
    // get number of frames
    UInt32 inFrames = inData->mBuffers[0].mDataByteSize / 4;
    // make sure enough space
    assert( inFrames <= numFrames );
    // channels
    SInt32 * left = (SInt32 *)inData->mBuffers[0].mData;
    SInt32 * right = (SInt32 *)inData->mBuffers[1].mData;
    // fixed to float scaling factor
    Float32 factor = (Float32)(1 << 24);
    // interleave (AU is by default non interleaved)
    for( UInt32 i = 0; i < inFrames; i++ )
    {
        // convert (AU is by default 8.24 fixed)
        left[i] = (SInt32)(buffy[2*i] * factor);
        right[i] = (SInt32)(buffy[2*i+1] * factor);
    }
}



//-----------------------------------------------------------------------------
// name: convertToUser()
// desc: convert to user data (stereo)
//-----------------------------------------------------------------------------
void convertToUser( AudioBufferList * inData, Float32 * buffy,
                   UInt32 numFrames, UInt32 & actualFrames )
{
    // make sure there are exactly two channels
    assert( inData->mNumberBuffers == MoAudio::m_numChannels );
    // get number of frames
    UInt32 inFrames = inData->mBuffers[0].mDataByteSize / sizeof(SInt32);
    // make sure enough space
    assert( inFrames <= numFrames );
    // channels
    SInt32 * left = (SInt32 *)inData->mBuffers[0].mData;
    SInt32 * right = (SInt32 *)inData->mBuffers[1].mData;
    // fixed to float scaling factor
    Float32 factor = (Float32)(1 << 24);
    
    //    NSLog(@" factor=%f ", factor);
    //    NSLog(@"  %f", MAXFLOAT);
    //    printf("\n factor = %f", factor);
    
    // interleave (AU is by default non interleaved)
    for( UInt32 i = 0; i < inFrames; i++ )
    {
        // convert (AU is by default 8.24 fixed)
        buffy[2*i] = ((Float32)left[i]) / factor;
        buffy[2*i+1] = ((Float32)right[i]) / factor;
    }
    // return
    actualFrames = inFrames;
}
__weak UILabel *labelToUpdate = nil;
void AudioCallback( Float32 * buffer, UInt32 frameSize, void * userData )
{
    
    
    //take only data from 1 channel
    Float32 zero = 0.0;
    vDSP_vsadd(buffer, 2, &zero, buffer, 1, frameSize*NUMCHANNELS);
    
    
    
    if (accumulateFrames(buffer, frameSize)==YES) { //if full
        
        //windowing the time domain data before FFT (using Blackman Window)
        if (windowBuffer==NULL) { windowBuffer = (Float32*) malloc(sizeof(Float32)*windowLength); }
        vDSP_blkman_window(windowBuffer, windowLength, 0);
        vDSP_vmul(dataAccumulator, 1, windowBuffer, 1, dataAccumulator, 1, accumulatorDataLenght);
        //=========================================
        
        
        Float32 maxHZValue = 0;
        Float32 maxHZ = strongestFrequencyHZ(dataAccumulator, fftConverter, accumulatorDataLenght, &maxHZValue);
        
        NSLog(@" max HZ = %0.3f ", maxHZ);
        dispatch_async(dispatch_get_main_queue(), ^{ //update UI only on main thread
            labelToUpdate.text = [NSString stringWithFormat:@"%0.3f HZ",maxHZ];
        });
        
        emptyAccumulator(); //empty the accumulator when finished
    }
    memset(buffer, 0, sizeof(Float32)*frameSize*NUMCHANNELS);
}




@implementation HiJackMgr

@synthesize rioUnit;
@synthesize inputProc;
@synthesize unitIsRunning;
@synthesize uartByteTransmit;
@synthesize maxFPS;
@synthesize newByte;



@synthesize displayMode;
@synthesize fftBufferManager;
@synthesize mute;

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        // Custom initialization
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    
    

}



CGPathRef CreateRoundedRectPath(CGRect RECT, CGFloat cornerRadius)
{
	CGMutablePathRef		path;
	path = CGPathCreateMutable();
	
	double		maxRad = MAX(CGRectGetHeight(RECT) / 2., CGRectGetWidth(RECT) / 2.);
	
	if (cornerRadius > maxRad) cornerRadius = maxRad;
	
	CGPoint		bl, tl, tr, br;
	
	bl = tl = tr = br = RECT.origin;
	tl.y += RECT.size.height;
	tr.y += RECT.size.height;
	tr.x += RECT.size.width;
	br.x += RECT.size.width;
	
	CGPathMoveToPoint(path, NULL, bl.x + cornerRadius, bl.y);
	CGPathAddArcToPoint(path, NULL, bl.x, bl.y, bl.x, bl.y + cornerRadius, cornerRadius);
	CGPathAddLineToPoint(path, NULL, tl.x, tl.y - cornerRadius);
	CGPathAddArcToPoint(path, NULL, tl.x, tl.y, tl.x + cornerRadius, tl.y, cornerRadius);
	CGPathAddLineToPoint(path, NULL, tr.x - cornerRadius, tr.y);
	CGPathAddArcToPoint(path, NULL, tr.x, tr.y, tr.x, tr.y - cornerRadius, cornerRadius);
	CGPathAddLineToPoint(path, NULL, br.x, br.y + cornerRadius);
	CGPathAddArcToPoint(path, NULL, br.x, br.y, br.x - cornerRadius, br.y, cornerRadius);
	
	CGPathCloseSubpath(path);
	
	CGPathRef				ret;
	ret = CGPathCreateCopy(path);
	CGPathRelease(path);
	return ret;
}

void cycleOscilloscopeLines()
{
	// Cycle the lines in our draw buffer so that they age and fade. The oldest line is discarded.
	int drawBuffer_i;
	for (drawBuffer_i=(kNumDrawBuffers - 2); drawBuffer_i>=0; drawBuffer_i--)
		memmove(drawBuffers[drawBuffer_i + 1], drawBuffers[drawBuffer_i], drawBufferLen);
}


#pragma mark -Audio Session Interruption Listener

void rioInterruptionListener(void *inClientData, UInt32 inInterruption)
{
	printf("Session interrupted! --- %s ---", inInterruption == kAudioSessionBeginInterruption ? "Begin Interruption" : "End Interruption");
	
	HiJackMgr *THIS = (HiJackMgr*)inClientData;
	
	if (inInterruption == kAudioSessionEndInterruption) {
		// make sure we are again the active session
		AudioSessionSetActive(true);
		AudioOutputUnitStart(THIS->rioUnit);
	}
	
	if (inInterruption == kAudioSessionBeginInterruption) {
		AudioOutputUnitStop(THIS->rioUnit);
    }
}

#pragma mark -Audio Session Property Listener

void propListener(	void *                  inClientData,
				  AudioSessionPropertyID	inID,
				  UInt32                  inDataSize,
				  const void *            inData)
{
	HiJackMgr*THIS = (HiJackMgr*)inClientData;
	
	if (inID == kAudioSessionProperty_AudioRouteChange)
	{
		try {
			// if there was a route change, we need to dispose the current rio unit and create a new one
			XThrowIfError(AudioComponentInstanceDispose(THIS->rioUnit), "couldn't dispose remote i/o unit");		
			
			SetupRemoteIO(THIS->rioUnit, THIS->inputProc, THIS->thruFormat);
			
			UInt32 size = sizeof(THIS->hwSampleRate);
			XThrowIfError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate, &size, &THIS->hwSampleRate), "couldn't get new sample rate");
			
			XThrowIfError(AudioOutputUnitStart(THIS->rioUnit), "couldn't start unit");
			
			// we need to rescale the sonogram view's color thresholds for different input
			CFStringRef newRoute;
			size = sizeof(CFStringRef);
			XThrowIfError(AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &size, &newRoute), "couldn't get new audio route");
			if (newRoute)
			{	
				CFShow(newRoute);
				if (CFStringCompare(newRoute, CFSTR("Headset"), NULL) == kCFCompareEqualTo) // headset plugged in
				{
					colorLevels[0] = .3;				
					colorLevels[5] = .5;
				}
				else if (CFStringCompare(newRoute, CFSTR("Receiver"), NULL) == kCFCompareEqualTo) // headset plugged in
				{
					colorLevels[0] = 0;
					colorLevels[5] = .333;
					colorLevels[10] = .667;
					colorLevels[15] = 1.0;
					
				}			
				else
				{
					colorLevels[0] = 0;
					colorLevels[5] = .333;
					colorLevels[10] = .667;
					colorLevels[15] = 1.0;
					
				}
	
			}
		} catch (CAXException e) {
			char buf[256];
			fprintf(stderr, "Error: %s (%s)\n", e.mOperation, e.FormatError(buf));
		}
		
	}
}


#pragma mark -RIO Render Callback

static OSStatus	PerformThru(
							void						*inRefCon, 
							AudioUnitRenderActionFlags 	*ioActionFlags, 
							const AudioTimeStamp 		*inTimeStamp, 
							UInt32 						inBusNumber, 
							UInt32 						inNumberFrames, 
							AudioBufferList 			*ioData)
{
	HiJackMgr *THIS = (HiJackMgr *)inRefCon;
	OSStatus err = AudioUnitRender(THIS->rioUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ioData);
	
	// TX vars
	static UInt32 phase = 0;
	static UInt32 phase2 = 0;
	static UInt32 lastPhase2 = 0;
	static SInt32 sample = 0;
	static SInt32 lastSample = 0;
	static int decState = STARTBIT;
	static int byteCounter = 1;
	static UInt8 parityTx = 0;
	
	// UART decoding
	static int bitNum = 0;
	static uint8_t uartByte = 0;
	
	// UART encode
	static uint32_t phaseEnc = 0;
	static uint32_t nextPhaseEnc = SAMPLESPERBIT;
	static uint8_t uartByteTx = 0x0;
	static uint32_t uartBitTx = 0;
	static uint8_t state = STARTBIT;
	static float uartBitEnc[SAMPLESPERBIT];
	static uint8_t currentBit = 1;
	static UInt8 parityRx = 0;
	
	if (err) { printf("PerformThru: error %d\n", (int)err); return err; }
	
	// Remove DC component
	//for(UInt32 i = 0; i < ioData->mNumberBuffers; ++i)
	//	THIS->dcFilter[i].InplaceFilter((SInt32*)(ioData->mBuffers[i].mData), inNumberFrames, 1);
	SInt32* lchannel = (SInt32*)(ioData->mBuffers[0].mData);
	//printf("sample %f\n", THIS->hwSampleRate);
	
	/************************************
	 * UART Decoding
	 ************************************/
#if 1
	for(int j = 0; j < inNumberFrames; j++) {
		float val = lchannel[j];
#ifdef DEBUGWAVE
		printf("%8ld, %8.0f\n", phase2, val);
#endif
#ifdef DECDEBUG2
		if(decState == DECODE)
			printf("%8ld, %8.0f\n", phase2, val);
#endif		
		phase2 += 1;
		if (val < THRESHOLD ) {
			sample = 0;
		} else {
			sample = 1;
		}
		if (sample != lastSample) {
			// transition
			SInt32 diff = phase2 - lastPhase2;
			switch (decState) {
				case STARTBIT:
					if (lastSample == 0 && sample == 1)
					{
						// low->high transition. Now wait for a long period
						decState = STARTBIT_FALL;
					}
					break;
				case STARTBIT_FALL:
					if (( SHORT < diff ) && (diff < LONG) )
					{
						// looks like we got a 1->0 transition.
						bitNum = 0;
						parityRx = 0;
						uartByte = 0;
						decState = DECODE;
					} else {
						decState = STARTBIT;
					}
					break;
				case DECODE:
					if (( SHORT < diff) && (diff < LONG) ) {
						// we got a valid sample.
						if (bitNum < 8) {
							uartByte = ((uartByte >> 1) + (sample << 7));
							bitNum += 1;
							parityRx += sample;
#ifdef DECDEBUG
							printf("Bit %d value %ld diff %ld parity %d\n", bitNum, sample, diff, parityRx & 0x01);
              //printf("%ld\n", sample);

#endif
						} else if (bitNum == 8) {
							// parity bit
							if(sample != (parityRx & 0x01))
							{
#ifdef DECDEBUGBYTE
								printf(" -- parity %ld,  UartByte 0x%x\n", sample, uartByte);
#endif
								decState = STARTBIT;
							} else {
#ifdef DECDEBUG
								printf(" ++ good parity %ld, UartByte 0x%x\n", sample, uartByte);
#endif
								
								bitNum += 1;
							}
							
						} else {
							// we should now have the stopbit
							if (sample == 1) {
								// we have a new and valid byte!
#ifdef DECDEBUGBYTE
								printf(" ++ StopBit: %ld UartByte 0x%x\n", sample, uartByte);
#endif
								NSAutoreleasePool	 *autoreleasepool = [[NSAutoreleasePool alloc] init];
								//////////////////////////////////////////////
								// This is where we receive the byte!!!
								if([THIS->theDelegate respondsToSelector:@selector(receive:)]) {
									[THIS->theDelegate receive:uartByte];
								}
                                THIS->textBoxByte = uartByte;
								//////////////////////////////////////////////
								[autoreleasepool release];
                                // only draw if stopbit is valid!
								if ((drawBufferIdx) >= drawBufferLen)
								{
									cycleOscilloscopeLines();
									drawBufferIdx = 0;
								}
								if (drawBufferLen == drawBufferLen_alloced) {
									drawBuffers[0][drawBufferIdx++] = uartByte-128; // shift to have 0 at the bottom!
								}

							} else {
								// not a valid byte.
#ifdef DECDEBUGBYTE
								printf(" -- NotValidStopBit: %ld UartByte %d\n", sample, uartByte);
#endif					
							}
							decState = STARTBIT;
						}
					} else if (diff > LONG) {
#ifdef DECDEBUG
						printf("diff too long %ld\n", diff);
#endif
						decState = STARTBIT;
					} else {
						// don't update the phase as we have to look for the next transition
						lastSample = sample;
						continue;
					}
					
					break;
				default:
					break;
			}
			lastPhase2 = phase2;
		}
		lastSample = sample;
	}
#endif
	if (THIS->displayMode == aurioTouchDisplayModeOscilloscopeWaveform)
	{
		// The draw buffer is used to hold a copy of the most recent PCM data to be drawn on the oscilloscope
		if (drawBufferLen != drawBufferLen_alloced)
		{
			int drawBuffer_i;
			
			// Allocate our draw buffer if needed
			if (drawBufferLen_alloced == 0)
				for (drawBuffer_i=0; drawBuffer_i<kNumDrawBuffers; drawBuffer_i++)
					drawBuffers[drawBuffer_i] = NULL;
			
			// Fill the first element in the draw buffer with PCM data
			for (drawBuffer_i=0; drawBuffer_i<kNumDrawBuffers; drawBuffer_i++)
			{
				drawBuffers[drawBuffer_i] = (SInt8 *)realloc(drawBuffers[drawBuffer_i], drawBufferLen);
				bzero(drawBuffers[drawBuffer_i], drawBufferLen);
			}
			
			drawBufferLen_alloced = drawBufferLen;
		}
        
		/*
         int i;
         
         SInt8 *data_ptr = (SInt8 *)(ioData->mBuffers[0].mData);
         for (i=0; i<inNumberFrames; i++)
         {
         if ((i+drawBufferIdx) >= drawBufferLen)
         {
         cycleOscilloscopeLines();
         drawBufferIdx = -i;
         }
         if (THIS->mute == YES) {
         drawBuffers[0][i + drawBufferIdx] = symbols[i]*64;
         } else {
         drawBuffers[0][i + drawBufferIdx] = data_ptr[2]*10;
         }
         data_ptr += 4;
         }
         drawBufferIdx += inNumberFrames;
         */
	}
    
	
	else if ((THIS->displayMode == aurioTouchDisplayModeSpectrum) || (THIS->displayMode == aurioTouchDisplayModeOscilloscopeFFT))
	{
		if (THIS->fftBufferManager == NULL) return noErr;
		
		if (THIS->fftBufferManager->NeedsNewAudioData())
		{
			THIS->fftBufferManager->GrabAudioData(ioData); 
		}
		
	}
	
	if (THIS->mute == YES) {
		// prepare sine wave
		
		SInt32 values[inNumberFrames];
		/*******************************
		 * Generate 22kHz Tone
		 *******************************/
		
		double waves;
		//printf("inBusNumber %d, inNumberFrames %d, ioData->NumberBuffers %d mNumberChannels %d\n", inBusNumber, inNumberFrames, ioData->mNumberBuffers, ioData->mBuffers[0].mNumberChannels);
		//printf("size %d\n", ioData->mBuffers[0].mDataByteSize);
		//printf("sample rate %f\n", THIS->hwSampleRate);
		for(int j = 0; j < inNumberFrames; j++) {
			
			
			waves = 0;
			
			//waves += sin(M_PI * 2.0f / THIS->hwSampleRate * 22050.0 * phase);
			waves += sin(M_PI * phase+0.5); // This should be 22.050kHz
			
			waves *= (AMPLITUDE); // <--------- make sure to divide by how many waves you're stacking
			
			values[j] = (SInt32)waves;
			//values[j] += values[j]<<16;
			//printf("%d: %ld\n", phase, values[j]);
			phase++;
			
		}
		// copy sine wave into left channels.
		//memcpy(ioData->mBuffers[0].mData, values, ioData->mBuffers[0].mDataByteSize);
		// copy sine wave into right channels.
		memcpy(ioData->mBuffers[1].mData, values, ioData->mBuffers[1].mDataByteSize);
		/*******************************
		 * UART Encoding
		 *******************************/
		for(int j = 0; j< inNumberFrames; j++) {
			if ( phaseEnc >= nextPhaseEnc){
				if (uartBitTx >= NUMSTOPBITS && THIS->newByte == TRUE) {
					state = STARTBIT;
					THIS->newByte = FALSE;
				} else {
					state = NEXTBIT;
				}
			}
			
			switch (state) {
				case STARTBIT:
				{
					//////////////////////////////////////////////
					// FIXME: This is where we inject the message!
					//////////////////////////////////////////////
                    //滑块发数据
					//uartByteTx = (uint8_t)THIS->slider.value;
                    //senddata:发数据
					uartByteTx = THIS->uartByteTransmit;
					//uartByteTx = 255;
					//uartByteTx += 1;
#ifdef DEBUG2
					printf("uartByteTx: 0x%x\n", uartByteTx);
#endif
					byteCounter += 1;
					uartBitTx = 0;
					parityTx = 0;
					
					state = NEXTBIT;
					// break; UNCOMMENTED ON PURPOSE. WE WANT TO FALL THROUGH!
				}
				case NEXTBIT:
				{
					uint8_t nextBit;
					if (uartBitTx == 0) {
						// start bit
						nextBit = 0;
					} else {
						if (uartBitTx == 9) {
							// parity bit
							nextBit = parityTx & 0x01;
						} else if (uartBitTx >= 10) {
							// stop bit
							nextBit = 1;
						} else {
							nextBit = (uartByteTx >> (uartBitTx - 1)) & 0x01;
							parityTx += nextBit;
						}
					}
					if (nextBit == currentBit) {
						if (nextBit == 0) {
							for( uint8_t p = 0; p<SAMPLESPERBIT; p++)
							{
								uartBitEnc[p] = -sin(M_PI * 2.0f / THIS->hwSampleRate * HIGHFREQ * (p+1));
							}
						} else {
							for( uint8_t p = 0; p<SAMPLESPERBIT; p++)
							{
								uartBitEnc[p] = sin(M_PI * 2.0f / THIS->hwSampleRate * HIGHFREQ * (p+1));
							}
						}
					} else {
						if (nextBit == 0) {
							for( uint8_t p = 0; p<SAMPLESPERBIT; p++)
							{
								uartBitEnc[p] = sin(M_PI * 2.0f / THIS->hwSampleRate * LOWFREQ * (p+1));
							}
						} else {
							for( uint8_t p = 0; p<SAMPLESPERBIT; p++)
							{
								uartBitEnc[p] = -sin(M_PI * 2.0f / THIS->hwSampleRate * LOWFREQ * (p+1));
							}
						}
					}
					
#ifdef DEBUG
					printf("BitTX %d: last %d next %d\n", uartBitTx, currentBit, nextBit);
#endif
					currentBit = nextBit;
					uartBitTx++;
					state = SAMEBIT;
					phaseEnc = 0;
					nextPhaseEnc = SAMPLESPERBIT;
					
					break;
				}
				default:
					break;
			}
			
			values[j] = (SInt32)(uartBitEnc[phaseEnc%SAMPLESPERBIT] * AMPLITUDE);
#ifdef DEBUG
			printf("val %ld\n", values[j]);
#endif
			phaseEnc++;
			
		}
		// copy data into right channel
		//memcpy(ioData->mBuffers[1].mData, values, ioData->mBuffers[1].mDataByteSize);
		// copy data into left channel
		memcpy(ioData->mBuffers[0].mData, values, ioData->mBuffers[0].mDataByteSize);
	}
    UInt32 actualFrames = 0;
	convertToUser( ioData, MoAudio::m_info->m_ioBuffer, MoAudio::m_info->m_bufferSize, actualFrames );
    MoAudio::m_callback( MoAudio::m_info->m_ioBuffer, actualFrames, MoAudio::m_bindle );
    
    convertFromUser( ioData, MoAudio::m_info->m_ioBuffer, MoAudio::m_info->m_bufferSize );
    
	

	return err;
}


- (void) setDelegate:(id <HiJackDelegate>) delegate {
	theDelegate = delegate;
}

- (id) init {
	// Initialize our remote i/o unit
    
    self.mute = YES;

    
    _GLview=[[EAGLView alloc]initWithFrame:CGRectMake(0, 0, [[UIScreen mainScreen] bounds].size.width, [[UIScreen mainScreen] bounds].size.height)];
    //_GLview.backgroundColor=[UIColor redColor];
    [self.view addSubview:_GLview];

	displayMode = aurioTouchDisplayModeOscilloscopeWaveform;
	
    [self initMomuAudio];
	
	inputProc.inputProc = PerformThru;
	inputProc.inputProcRefCon = self;
	
	newByte = FALSE;
	CFURLRef url = NULL;
	try {	
		url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, CFStringRef([[NSBundle mainBundle] pathForResource:@"button_press" ofType:@"caf"]), kCFURLPOSIXPathStyle, false);
		XThrowIfError(AudioServicesCreateSystemSoundID(url, &buttonPressSound), "couldn't create button tap alert sound");
		CFRelease(url);
		

		// Initialize and configure the audio session
		XThrowIfError(AudioSessionInitialize(NULL, NULL, rioInterruptionListener, self), "couldn't initialize audio session");
		XThrowIfError(AudioSessionSetActive(true), "couldn't set audio session active\n");
		
		UInt32 audioCategory = kAudioSessionCategory_PlayAndRecord;
		XThrowIfError(AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(audioCategory), &audioCategory), "couldn't set audio category");
		XThrowIfError(AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, propListener, self), "couldn't set property listener");
		
		Float32 preferredBufferSize = .005;
		XThrowIfError(AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize), "couldn't set i/o buffer duration");
		
		UInt32 size = sizeof(hwSampleRate);
		XThrowIfError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate, &size, &hwSampleRate), "couldn't get hw sample rate");
		
		XThrowIfError(SetupRemoteIO(rioUnit, inputProc, thruFormat), "couldn't setup remote i/o unit");
		
		dcFilter = new DCRejectionFilter[thruFormat.NumberChannels()];
		
		UInt32 maxFPSt;
		size = sizeof(maxFPSt);
		XThrowIfError(AudioUnitGetProperty(rioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPSt, &size), "couldn't get the remote I/O unit's max frames per slice");
		self.maxFPS = maxFPSt;
		
		XThrowIfError(AudioOutputUnitStart(rioUnit), "couldn't start remote i/o unit");
		
		size = sizeof(thruFormat);
		XThrowIfError(AudioUnitGetProperty(rioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &thruFormat, &size), "couldn't get the remote I/O unit's output client format");
		fftBufferManager = new FFTBufferManager(maxFPS);
		l_fftData = new int32_t[maxFPS/2];
		
		oscilLine = (GLfloat*)malloc(drawBufferLen * 2 * sizeof(GLfloat));

		unitIsRunning = 1;
	}
	catch (CAXException &e) {
		char buf[256];
		fprintf(stderr, "Error: %s (%s)\n", e.mOperation, e.FormatError(buf));
		unitIsRunning = 0;
		if (dcFilter) delete[] dcFilter;
	}
	catch (...) {
		fprintf(stderr, "An unknown error occurred\n");
		unitIsRunning = 0;
		if (dcFilter) delete[] dcFilter;
	}
    
    
    // Set ourself as the delegate for the EAGLView so that we get drawing and touch events
	_GLview.delegate = self;
	
	// Enable multi touch so we can handle pinch and zoom in the oscilloscope
	_GLview.multipleTouchEnabled = YES;
	
	// Set up our overlay view that pops up when we are pinching/zooming the oscilloscope
	UIImage *img_ui = nil;
	{
		// Draw the rounded rect for the bg path using this convenience function
		CGPathRef bgPath = CreateRoundedRectPath(CGRectMake(0, 0, 110, 234), 15.);
		
		CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
		// Create the bitmap context into which we will draw
		CGContextRef cxt = CGBitmapContextCreate(NULL, 110, 234, 8, 4*110, cs, kCGImageAlphaPremultipliedFirst);
		CGContextSetFillColorSpace(cxt, cs);
		CGFloat fillClr[] = {0., 0., 0., 0.7};
		CGContextSetFillColor(cxt, fillClr);
		// Add the rounded rect to the context...
		CGContextAddPath(cxt, bgPath);
		// ... and fill it.
		CGContextFillPath(cxt);
		
		// Make a CGImage out of the context
		CGImageRef img_cg = CGBitmapContextCreateImage(cxt);
		// Make a UIImage out of the CGImage
		img_ui = [UIImage imageWithCGImage:img_cg];
		
		// Clean up
		CGImageRelease(img_cg);
		CGColorSpaceRelease(cs);
		CGContextRelease(cxt);
		CGPathRelease(bgPath);
	}
	
	// Create the image view to hold the background rounded rect which we just drew
	_sampleSizeOverlay = [[UIImageView alloc] initWithImage:img_ui];
	_sampleSizeOverlay.frame = CGRectMake(190, 124, 110, 234);
    //[_GLview addSubview:_sampleSizeOverlay];
	
	// Create the text view which shows the size of our oscilloscope window as we pinch/zoom
	_sampleSizeText = [[UILabel alloc] initWithFrame:CGRectMake(-62, 0, 234, 234)];
	_sampleSizeText.textAlignment = NSTextAlignmentCenter;
	_sampleSizeText.textColor = [UIColor whiteColor];
	_sampleSizeText.text = @"0000 ms";
	_sampleSizeText.font = [UIFont boldSystemFontOfSize:36.];
	// Rotate the text view since we want the text to draw top to bottom (when the device is oriented vertically)
	_sampleSizeText.transform = CGAffineTransformMakeRotation(M_PI_2);
	_sampleSizeText.backgroundColor = [UIColor clearColor];
	
	// Add the text view as a subview of the overlay BG
	[_sampleSizeOverlay addSubview:_sampleSizeText];
	// Text view was retained by the above line, so we can release it now
	[_sampleSizeText release];
	
	// We don't add sampleSizeOverlay to our main view yet. We just hang on to it for now, and add it when we
	// need to display it, i.e. when a user starts a pinch/zoom.
	
	// Set up the view to refresh at 20 hz
	[_GLview setAnimationInterval:1./20.];
	[_GLview startAnimation];
	
	_slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 100, 100, 10)];
	
	// Rotate slider by 270 degree County Clockwise to vertical position

    _slider.transform = CGAffineTransformRotate(_slider.transform,0/180*M_PI);
	[_slider addTarget:self action:@selector(sliderAction:) forControlEvents:UIControlEventValueChanged];
	[_slider setBackgroundColor:[UIColor clearColor]];
	_slider.minimumValue = 0.0;
	_slider.maximumValue = 255.0;
	_slider.continuous = NO;
	_slider.value = 0.0;
	[_GLview addSubview:_slider];
	[_slider release];
    
	_textBox = [[UITextField alloc] initWithFrame:CGRectMake(0.0f, 190.0f+72, 60.0f, 30.0f)];
    
	// Rotate textbox by 270 degree County Clockwise to vertical position
	_textBox.transform = CGAffineTransformRotate(_textBox.transform, 90.0/180*M_PI);
	[_textBox setBackgroundColor:[UIColor whiteColor]];
	_textBox.text = @"test";
	_textBox.borderStyle = UITextBorderStyleBezel;
	_textBox.enabled = false;
	[self.view addSubview:_textBox];
	[_textBox release];
    _hzlabelToUpdate=[[UILabel alloc] initWithFrame:CGRectMake(-20, 75+80, 100, 30)];
	_hzlabelToUpdate.textAlignment = NSTextAlignmentRight;
	_hzlabelToUpdate.textColor = [UIColor blueColor];
	_hzlabelToUpdate.text = @"0000 HZ";
	_hzlabelToUpdate.font = [UIFont boldSystemFontOfSize:15.];
	// Rotate the text view since we want the text to draw top to bottom (when the device is oriented vertically)
	_hzlabelToUpdate.transform = CGAffineTransformRotate(_hzlabelToUpdate.transform, 90.0/180*M_PI);
	_hzlabelToUpdate.backgroundColor = [UIColor clearColor];
    // Add the text view as a subview of the overlay BG
	[_GLview addSubview:_hzlabelToUpdate];
	// Text view was retained by the above line, so we can release it now
    labelToUpdate = _hzlabelToUpdate;
	[_hzlabelToUpdate release];

    
    
    
	return self;
}
-(void) initMomuAudio {
    fftConverter = FFTHelperCreate(accumulatorDataLenght);
    initializeAccumulator();
    
    bool result = false;
    result = MoAudio::init( SAMPLE_RATE, FRAMESIZE, NUMCHANNELS, false);
    if (!result) { NSLog(@" MoAudio init ERROR"); }
    result = MoAudio::start( AudioCallback, NULL );
    if (!result) { NSLog(@" MoAudio start ERROR"); }
}
-(void)sliderAction:(id)sender
{
    [self send:_slider.value];
}
- (int) send:(UInt8) data {
	if (newByte == FALSE) {
		// transmitter ready
		self.uartByteTransmit = data;
		newByte = TRUE;
		return 0;
	} else {
		return 1;
	}
}


- (void)dealloc
{
	delete[] dcFilter;
    destroyAccumulator();
    FFTHelperRelease(fftConverter);

	[super dealloc];

}


- (void)setFFTData:(int32_t *)FFTDATA length:(NSUInteger)LENGTH
{
	if (LENGTH != fftLength)
	{
		fftLength = LENGTH;
		fftData = (SInt32 *)(realloc(fftData, LENGTH * sizeof(SInt32)));
	}
	memmove(fftData, FFTDATA, fftLength * sizeof(Float32));
	hasNewFFTData = YES;
}


- (void)createGLTexture:(GLuint *)texName fromCGImage:(CGImageRef)img
{
	GLubyte *spriteData = NULL;
	CGContextRef spriteContext;
	GLuint imgW, imgH, texW, texH;
	
	imgW = CGImageGetWidth(img);
	imgH = CGImageGetHeight(img);
	
	// Find smallest possible powers of 2 for our texture dimensions
	for (texW = 1; texW < imgW; texW *= 2) ;
	for (texH = 1; texH < imgH; texH *= 2) ;
	
	// Allocated memory needed for the bitmap context
	spriteData = (GLubyte *) calloc(texH, texW * 4);
	// Uses the bitmatp creation function provided by the Core Graphics framework.
	spriteContext = CGBitmapContextCreate(spriteData, texW, texH, 8, texW * 4, CGImageGetColorSpace(img), kCGImageAlphaPremultipliedLast);
	
	// Translate and scale the context to draw the image upside-down (conflict in flipped-ness between GL textures and CG contexts)
	CGContextTranslateCTM(spriteContext, 0., texH);
	CGContextScaleCTM(spriteContext, 1., -1.);
	
	// After you create the context, you can draw the sprite image to the context.
	CGContextDrawImage(spriteContext, CGRectMake(0.0, 0.0, imgW, imgH), img);
	// You don't need the context at this point, so you need to release it to avoid memory leaks.
	CGContextRelease(spriteContext);
	
	// Use OpenGL ES to generate a name for the texture.
	glGenTextures(1, texName);
	// Bind the texture name.
	glBindTexture(GL_TEXTURE_2D, *texName);
	// Speidfy a 2D texture image, provideing the a pointer to the image data in memory
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, texW, texH, 0, GL_RGBA, GL_UNSIGNED_BYTE, spriteData);
	// Set the texture parameters to use a minifying filter and a linear filer (weighted average)
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	
	// Enable use of the texture
	glEnable(GL_TEXTURE_2D);
	// Set a blending function to use
	glBlendFunc(GL_SRC_ALPHA,GL_ONE);
	//glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
	// Enable blending
	glEnable(GL_BLEND);
	
	free(spriteData);
}


- (void)setupViewForOscilloscope
{
	CGImageRef img;
	
	// Load our GL textures
	
	img = [UIImage imageNamed:@"oscilloscope.png"].CGImage;
	[self createGLTexture:&bgTexture fromCGImage:img];
	
	img = [UIImage imageNamed:@"fft_off.png"].CGImage;
	[self createGLTexture:&fftOffTexture fromCGImage:img];
	
	img = [UIImage imageNamed:@"fft_on.png"].CGImage;
	[self createGLTexture:&fftOnTexture fromCGImage:img];
	
	img = [UIImage imageNamed:@"mute_off.png"].CGImage;
	[self createGLTexture:&muteOffTexture fromCGImage:img];
	
	img = [UIImage imageNamed:@"mute_on.png"].CGImage;
	[self createGLTexture:&muteOnTexture fromCGImage:img];
    
	img = [UIImage imageNamed:@"sonogram.png"].CGImage;
	[self createGLTexture:&sonoTexture fromCGImage:img];
    
	initted_oscilloscope = YES;
}


- (void)clearTextures
{
	bzero(texBitBuffer, sizeof(UInt32) * 512);
	SpectrumLinkedTexture *curTex;
	
	for (curTex = firstTex; curTex; curTex = curTex->nextTex)
	{
		glBindTexture(GL_TEXTURE_2D, curTex->texName);
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 512, 0, GL_RGBA, GL_UNSIGNED_BYTE, texBitBuffer);
	}
}


- (void)setupViewForSpectrum
{
	glClearColor(0., 0., 0., 0.);
	
	spectrumRect = CGRectMake(10., 10., 460., 300.);
	
	// The bit buffer for the texture needs to be 512 pixels, because OpenGL textures are powers of
	// two in either dimensions. Our texture is drawing a strip of 300 vertical pixels on the screen,
	// so we need to step up to 512 (the nearest power of 2 greater than 300).
	texBitBuffer = (UInt32 *)(malloc(sizeof(UInt32) * 512));
	
	// Clears the view with black
	glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
	
	glEnableClientState(GL_VERTEX_ARRAY);
	glEnableClientState(GL_TEXTURE_COORD_ARRAY);
	
	NSUInteger texCount = ceil(CGRectGetWidth(spectrumRect) / (CGFloat)SPECTRUM_BAR_WIDTH);
	GLuint *texNames;
	
	texNames = (GLuint *)(malloc(sizeof(GLuint) * texCount));
	glGenTextures(texCount, texNames);
	
	int i;
	SpectrumLinkedTexture *curTex = NULL;
	firstTex = (SpectrumLinkedTexture *)(calloc(1, sizeof(SpectrumLinkedTexture)));
	firstTex->texName = texNames[0];
	curTex = firstTex;
	
	bzero(texBitBuffer, sizeof(UInt32) * 512);
	
	glBindTexture(GL_TEXTURE_2D, curTex->texName);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	
	for (i=1; i<texCount; i++)
	{
		curTex->nextTex = (SpectrumLinkedTexture *)(calloc(1, sizeof(SpectrumLinkedTexture)));
		curTex = curTex->nextTex;
		curTex->texName = texNames[i];
		
		glBindTexture(GL_TEXTURE_2D, curTex->texName);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	}
	
	// Enable use of the texture
	glEnable(GL_TEXTURE_2D);
	// Set a blending function to use
	glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
	// Enable blending
	glEnable(GL_BLEND);
	
	initted_spectrum = YES;
	
	free(texNames);
	
}



- (void)drawOscilloscope
{
	// Clear the view
	glClear(GL_COLOR_BUFFER_BIT);
	
	glBlendFunc(GL_SRC_ALPHA, GL_ONE);
	
	glColor4f(1., 1., 1., 1.);
	
	glPushMatrix();
	
	glTranslatef(0., 480., 0.);
	glRotatef(-90., 0., 0., 1.);
	
	
	glEnable(GL_TEXTURE_2D);
	glEnableClientState(GL_VERTEX_ARRAY);
	glEnableClientState(GL_TEXTURE_COORD_ARRAY);
	
	_textBox.text = [NSString stringWithFormat:@"%.1f V", textBoxByte/255.0*3.3];
    
	
	{
		// Draw our background oscilloscope screen
		const GLfloat vertices[] = {
			0., 0.,
			512., 0.,
			0.,  512.,
			512.,  512.,
		};
		const GLshort texCoords[] = {
			0, 0,
			1, 0,
			0, 1,
			1, 1,
		};
		
		
		glBindTexture(GL_TEXTURE_2D, bgTexture);
		
		glVertexPointer(2, GL_FLOAT, 0, vertices);
		glTexCoordPointer(2, GL_SHORT, 0, texCoords);
		
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	}
	
	{
		// Draw our buttons
		const GLfloat vertices[] = {
			0., 0.,
			128, 0.,
			0.,  64,
			128,  64,
		};
		const GLshort texCoords[] = {
			0, 0,
			1, 0,
			0, 1,
			1, 1,
		};
		
		glPushMatrix();
		
		glVertexPointer(2, GL_FLOAT, 0, vertices);
		glTexCoordPointer(2, GL_SHORT, 0, texCoords);
        
		glTranslatef(5, 0, 0);
		//glBindTexture(GL_TEXTURE_2D, sonoTexture);
		//glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
		glTranslatef(250, 0, 0);
		glBindTexture(GL_TEXTURE_2D, mute ? muteOnTexture : muteOffTexture);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
		glTranslatef(99, 0, 0);
		glBindTexture(GL_TEXTURE_2D, (displayMode == aurioTouchDisplayModeOscilloscopeFFT) ? fftOnTexture : fftOffTexture);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
		
		glPopMatrix();
		
	}
	
	
	
	if (displayMode == aurioTouchDisplayModeOscilloscopeFFT)
	{
		if (fftBufferManager->HasNewAudioData())
		{
			if (fftBufferManager->ComputeFFT(l_fftData))
				[self setFFTData:l_fftData length:fftBufferManager->GetNumberFrames() / 2];
			else
				hasNewFFTData = NO;
		}
        
		if (hasNewFFTData)
		{
            
			int y, maxY;
			maxY = drawBufferLen;
			for (y=0; y<maxY; y++)
			{
				CGFloat yFract = (CGFloat)y / (CGFloat)(maxY - 1);
				CGFloat fftIdx = yFract * ((CGFloat)fftLength);
				
				double fftIdx_i, fftIdx_f;
				fftIdx_f = modf(fftIdx, &fftIdx_i);
				
				SInt8 fft_l, fft_r;
				CGFloat fft_l_fl, fft_r_fl;
				CGFloat interpVal;
				
				fft_l = (fftData[(int)fftIdx_i] & 0xFF000000) >> 24;
				fft_r = (fftData[(int)fftIdx_i + 1] & 0xFF000000) >> 24;
				fft_l_fl = (CGFloat)(fft_l + 80) / 64.;
				fft_r_fl = (CGFloat)(fft_r + 80) / 64.;
				interpVal = fft_l_fl * (1. - fftIdx_f) + fft_r_fl * fftIdx_f;
				
				interpVal = CLAMP(0., interpVal, 1.);
                
				drawBuffers[0][y] = (interpVal * 120);
				
			}
			cycleOscilloscopeLines();
			
		}
	}
	
	
	
	GLfloat *oscilLine_ptr;
	GLfloat max = drawBufferLen;
	SInt8 *drawBuffer_ptr;
	
	// Alloc an array for our oscilloscope line vertices
	if (resetOscilLine) {
		oscilLine = (GLfloat*)realloc(oscilLine, drawBufferLen * 2 * sizeof(GLfloat));
		resetOscilLine = NO;
	}
	
	glPushMatrix();
	
	// Translate to the left side and vertical center of the screen, and scale so that the screen coordinates
	// go from 0 to 1 along the X, and -1 to 1 along the Y
	glTranslatef(17., 182., 0.);
	glScalef(448., 116., 1.);
	
	// Set up some GL state for our oscilloscope lines
	glDisable(GL_TEXTURE_2D);
	glDisableClientState(GL_TEXTURE_COORD_ARRAY);
	glDisableClientState(GL_COLOR_ARRAY);
	glDisable(GL_LINE_SMOOTH);
	glLineWidth(2.);
	
	int drawBuffer_i;
	// Draw a line for each stored line in our buffer (the lines are stored and fade over time)
	for (drawBuffer_i=0; drawBuffer_i<kNumDrawBuffers; drawBuffer_i++)
	{
		if (!drawBuffers[drawBuffer_i]) continue;
		
		oscilLine_ptr = oscilLine;
		drawBuffer_ptr = drawBuffers[drawBuffer_i];
		
		GLfloat i;
		// Fill our vertex array with points
		for (i=0.; i<max; i=i+1.)
		{
			*oscilLine_ptr++ = i/max;
			*oscilLine_ptr++ = (Float32)(*drawBuffer_ptr++) / 128.;
		}
		
		// If we're drawing the newest line, draw it in solid green. Otherwise, draw it in a faded green.
		if (drawBuffer_i == 0)
			glColor4f(0., 1., 0., 1.);
		else
			glColor4f(0., 1., 0., (.24 * 0. *(1. - ((GLfloat)drawBuffer_i / (GLfloat)kNumDrawBuffers))));
		
		// Set up vertex pointer,
		glVertexPointer(2, GL_FLOAT, 0, oscilLine);
		
		// and draw the line.
		glDrawArrays(GL_LINE_STRIP, 0, drawBufferLen);
		
	}
	
	glPopMatrix();
    
	glPopMatrix();
}


- (void)cycleSpectrum
{
	SpectrumLinkedTexture *newFirst;
	newFirst = (SpectrumLinkedTexture *)calloc(1, sizeof(SpectrumLinkedTexture));
	newFirst->nextTex = firstTex;
	firstTex = newFirst;
	
	SpectrumLinkedTexture *thisTex = firstTex;
	do {
		if (!(thisTex->nextTex->nextTex))
		{
			firstTex->texName = thisTex->nextTex->texName;
			free(thisTex->nextTex);
			thisTex->nextTex = NULL;
		}
		thisTex = thisTex->nextTex;
	} while (thisTex);
}


- (void)renderFFTToTex
{
	[self cycleSpectrum];
	
	UInt32 *texBitBuffer_ptr = texBitBuffer;
	
	static int numLevels = sizeof(colorLevels) / sizeof(GLfloat) / 5;
	
	int y, maxY;
	maxY = CGRectGetHeight(spectrumRect);
	for (y=0; y<maxY; y++)
	{
		CGFloat yFract = (CGFloat)y / (CGFloat)(maxY - 1);
		CGFloat fftIdx = yFract * ((CGFloat)fftLength-1);
        
		double fftIdx_i, fftIdx_f;
		fftIdx_f = modf(fftIdx, &fftIdx_i);
		
		SInt8 fft_l, fft_r;
		CGFloat fft_l_fl, fft_r_fl;
		CGFloat interpVal;
		
		fft_l = (fftData[(int)fftIdx_i] & 0xFF000000) >> 24;
		fft_r = (fftData[(int)fftIdx_i + 1] & 0xFF000000) >> 24;
		fft_l_fl = (CGFloat)(fft_l + 80) / 64.;
		fft_r_fl = (CGFloat)(fft_r + 80) / 64.;
		interpVal = fft_l_fl * (1. - fftIdx_f) + fft_r_fl * fftIdx_f;
		
		interpVal = sqrt(CLAMP(0., interpVal, 1.));
        
		UInt32 newPx = 0xFF000000;
		
		int level_i;
		const GLfloat *thisLevel = colorLevels;
		const GLfloat *nextLevel = colorLevels + 5;
		for (level_i=0; level_i<(numLevels-1); level_i++)
		{
			if ( (*thisLevel <= interpVal) && (*nextLevel >= interpVal) )
			{
				double fract = (interpVal - *thisLevel) / (*nextLevel - *thisLevel);
				newPx =
				((UInt8)(255. * linearInterp(thisLevel[1], nextLevel[1], fract)) << 24)
				|
				((UInt8)(255. * linearInterp(thisLevel[2], nextLevel[2], fract)) << 16)
				|
				((UInt8)(255. * linearInterp(thisLevel[3], nextLevel[3], fract)) << 8)
				|
				(UInt8)(255. * linearInterp(thisLevel[4], nextLevel[4], fract))
				;
				break;
			}
			
			thisLevel+=5;
			nextLevel+=5;
		}
		
		*texBitBuffer_ptr++ = newPx;
	}
	
	glBindTexture(GL_TEXTURE_2D, firstTex->texName);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 512, 0, GL_RGBA, GL_UNSIGNED_BYTE, texBitBuffer);
	
	hasNewFFTData = NO;
}



- (void)drawSpectrum
{
	// Clear the view
	glClear(GL_COLOR_BUFFER_BIT);
	
	if (fftBufferManager->HasNewAudioData())
	{
		if (fftBufferManager->ComputeFFT(l_fftData))
		{
			[self setFFTData:l_fftData length:fftBufferManager->GetNumberFrames() / 2];
		}
		else
			hasNewFFTData = NO;
	}
	
	if (hasNewFFTData) [self renderFFTToTex];
	
	glClear(GL_COLOR_BUFFER_BIT);
	
	glEnable(GL_TEXTURE);
	glEnable(GL_TEXTURE_2D);
	
	glPushMatrix();
	glTranslatef(0., 480., 0.);
	glRotatef(-90., 0., 0., 1.);
	glTranslatef(spectrumRect.origin.x + spectrumRect.size.width, spectrumRect.origin.y, 0.);
	
	GLfloat quadCoords[] = {
		0., 0.,
		SPECTRUM_BAR_WIDTH, 0.,
		0., 512.,
		SPECTRUM_BAR_WIDTH, 512.,
	};
	
	GLshort texCoords[] = {
		0, 0,
		1, 0,
		0, 1,
		1, 1,
	};
	
	glVertexPointer(2, GL_FLOAT, 0, quadCoords);
	glEnableClientState(GL_VERTEX_ARRAY);
	glTexCoordPointer(2, GL_SHORT, 0, texCoords);
	glEnableClientState(GL_TEXTURE_COORD_ARRAY);
	
	glColor4f(1., 1., 1., 1.);
	
	SpectrumLinkedTexture *thisTex;
	glPushMatrix();
	for (thisTex = firstTex; thisTex; thisTex = thisTex->nextTex)
	{
		glTranslatef(-(SPECTRUM_BAR_WIDTH), 0., 0.);
		glBindTexture(GL_TEXTURE_2D, thisTex->texName);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	}
	glPopMatrix();
	glPopMatrix();
	
	glFlush();
	
}

- (void)drawView:(id)sender forTime:(NSTimeInterval)time
{
	if ((displayMode == aurioTouchDisplayModeOscilloscopeWaveform) || (displayMode == aurioTouchDisplayModeOscilloscopeFFT))
	{
		if (!initted_oscilloscope)
        [self setupViewForOscilloscope];
		[self drawOscilloscope];
	} else if (displayMode == aurioTouchDisplayModeSpectrum) {
		if (!initted_spectrum) [self setupViewForSpectrum];
		[self drawSpectrum];
	}
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
	// If we're if waveform mode and not currently in a pinch event, and we've got two touches, start a pinch event
	if ((!pinchEvent) && ([[event allTouches] count] == 2) && (self.displayMode == aurioTouchDisplayModeOscilloscopeWaveform))
	{
		pinchEvent = event;
		NSArray *t = [[event allTouches] allObjects];
		lastPinchDist = fabs([[t objectAtIndex:0] locationInView:_GLview].x - [[t objectAtIndex:1] locationInView:_GLview].x);
		
		sampleSizeText.text = [NSString stringWithFormat:@"%i ms", drawBufferLen / (int)(hwSampleRate / 1000.)];
		[_GLview addSubview:sampleSizeOverlay];
	}
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
	// If we are in a pinch event...
	if ((event == pinchEvent) && ([[event allTouches] count] == 2))
	{
		CGFloat thisPinchDist, pinchDiff;
		NSArray *t = [[event allTouches] allObjects];
		thisPinchDist = fabs([[t objectAtIndex:0] locationInView:_GLview].x - [[t objectAtIndex:1] locationInView:_GLview].x);
		
		// Find out how far we traveled since the last event
		pinchDiff = thisPinchDist - lastPinchDist;
		// Adjust our draw buffer length accordingly,
		drawBufferLen -= 12 * (int)pinchDiff;
		drawBufferLen = CLAMP(kMinDrawSamples, drawBufferLen, kMaxDrawSamples);
		resetOscilLine = YES;
		
		// and display the size of our oscilloscope window in our overlay view
		sampleSizeText.text = [NSString stringWithFormat:@"%i ms", drawBufferLen / (int)(hwSampleRate / 1000.)];
		
		lastPinchDist = thisPinchDist;
	}
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
	if (event == pinchEvent)
	{
		// If our pinch/zoom has ended, nil out the pinchEvent and remove the overlay view
		[sampleSizeOverlay removeFromSuperview];
		pinchEvent = nil;
		return;
	}
    
	// any tap in sonogram view will exit back to the waveform
	if (self.displayMode == aurioTouchDisplayModeSpectrum)
	{
		AudioServicesPlaySystemSound(buttonPressSound);
		self.displayMode = aurioTouchDisplayModeOscilloscopeWaveform;
		return;
	}
	
	UITouch *touch = [touches anyObject];
#if 0
	if (CGRectContainsPoint(CGRectMake(0., 5., 52., 99.), [touch locationInView:view])) // The Sonogram button was touched
	{
		AudioServicesPlaySystemSound(buttonPressSound);
		if ((self.displayMode == aurioTouchDisplayModeOscilloscopeWaveform) || (self.displayMode == aurioTouchDisplayModeOscilloscopeFFT))
		{
			if (!initted_spectrum) [self setupViewForSpectrum];
			[self clearTextures];
			self.displayMode = aurioTouchDisplayModeSpectrum;
		}
	}
#endif
	if (CGRectContainsPoint(CGRectMake(0., 255.+44, 52., 99.), [touch locationInView:_GLview])) // The Mute button was touched
	{
		AudioServicesPlaySystemSound(buttonPressSound);
		self.mute = !(self->mute);
		return;
	}
	else if (CGRectContainsPoint(CGRectMake(0., 354+44, 52., 99.), [touch locationInView:_GLview])) // The FFT button was touched
	{
		AudioServicesPlaySystemSound(buttonPressSound);
		self.displayMode = (self.displayMode == aurioTouchDisplayModeOscilloscopeWaveform) ?  aurioTouchDisplayModeOscilloscopeFFT :
        aurioTouchDisplayModeOscilloscopeWaveform;
		return;
	}
}


@end
