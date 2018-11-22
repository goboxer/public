class AudioNode extends AudioWorkletNode {
  constructor(context, options) {
    // Setting default values for the input, the output and the channel count.
    options.numberOfInputs = 1
    options.numberOfOutputs = 1
    options.channelCount = 1
    options.updatingInterval = 100
    options.updatingRecording = options.hasOwnProperty('updatingRecording') ? options.updatingRecording : true

    super(context, 'my-worklet-processor', options)
    // States in AudioWorkletNode
    this._updatingInterval = options.updatingInterval
    this._channelCount = options.channelCount
    this._is_recording = options.updatingRecording
    this._recBuffers = []
    this._recLength = 0
  
    // Handles updated values from AudioWorkletProcessor
    this.port.onmessage = event => {
     
      if (event.data.output) {
        if(this._recBuffers.length === 0){
          this._recBuffers[0] = []
        }
      
        this._recBuffers[0].push(event.data.output[0])
        this._recLength += event.data.output[0].length

      }
      if (event.data.silence_found) {
        console.log('silence found')
        console.log(this._recLength)
          if(this._recLength > 50000){
            outputFromOptions() 
          }
      }
    }

    this.port.start();
  }

  get updatingRecording() {
    console.log('get isRecording')
    return this._is_recording;
  }
  set updatingRecording(internal_value) {
    console.log('set is_recording')
    console.log(internal_value)
    this._is_recording = internal_value
    this.port.postMessage({ is_recording: internal_value })
  }

  exportWAV(type, sampleRate) {
    let buffers = []
    let recBuffers = this._recBuffers[0]
    let recLength = this._recLength
    this._recBuffers[0] = []
    this._recLength = 0
    buffers.push(this.mergeBuffers(recBuffers, recLength)) 
    let dataview = this.encodeWAV(buffers[0], sampleRate);
    let audioBlob = new Blob([dataview], { type: type });
    return audioBlob
  }

  mergeBuffers(recBuffers, recLength) {
    let result = new Float32Array(recLength)
    let offset = 0
    for (let i = 0; i < recBuffers.length; i++) {
      result.set(recBuffers[i], offset)
      offset += recBuffers[i].length
    }
    return result
  }

  encodeWAV(samples, sampleRate) {
    let buffer = new ArrayBuffer(44 + samples.length * 2);
    let view = new DataView(buffer);

    /* RIFF identifier */
    this.writeString(view, 0, 'RIFF');
    /* RIFF chunk length */
    view.setUint32(4, 36 + samples.length * 2, true);
    /* RIFF type */
    this.writeString(view, 8, 'WAVE');
    /* format chunk identifier */
    this.writeString(view, 12, 'fmt ');
    /* format chunk length */
    view.setUint32(16, 16, true);
    /* sample format (raw) */
    view.setUint16(20, 1, true);
    /* channel count */
    view.setUint16(22, this._channelCount, true);
    /* sample rate */
    view.setUint32(24, sampleRate, true);
    /* byte rate (sample rate * block align) */
    view.setUint32(28, sampleRate * 4, true);
    /* block align (channel count * bytes per sample) */
    view.setUint16(32, this._channelCount * 2, true);
    /* bits per sample */
    view.setUint16(34, 16, true);
    /* data chunk identifier */
    this.writeString(view, 36, 'data');
    /* data chunk length */
    view.setUint32(40, samples.length * 2, true);

    this.floatTo16BitPCM(view, 44, samples);

    return view;
  }

  writeString(view, offset, string) {
    for (var i = 0; i < string.length; i++) {
      view.setUint8(offset + i, string.charCodeAt(i));
    }
  }

  floatTo16BitPCM(output, offset, input) {
    for (var i = 0; i < input.length; i++ , offset += 2) {
      var s = Math.max(-1, Math.min(1, input[i]));
      output.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7FFF, true);
    }
  }

}