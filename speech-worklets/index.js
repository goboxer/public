let recorder = new Recorder();
let translatedData = [];

function init() {
    if(GOOGLE_API_KEY.trim() === ""){
        document.getElementById("api_key").classList.remove('hidden')
        document.getElementById('input_api_key').addEventListener('paste', handlePaste);
    }
}

function clearScreen() {
    console.log('CLEAR')
    stop()
    document.getElementById("transcript").value = ""
    document.getElementById("confidence").innerHTML = ""
    document.getElementById("list").innerHTML = ""
}

function updateAPIKey(e) {
    GOOGLE_API_KEY = e.value;
    console.log(GOOGLE_API_KEY)
}

function handlePaste(e) {
    var clipboardData, pastedData;

    // Get pasted data via clipboard API
    clipboardData = e.clipboardData || window.clipboardData;
    pastedData = clipboardData.getData('Text');
 
    // copy pasedData to api key
   GOOGLE_API_KEY = pastedData;
   console.log(GOOGLE_API_KEY)
}

function record() {
    if (!recorder) {
        recorder = new Recorder()
    }

    if (!recorder.isRecording()) {
        recorder.record()
        document.getElementById('recording_icon').classList.add('disabled')
        document.getElementById('stop_icon').classList.remove('disabled')
    }
}

function stop() {
    if (recorder.isRecording()) {
        recorder.stop()
        outputFromOptions()
        document.getElementById('recording_icon').classList.remove('disabled')
        document.getElementById('stop_icon').classList.add('disabled')
    }
}

function outputFromOptions() {
    let outputs = document.querySelectorAll('input[name=output]:checked');
    if (outputs.length === 2) {
        //both options are selected
        createDownloadAndTranscript()
    } else {
        for (var i = 0; i < outputs.length; ++i) {
            if (outputs[i].type == "checkbox" && outputs[i].checked) {
                if (outputs[i].value === "file") {
                    createDownloadLink()
                }
                if (outputs[i].value === "transcript") {
                    createTranscript()
                }
            }
        }
    }

}

function createDownloadAndTranscript() {
    console.log("CREATE DOWNLOAD FILE AND TRANSCRIPT")
    let that = this
    recorder && recorder.exportWAV(function (blob) {
        createDownloadFromBlob(blob)
        crateTranscriptFromBlob(blob)
    })
}

function createDownloadLink() {
    console.log("CREATE DOWNLOAD FILE")
    let that = this
    recorder && recorder.exportWAV(function (blob) {
        createDownloadFromBlob(blob)
    })
}

function createDownloadFromBlob(blob) {
    console.log('CREATE BLOB DOWNLOAD')
    console.log(blob)

    var url = URL.createObjectURL(blob)
    var li = document.createElement('li')
    var au = document.createElement('audio')
    var hf = document.createElement('a')

    au.controls = true
    au.src = url
    hf.href = url
    hf.download = new Date().toISOString() + '.wav'
    hf.innerHTML = hf.download
    li.appendChild(au)
    li.appendChild(hf)
    document.getElementById("list").appendChild(li)
}

function createTranscript() {

    recorder && recorder.exportWAV(function (blob) {
        crateTranscriptFromBlob(blob)
    })
}

function crateTranscriptFromBlob(blob) {
    console.log('CREATE TRANSCRIPT')
    let that = this

    let reader = new FileReader()
    reader.onload = function (event) {

        let arrayBuffer = event.target.result

        var encData = []
        var result = encodeFlac(arrayBuffer, encData, false);

        var base64Reader = new FileReader()
        base64Reader.onload = function () {
            let base64data = base64Reader.result
            // Will need to strip the prefix 'data:audio/flac;base64,'
            // -> data:audio/flac;base64,ZkxhQwAAACIQABAA...
            let encoded = base64data.replace(/^data:(.*;base64,)?/, '')
            if ((encoded.length % 4) > 0) {
                encoded += '='.repeat(4 - (encoded.length % 4))
            }
            that.postSpeech(encoded)
        }
        base64Reader.readAsDataURL(new Blob(encData, { type: 'audio/flac' }))
    }
    reader.readAsArrayBuffer(blob)
}

function postSpeech(audioObject) {
    let translation_number = translatedData.length
    translatedData.push({translation_number:translation_number, data:{}})
    
    var start = new Date()
    console.log('POST SPEECH')
    axios.post(`https://speech.googleapis.com/v1p1beta1/speech:recognize?key=` + GOOGLE_API_KEY, {
        'config': {
            encoding: 'FLAC',
            languageCode: 'en'
        },
        'audio': {
            'content': audioObject
        }
    },
        {
            'headers': {
                'Content-Type': 'application/json; charset=utf-8'
            }
        })
        .then(function (response) {
            console.log(response)

            var result = translatedData.filter(obj => {
                return obj.translation_number === translation_number
              })

              result[0].data = response.data

            processResponse()
            var end = new Date()
            var diff = (end - start) / 1000
            console.log('Speech request latency in seconds', diff)
        })
        .catch(function (error) {
            console.log(error)
        })
}

function processResponse() {
    try {

        document.getElementById("transcript").value = ""

        for(var x=0; x < translatedData.length; x++){
            if(translatedData[x].data.results){
                for(var i=0; i < translatedData[x].data.results.length; ++i){
                    let v = document.getElementById("transcript").value.trim() === "" ? translatedData[x].data.results[i].alternatives[0].transcript : document.getElementById("transcript").value.trim() + '\n' + translatedData[x].data.results[i].alternatives[0].transcript
                    document.getElementById("transcript").value = v
                    document.getElementById("transcript").value.trim() 
                    document.getElementById("confidence").innerHTML = 'Confidence ' + translatedData[x].data.results[i].alternatives[0].confidence
                }
            } 
        }
        

    } catch (err) {
        console.log(err)
    }
}