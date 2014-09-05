/*----------------------------------------------------------------------------
  MoMu: A Mobile Music Toolkit
  Copyright (c) 2010 Nicholas J. Bryan, Jorge Herrera, Jieun Oh, and Ge Wang
  All rights reserved.
    http://momu.stanford.edu/toolkit/
 
  Mobile Music Research @ CCRMA
  Music, Computing, Design Group
  Stanford University
    http://momu.stanford.edu/
    http://ccrma.stanford.edu/groups/mcd/
 
 MoMu is distributed under the following BSD style open source license:
 
 Permission is hereby granted, free of charge, to any person obtaining a 
 copy of this software and associated documentation files (the
 "Software"), to deal in the Software without restriction, including
 without limitation the rights to use, copy, modify, merge, publish,
 distribute, sublicense, and/or sell copies of the Software, and to
 permit persons to whom the Software is furnished to do so, subject to
 the following conditions:
 
 The authors encourage users of MoMu to include this copyright notice,
 and to let us know that you are using MoMu. Any person wishing to 
 distribute modifications to the Software is encouraged to send the 
 modifications to the original authors so that they can be incorporated 
 into the canonical version.
 
 The Software is provided "as is", WITHOUT ANY WARRANTY, express or implied,
 including but not limited to the warranties of MERCHANTABILITY, FITNESS
 FOR A PARTICULAR PURPOSE and NONINFRINGEMENT.  In no event shall the authors
 or copyright holders by liable for any claim, damages, or other liability,
 whether in an actino of a contract, tort or otherwise, arising from, out of
 or in connection with the Software or the use or other dealings in the 
 software.
 -----------------------------------------------------------------------------*/
//-----------------------------------------------------------------------------
// name: mo_audio.cpp
// desc: MoPhO audio layer
//       - adapted from the smule audio layer & library (SMALL)
//         (see original header below)
//
// authors: Ge Wang (ge@ccrma.stanford.edu | ge@smule.com)
//          Spencer Salazar (spencer@smule.com)
//    date: October 2009
//    version: 1.0.0
//
// Mobile Music research @ CCRMA, Stanford University:
//     http://momu.stanford.edu/
//-----------------------------------------------------------------------------
//-----------------------------------------------------------------------------
// name: small.cpp (original)
// desc: the smule audio layer & library (SMALL)
//
// created by Ge Wang on 6/27/2008
// re-implemented using Audio Unit Remote I/O on 8/12/2008
// updated for iPod Touch by Spencer Salazar and Ge wang on 8/10/2009
//-----------------------------------------------------------------------------
#include "mo_audio.h"
#include <AudioToolbox/AudioToolbox.h>


// static member initialization
bool MoAudio::m_hasInit = false;
bool MoAudio::m_isRunning = false;
bool MoAudio::m_isMute = false;
bool MoAudio::m_handleInput = false;
Float64 MoAudio::m_srate = 44100.0;
Float64 MoAudio::m_hwSampleRate = 44100.0;
UInt32 MoAudio::m_frameSize = 0;
UInt32 MoAudio::m_numChannels = 1; //2;
AudioUnit MoAudio::m_au;
MoAudioUnitInfo * MoAudio::m_info = NULL;
MoCallback MoAudio::m_callback = NULL;
// Float32 * MoAudio::m_buffer = NULL;
// UInt32 MoAudio::m_bufferFrames = 2048;
AURenderCallbackStruct MoAudio::m_renderProc;
void * MoAudio::m_bindle = NULL;

bool MoAudio::builtIntAEC_Enabled = false;

// number of buffers
#define MO_DEFAULT_NUM_BUFFERS   3
#define SAMPLE_RATE 44100  //22050 //44100
#define FRAMESIZE  512
#define NUMCHANNELS 2

#define kOutputBus 0
#define kInputBus 1






//__weak UILabel *labelToUpdate = nil;







// prototypes
bool setupRemoteIO( AudioUnit & inRemoteIOUnit, AURenderCallbackStruct inRenderProc,
                   AudioStreamBasicDescription & outFormat, OSType componentSubType);


//-----------------------------------------------------------------------------
// name: silenceData()
// desc: zero out a buffer list of audio data
//-----------------------------------------------------------------------------
void silenceData( AudioBufferList * inData )
{
    for( UInt32 i = 0; i < inData->mNumberBuffers; i++ )
        memset( inData->mBuffers[i].mData, 0, inData->mBuffers[i].mDataByteSize );
}







//bool MoAudio::init( Float64 srate, UInt32 frameSize, UInt32 numChannels )
bool MoAudio::init( Float64 srate, UInt32 frameSize, UInt32 numChannels, bool enableBuiltInAEC )
{
    
    MoAudio::builtIntAEC_Enabled = enableBuiltInAEC;
    
    // sanity check
    if( m_hasInit )
    {
        // TODO: error message
        NSLog(@" error = hasInit ");
        return false;
    }
    
    // TODO: fix this
    //    assert( numChannels == 2 );
    
    // set audio unit callback
       // allocate info
    m_info = new MoAudioUnitInfo();
    
    // set the desired data format
    m_info->m_dataFormat.mSampleRate = srate;
    m_info->m_dataFormat.mFormatID = kAudioFormatLinearPCM;
    m_info->m_dataFormat.mChannelsPerFrame = numChannels;
    m_info->m_dataFormat.mBitsPerChannel = 32;
    m_info->m_dataFormat.mBytesPerPacket = m_info->m_dataFormat.mBytesPerFrame =
    m_info->m_dataFormat.mChannelsPerFrame * sizeof(SInt32);
    m_info->m_dataFormat.mFramesPerPacket = 1;
    m_info->m_dataFormat.mReserved = 0;
    m_info->m_dataFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger;
    m_info->m_done = 0;
    
    // bound parameters
    if( frameSize > m_info->m_bufferSize )
        frameSize = m_info->m_bufferSize;
    
    //    if( numChannels != 2 )
    //        numChannels = 2;
    
    // copy parameters
    m_srate = srate;
    m_frameSize = frameSize;
    m_numChannels = numChannels;
       // initialize buffer
    m_info->m_ioBuffer = new Float32[m_info->m_bufferSize * m_numChannels];
    // make sure
    if( !m_info->m_ioBuffer )
    {
        // TODO: "couldn't allocate memory for I/O buffer"
        NSLog(@" error = couldn't allocate memory for I/O buffer");
        return false;
    }
    
        
    // done with initialization
    m_hasInit = true;
    
    return true;
}
bool MoAudio::start( MoCallback callback, void * bindle )
{
    // assert
    assert( callback != NULL );
    
    // sanity check
    if( !m_hasInit )
    {
        // TODO: error message
        return false;
    }
    
    // sanity check 2
    if( m_isRunning )
    {
        // TODO: warning message
        return false;
    }
    
    // remember the callback
    m_callback = callback;
    // remember the bindle
    m_bindle = bindle;
    
    // status code
    OSStatus err;
    
    // start audio unit
    err = AudioOutputUnitStart( m_au );
    if( err )
    {
        // TODO: "couldn't start audio unit...\n" );
        return false;
    }
    
    // started
    m_isRunning = true;
    
    return true;
}




