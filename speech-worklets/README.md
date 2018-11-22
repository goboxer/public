# Speech to text via Audio Worklets

This example exists because web browsers do not support the audio formats required by Google's Cloud Speech-to-Text API, see [Troubleshooting](https://cloud.google.com/speech-to-text/docs/support). However using [Audio Worklets](https://developers.google.com/web/updates/2017/12/audio-worklet) it is possible to take the raw audio PCM (Pulse-code modulation) buffer and convert this into a supported format. 

This example demonstrates client side PCM (Pulse-code modulation) audio recording with transcoding to FLAC (Free Lossless Audio Codec) and transcribing with Google's Cloud Speech-to-Text API.

## Credits

This example is mainly pulling together prior art from the following sources:

- [Recorder.js from Matt Diamond](https://github.com/mattdiamond/Recorderjs)
- [FLAC encoder compiled in JavaScript using emscripten](https://github.com/mmig/libflac.js)
- [Google Chrome Labs Samples](https://github.com/GoogleChromeLabs/web-audio-samples)
  - Classes for creating RingBuffer and InputBuffer

## Library code:

- [FLAC encoder compiled in JavaScript using emscripten](https://github.com/mmig/libflac.js)
  - Handles converting WAV PCM to FLAC
  - lib/libflac
- [A plugin for recording/exporting the output of Web Audio API nodes](https://github.com/mattdiamond/Recorderjs)
  - Handles interacting with the AudioContext, buffering, pauses etc
  - lib/recorder.js

## References

- [Speaking with a Webpage - Streaming speech transcripts](https://codelabs.developers.google.com/codelabs/speaking-with-a-webpage)
- [Google's Cloud Speech-to-Text API](https://cloud.google.com/speech-to-text/docs/support)
- [Web Audio API - ScriptProcessorNode](https://developer.mozilla.org/en-US/docs/Web/API/ScriptProcessorNode)
- [WAV PCM soundfile format](http://soundfile.sapp.org/doc/WaveFormat/)
- [Example for client-side encoding microphone audio into FLAC](https://github.com/mmig/speech-to-flac)
- [Opus & Wave Recorder](https://github.com/chris-rudmin/opus-recorder)
- [Local recording in Jitsi Meet](http://blog.radiumz.org/en/article/local-recording-jitsi-meet)
