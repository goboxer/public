import Module from './variable-buffer-kernel-wasmmodule.js';
import { HeapAudioBuffer, RingBuffer } from '/lib/wasm-audio-helper.js';

class MyWorkletProcessor extends AudioWorkletProcessor {

    constructor(options) {
        super(options)
        this._volume = 0
        this._silence_found = false
        this._updatingInterval = 50
        this._nextUpdateFrame = this.interval
        this._is_recording = options.is_recording ? options.is_recording : true
        this._kernelBufferSize = options.processorOptions.kernelBufferSize;
        this._channelCount = options.processorOptions.channelCount;

        // RingBuffers for input and output.
        this._inputRingBuffer =
            new RingBuffer(this._kernelBufferSize, this._channelCount);

        // For WASM memory, also for input and output.
        this._heapInputBuffer =
            new HeapAudioBuffer(Module, this._kernelBufferSize, this._channelCount);

        // WASM audio processing kernel.
        this._kernel = new Module.VariableBufferKernel(this._kernelBufferSize);

        this.port.onmessage = (event) => {
            // Handling data from the node.
            if (event.data.hasOwnProperty('updatingRecording')) {
                this._is_recording = event.data.updatingRecording;
            }
        };

        this.port.start();
    }

    get interval() {
        return this._updatingInterval / 1000 * sampleRate;
    }

    get recording() {
        return this._is_recording;
    }

    calculateVolume(buffer) {
        let previous_volume = this._volume
        const meterSmoothingFactor = 0.9
        const meterMinimum = 0.00001

        let bufferLength = buffer.length;
        let sum = 0, x = 0, rms = 0;
        // Calculated the squared-sum.
        for (let i = 0; i < bufferLength; ++i) {
            x = buffer[i];
            sum += x * x;
        }

        // Calculate the RMS level and update the volume.
        rms = Math.sqrt(sum / bufferLength);
        this._volume = Math.max(rms, this._volume * meterSmoothingFactor)

        // Update and sync the volume property with the main thread.
        this._nextUpdateFrame -= bufferLength;
        if (this._nextUpdateFrame < 0) {
            this._nextUpdateFrame += this.interval;
           
            if((previous_volume * 1000) > 1 && (this._volume * 1000) < 1){
                this._silence_found = true
            }
        }
    }

    process(inputs, outputs, parameters) {
        let input = inputs[0]

        if (input.length > 0) {
            let buffer = inputs[0][0]
            this.calculateVolume(buffer) 
        }

        // AudioWorkletProcessor always gets 128 frames in and 128 frames out. Here
        // we push 128 frames into the ring buffer.
        this._inputRingBuffer.push(input);

        // Process only if we have enough frames for the kernel.
        if (this._inputRingBuffer.framesAvailable >= this._kernelBufferSize || !this.recording || (this._silence_found && this.interval.framesAvailable >= 1024)) {

            // Get the queued data from the input ring buffer.
            this._inputRingBuffer.pull(this._heapInputBuffer.getChannelData());

            // This WASM process function can be replaced with ScriptProcessor's
            // |onaudioprocess| callback funciton. However, if the event handler
            // touches DOM in the main scope, it needs to be translated with the
            // async messaging via MessagePort.
            // this._kernel.process(this._heapInputBuffer.getHeapAddress(),
            //     this._heapOutputBuffer.getHeapAddress(),
            //     this._channelCount);



            this.port.postMessage({ output: this._heapInputBuffer.getChannelData() });
            if(this._silence_found){
                this.port.postMessage({ silence_found: true }); 
                this._silence_found = false
            }
        }

        return this.recording;
    }
}

registerProcessor('my-worklet-processor', MyWorkletProcessor) // eslint-disable-line no-undef