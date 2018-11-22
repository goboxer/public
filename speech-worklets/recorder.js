class Recorder {
    constructor(cfg) {
        let self = this
        this.config = cfg || {}
        if (!this.context) {
            this.context = new window.AudioContext()
        } else {
            this.context.resume()
        }
        this.recording = false
        this.wavEncoder
        this.context
        this.callbacks = {
            getBuffer: [],
            exportWAV: []
        }
    }

    startRecording() {
        if (!this.context) {
            this.context = new window.AudioContext()
        }

        this.context.audioWorklet.addModule('processor.js').then(() => {
            console.log('added worklet module')

            navigator.mediaDevices.getUserMedia({ audio: true, video: false })
                .then(stream => {
                    console.log('Have stream')
                    let microphone = this.context.createMediaStreamSource(stream)
                    this.wavEncoder = new AudioNode(this.context, {
                        updatingRecording: this.recording, processorOptions: {
                            kernelBufferSize: 4096,
                            channelCount: 1,
                        }
                    })
                    microphone.connect(this.wavEncoder).connect(this.context.destination)
                })
        })
            .catch((e) => {
                alert('Error getting audio')
                console.log(e)
            })
    }

    isRecording() {
        return this.recording
    }

    record() {
        console.log('Start recorder')
        this.recording = true
        this.startRecording()
    }

    stop() {
        console.log('Stop recorder')
        this.recording = false
        this.wavEncoder.port.postMessage({ updatingRecording: this.recording })
        // if (this.context) {
        //     this.context.close()
        // }
    }

    exportWAV(cb) {
        console.log('inside export wav')
        let mimeType = 'audio/wav'
        cb = cb || this.config.callback
        if (!cb) {
            throw new Error('Callback not set')
        }

        this.callbacks.exportWAV.push(cb)
        let blob = this.wavEncoder.exportWAV(mimeType, this.context.sampleRate)

        cb(blob)
    }
}

